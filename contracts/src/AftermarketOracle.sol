// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IAftermarketOracle} from "./interfaces/IAftermarketOracle.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";
import {ITradingCalendar} from "./interfaces/ITradingCalendar.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {Quote, Session, Verdict} from "./libraries/Types.sol";

/// @notice Immutable deployment parameters for one `AftermarketOracle` instance.
/// @dev Passed whole so the factory can hash it into a CREATE2 salt: one config, one address.
/// @param collateralToken        B20 tokenized equity used as Morpho collateral.
/// @param loanToken              Loan-side asset of the Morpho market. Assumed USD-denominated.
/// @param feed                   Chainlink total-return aggregator for the underlying equity.
/// @param pool                   Aerodrome Slipstream pool holding `collateralToken` and `loanToken`.
/// @param calendar               `ITradingCalendar` describing the US equity session.
/// @param multiplierRegistry     Optional issuer pause registry exposing `paused()`. Zero disables the probe.
/// @param twapWindow             Seconds of Slipstream TWAP used for the corroborating mark.
/// @param stalenessBudget        Per-`Session` feed age tolerance, in seconds.
/// @param divergenceBandBps      Per-`Session` anchor/pool disagreement tolerance, in bps.
/// @param baseHaircutBps         Gap haircut applied the moment the regular session ends.
/// @param haircutSlopeBpsPerHour Additional haircut per whole hour the market stays shut.
/// @param maxHaircutBps          Ceiling on the gap haircut. Must be below `10_000`.
/// @param minPoolLiquidityUsd    Loan-side pool depth, 1e18 USD, below which the pool cannot corroborate.
/// @param minMultiplier          Lower bound on the B20 `multiplier()`, WAD.
/// @param maxMultiplier          Upper bound on the B20 `multiplier()`, WAD.
/// @dev The multiplier bounds are a garbage filter, not a corporate-action detector, and they are
///      configured wide on purpose. A static range detects a LEVEL and never a CHANGE, so it cannot
///      distinguish a 10:1 split from a 10x total return, and narrowing it does not buy safety - it
///      buys an outage. `minMultiplier` at 0.5e18 puts a routine 1:5 reverse split outside the band
///      and halts that asset's oracle PERMANENTLY, for every holder, with no owner and no setter
///      anywhere in this contract to widen it again. The brake that actually belongs on a
///      corporate action is a size cap on what may be sold in response to one, and it lives in
///      `AftermarketCredit.sweepYield` where the selling happens.
struct OracleConfig {
    address collateralToken;
    address loanToken;
    address feed;
    address pool;
    address calendar;
    address multiplierRegistry;
    uint32 twapWindow;
    uint32[6] stalenessBudget;
    uint16[6] divergenceBandBps;
    uint16 baseHaircutBps;
    uint16 haircutSlopeBpsPerHour;
    uint16 maxHaircutBps;
    uint128 minPoolLiquidityUsd;
    uint128 minMultiplier;
    uint128 maxMultiplier;
}

/// @title  AftermarketOracle
/// @notice A session-aware price oracle for Coinbase B20 tokenized US equities on Base.
///
/// @dev ## The problem
///
/// A B20 equity token trades 24/7 on Base. Its Chainlink reference feed does not: `updatedAt` freezes
/// at the closing print and stays frozen through the night, the weekend and every exchange holiday.
/// Over a normal weekend the reference is roughly 64 hours old while the onchain pool keeps printing
/// new prices against it. Chainlink's own guidance is to never settle or liquidate against a frozen
/// feed, and yet a naive `latestRoundData()` oracle does exactly that.
///
/// ## The response
///
/// This oracle fuses four sources - the Chainlink anchor, an Aerodrome Slipstream TWAP, the B20
/// `multiplier()` corporate-action signal, and an onchain trading calendar - into a single `Verdict`
/// plus two deliberately asymmetric marks. When the verdict is untrusted, `price()` reverts.
///
/// Reverting is the product. Morpho Blue reads `IOracle.price()` in exactly three places - `borrow`,
/// `withdrawCollateral` and `liquidate` - and never in `supply`, `withdraw`, `repay`,
/// `supplyCollateral` or `flashLoan`. A reverting oracle therefore freezes new borrowing, freezes
/// collateral withdrawal and freezes liquidation, while leaving repayment and collateral top-up wide
/// open. The borrower can always cure; nobody can seize. That behaviour is inherited from Morpho's own
/// audited code - this contract only supplies the truth function.
///
/// ## The two marks
///
/// - `markBorrow    = min(anchor, pool) * (1 - haircut)`: it must be hard to over-borrow against a
///   price nobody can currently verify.
/// - `markLiquidate = max(anchor, pool) * (1 + haircut)`: it must be equally hard to seize somebody's
///   collateral on that same unverifiable price.
///
/// The haircut widens with every hour the market stays shut, because that is exactly how gap risk
/// accumulates: the longer the reference has been frozen, the further the next open can be from it.
///
/// `price()` hands Morpho the pessimistic mark. A Morpho market carries a single immutable LLTV and a
/// single price hook, so session-dependent risk cannot be expressed by moving the LLTV - it has to be
/// expressed by moving the mark, and at that single hook we take the lender-conservative side. The
/// full asymmetry lives in Aftermarket's own credit contract, which controls both call sites and can
/// read `markBorrow()` and `markLiquidate()` independently.
///
/// ## A limitation worth publishing: the staleness budgets are per session, not per print
///
/// `stalenessBudget` is indexed by the session the query lands in and compared against
/// `block.timestamp - updatedAt`. A Coinbase equity feed only prints during the REGULAR session, so
/// the feed's age at the *start* of any other session is already the distance back to the previous
/// 16:00 close. At the shipped configuration the two do not line up, and they cannot be made to
/// without abandoning the per-session table:
///
/// | session                       | budget | feed age when the session begins   | verdict          |
/// |-------------------------------|--------|------------------------------------|------------------|
/// | PRE (04:00-09:30 ET)          | 6h     | 12h, rising to 17.5h               | always stale     |
/// | CLOSED_OVERNIGHT, Mon 00:00-04:00 | 25h | 56h, since Friday's close         | always stale     |
///
/// That is roughly 19% of every week in which this oracle refuses to mark, and therefore in which
/// `flag`, `cure`, `liquidate`, `draw` and a debt-bearing `withdrawCollateral` all revert for every
/// user of every asset. It is a *freeze*, not an exposure: nothing can be seized and nothing can be
/// over-borrowed, and `repay` and `depositCollateral` read no oracle at all, so the borrower's exit
/// is never affected.
///
/// It is left as it is, deliberately. Widening the PRE and POST budgets to cover the overnight gap
/// would make those sessions mark collateral against a print that is up to seventeen hours old - the
/// exact thing the staleness rule exists to prevent - and would do it during sessions the credit
/// engine already treats as closed, so the only new capability it would buy is the ability to start
/// a grace clock a few hours earlier. The cost of leaving it is that the one keeper-favourable flag
/// window (PRE, where `nextOpen` is *today's* bell, so a flag there would expire the same morning)
/// is unusable, and every flag therefore defers to the following trading day. An operator who wants
/// that window can raise `stalenessBudgetSeconds[1]` and `[2]` past 20 hours in the deployment
/// config without touching this contract; it is a risk decision, and it should be taken explicitly.
///
/// The contract is immutable: no owner, no upgrade path, no setters. Every external read is a
/// `staticcall` whose failure degrades the verdict instead of bricking the oracle, so `peek()` never
/// reverts and keepers and UIs always get an answer.
contract AftermarketOracle is IAftermarketOracle {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice A required constructor address was zero.
    error ZeroAddress();
    /// @notice `twapWindow` was zero, or longer than `MAX_TWAP_WINDOW`.
    error InvalidTwapWindow(uint32 window);
    /// @notice The pool does not hold exactly the collateral and loan tokens.
    error PoolTokenMismatch(address token0, address token1);
    /// @notice Collateral, loan or feed decimals exceed 18.
    error UnsupportedDecimals(uint8 tokenDecimals);
    /// @notice `baseHaircutBps > maxHaircutBps`, or `maxHaircutBps >= 10_000`.
    error InvalidHaircutConfig();
    /// @notice Multiplier bounds are inverted, zero, or exclude the token multiplier at deploy time.
    error InvalidMultiplierBounds(uint256 lowerBound, uint256 upperBound, uint256 current);
    /// @notice A divergence band was configured at or above 100%.
    error InvalidDivergenceBand(uint16 bandBps);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice One unit of 1e18 fixed point.
    uint256 internal constant WAD = 1e18;
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;
    /// @notice Longest TWAP window accepted at construction.
    uint32 internal constant MAX_TWAP_WINDOW = 7 days;
    /// @notice Prices above 1e12 USD per whole token are treated as garbage rather than trusted.
    /// @dev Also the ceiling that keeps every downstream multiplication inside `uint256`.
    uint256 internal constant MAX_PRICE_WAD = 1e30;
    /// @notice Number of entries in `Session`.
    uint256 internal constant SESSION_COUNT = 6;

    /// @dev `IB20Asset.multiplier()`.
    bytes4 internal constant MULTIPLIER_SELECTOR = bytes4(keccak256("multiplier()"));
    /// @dev `IB20.isPaused(PausableFeature)`; `PausableFeature.TRANSFER` is ordinal 0.
    bytes4 internal constant IS_PAUSED_SELECTOR = bytes4(keccak256("isPaused(uint8)"));
    /// @dev `Pausable.paused()`, probed on the optional issuer registry.
    bytes4 internal constant PAUSED_SELECTOR = bytes4(keccak256("paused()"));

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAftermarketOracle
    address public immutable collateralToken;
    /// @inheritdoc IAftermarketOracle
    address public immutable loanToken;
    /// @inheritdoc IAftermarketOracle
    address public immutable feed;
    /// @inheritdoc IAftermarketOracle
    address public immutable pool;
    /// @inheritdoc IAftermarketOracle
    address public immutable calendar;

    /// @notice Optional issuer pause registry. Zero when no registry is wired up.
    address public immutable multiplierRegistry;
    /// @notice Seconds of Slipstream TWAP used for the corroborating mark.
    uint32 public immutable twapWindow;
    /// @notice Gap haircut applied the moment the regular session ends, in bps.
    uint16 public immutable baseHaircutBps;
    /// @notice Additional gap haircut per whole hour the market stays shut, in bps.
    uint16 public immutable haircutSlopeBpsPerHour;
    /// @notice Ceiling on the gap haircut, in bps.
    uint16 public immutable maxHaircutBps;
    /// @notice Loan-side pool depth below which the pool cannot corroborate the feed, 1e18 USD.
    uint128 public immutable minPoolLiquidityUsd;
    /// @notice Lower bound on the B20 multiplier, WAD.
    uint128 public immutable minMultiplier;
    /// @notice Upper bound on the B20 multiplier, WAD.
    uint128 public immutable maxMultiplier;
    /// @notice True when the collateral answered `multiplier()` at deploy time and is therefore policed.
    bool public immutable tracksMultiplier;
    /// @notice True when `collateralToken` is the pool `token0`.
    bool public immutable collateralIsToken0;

    /// @dev Six `uint32` staleness budgets packed little-endian, `Session` ordinal `i` at bit `32 * i`.
    uint256 internal immutable _stalenessPacked;
    /// @dev Six `uint16` divergence bands packed little-endian, `Session` ordinal `i` at bit `16 * i`.
    uint256 internal immutable _bandPacked;
    /// @dev `10 ** (18 - feedDecimals)`; turns a raw feed answer into a WAD USD price.
    uint256 internal immutable _anchorScale;
    /// @dev `10 ** collateralDecimals`.
    uint256 internal immutable _collateralUnit;
    /// @dev `10 ** loanDecimals`.
    uint256 internal immutable _loanUnit;
    /// @dev `10 ** (18 + loanDecimals - collateralDecimals)`; turns a WAD mark into the Morpho scale.
    uint256 internal immutable _morphoScale;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param cfg Full immutable configuration. See `OracleConfig`.
    constructor(OracleConfig memory cfg) {
        if (
            cfg.collateralToken == address(0) || cfg.loanToken == address(0) || cfg.feed == address(0)
                || cfg.pool == address(0) || cfg.calendar == address(0)
        ) revert ZeroAddress();
        if (cfg.twapWindow == 0 || cfg.twapWindow > MAX_TWAP_WINDOW) revert InvalidTwapWindow(cfg.twapWindow);
        if (cfg.baseHaircutBps > cfg.maxHaircutBps || cfg.maxHaircutBps >= BPS) revert InvalidHaircutConfig();
        if (cfg.minMultiplier == 0 || cfg.minMultiplier > cfg.maxMultiplier) {
            revert InvalidMultiplierBounds(cfg.minMultiplier, cfg.maxMultiplier, 0);
        }

        collateralToken = cfg.collateralToken;
        loanToken = cfg.loanToken;
        feed = cfg.feed;
        pool = cfg.pool;
        calendar = cfg.calendar;
        multiplierRegistry = cfg.multiplierRegistry;
        twapWindow = cfg.twapWindow;
        baseHaircutBps = cfg.baseHaircutBps;
        haircutSlopeBpsPerHour = cfg.haircutSlopeBpsPerHour;
        maxHaircutBps = cfg.maxHaircutBps;
        minPoolLiquidityUsd = cfg.minPoolLiquidityUsd;
        minMultiplier = cfg.minMultiplier;
        maxMultiplier = cfg.maxMultiplier;

        // Token ordering is detected once. The collateral may sit on either side of the pool.
        address t0 = ICLPool(cfg.pool).token0();
        address t1 = ICLPool(cfg.pool).token1();
        bool collIs0 = t0 == cfg.collateralToken && t1 == cfg.loanToken;
        bool collIs1 = t1 == cfg.collateralToken && t0 == cfg.loanToken;
        if (!collIs0 && !collIs1) revert PoolTokenMismatch(t0, t1);
        collateralIsToken0 = collIs0;
        // A real Slipstream pool always reports a positive tick spacing; a look-alike will not.
        if (ICLPool(cfg.pool).tickSpacing() <= 0) revert PoolTokenMismatch(t0, t1);

        uint8 collateralDecimals = IERC20Metadata(cfg.collateralToken).decimals();
        uint8 loanDecimals = IERC20Metadata(cfg.loanToken).decimals();
        uint8 feedDecimals = IAggregatorV3(cfg.feed).decimals();
        if (collateralDecimals > 18) revert UnsupportedDecimals(collateralDecimals);
        if (loanDecimals > 18) revert UnsupportedDecimals(loanDecimals);
        if (feedDecimals > 18) revert UnsupportedDecimals(feedDecimals);

        _collateralUnit = 10 ** uint256(collateralDecimals);
        _loanUnit = 10 ** uint256(loanDecimals);
        _anchorScale = 10 ** uint256(18 - feedDecimals);
        // Morpho quotes `10 ** collateralDecimals` of collateral in `10 ** loanDecimals` of loan token,
        // scaled by 1e36. Starting from a WAD USD price that reduces to a single power of ten, and the
        // exponent is always non-negative because both token decimals are capped at 18.
        _morphoScale = 10 ** uint256(18 + loanDecimals - collateralDecimals);

        uint256 stalenessPacked;
        uint256 bandPacked;
        for (uint256 i = 0; i < SESSION_COUNT; ++i) {
            if (cfg.divergenceBandBps[i] >= BPS) revert InvalidDivergenceBand(cfg.divergenceBandBps[i]);
            stalenessPacked |= uint256(cfg.stalenessBudget[i]) << (32 * i);
            bandPacked |= uint256(cfg.divergenceBandBps[i]) << (16 * i);
        }
        _stalenessPacked = stalenessPacked;
        _bandPacked = bandPacked;

        // Probe the corporate-action surface once. A collateral token that answers `multiplier()` is
        // policed forever after, and a later failure to answer is treated as a halt. A token that does
        // not expose one is never policed, so the oracle also works over plain ERC-20 collateral.
        (bool ok, uint256 current) = _staticcallWord(cfg.collateralToken, abi.encodeWithSelector(MULTIPLIER_SELECTOR));
        if (ok && (current < cfg.minMultiplier || current > cfg.maxMultiplier)) {
            revert InvalidMultiplierBounds(cfg.minMultiplier, cfg.maxMultiplier, current);
        }
        tracksMultiplier = ok;
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIG READERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Feed age tolerated during `session`, in seconds.
    function stalenessBudget(Session session) public view returns (uint256) {
        return uint32(_stalenessPacked >> (32 * uint256(session)));
    }

    /// @notice Anchor/pool disagreement tolerated during `session`, in bps.
    function divergenceBand(Session session) public view returns (uint256) {
        return uint16(_bandPacked >> (16 * uint256(session)));
    }

    /*//////////////////////////////////////////////////////////////
                              ORACLE READS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAftermarketOracle
    function peek() external view returns (Quote memory q) {
        (q,,) = _read();
    }

    /// @inheritdoc IAftermarketOracle
    function price() external view returns (uint256) {
        (Quote memory q, int256 rawAnswer, bool feedOk) = _read();
        _enforce(q, rawAnswer, feedOk);
        return q.markBorrow;
    }

    /// @inheritdoc IAftermarketOracle
    function markBorrow() external view returns (uint256) {
        (Quote memory q, int256 rawAnswer, bool feedOk) = _read();
        _enforce(q, rawAnswer, feedOk);
        return q.markBorrow;
    }

    /// @inheritdoc IAftermarketOracle
    function markLiquidate() external view returns (uint256) {
        (Quote memory q, int256 rawAnswer, bool feedOk) = _read();
        _enforce(q, rawAnswer, feedOk);
        return q.markLiquidate;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Translates an untrusted verdict into the matching typed revert. No-op when trusted.
    function _enforce(Quote memory q, int256 rawAnswer, bool feedOk) internal view {
        if (q.verdict == Verdict.TRUSTED || q.verdict == Verdict.TRUSTED_CLOSED) return;
        if (!feedOk) revert InvalidFeedAnswer(rawAnswer);
        if (q.verdict == Verdict.UNTRUSTED_HALTED) revert MarketHalted(q.multiplier);
        if (q.verdict == Verdict.UNTRUSTED_STALE) revert StaleFeed(q.session, q.feedAge, q.stalenessBudget);
        if (q.verdict == Verdict.UNTRUSTED_THIN) revert PoolTooThin(q.poolLiquidityUsd, minPoolLiquidityUsd);
        revert SourcesDiverged(q.session, q.divergenceBps, q.divergenceBand);
    }

    /// @dev The whole truth function. Every branch is total: this can never revert.
    /// @return q         Fully populated quote.
    /// @return rawAnswer Raw Chainlink answer, for the `InvalidFeedAnswer` revert payload.
    /// @return feedOk    False when the feed did not answer, or answered non-positively or absurdly.
    function _read() internal view returns (Quote memory q, int256 rawAnswer, bool feedOk) {
        // --- (d) calendar -------------------------------------------------------------------
        (bool calendarOk, Session session, uint64 nextOpen_, uint64 lastClose_, uint256 closedFor_) = _readCalendar();
        // With no session view we assume nothing: the tightest budgets (REGULAR), the maximum haircut,
        // and no tolerance for a pool that cannot corroborate the feed.
        Session thresholdSession = calendarOk ? session : Session.REGULAR;
        q.session = session;
        q.nextOpen = nextOpen_;
        q.lastClose = lastClose_;
        q.stalenessBudget = stalenessBudget(thresholdSession);
        q.divergenceBand = divergenceBand(thresholdSession);
        q.haircutBps = _haircutBps(session, closedFor_, calendarOk);

        // --- (a) Chainlink anchor -----------------------------------------------------------
        (feedOk, rawAnswer, q.anchorPrice, q.feedAge) = _readFeed();

        // --- (c) B20 corporate action -------------------------------------------------------
        bool halted;
        (q.multiplier, halted) = _readMultiplier();

        // --- (b) Aerodrome corroboration ----------------------------------------------------
        bool observeOk;
        (observeOk, q.poolPrice, q.poolLiquidityUsd) = _readPoolPrice();
        q.poolLiquidityUsd = _cappedDepthWad(observeOk, q.poolLiquidityUsd);
        bool poolUsable = observeOk && q.poolPrice != 0 && q.poolLiquidityUsd >= minPoolLiquidityUsd;

        if (feedOk && poolUsable) {
            uint256 diff = q.anchorPrice > q.poolPrice ? q.anchorPrice - q.poolPrice : q.poolPrice - q.anchorPrice;
            q.divergenceBps = Math.mulDiv(diff, BPS, q.anchorPrice);
        }

        // --- the two marks ------------------------------------------------------------------
        // With no usable pool both marks collapse onto the anchor, and the haircut still applies in its
        // respective direction: a single unverifiable source does not earn a tighter spread.
        // With no anchor at all there is no mark. A missing Chainlink reference is not a price of zero,
        // and one unattested pool print is not a substitute for the reference it was meant to check.
        //
        // The pool may always pull the borrow mark DOWN - that is the direction in which a live venue
        // disagreeing with a frozen reference is information, and it can only ever reduce someone's
        // borrowing power. It may pull the seizure mark UP only while the anchor is not itself live,
        // i.e. outside the regular session, when the pool is the only witness there is. Letting it do
        // so during a regular session bought a marginal borrower a full divergence band of protection
        // for the cost of a one-sided push in a shallow pool: `markLiquidate` and therefore the whole
        // seizure threshold followed the pool upward, while `markBorrow` stayed pinned to the anchor,
        // so the purchase was entirely one-sided. The pool's job is to catch an anchor that is stale
        // and too HIGH; raising the mark is the side an attacker wants.
        if (feedOk) {
            (q.markBorrow, q.markLiquidate) = _marks(
                q.anchorPrice, poolUsable ? q.poolPrice : 0, q.haircutBps, calendarOk && session == Session.REGULAR
            );
        }

        // --- verdict, in order ---------------------------------------------------------------
        bool sessionOpen = calendarOk && _isOpen(session);
        if (!feedOk || halted) {
            q.verdict = Verdict.UNTRUSTED_HALTED;
        } else if (q.feedAge > q.stalenessBudget) {
            q.verdict = Verdict.UNTRUSTED_STALE;
        } else if (!poolUsable && !sessionOpen) {
            // While a session is running the feed is live, so a shallow pool is merely uninformative.
            // Once it closes the pool is the only live witness, and losing it means losing the mark.
            q.verdict = Verdict.UNTRUSTED_THIN;
        } else if (poolUsable && q.divergenceBps > q.divergenceBand) {
            q.verdict = Verdict.UNTRUSTED_DIVERGENT;
        } else {
            q.verdict = sessionOpen ? Verdict.TRUSTED : Verdict.TRUSTED_CLOSED;
        }
    }

    /// @dev The two asymmetric marks, in the Morpho scale.
    /// @param anchor     Chainlink reference, WAD USD.
    /// @param poolPrice_ Corroborating TWAP, WAD USD, or zero when the pool cannot corroborate.
    /// @param haircut    Gap haircut in bps, applied in each mark's own direction.
    /// @param anchorLive Whether the reference is itself printing right now, i.e. a regular session.
    function _marks(uint256 anchor, uint256 poolPrice_, uint256 haircut, bool anchorLive)
        internal
        view
        returns (uint256 markBorrow_, uint256 markLiquidate_)
    {
        uint256 low = poolPrice_ != 0 && poolPrice_ < anchor ? poolPrice_ : anchor;
        uint256 high = poolPrice_ != 0 && !anchorLive && poolPrice_ > anchor ? poolPrice_ : anchor;
        markBorrow_ = _toMorpho(low * (BPS - haircut) / BPS);
        markLiquidate_ = _toMorpho(high * (BPS + haircut) / BPS);
    }

    /// @dev `min(base + slope * hoursClosed, cap)`, zero while a regular session is running.
    function _haircutBps(Session session, uint256 closedFor_, bool calendarOk) internal view returns (uint256) {
        if (!calendarOk) return maxHaircutBps;
        if (session == Session.REGULAR) return 0;
        uint256 hoursClosed = closedFor_ / 1 hours;
        if (hoursClosed > type(uint32).max) hoursClosed = type(uint32).max;
        uint256 haircut = uint256(baseHaircutBps) + uint256(haircutSlopeBpsPerHour) * hoursClosed;
        return haircut > maxHaircutBps ? maxHaircutBps : haircut;
    }

    /// @dev REGULAR, PRE and POST all have a live tape; the three CLOSED_* states do not.
    function _isOpen(Session session) internal pure returns (bool) {
        return session == Session.REGULAR || session == Session.PRE || session == Session.POST;
    }

    /// @dev WAD USD price to the Morpho `1e36 * 10**(loanDec - collDec)` scale.
    function _toMorpho(uint256 markWad) internal view returns (uint256) {
        return markWad * _morphoScale;
    }

    /// @dev `sessionAt` and `closedFor`, both tolerant of a missing or reverting calendar.
    function _readCalendar()
        internal
        view
        returns (bool ok, Session session, uint64 nextOpen_, uint64 lastClose_, uint256 closedFor_)
    {
        (bool sessionOk, bytes memory data) =
            _staticcall(calendar, abi.encodeCall(ITradingCalendar.sessionAt, (block.timestamp)));
        if (!sessionOk || data.length < 96) return (false, Session.CLOSED_HOLIDAY, 0, 0, 0);

        uint256 rawSession;
        uint256 rawNextOpen;
        uint256 rawLastClose;
        assembly ("memory-safe") {
            rawSession := mload(add(data, 0x20))
            rawNextOpen := mload(add(data, 0x40))
            rawLastClose := mload(add(data, 0x60))
        }
        if (rawSession >= SESSION_COUNT || rawNextOpen > type(uint64).max || rawLastClose > type(uint64).max) {
            return (false, Session.CLOSED_HOLIDAY, 0, 0, 0);
        }

        (bool closedOk, uint256 closedWord) =
            _staticcallWord(calendar, abi.encodeCall(ITradingCalendar.closedFor, (block.timestamp)));
        if (!closedOk) return (false, Session.CLOSED_HOLIDAY, 0, 0, 0);

        return (true, Session(rawSession), uint64(rawNextOpen), uint64(rawLastClose), closedWord);
    }

    /// @dev Chainlink `latestRoundData`, normalised to WAD USD. An `updatedAt` of zero surfaces as a
    ///      maximal age and is caught by the staleness rule rather than by the answer rule.
    function _readFeed() internal view returns (bool ok, int256 rawAnswer, uint256 anchorWad, uint256 age) {
        (bool success, bytes memory data) = _staticcall(feed, abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!success || data.length < 160) return (false, 0, 0, type(uint256).max);

        uint256 updatedAt;
        assembly ("memory-safe") {
            rawAnswer := mload(add(data, 0x40))
            updatedAt := mload(add(data, 0x80))
        }
        age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (rawAnswer <= 0) return (false, rawAnswer, 0, age);

        uint256 answer = uint256(rawAnswer);
        if (answer > MAX_PRICE_WAD / _anchorScale) return (false, rawAnswer, 0, age);
        return (true, rawAnswer, answer * _anchorScale, age);
    }

    /// @dev The B20 corporate-action surface: multiplier bounds, token transfer pause, issuer registry.
    /// @return multiplier_ Current multiplier in WAD, or WAD when the token exposes none.
    /// @return halted      True when a corporate action or a pause makes the mark meaningless.
    function _readMultiplier() internal view returns (uint256 multiplier_, bool halted) {
        multiplier_ = WAD;
        if (tracksMultiplier) {
            (bool ok, uint256 current) = _staticcallWord(collateralToken, abi.encodeWithSelector(MULTIPLIER_SELECTOR));
            // A token that answered at deploy time and stops answering now is a halt, not a footnote.
            if (!ok) return (0, true);
            multiplier_ = current;
            if (current < minMultiplier || current > maxMultiplier) return (current, true);
        }

        // `PausableFeature.TRANSFER` is ordinal 0. Paused transfers mean the collateral cannot move, so
        // no liquidation could settle even if we were willing to price it.
        (bool pausedOk, uint256 pausedWord) =
            _staticcallWord(collateralToken, abi.encodeWithSelector(IS_PAUSED_SELECTOR, uint8(0)));
        if (pausedOk && pausedWord != 0) return (multiplier_, true);

        if (multiplierRegistry != address(0)) {
            (bool registryOk, uint256 registryWord) =
                _staticcallWord(multiplierRegistry, abi.encodeWithSelector(PAUSED_SELECTOR));
            if (registryOk && registryWord != 0) return (multiplier_, true);
        }
    }

    /// @dev Arithmetic-mean-tick TWAP over `twapWindow`, converted to WAD USD per whole collateral
    ///      token, together with the loan-side depth that actually backed that TWAP. A pool with
    ///      insufficient observation cardinality reverts inside `observe`; that is reported as "not
    ///      usable", never propagated.
    /// @return ok       Whether the window produced a usable mean tick.
    /// @return priceWad Mean-tick price, WAD USD per whole collateral token.
    /// @return depthWad Loan-side depth backing the window, 1e18 USD. See `_depthWad`.
    function _readPoolPrice() internal view returns (bool ok, uint256 priceWad, uint256 depthWad) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (bool success, bytes memory data) = _staticcall(pool, abi.encodeCall(ICLPool.observe, (secondsAgos)));
        // Two two-element arrays: two head offsets plus two length-prefixed bodies.
        if (!success || data.length < 256) return (false, 0, 0);

        uint256 headOffset0;
        uint256 headOffset1;
        uint256 lengths;
        int256 cumulativeOld;
        int256 cumulativeNow;
        assembly ("memory-safe") {
            headOffset0 := mload(add(data, 0x20))
            headOffset1 := mload(add(data, 0x40))
            // Both array lengths, folded into one comparison: `tickCumulatives` at 0x60 and
            // `secondsPerLiquidityCumulativeX128s` at 0xc0. Both are read below, so both are
            // validated here rather than trusting the payload's shape.
            lengths := or(shl(128, mload(add(data, 0x60))), mload(add(data, 0xc0)))
            cumulativeOld := mload(add(data, 0x80))
            cumulativeNow := mload(add(data, 0xa0))
        }
        if (headOffset0 != 0x40 || headOffset1 != 0xa0 || lengths != ((2 << 128) | 2)) return (false, 0, 0);
        if (cumulativeOld < type(int56).min || cumulativeOld > type(int56).max) return (false, 0, 0);
        if (cumulativeNow < type(int56).min || cumulativeNow > type(int56).max) return (false, 0, 0);

        int256 delta = cumulativeNow - cumulativeOld;
        int256 window = int256(uint256(twapWindow));
        int256 meanTick = delta / window;
        // The Uniswap convention: the mean tick rounds towards negative infinity.
        if (delta < 0 && delta % window != 0) --meanTick;
        if (meanTick < TickMath.MIN_TICK || meanTick > TickMath.MAX_TICK) return (false, 0, 0);

        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(int24(meanTick));
        priceWad = _quoteAtSqrtRatio(sqrtRatioX96);
        if (priceWad == 0 || priceWad > MAX_PRICE_WAD) return (false, 0, 0);
        return (true, priceWad, _depthWad(data, sqrtRatioX96));
    }

    /// @dev Loan-side depth that backed the TWAP window, 1e18 USD.
    ///
    ///      `observe` returns a second cumulative that callers usually discard,
    ///      `secondsPerLiquidityCumulativeX128`. Its difference across the window inverts to the
    ///      harmonic mean of the pool in-range liquidity over exactly the window whose price is
    ///      being trusted, which is precisely the quantity the cost of manipulating that price
    ///      depends on. Converting it at the mean tick gives the loan-side virtual reserve: the
    ///      constant-product-equivalent depth a swap would have to move.
    ///
    ///      The measure this replaces was `loanToken.balanceOf(pool)`. In a concentrated-liquidity
    ///      pool the two are unrelated: a single-sided position parked far out of range adds to the
    ///      balance, contributes nothing to the depth that resists a push, carries no inventory risk
    ///      and can be withdrawn immediately. A depth floor meant to stop a thin pool corroborating
    ///      a frozen feed was therefore satisfiable with one transfer. This one is not, because
    ///      liquidity that was never in range during the window never enters the average.
    ///
    ///      The raw balance is still taken as a second, independent ceiling in `_read`: virtual
    ///      reserves exceed real ones in a concentrated pool, and no swap can take out more of the
    ///      loan token than the pool actually holds.
    function _depthWad(bytes memory data, uint160 sqrtRatioX96) internal view returns (uint256) {
        uint256 splOld;
        uint256 splNow;
        assembly ("memory-safe") {
            splOld := mload(add(data, 0xe0))
            splNow := mload(add(data, 0x100))
        }
        // The cumulative is a uint160 that is allowed to wrap, so the difference is taken modulo
        // 2^160 exactly as the Uniswap oracle library does.
        unchecked {
            uint256 splDelta = (splNow - splOld) & type(uint160).max;
            if (splDelta == 0) return 0;

            uint256 liquidity = Math.mulDiv(uint256(twapWindow), 1 << 128, splDelta);
            // Virtual reserve of the loan token at the mean price: `L * sqrtP` when the loan token
            // is token1, `L / sqrtP` when it is token0.
            uint256 reserve = collateralIsToken0
                ? Math.mulDiv(liquidity, sqrtRatioX96, 1 << 96)
                : Math.mulDiv(liquidity, 1 << 96, sqrtRatioX96);
            return Math.mulDiv(reserve, WAD, _loanUnit);
        }
    }

    /// @dev Quotes one whole collateral token in whole loan tokens at `sqrtRatioX96`, as WAD.
    ///      Mirrors the Uniswap `OracleLibrary.getQuoteAtTick` shape, specialised to this pair.
    function _quoteAtSqrtRatio(uint160 sqrtRatioX96) internal view returns (uint256) {
        uint256 quoteRaw;
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteRaw = collateralIsToken0
                ? Math.mulDiv(ratioX192, _collateralUnit, 1 << 192)
                : Math.mulDiv(1 << 192, _collateralUnit, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteRaw = collateralIsToken0
                ? Math.mulDiv(ratioX128, _collateralUnit, 1 << 128)
                : Math.mulDiv(1 << 128, _collateralUnit, ratioX128);
        }
        return Math.mulDiv(quoteRaw, WAD, _loanUnit);
    }

    /// @dev The smaller of the two independent ceilings on how much of the loan token a swap could
    ///      actually move: the in-range liquidity that backed the TWAP window, and the balance the
    ///      pool physically holds. Virtual reserves exceed real ones in a concentrated pool, and
    ///      out-of-range liquidity is not depth, so neither measure dominates the other.
    ///      With no usable TWAP window there is no liquidity average to speak of and the pool is
    ///      unusable anyway, so the balance is reported on its own rather than as a zero that would
    ///      tell a UI less than it knows.
    function _cappedDepthWad(bool observeOk, uint256 depthWad) internal view returns (uint256) {
        uint256 balanceWad = _readPoolLiquidityUsd();
        if (!observeOk) return balanceWad;
        return balanceWad < depthWad ? balanceWad : depthWad;
    }

    /// @dev Loan-side balance held by the pool, in WAD USD. The loan token is assumed
    ///      USD-denominated, which holds for every Morpho market this oracle is meant for.
    function _readPoolLiquidityUsd() internal view returns (uint256) {
        (bool ok, uint256 balance) = _staticcallWord(loanToken, abi.encodeCall(IERC20.balanceOf, (pool)));
        if (!ok) return 0;
        return Math.mulDiv(balance, WAD, _loanUnit);
    }

    /// @dev A `staticcall` that never bubbles. Callers must validate `ret` themselves.
    function _staticcall(address target, bytes memory data) internal view returns (bool ok, bytes memory ret) {
        if (target.code.length == 0) return (false, "");
        (ok, ret) = target.staticcall(data);
    }

    /// @dev A `staticcall` returning a single 32-byte word, without ABI decoding that could revert.
    function _staticcallWord(address target, bytes memory data) internal view returns (bool ok, uint256 word) {
        bytes memory ret;
        (ok, ret) = _staticcall(target, data);
        if (!ok || ret.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
    }
}
