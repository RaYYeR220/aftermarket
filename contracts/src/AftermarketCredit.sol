// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IB20Asset} from "base-std/interfaces/IB20Asset.sol";

import {AftermarketVault} from "./AftermarketVault.sol";
import {ISessionRateModel} from "./SessionRateModel.sol";
import {IAftermarketCredit} from "./interfaces/IAftermarketCredit.sol";
import {IEligibility} from "./interfaces/IEligibility.sol";
import {ISwapAdapter} from "./interfaces/ISwapAdapter.sol";
import {ITradingCalendar} from "./interfaces/ITradingCalendar.sol";
import {Session} from "./libraries/Types.sol";

/// @title  AftermarketCredit
/// @notice A portfolio securities-backed line of credit against Coinbase B20 tokenized US equities:
///         post a basket, draw USDC, and never get liquidated while the US market is closed.
///
/// @dev The design question this contract answers is narrow and specific. B20 tokens trade on Base
///      twenty-four hours a day, but their Chainlink reference feed only moves while the underlying
///      equity market does. Over a weekend the feed is more than fifty hours stale while the
///      Aerodrome pool keeps printing. Every existing lending market either liquidates against a
///      price nobody can defend, or freezes the borrower out entirely.
///
///      Aftermarket takes a third position, and it shows up in exactly which functions are allowed
///      to read a price:
///
///      | function                        | reads a mark | why |
///      |---------------------------------|--------------|-----|
///      | `openLine`, `depositCollateral` | no           | adding collateral only reduces risk |
///      | `repay`, `repayOnBehalf`        | no           | a borrower must always be able to cure |
///      | `withdrawCollateral`            | only if debt remains | a debt-free user is never trapped |
///      | `draw`                          | yes          | new risk needs a defensible price |
///      | `flag`, `liquidate`             | yes          | seizure needs a defensible price |
///
///      `IAftermarketOracle.markBorrow` and `markLiquidate` revert when the oracle cannot stand
///      behind its number. That revert is deliberately not caught anywhere in the risk-increasing
///      paths: an oracle outage must freeze new borrowing and freeze seizure, while leaving repay
///      and deposit wide open. It is the safety spine of the whole protocol.
///
///      On top of that sits the grace mechanism. A line that goes underwater is `flag`ged rather
///      than seized, and the grace clock is set past the next opening bell, so the borrower always
///      gets a real market in which to react. `liquidate` additionally refuses to run unless the
///      calendar says a regular session is running right now.
///
///      A second table governs the other axis, jurisdiction. The collateral is offered under
///      Regulation S, so every path by which a B20 token can move INTO an account is gated on
///      `eligibility`, and no path by which a borrower gets OUT is:
///
///      | function                             | checks eligibility | of whom |
///      |--------------------------------------|--------------------|---------|
///      | `openLine`, `depositCollateral`      | yes                | `msg.sender` |
///      | `draw`                               | yes                | `msg.sender` |
///      | `liquidate`                          | yes                | `receiver`, the account the securities go to |
///      | `repay`, `repayOnBehalf`, `cure`     | no                 | - |
///      | `withdrawCollateral`, `realizeBadDebt` | no               | - |
///
///      The gate address itself is immutable, so none of that is a promise about an owner key. See
///      `eligibility` and `liquidate` for the reasoning behind each half.
contract AftermarketCredit is IAftermarketCredit, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 1e4;

    /// @notice Scale of an `IAftermarketOracle` mark: `collateralRaw * mark / 1e36 == loanRaw`.
    uint256 internal constant ORACLE_SCALE = 1e36;

    /// @notice Virtual shares and assets, mirroring the OpenZeppelin/Morpho technique.
    /// @dev They make the very first borrow price its shares against a non-empty market, so nobody
    ///      can seed one wei of debt and then inflate the share price under a later borrower.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Hard cap on distinct collateral assets per line.
    /// @dev Every valuation walks this list and calls an oracle per entry, so the bound is what
    ///      keeps `flag` and `liquidate` inside a block gas limit. An unbounded basket would be a
    ///      griefing vector: a borrower could make their own position too expensive to liquidate.
    uint256 public constant MAX_ASSETS = 8;

    /// @notice Fraction of the outstanding debt a single `liquidate` call may repay.
    uint256 public constant CLOSE_FACTOR_BPS = 5_000;

    /// @notice Floor on the grace period, even if the market is open right now.
    uint256 public constant MIN_GRACE = 1 hours;

    /// @notice Extra time granted after the opening bell so the borrower can actually trade.
    uint256 public constant CURE_WINDOW = 30 minutes;

    /// @notice Ceiling on any advance rate or liquidation threshold.
    uint256 public constant MAX_FACTOR_BPS = 9_500;

    /// @notice Ceiling on the liquidation bonus.
    uint256 public constant MAX_LIQ_BONUS_BPS = 2_000;

    /// @notice Largest fraction of a position `sweepYield` will sell in one call, in bps.
    /// @dev A B20 `multiplier()` move carries two economically opposite events through one number:
    ///      a distribution, which is accretive to the raw unit, and a split, which is neutral to it
    ///      because the per-share price falls in step. The contract cannot tell them apart from the
    ///      multiplier alone, so it refuses the sizes only a split can produce. A 10:1 split asks
    ///      this function to sell 90% of the borrower's position on a market order into a shallow
    ///      pool on an event that moved nobody's wealth; no real distribution is anywhere near that
    ///      large, so a cap turns a catastrophic misfire into a revert an operator can see.
    uint256 public constant MAX_SWEEP_BPS = 1_000;

    /// @notice Ratio below which a residual basket is treated as unrecoverable rather than seizable.
    /// @dev A line whose remaining collateral supports less than `1 / BAD_DEBT_DUST_DIVISOR` of its
    ///      own debt cannot be cleared by a liquidator in practice: their entire profit is the bonus
    ///      on that residue, which is orders of magnitude below the gas of the call. Left alone, the
    ///      debt stays on `totalDebtAssets` and keeps compounding, so the vault's share price counts
    ///      money nobody will ever pay and the first LP out is paid with the last one's capital.
    ///      Recognising the loss at that point is strictly better for every supplier than carrying it.
    uint256 public constant BAD_DEBT_DUST_DIVISOR = 10_000;

    /// @notice Ceiling on the per-second borrow rate `_accrue` will apply, WAD (~1000% APR).
    /// @dev `rateModel` is owner-settable and `_taylorCompounded` forms `x*n`, `x^2` and `x^3` in
    ///      checked arithmetic, so an absurd curve would revert inside `_accrue` - and every
    ///      state-changing entry point begins with `_accrue`, including `repay`. Clamping here means
    ///      a mis-specified model can make credit expensive but can never trap a borrower's
    ///      collateral, which is the one thing the design promises is impossible.
    uint256 internal constant MAX_RATE_PER_SECOND = 317_097_919_838;

    /// @notice Sentinel returned by `healthFactor` when an oracle refused to produce a mark.
    /// @dev Distinguished from a genuine zero by the accompanying `priced` flag, so a UI never has
    ///      to guess whether a line is insolvent or merely unpriceable right now.
    uint256 public constant HEALTH_UNKNOWN = 0;

    /// @notice Health factor reported for a line with no debt.
    uint256 public constant HEALTH_NO_DEBT = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The single debt asset. Aftermarket lends USDC only.
    IERC20 public immutable usdc;

    /// @notice The ERC-4626 vault that supplies the USDC.
    AftermarketVault public immutable vaultContract;

    /// @notice The trading calendar. The one and only source of "is the US market open".
    ITradingCalendar public immutable calendar;

    /// @notice Reg-S gate consulted on every action that admits a security or new risk.
    ///
    /// @dev Immutable, and that is the whole point. A settable gate makes the Regulation-S property
    ///      a promise about the owner rather than a property of the bytecode: one `setEligibility`
    ///      transaction installing a contract whose `requireEligible` is a no-op would evaporate the
    ///      entire design, silently, with no other visible change. Nobody reviewing this protocol
    ///      should have to take that on trust, so the key cannot do it - not the deployer's key, not
    ///      a compromised key, not a future multisig's.
    ///
    ///      The price is real and is paid deliberately: if the attestation landscape changes, or
    ///      `RegSGate` needs to be replaced, this engine cannot follow it. The migration is a new
    ///      engine, which is exactly the amount of ceremony a change to a jurisdiction gate should
    ///      cost. The safety property is unaffected either way, because the gate is only ever
    ///      consulted on the way in: `repay`, `cure` and a debt-clearing `withdrawCollateral` read
    ///      it not at all, so an unreplaceable gate can never trap anybody's collateral.
    ///
    ///      What this does NOT make true is stated with equal care in `CLAIMS.md`. The gate address
    ///      is frozen; the answers behind it are not. `RegSGate` still lets its own owner repoint
    ///      its fallback registry, and the registry's owner is implicitly an attester, so the
    ///      jurisdiction of an account can still be asserted by a key rather than proven by
    ///      Coinbase. `RegSGate.check` reports which of the two happened, as `source`.
    IEligibility public immutable eligibility;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Session-aware interest-rate curve.
    ISessionRateModel public rateModel;

    /// @notice Router used by `sweepYield` to turn accrued dividends into debt repayment.
    ISwapAdapter public swapAdapter;

    /// @notice Worst execution `sweepYield` will accept against the oracle mark, in bps.
    uint16 public maxSlippageBps;

    /// @dev Packed market totals. Interest accrues into `totalDebtAssetsStored`; shares are what
    ///      individual lines hold.
    uint128 internal totalDebtAssetsStored;
    uint128 internal totalDebtSharesStored;

    /// @dev Timestamp of the last interest accrual.
    uint64 internal lastAccrual;

    /// @dev Interest earned but not yet worth a whole unit of the loan token, carried at WAD scale
    ///      so no accrual schedule can round it away. Always below `WAD`, and packed alongside
    ///      `lastAccrual`. See `_accrue`.
    uint64 internal accrualRemainder;

    /// @dev Per-user line. One slot: 128 + 40 + 40 + 40 = 248 bits.
    struct Line {
        uint128 debtShares;
        uint40 openedAt;
        uint40 graceUntil;
        uint40 flaggedAt;
    }

    /// @dev Working set for `sweepYield`, kept in memory to stay inside the EVM stack.
    struct Sweep {
        uint256 multiplierWas;
        uint256 multiplierNow;
        uint256 sold;
        uint256 minOut;
        uint256 proceeds;
        uint256 repaid;
    }

    mapping(address user => Line) internal lines;
    /// @notice Full risk policy and live posted balance for each collateral asset.
    mapping(address asset => AssetConfig) public assetConfig;
    mapping(address user => address[]) internal postedAssets;

    /// @notice Raw collateral units held for `user` in `asset`.
    mapping(address user => mapping(address asset => uint256)) public collateral;

    /// @notice B20 `multiplier()` recorded the last time collateral was posted or swept.
    mapping(address user => mapping(address asset => uint256)) public multiplierCheckpoint;

    /// @notice Whether anyone may run `sweepYield` for this user.
    mapping(address user => bool) public autoRepayEnabled;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param usdc_           Loan asset.
    /// @param vault_          Address the `AftermarketVault` will be deployed at. The vault checks
    ///                        the reverse link in its own constructor, so a wrong address here can
    ///                        only ever produce a failed deployment, never a live mis-wired system.
    /// @param calendar_       Trading calendar.
    /// @param eligibility_    Reg-S gate. Immutable once set; see the field's NatSpec for why the
    ///                        owner deliberately cannot repoint it.
    /// @param rateModel_      Interest-rate model.
    /// @param swapAdapter_    DEX adapter used by `sweepYield`.
    /// @param maxSlippageBps_ Slippage budget for `sweepYield`.
    /// @param owner_          Initial owner (`Ownable2Step`).
    constructor(
        IERC20 usdc_,
        address vault_,
        ITradingCalendar calendar_,
        IEligibility eligibility_,
        ISessionRateModel rateModel_,
        ISwapAdapter swapAdapter_,
        uint16 maxSlippageBps_,
        address owner_
    ) Ownable(owner_) {
        if (
            address(usdc_) == address(0) || vault_ == address(0) || address(calendar_) == address(0)
                || address(eligibility_) == address(0) || address(rateModel_) == address(0)
        ) {
            revert ZeroAddress();
        }
        if (maxSlippageBps_ > BPS) revert InvalidSlippage(maxSlippageBps_);

        usdc = usdc_;
        vaultContract = AftermarketVault(vault_);
        calendar = calendar_;
        eligibility = eligibility_;
        rateModel = rateModel_;
        swapAdapter = swapAdapter_;
        maxSlippageBps = maxSlippageBps_;
        lastAccrual = uint64(block.timestamp);

        // Every USDC that comes back to the protocol - repayment, liquidation, swept dividend -
        // lands here first and is then pulled by the vault. Granting the allowance once keeps the
        // borrower-facing approval surface to a single address: the one they call.
        usdc_.forceApprove(vault_, type(uint256).max);

        emit EligibilitySet(address(eligibility_));
        emit RateModelSet(address(rateModel_));
        emit SwapAdapterSet(address(swapAdapter_));
        emit MaxSlippageSet(maxSlippageBps_);
    }

    /*//////////////////////////////////////////////////////////////
                             OWNER CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the full risk policy for one collateral asset.
    /// @dev The validation encodes the shape of the product rather than arbitrary bounds.
    ///      `advanceClosed <= advanceOpen` because a closed market is strictly riskier to lend
    ///      against; `liqThresholdClosed >= liqThresholdOpen` because a closed market is strictly
    ///      worse to seize in. `advance <= liqThreshold` keeps a freshly maxed-out line from being
    ///      instantly liquidatable. The ceiling of 9500 bps leaves room for the bonus.
    ///
    ///      It also validates the *wiring*, not just the shape. An oracle that prices a different
    ///      security than the one it is installed for is the Rho Markets failure mode: no code bug,
    ///      one mis-copied address at deployment, and an entire market valued off the wrong feed.
    ///      Two staticcalls close it, and `AftermarketOracleFactory.predictAddress` already makes
    ///      the correct address computable offchain, so there is no reason not to assert it onchain.
    /// @param asset  Collateral token.
    /// @param params New policy. `posted` is protocol accounting and is preserved.
    function setAsset(address asset, AssetParams calldata params) external onlyOwner {
        if (asset == address(0) || address(params.oracle) == address(0)) revert ZeroAddress();

        address pricedToken = params.oracle.collateralToken();
        if (pricedToken != asset) revert OracleAssetMismatch(asset, pricedToken);
        address pricedLoan = params.oracle.loanToken();
        if (pricedLoan != address(usdc)) revert OracleAssetMismatch(address(usdc), pricedLoan);

        if (params.advanceOpenBps > MAX_FACTOR_BPS || params.liqThresholdOpenBps > MAX_FACTOR_BPS) {
            revert InvalidAssetConfig();
        }
        if (params.advanceOpenBps > params.liqThresholdOpenBps) revert InvalidAssetConfig();
        if (params.advanceClosedBps > params.advanceOpenBps) revert InvalidAssetConfig();
        if (params.liqThresholdClosedBps < params.liqThresholdOpenBps) revert InvalidAssetConfig();
        if (params.liqThresholdClosedBps > MAX_FACTOR_BPS) revert InvalidAssetConfig();
        if (params.liqBonusBps > MAX_LIQ_BONUS_BPS) revert InvalidAssetConfig();

        AssetConfig storage c = assetConfig[asset];
        if (params.cap < c.posted) revert AssetCapExceeded(asset, c.posted, params.cap);

        c.oracle = params.oracle;
        c.advanceOpenBps = params.advanceOpenBps;
        c.advanceClosedBps = params.advanceClosedBps;
        c.liqThresholdOpenBps = params.liqThresholdOpenBps;
        c.liqThresholdClosedBps = params.liqThresholdClosedBps;
        c.liqBonusBps = params.liqBonusBps;
        c.cap = params.cap;
        c.enabled = params.enabled;

        emit AssetConfigured(asset, params);
    }

    /// @notice Replaces the interest-rate model.
    /// @dev Interest is accrued to the current second first, so a curve change can never be applied
    ///      retroactively to time that has already passed.
    function setRateModel(ISessionRateModel rateModel_) external onlyOwner {
        if (address(rateModel_) == address(0)) revert ZeroAddress();
        _accrue();
        rateModel = rateModel_;
        emit RateModelSet(address(rateModel_));
    }

    /// @notice Replaces the DEX adapter used by `sweepYield`.
    /// @dev The adapter is the only untrusted contract in the system, which is why it is swappable
    ///      and why it never gets to decide slippage or recipients.
    function setSwapAdapter(ISwapAdapter swapAdapter_) external onlyOwner {
        if (address(swapAdapter_) == address(0)) revert ZeroAddress();
        swapAdapter = swapAdapter_;
        emit SwapAdapterSet(address(swapAdapter_));
    }

    /// @notice Sets the slippage budget `sweepYield` will tolerate against the oracle mark.
    function setMaxSlippage(uint16 maxSlippageBps_) external onlyOwner {
        if (maxSlippageBps_ > BPS) revert InvalidSlippage(maxSlippageBps_);
        maxSlippageBps = maxSlippageBps_;
        emit MaxSlippageSet(maxSlippageBps_);
    }

    /*//////////////////////////////////////////////////////////////
                              BORROWER FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Opens a credit line for the caller.
    /// @dev Gated on eligibility because opening a line is the first risk-increasing act. Reads no
    ///      oracle: opening a line creates no exposure by itself, so an oracle outage must not stop
    ///      it. The explicit step exists so the UI has one place to surface the Reg-S attestation
    ///      and so `depositCollateral` cannot silently onboard someone who never agreed to it.
    function openLine() external {
        eligibility.requireEligible(msg.sender);

        Line storage l = lines[msg.sender];
        if (l.openedAt != 0) revert LineAlreadyOpen(msg.sender);

        // forge-lint: disable-next-line(unsafe-typecast)
        l.openedAt = uint40(block.timestamp);
        emit LineOpened(msg.sender, uint64(block.timestamp));
    }

    /// @notice Opts in or out of permissionless `sweepYield`.
    /// @dev Off by default. Letting a stranger sell part of your collateral is a real delegation, so
    ///      it is the borrower's explicit choice rather than a protocol default.
    function setAutoRepay(bool enabled) external {
        autoRepayEnabled[msg.sender] = enabled;
        emit AutoRepaySet(msg.sender, enabled);
    }

    /// @notice Posts `amount` raw units of `asset` as collateral.
    /// @dev Reads no oracle mark. Collateral can only ever improve a line's health, so refusing the
    ///      deposit because a price feed is stale would punish exactly the user who is trying to fix
    ///      their position during an outage. Eligibility *is* checked, because posting collateral is
    ///      the step that brings a tokenized security into the protocol.
    /// @param asset  Collateral token, previously configured by the owner.
    /// @param amount Raw units to post. B20 balances are raw; the dividend multiplier is a separate
    ///               read and is checkpointed here, not folded into the balance.
    function depositCollateral(address asset, uint256 amount) external nonReentrant {
        _accrue();
        eligibility.requireEligible(msg.sender);

        if (amount == 0) revert ZeroAmount();
        if (lines[msg.sender].openedAt == 0) revert LineNotOpen(msg.sender);

        AssetConfig storage c = assetConfig[asset];
        if (!c.enabled) revert AssetNotEnabled(asset);

        uint128 newPosted = c.posted + _u128(amount);
        if (newPosted > c.cap) revert AssetCapExceeded(asset, newPosted, c.cap);
        c.posted = newPosted;

        uint256 balance = collateral[msg.sender][asset];
        if (balance == 0) {
            address[] storage list = postedAssets[msg.sender];
            if (list.length >= MAX_ASSETS) revert TooManyAssets(MAX_ASSETS);
            list.push(asset);
        }

        _rollMultiplierCheckpoint(msg.sender, asset, balance, balance + amount);
        collateral[msg.sender][asset] = balance + amount;

        emit CollateralDeposited(msg.sender, asset, amount, balance + amount);

        // Effects before the transfer, per checks-effects-interactions. This assumes the collateral
        // token moves exactly `amount`; B20 assets and USDC do, and a fee-on-transfer token would
        // have to be rejected at listing time rather than accounted for here.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraws `amount` raw units of `asset` to `to`.
    /// @dev Reads an oracle mark only when debt remains after the withdrawal. That asymmetry is
    ///      deliberate and load-bearing: a user who has repaid everything owns their collateral
    ///      outright, and neither a stale feed nor a change of compliance provider may hold it
    ///      hostage. Correspondingly, this function is never gated on eligibility.
    /// @param asset  Collateral token.
    /// @param amount Raw units to withdraw.
    /// @param to     Recipient.
    function withdrawCollateral(address asset, uint256 amount, address to) external nonReentrant {
        Session s = _accrue();

        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        uint256 balance = collateral[msg.sender][asset];
        if (amount > balance) revert InsufficientCollateral(asset, balance, amount);

        _removeCollateral(msg.sender, asset, amount);

        uint256 debt = _debtStored(msg.sender);
        uint256 power;
        if (debt != 0) {
            (power,) = _borrowPower(msg.sender, s);
            if (debt > power) revert Undercollateralized(debt, power);
        }

        // Surviving the check above means the line sits inside its own advance rate, which is
        // exactly what `cure` demands. Clearing the flag here is not a courtesy: the grace
        // guarantee is stored per flag, so a line that was flagged, recovered, and then had
        // collateral pulled out of it would carry an already-expired deadline into its next
        // unhealthy moment and be seizable in the same block it went underwater, with no notice
        // at all. `draw` refuses a flagged line outright; this is the same protection, applied on
        // the path a borrower is far more likely to take.
        Line storage l = lines[msg.sender];
        if (l.flaggedAt != 0) {
            l.flaggedAt = 0;
            l.graceUntil = 0;
            emit LineCured(msg.sender, msg.sender, debt, power);
        }

        emit CollateralWithdrawn(msg.sender, asset, amount, to);

        IERC20(asset).safeTransfer(to, amount);
    }

    /// @notice Draws `assets` USDC against the posted basket, sending it to `to`.
    /// @dev The one place where borrowing power is created, and therefore the one place that must
    ///      have a defensible price for every asset in the basket. `markBorrow` reverting is not an
    ///      error condition to be handled, it is the answer: no trustworthy price means no new risk.
    /// @param assets USDC to draw.
    /// @param to     Recipient of the USDC.
    function draw(uint256 assets, address to) external nonReentrant {
        Session s = _accrue();
        eligibility.requireEligible(msg.sender);

        if (assets == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        Line storage l = lines[msg.sender];
        if (l.openedAt == 0) revert LineNotOpen(msg.sender);
        // A flagged line is one the protocol has already judged unhealthy. Even if a repayment has
        // since made it safe, the borrower must clear the flag with `cure` first, so that the
        // grace clock cannot be quietly reset by a draw.
        if (l.flaggedAt != 0) revert LineIsFlagged(msg.sender);
        // No opening bell the calendar is prepared to name means no session in which this position
        // could ever be flagged, cured or seized. Refusing new debt there is the other half of the
        // calendar failing closed: without it, past the horizon the protocol would become a one-way
        // ratchet that still lends against collateral nobody can ever take.
        if (calendar.nextOpen(block.timestamp) == 0) revert CalendarHorizon();

        uint256 shares = _toSharesUp(assets, totalDebtAssetsStored, totalDebtSharesStored);
        l.debtShares += _u128(shares);
        totalDebtSharesStored += _u128(shares);
        totalDebtAssetsStored += _u128(assets);

        uint256 debt = _debtStored(msg.sender);
        (uint256 power,) = _borrowPower(msg.sender, s);
        if (debt > power) revert Undercollateralized(debt, power);

        emit Drawn(msg.sender, to, assets, shares);

        vaultContract.lend(to, assets);
    }

    /// @notice Repays up to `assets` USDC of the caller's own debt.
    /// @dev Reads no oracle and checks no eligibility, by design. Curing a position is the one
    ///      action that must work under every possible failure of every other component: feeds
    ///      stale, sources diverged, pool halted, attestation expired. Pass `type(uint256).max` to
    ///      clear the line exactly, with no dust left behind by rounding.
    /// @param assets USDC to repay, or `type(uint256).max` for the full outstanding debt.
    /// @return repaidAssets USDC actually taken from the caller.
    /// @return repaidShares Debt shares burned.
    function repay(uint256 assets) external nonReentrant returns (uint256 repaidAssets, uint256 repaidShares) {
        return _repayFrom(msg.sender, msg.sender, assets);
    }

    /// @notice Repays up to `assets` USDC of `user`'s debt, paid by the caller.
    /// @dev Permissionless and ungated for the same reason as `repay`: a third party reducing
    ///      someone's debt can never harm them, and a keeper, a friend, or the borrower's own
    ///      second wallet must be able to rescue a line during an oracle outage.
    /// @param user   Line to repay.
    /// @param assets USDC to repay, or `type(uint256).max` for that line's full outstanding debt.
    function repayOnBehalf(address user, uint256 assets)
        external
        nonReentrant
        returns (uint256 repaidAssets, uint256 repaidShares)
    {
        return _repayFrom(msg.sender, user, assets);
    }

    /*//////////////////////////////////////////////////////////////
                          FLAG / CURE / LIQUIDATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Marks `user`'s line as unhealthy and starts the grace clock. Permissionless.
    /// @dev This is the differentiator. Instead of seizing the moment a line crosses its threshold,
    ///      Aftermarket starts a timer that is guaranteed to run past the next opening bell plus a
    ///      cure window. A borrower flagged on a Friday evening therefore has all weekend plus half
    ///      an hour of a real, liquid, two-sided market to fix it. Reads `markLiquidate`, so an
    ///      oracle that will not stand behind a price cannot start the clock either.
    /// @param user Line to flag.
    function flag(address user) external nonReentrant {
        Session s = _accrue();

        Line storage l = lines[user];
        if (l.flaggedAt != 0) revert AlreadyFlagged(user, l.graceUntil);

        uint256 debt = _debtStored(user);
        if (debt == 0) revert NoDebt(user);

        uint256 threshold = _actionableThreshold(user, s);
        if (debt <= threshold) revert LineHealthy(debt, threshold);

        uint64 nextOpen = calendar.nextOpen(block.timestamp);
        // The calendar answers zero when the next open lies outside the horizon its holiday table
        // actually covers. Without a real opening bell there is no grace period that can be
        // promised, so the line is simply not flaggable - and, since `isOpen` is false past that
        // horizon too, it is not seizable either.
        if (nextOpen == 0) revert CalendarHorizon();
        uint256 floorDeadline = block.timestamp + MIN_GRACE;
        uint256 openDeadline = uint256(nextOpen) + CURE_WINDOW;
        uint64 deadline = uint64(floorDeadline > openDeadline ? floorDeadline : openDeadline);

        // uint40 covers timestamps past the year 36000; both values are seconds since the epoch.
        // forge-lint: disable-next-line(unsafe-typecast)
        l.flaggedAt = uint40(block.timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        l.graceUntil = uint40(deadline);

        emit LineFlagged(user, msg.sender, debt, threshold, deadline, nextOpen, s);
    }

    /// @notice Clears the flag on `user`'s line once it is genuinely healthy again. Permissionless.
    ///
    /// @dev Anyone may call it because clearing a stale flag is unambiguously good for the borrower
    ///      and costs the protocol nothing: the health check is re-run against live marks, so a line
    ///      that is still underwater simply cannot be cured.
    ///
    ///      Curing is the exact complement of flagging, and both halves of that matter.
    ///
    ///      It is measured at OPEN-session parameters, and it runs only while the US market is open.
    ///      Testing it at whatever session happened to be running meant "cured" was worth no more
    ///      than "not seizable at this instant" - and the seizure threshold moves on its own twice
    ///      at every closing bell, once because the policy switches to `liqThresholdClosedBps` and
    ///      once because the oracle marks collateral *up* by the gap haircut. A line parked between
    ///      the open and closed thresholds was therefore unhealthy every morning and healthy every
    ///      evening, so the borrower could clear each morning's flag before its deadline was ever
    ///      reached and postpone seizure indefinitely for the price of one transaction a day.
    ///      Requiring an open market removes both steps at once: the haircut is zero by
    ///      construction during a regular session, and the open threshold is the one that applies.
    ///
    ///      What the complement buys, beyond closing that loop, is that a flag can never outlive
    ///      the condition that raised it. `liquidate` seizes only while the market is open and only
    ///      when `debt > threshold`; `cure` clears only while the market is open and only when
    ///      `debt <= threshold`. Every line is therefore exactly one of curable or seizable in any
    ///      session a seizure could happen in, so a borrower who recovers can always clear the flag
    ///      before the next adverse move, and can never be seized on an expired clock left over
    ///      from an episode that has passed. A borrower who does not recover keeps their flag and
    ///      their notice, which is the point.
    /// @param user Line to cure.
    function cure(address user) external nonReentrant {
        Session s = _accrue();
        if (!calendar.isOpen(block.timestamp)) revert MarketClosed(s);

        Line storage l = lines[user];
        if (l.flaggedAt == 0) revert NotFlagged(user);

        uint256 debt = _debtStored(user);
        uint256 threshold;
        if (debt != 0) threshold = _actionableThreshold(user, s);
        if (debt > threshold) revert CureIncomplete(debt, threshold);

        l.flaggedAt = 0;
        l.graceUntil = 0;

        emit LineCured(user, msg.sender, debt, threshold);
    }

    /// @notice Seizes collateral from a flagged, expired, still-unhealthy line while the US market
    ///         is open.
    /// @dev Four conditions, and the third is the product:
    ///      1. the line is flagged, so the borrower has had notice;
    ///      2. the grace period has expired, so they have had time;
    ///      3. `calendar.isOpen(block.timestamp)` - Aftermarket never seizes collateral while the US
    ///         market is closed, because in that window there is no price discovery to liquidate
    ///         against and no market for the borrower to escape through;
    ///      4. the line is still unhealthy at live marks.
    ///
    ///      Seizure is valued at `markLiquidate` plus the asset's bonus and capped at what the
    ///      borrower actually holds; when the cap binds, the repay amount is scaled down to match,
    ///      so a liquidator never pays for collateral that is not there. If what is left of the
    ///      basket is worth less than the transaction that would take it, the residual debt is
    ///      written off immediately against `totalDebtAssets` rather than being left to inflate the
    ///      vault's share price with money nobody will ever pay.
    ///
    ///      **The account that ends up holding the seized securities must be eligible, and the
    ///      account that pays for them need not be.** That split is the whole design of the gate on
    ///      this function, and it is what lets liquidation be both compliant and liquid.
    ///
    ///      Seizure moves two different things in opposite directions. USDC comes in from
    ///      `msg.sender`; a Reg-S tokenized security goes out to `receiver`. Only the second leg
    ///      carries a jurisdiction obligation - the first is a stablecoin payment, which anybody
    ///      anywhere may make - so `receiver` is checked against `eligibility` and `msg.sender` is
    ///      deliberately not. In practice that means a searcher's bot, a flash-loan router, a relayer
    ///      or a multisig's executor can all fund a liquidation with no attestation of their own, as
    ///      long as the collateral lands with an attested non-US person. The liquidator set is
    ///      therefore bounded by who may HOLD the security, not by who may send a transaction, which
    ///      is the widest set the Regulation-S premise permits and answers the real objection to
    ///      gating this path: that an unliquidatable position turns a solvent protocol into an
    ///      insolvent one.
    ///
    ///      There is no way around it by naming somebody else. `receiver` is the address the tokens
    ///      are transferred to, and it is the address that is checked; an ineligible caller cannot
    ///      pass itself, and cannot pass an ineligible third party either. Whether an attested
    ///      receiver then transfers onward is outside this protocol - the B20 token performs no
    ///      per-transfer jurisdiction check of its own - but Aftermarket no longer operates the
    ///      channel. `withdrawCollateral(asset, amount, to)` is left ungated for the opposite and
    ///      equally deliberate reason: it is an exit, the borrower already holds the position, and a
    ///      compliance rule that can trap somebody's collateral is a bug rather than a feature.
    /// @param user            Line to liquidate.
    /// @param collateralAsset Asset to seize.
    /// @param repayAssets     USDC the liquidator wishes to repay; at most 50% of the debt.
    /// @param receiver        Account the seized collateral is transferred to. Must be eligible.
    /// @return seized         Raw collateral units transferred to `receiver`.
    /// @return repaid         USDC actually taken from `msg.sender`.
    function liquidate(address user, address collateralAsset, uint256 repayAssets, address receiver)
        external
        nonReentrant
        returns (uint256 seized, uint256 repaid)
    {
        return _liquidate(user, collateralAsset, repayAssets, receiver);
    }

    /// @notice Seizes collateral to the caller's own account.
    /// @dev Identical to the four-argument form with `receiver = msg.sender`, and gated identically:
    ///      the caller is the one who ends up holding the security, so the caller is the one
    ///      `eligibility` is asked about. It exists because self-liquidation is the common case and
    ///      restating one's own address is noise, not because the short form is looser.
    function liquidate(address user, address collateralAsset, uint256 repayAssets)
        external
        nonReentrant
        returns (uint256 seized, uint256 repaid)
    {
        return _liquidate(user, collateralAsset, repayAssets, msg.sender);
    }

    /// @dev The single seizure implementation. Both entry points land here, so the eligibility check
    ///      on the receiving account cannot be reachable from one and not the other.
    function _liquidate(address user, address collateralAsset, uint256 repayAssets, address receiver)
        internal
        returns (uint256 seized, uint256 repaid)
    {
        if (receiver == address(0)) revert ZeroAddress();
        eligibility.requireEligible(receiver);

        Session s = _requireSeizable(user, repayAssets);

        uint256 repayCapped;
        (seized, repayCapped) = _quoteSeizure(user, collateralAsset, repayAssets);
        _removeCollateral(user, collateralAsset, seized);

        uint256 repaidShares;
        (repaid, repaidShares) = _burnDebt(user, repayCapped);

        emit Liquidated(user, msg.sender, collateralAsset, repaid, repaidShares, seized, receiver);

        Line storage l = lines[user];
        if (l.debtShares != 0 && _isUnrecoverable(user, s)) {
            _realizeBadDebt(user);
        }
        if (l.debtShares == 0) {
            l.flaggedAt = 0;
            l.graceUntil = 0;
        }

        usdc.safeTransferFrom(msg.sender, address(this), repaid);
        vaultContract.settle(address(this), repaid);
        IERC20(collateralAsset).safeTransfer(receiver, seized);
    }

    /// @notice Writes off the debt of a flagged, expired line whose remaining collateral is worth
    ///         less than the transaction that would seize it. Permissionless.
    ///
    /// @dev The counterpart to `liquidate`, and it exists because liquidation alone never finishes
    ///      the job. A cascade against a fallen asset ends with a residue too small to be worth a
    ///      liquidator's gas; the debt behind it stays on `totalDebtAssets`, `_accrue` keeps
    ///      compounding interest on it, and `AftermarketVault.totalAssets` keeps quoting a share
    ///      price backed by money nobody will ever pay. That is not a rounding artefact - it is a
    ///      transfer from whichever supplier redeems last to whichever redeems first, and it grows.
    ///
    ///      Every guarantee `liquidate` makes is enforced here too, for the same reasons: the line
    ///      must be flagged, its grace period must have run out, the US market must be open, and
    ///      every posted asset must be priceable, so nothing is ever written off on a price the
    ///      protocol cannot defend or on a line that was never given notice. The borrower keeps the
    ///      residual collateral - once the debt is gone it is unambiguously theirs - and that
    ///      residue is bounded to under `1 / BAD_DEBT_DUST_DIVISOR` of the debt being recognised.
    /// @param user Line to write off.
    function realizeBadDebt(address user) external nonReentrant {
        Session s = _accrue();

        Line storage l = lines[user];
        if (l.flaggedAt == 0) revert NotFlagged(user);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < l.graceUntil) revert GraceNotExpired(l.graceUntil);
        if (!calendar.isOpen(block.timestamp)) revert MarketClosed(s);
        if (l.debtShares == 0) revert NoDebt(user);

        (uint256 threshold, uint256 unpriced) = _seizureRisk(user, s);
        if (unpriced != 0) revert UnpricedCollateral(unpriced);

        uint256 debt = _debtStored(user);
        if (threshold * BAD_DEBT_DUST_DIVISOR > debt) revert LineNotDust(threshold, debt);

        _realizeBadDebt(user);
        l.flaggedAt = 0;
        l.graceUntil = 0;
    }

    /// @dev Enforces the four seizure preconditions and the close factor. Split out of `liquidate`
    ///      so the checks and the arithmetic can each be read on their own, and returns the session
    ///      it priced at so the caller cannot end up applying two different ones in a single call.
    function _requireSeizable(address user, uint256 repayAssets) internal returns (Session s) {
        s = _accrue();

        Line storage l = lines[user];
        if (l.flaggedAt == 0) revert NotFlagged(user);
        // A deadline comparison is exactly what this is for; a validator nudging the clock by a
        // few seconds cannot meaningfully shorten a grace period measured in hours or days.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < l.graceUntil) revert GraceNotExpired(l.graceUntil);
        if (!calendar.isOpen(block.timestamp)) revert MarketClosed(s);
        if (repayAssets == 0) revert ZeroAmount();

        uint256 debt = _debtStored(user);
        uint256 threshold = _actionableThreshold(user, s);
        if (debt <= threshold) revert LineHealthy(debt, threshold);

        uint256 maxRepay = _mulDown(debt, CLOSE_FACTOR_BPS, BPS);
        if (repayAssets > maxRepay) revert CloseFactorExceeded(repayAssets, maxRepay);
    }

    /// @dev The seizure threshold the flag and seizure paths are allowed to act on.
    ///
    ///      A basket in which the *priceable* part alone already fails the test is a real judgement
    ///      and is acted on - that is the whole point of not letting one unpriceable leg veto the
    ///      other seven. A basket in which nothing at all could be priced also produces a threshold
    ///      of zero, but for the vacuous reason that nothing was counted, and acting on that would
    ///      turn any total oracle outage into universal insolvency and let a keeper start a grace
    ///      clock against every borrower at once. The two cases are told apart here rather than at
    ///      the call sites so they can never drift.
    function _actionableThreshold(address user, Session s) internal view returns (uint256 threshold) {
        uint256 unpriced;
        (threshold, unpriced) = _seizureRisk(user, s);
        if (unpriced != 0 && threshold == 0) revert UnpricedCollateral(unpriced);
    }

    /// @dev Whether what is left of a line is worth less than the gas of taking it. Never true
    ///      while any leg is unpriceable: a write-off is a permanent loss recognised on the
    ///      supplier side, and an oracle outage must never be able to trigger one.
    function _isUnrecoverable(address user, Session s) internal view returns (bool) {
        (uint256 threshold, uint256 unpriced) = _seizureRisk(user, s);
        if (unpriced != 0) return false;
        return threshold * BAD_DEBT_DUST_DIVISOR <= _debtStored(user);
    }

    /// @notice Prices a hypothetical seizure: what a liquidator would receive, and what they would
    ///         actually pay once the borrower's balance caps it.
    /// @dev Public so liquidation bots can size a call offchain against the exact arithmetic the
    ///      contract will run, instead of guessing and eating a revert.
    /// @return seized Raw collateral units, `markLiquidate` plus the asset bonus, capped at balance.
    /// @return cost   USDC the liquidator pays, scaled down proportionally when the cap binds.
    function quoteSeizure(address user, address asset, uint256 repayAssets)
        external
        view
        returns (uint256 seized, uint256 cost)
    {
        return _quoteSeizure(user, asset, repayAssets);
    }

    function _quoteSeizure(address user, address asset, uint256 repayAssets)
        internal
        view
        returns (uint256 seized, uint256 cost)
    {
        AssetConfig storage c = assetConfig[asset];
        uint256 mark = c.oracle.markLiquidate();
        uint256 bonus = BPS + c.liqBonusBps;

        cost = repayAssets;
        seized = _mulDown(Math.mulDiv(cost, ORACLE_SCALE, mark), bonus, BPS);

        uint256 balance = collateral[user][asset];
        if (seized > balance) {
            seized = balance;
            // Rounded UP, in both steps, and therefore never to zero. This is the liquidator's
            // payment, so the rounding belongs on their side of the trade - and rounding it down
            // was what made a small leg permanently unseizable: below `(BPS + bonus) / mark` raw
            // units the cost floored to zero, `_quoteSeizure` reverted, the leg could never be
            // removed from `postedAssets`, and the write-off behind it was unreachable forever.
            // An ordinary liquidation cascade on a fallen asset produces exactly that residue on
            // its own. One unit of the loan token now clears any crumb.
            cost = Math.mulDiv(
                Math.mulDiv(seized, mark, ORACLE_SCALE, Math.Rounding.Ceil), BPS, bonus, Math.Rounding.Ceil
            );
            // The cap binding means the liquidator asked to repay more than the balance is worth,
            // so the rounded-up cost is already at or below what they offered; clamping keeps that
            // true against the rounding and keeps the close factor exact.
            if (cost > repayAssets) cost = repayAssets;
        }
        if (seized == 0 || cost == 0) revert ZeroAmount();
    }

    /// @dev Single place that shrinks a collateral position, so the posted-asset list, the
    ///      protocol-wide cap accounting and the multiplier checkpoint can never drift apart.
    function _removeCollateral(address user, address asset, uint256 amount) internal {
        uint256 remaining = collateral[user][asset] - amount;
        collateral[user][asset] = remaining;
        assetConfig[asset].posted -= _u128(amount);
        if (remaining == 0) {
            _dropPostedAsset(user, asset);
            multiplierCheckpoint[user][asset] = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          SELF-REPAYING COLLATERAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Sells the dividend/split slice that accrued on `user`'s `asset` position and puts the
    ///         proceeds against their debt.
    ///
    /// @dev B20 tokens carry corporate actions through an onchain `multiplier()` rather than by
    ///      minting: raw balances stay constant and the scaled value moves. So when the multiplier
    ///      goes from `m0` to `m`, the fraction of the current position that represents new value is
    ///      `(m - m0) / m`, and selling exactly that fraction of the raw balance returns the holding
    ///      to its pre-distribution economic size while banking the dividend.
    ///
    ///      Note for anyone reading this against mainnet: every live B20 multiplier is still exactly
    ///      1e18 today, because no dividend or split has occurred since the 2026-08-24 launch. This
    ///      path is therefore exercised against a simulated multiplier increase, not against a
    ///      historical one, and `sweepYield` is a no-op (it reverts `NothingToSweep`) until an
    ///      issuer actually calls `updateMultiplier`.
    ///
    ///      A trusted `markBorrow` is required: the swap is a market order against a pool, and the
    ///      only thing standing between it and a sandwich is a `minOut` derived from a price the
    ///      oracle is willing to defend. Proceeds beyond the outstanding debt are sent straight to
    ///      the user rather than being held as an internal credit balance - the engine keeps no idle
    ///      user funds, so there is no second ledger to keep consistent and nothing to lose track of.
    ///
    ///      It runs only while the US market is open, and that is a slippage control rather than a
    ///      calendar nicety. `minOut` is derived from `markBorrow`, which is already the pessimistic
    ///      mark: the lower of the two venues, discounted again by the gap haircut. Outside a
    ///      regular session that haircut is live and the divergence band is at its widest, so the
    ///      floor a "1% slippage budget" actually enforces becomes `anchor x (1 - band) x
    ///      (1 - haircut) x (1 - budget)` - as much as a quarter of the position over a long
    ///      holiday weekend. Inside a regular session the haircut is zero by construction and the
    ///      pool is at its deepest, which is also simply the right time to send a market order.
    ///
    /// @param user  Line to sweep.
    /// @param asset Collateral token whose multiplier has increased.
    /// @return sold     Raw collateral units sold.
    /// @return proceeds USDC received from the adapter.
    /// @return repaid   USDC applied to the debt.
    function sweepYield(address user, address asset)
        external
        nonReentrant
        returns (uint256 sold, uint256 proceeds, uint256 repaid)
    {
        Session s = _accrue();
        if (!calendar.isOpen(block.timestamp)) revert MarketClosed(s);

        if (msg.sender != user && !autoRepayEnabled[user]) revert AutoRepayDisabled(user);

        // Held in memory rather than on the stack: the sweep needs the before and after multiplier,
        // the slice, the quote and both legs of the settlement all live at once.
        Sweep memory v;
        bool multiplierOk;
        (v.multiplierNow, multiplierOk) = _multiplierOf(asset);
        v.multiplierWas = multiplierCheckpoint[user][asset];

        uint256 balance = collateral[user][asset];
        if (!multiplierOk || balance == 0 || v.multiplierNow <= v.multiplierWas) {
            revert NothingToSweep(user, asset);
        }

        // A checkpoint of zero means one was never recorded - the only way to reach it is a deposit
        // made while `multiplier()` was not answering - and treating it as a multiplier of zero
        // would size the slice at the entire position.
        if (v.multiplierWas == 0) revert NothingToSweep(user, asset);

        v.sold = _mulDown(balance, v.multiplierNow - v.multiplierWas, v.multiplierNow);
        if (v.sold == 0) revert NothingToSweep(user, asset);

        uint256 sweepCap = _mulDown(balance, MAX_SWEEP_BPS, BPS);
        if (v.sold > sweepCap) revert SweepTooLarge(v.sold, sweepCap);

        v.minOut =
            _mulDown(_mulDown(v.sold, assetConfig[asset].oracle.markBorrow(), ORACLE_SCALE), BPS - maxSlippageBps, BPS);

        // `sold` is strictly less than `balance` because the accrued fraction is strictly below one,
        // so the position always survives the sweep and the new checkpoint always has a home.
        _removeCollateral(user, asset, v.sold);
        multiplierCheckpoint[user][asset] = v.multiplierNow;

        v.proceeds = _swapForUsdc(asset, v.sold, v.minOut);
        v.repaid = _applyProceeds(user, v.proceeds);

        emit YieldSwept(
            user, asset, v.multiplierWas, v.multiplierNow, v.sold, v.proceeds, v.repaid, v.proceeds - v.repaid
        );

        return (v.sold, v.proceeds, v.repaid);
    }

    /// @dev Sells `amountIn` of `asset` for USDC through the adapter under an exact allowance.
    ///      The allowance is opened and closed around the call so a compromised or replaced adapter
    ///      is never left holding standing permission over collateral.
    function _swapForUsdc(address asset, uint256 amountIn, uint256 minOut) internal returns (uint256 amountOut) {
        ISwapAdapter adapter = swapAdapter;
        IERC20(asset).forceApprove(address(adapter), amountIn);
        amountOut = adapter.swapExactIn(asset, address(usdc), amountIn, minOut, address(this));
        IERC20(asset).forceApprove(address(adapter), 0);
        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);
    }

    /// @dev Applies swap proceeds to the debt and forwards anything left over to the user.
    function _applyProceeds(address user, uint256 proceeds) internal returns (uint256 repaid) {
        uint256 debt = _debtStored(user);
        repaid = proceeds < debt ? proceeds : debt;

        if (repaid != 0) {
            _burnDebt(user, repaid);
            // A line with nothing left to owe has nothing left to seize, exactly as on the repay
            // path. Leaving the flag standing here would block `draw` on a debt-free line.
            Line storage l = lines[user];
            if (l.debtShares == 0 && l.flaggedAt != 0) {
                l.flaggedAt = 0;
                l.graceUntil = 0;
                emit LineCured(user, msg.sender, 0, 0);
            }
            vaultContract.settle(address(this), repaid);
        }

        uint256 surplus = proceeds - repaid;
        if (surplus != 0) usdc.safeTransfer(user, surplus);
    }

    /*//////////////////////////////////////////////////////////////
                                INTEREST
    //////////////////////////////////////////////////////////////*/

    /// @notice Brings the market's debt total up to `block.timestamp`.
    /// @dev Permissionless and idempotent within a block. Every state-changing entry point calls it
    ///      first, so an explicit call is only ever needed by a keeper that wants the accrual event
    ///      emitted on a schedule. Guarded like everything else that writes: `sweepYield` hands
    ///      control to the swap adapter, the only untrusted contract in the system, at a moment when
    ///      the collateral slice has already been removed and the debt has not yet been reduced, and
    ///      an unguarded write reachable from there is a way to observe the position mid-flight.
    function accrue() external nonReentrant {
        _accrue();
    }

    /// @dev Accrues interest and returns the session it priced at, so callers do not pay for a
    ///      second calendar read and cannot end up applying two different sessions in one call.
    ///
    ///      The rate is sampled once and applied to the whole elapsed window, which is Morpho
    ///      Blue's model - and it is only sound because, exactly as in Morpho, every action that
    ///      changes the market's liquidity closes the window first. `AftermarketVault.deposit`,
    ///      `mint`, `withdraw` and `redeem` all call `accrue()` before they touch a single USDC,
    ///      so the utilisation this samples is always the utilisation that actually prevailed over
    ///      the window it is charging for. Without that ordering a one-block deposit - flash-loaned
    ///      or simply backrun onto somebody else's - would reprice a month of interest at a
    ///      utilisation that existed for one block, and the difference would be paid by the other
    ///      suppliers.
    ///
    ///      Because that argument rests entirely on the window being closed, this function closes it
    ///      unconditionally. Interest too small to be worth a whole unit of the loan token is carried
    ///      in `accrualRemainder` at WAD scale rather than discarded, which is what lets the clock
    ///      advance every time without losing anything. Neither shortcut is available: discarding
    ///      the remainder lets anyone pin a small market at zero interest by calling the
    ///      permissionless `accrue()` every block, and leaving the clock open instead lets a market
    ///      sit at a dust total debt for months and then charge that whole window against the next
    ///      borrower's freshly-drawn principal.
    function _accrue() internal returns (Session s) {
        s = calendar.session();

        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0) return s;
        lastAccrual = uint64(block.timestamp);

        uint256 debt = totalDebtAssetsStored;
        if (debt == 0) return s;

        uint256 rate = rateModel.ratePerSecondAt(debt, _totalSupplyAssets(debt), s);
        if (rate > MAX_RATE_PER_SECOND) rate = MAX_RATE_PER_SECOND;

        uint256 scaled = debt * _taylorCompounded(rate, elapsed) + accrualRemainder;
        uint256 interest = scaled / WAD;
        // The leftover is strictly below WAD, so it always fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        accrualRemainder = uint64(scaled - interest * WAD);
        if (interest == 0) return s;

        totalDebtAssetsStored = _u128(debt + interest);
        emit Accrued(interest, debt + interest, rate, s);
    }

    /// @dev Interest not yet written to storage, priced at `s`. Mirrors `_accrue` exactly -
    ///      including the rate clamp and the carried remainder - so the projection a supplier sees
    ///      is the one they will get.
    function _pendingInterest(uint256 debt, Session s) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0 || debt == 0) return 0;
        uint256 rate = rateModel.ratePerSecondAt(debt, _totalSupplyAssets(debt), s);
        if (rate > MAX_RATE_PER_SECOND) rate = MAX_RATE_PER_SECOND;
        return (debt * _taylorCompounded(rate, elapsed) + accrualRemainder) / WAD;
    }

    /// @dev Total assets backing the market: idle vault USDC plus outstanding debt. Read from the
    ///      vault's raw balance rather than `vault.totalAssets()` to avoid recursing back into this
    ///      contract's own debt projection.
    ///
    ///      A raw balance is donation-sensitive, and deliberately left that way. A bare ERC-20
    ///      transfer into the vault is not an entry point, so unlike a deposit it does NOT close the
    ///      accrual window first, and a donation landing immediately before an `accrue()` does
    ///      reprice the whole open window. What makes that uneconomic is the donation itself: it is
    ///      irrecoverable, and suppressing utilisation enough to matter means gifting the suppliers
    ///      a multiple of the interest saved. The recoverable version of the same manipulation - a
    ///      one-block deposit - is the one that had to be closed, and it is closed in the vault.
    function _totalSupplyAssets(uint256 debt) internal view returns (uint256) {
        return usdc.balanceOf(address(vaultContract)) + debt;
    }

    /// @dev First three non-zero terms of the Taylor expansion of `e^(x*n) - 1`, WAD in and out.
    ///      Continuous compounding without a `pow`, and it under-approximates, so the protocol never
    ///      charges more than true continuous interest.
    function _taylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = _mulDown(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = _mulDown(secondTerm, firstTerm, 3 * WAD);
        return firstTerm + secondTerm + thirdTerm;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAftermarketCredit
    function vault() external view returns (address) {
        return address(vaultContract);
    }

    /// @inheritdoc IAftermarketCredit
    function totalDebtAssets() public view returns (uint256) {
        uint256 debt = totalDebtAssetsStored;
        return debt + _pendingInterest(debt, calendar.session());
    }

    /// @notice Total debt shares outstanding across every line.
    /// @dev The sum of every line's `debtSharesOf` must equal this at all times; it is the ledger
    ///      invariant the whole interest model rests on.
    function totalDebtShares() external view returns (uint256) {
        return totalDebtSharesStored;
    }

    /// @notice Debt shares held by `user`.
    function debtSharesOf(address user) external view returns (uint256) {
        return lines[user].debtShares;
    }

    /// @notice Grace deadline for a flagged line; zero when the line is not flagged.
    function graceUntil(address user) external view returns (uint64) {
        return lines[user].graceUntil;
    }

    /// @notice USDC owed by `user`, projected to `block.timestamp`.
    /// @dev Capped at the market total for the reason given on `_capToMarket`, so that the number a
    ///      borrower is quoted is always a number they can actually pay.
    function debtOf(address user) public view returns (uint256) {
        uint128 shares = lines[user].debtShares;
        if (shares == 0) return 0;
        uint256 total = totalDebtAssets();
        return _capToMarket(_toAssetsUp(shares, total, totalDebtSharesStored), total);
    }

    /// @notice Debt shares held by `user`.

    /// @notice USDC `user` could owe in total before the line becomes ineligible for further draws.
    /// @dev Reverts if any posted oracle refuses to mark. Callers that must not revert should use
    ///      `positionOf`, which reports the same number behind a `priced` flag. The engine's own
    ///      risk decisions work off a partially-priced basket (see `_borrowPower`); the public view
    ///      does not, because an integrator reading a number has no way to tell how much of the
    ///      basket it covers.
    function borrowPower(address user) external view returns (uint256) {
        (uint256 power, uint256 unpriced) = _borrowPower(user, calendar.session());
        if (unpriced != 0) revert UnpricedCollateral(unpriced);
        return power;
    }

    /// @notice Debt level at or above which `user`'s line may be flagged and eventually seized.
    /// @dev Uses `markLiquidate` - the optimistic mark - so that it is strictly harder to take
    ///      someone's collateral than it is to stop them borrowing more. Reverts on a partially
    ///      priceable basket, for the same reason as `borrowPower`.
    function seizureThreshold(address user) external view returns (uint256) {
        (uint256 threshold, uint256 unpriced) = _seizureRisk(user, calendar.session());
        if (unpriced != 0) revert UnpricedCollateral(unpriced);
        return threshold;
    }

    /// @notice Borrowing power and seizure threshold together, at the current session.
    /// @dev Deliberately one call rather than two: both legs must succeed or fail as a unit, so
    ///      `positionOf` can report a coherent "unpriced" position instead of a half-filled struct
    ///      in which one mark was available and the other was not.
    function riskOf(address user) external view returns (uint256 power, uint256 threshold) {
        Session s = calendar.session();
        uint256 unpricedPower;
        uint256 unpricedThreshold;
        (power, unpricedPower) = _borrowPower(user, s);
        (threshold, unpricedThreshold) = _seizureRisk(user, s);
        if (unpricedPower != 0 || unpricedThreshold != 0) {
            revert UnpricedCollateral(unpricedPower + unpricedThreshold);
        }
    }

    /// @notice Health factor, WAD, where 1e18 is exactly at the seizure threshold.
    /// @dev Never reverts. `priced` is false and `hf` is `HEALTH_UNKNOWN` when any oracle in the
    ///      basket refuses to produce a mark; keepers must treat that as "do not act", which is the
    ///      whole point, and a UI can say "price unavailable" instead of showing a scary zero.
    /// @return hf     Health factor, `HEALTH_NO_DEBT` when there is no debt.
    /// @return priced Whether every oracle in the basket produced a mark.
    function healthFactor(address user) external view returns (uint256 hf, bool priced) {
        uint256 debt = debtOf(user);
        if (debt == 0) return (HEALTH_NO_DEBT, true);

        try this.seizureThreshold(user) returns (uint256 threshold) {
            return (_mulDown(threshold, WAD, debt), true);
        } catch {
            return (HEALTH_UNKNOWN, false);
        }
    }

    /// @notice Health factor, WAD, reverting when any oracle refuses to mark.
    /// @dev The strict variant exists so that onchain integrators cannot accidentally treat an
    ///      oracle outage as a health reading of zero.
    function healthFactorStrict(address user) external view returns (uint256) {
        uint256 debt = debtOf(user);
        if (debt == 0) return HEALTH_NO_DEBT;
        (uint256 threshold, uint256 unpriced) = _seizureRisk(user, calendar.session());
        if (unpriced != 0) revert UnpricedCollateral(unpriced);
        return _mulDown(threshold, WAD, debt);
    }

    /// @notice Whether `user`'s line is currently flagged.
    function isFlagged(address user) external view returns (bool) {
        return lines[user].flaggedAt != 0;
    }

    /// @notice Collateral assets currently posted by `user`.
    function assetsOf(address user) external view returns (address[] memory) {
        return postedAssets[user];
    }

    /// @notice Everything a UI or keeper needs about one line, in a single non-reverting call.
    function positionOf(address user) external view returns (Position memory p) {
        Line storage l = lines[user];
        p.debtShares = l.debtShares;
        p.debtAssets = debtOf(user);
        p.openedAt = l.openedAt;
        p.flaggedAt = l.flaggedAt;
        p.graceUntil = l.graceUntil;
        p.flagged = l.flaggedAt != 0;
        p.autoRepayEnabled = autoRepayEnabled[user];
        p.session = calendar.session();

        try this.riskOf(user) returns (uint256 power, uint256 threshold) {
            p.priced = true;
            p.borrowPower = power;
            p.seizureThreshold = threshold;
            p.healthFactor = p.debtAssets == 0 ? HEALTH_NO_DEBT : _mulDown(threshold, WAD, p.debtAssets);
        } catch {
            p.priced = false;
            p.healthFactor = p.debtAssets == 0 ? HEALTH_NO_DEBT : HEALTH_UNKNOWN;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: RISK
    //////////////////////////////////////////////////////////////*/

    /// @dev "Open" means exactly one thing in this contract: a regular session is running, which is
    ///      the same predicate `ITradingCalendar.isOpen` uses and therefore the same predicate that
    ///      permits seizure. Tying full borrowing power and the right to liquidate to one condition
    ///      means the protocol can never be in the state of "generous enough to lend against, but
    ///      too closed to defend". Pre and post-market sessions are treated as closed here even
    ///      though the rate model prices them at par, because the reference feed is only guaranteed
    ///      live during the regular session.
    function _isOpen(Session s) internal pure returns (bool) {
        return s == Session.REGULAR;
    }

    /*//////////////////////////////////////////////////////////////

      A basket is valued asset by asset, and an asset whose oracle refuses to produce a mark
      contributes NOTHING to either side of the risk calculation rather than aborting it.

      The rule this encodes is: a price the protocol would refuse to seize on is also a price it
      must refuse to lend on. Crediting an unpriceable asset would let it do both jobs at once -
      support the debt that made a seizure necessary, and then block the seizure - which is exactly
      the state one raw unit of a second collateral used to be able to create. Health became a
      logical AND over every posted oracle, so the availability of the whole risk engine was set by
      the worst asset any borrower chose to hold a wei of, and the cost of switching it off was the
      gas to deposit that wei plus a nudge to the thinnest pool in the protocol. An issuer pausing
      transfers on that asset around a routine corporate action did it for free.

      What keeps this safe in the other direction is the asymmetry, not the valuation. Ignoring an
      asset lowers the seizure threshold, which on its own would make *deflating* one leg a way to
      force-liquidate a healthy line - strictly worse than the veto it replaces. So the asset itself
      stays unseizable: `_quoteSeizure` reads `markLiquidate` directly and still reverts, so no
      liquidator can ever take collateral at a price the protocol cannot defend. The exposure a
      borrower carries is therefore bounded to losing *priceable* collateral at a *defensible*
      price, behind the full flag-and-grace notice period, with `cure`, `repay` and
      `depositCollateral` all still open to them and none of them reading an oracle for the halted
      leg. That is the trade: a bounded, noticed, price-defensible loss for the borrower in place of
      an unbounded, silent, unrecoverable one for every supplier in the vault.

      `unpriced` is returned rather than swallowed so callers can still distinguish "worth nothing"
      from "cannot be valued": the public views reject a partial basket outright, which is what
      keeps `positionOf().priced` meaning what a keeper and a UI think it means, and the bad-debt
      write-off refuses to run at all while any leg is unpriceable.

    //////////////////////////////////////////////////////////////*/

    /// @dev Sum over the basket of `collateral * markBorrow / 1e36 * advance / 1e4`.
    /// @return power    Borrowing power of every leg that could be priced.
    /// @return unpriced Number of legs whose oracle refused to mark.
    function _borrowPower(address user, Session s) internal view returns (uint256 power, uint256 unpriced) {
        address[] storage list = postedAssets[user];
        uint256 n = list.length;
        bool open = _isOpen(s);

        for (uint256 i; i < n; ++i) {
            address asset = list[i];
            uint256 amount = collateral[user][asset];
            if (amount == 0) continue;

            AssetConfig storage c = assetConfig[asset];
            try c.oracle.markBorrow() returns (uint256 mark) {
                uint256 value = Math.mulDiv(amount, mark, ORACLE_SCALE);
                power += _mulDown(value, open ? c.advanceOpenBps : c.advanceClosedBps, BPS);
            } catch {
                unchecked {
                    ++unpriced;
                }
            }
        }
    }

    /// @dev Sum over the basket of `collateral * markLiquidate / 1e36 * liqThreshold / 1e4`.
    /// @return threshold Debt level above which the priceable collateral no longer covers the line.
    /// @return unpriced  Number of legs whose oracle refused to mark.
    function _seizureRisk(address user, Session s) internal view returns (uint256 threshold, uint256 unpriced) {
        address[] storage list = postedAssets[user];
        uint256 n = list.length;
        bool open = _isOpen(s);

        for (uint256 i; i < n; ++i) {
            address asset = list[i];
            uint256 amount = collateral[user][asset];
            if (amount == 0) continue;

            AssetConfig storage c = assetConfig[asset];
            try c.oracle.markLiquidate() returns (uint256 mark) {
                uint256 value = Math.mulDiv(amount, mark, ORACLE_SCALE);
                threshold += _mulDown(value, open ? c.liqThresholdOpenBps : c.liqThresholdClosedBps, BPS);
            } catch {
                unchecked {
                    ++unpriced;
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: DEBT PLUMBING
    //////////////////////////////////////////////////////////////*/

    /// @dev Debt of `user` against the stored totals. Only correct immediately after `_accrue`.
    function _debtStored(address user) internal view returns (uint256) {
        uint128 shares = lines[user].debtShares;
        if (shares == 0) return 0;
        return _capToMarket(_toAssetsUp(shares, totalDebtAssetsStored, totalDebtSharesStored), totalDebtAssetsStored);
    }

    /// @dev A line can never owe more than the whole market does.
    ///
    ///      `_toAssetsUp` rounds against the borrower, which is right on every ordinary repayment
    ///      and wrong on the last one: when a market has several lines and its asset total has been
    ///      ground down to a few units, the ceiling can put one line's debt a single unit above
    ///      `totalDebtAssetsStored`. Left alone that unit is subtracted from a total that does not
    ///      contain it, and the subtraction reverts - permanently, on the one function this design
    ///      promises can never be closed to a borrower. Capping is exact rather than approximate:
    ///      the market's own total is the true upper bound on any share of it, so the cap can only
    ///      ever discard rounding dust that nobody is owed.
    function _capToMarket(uint256 assets, uint256 marketAssets) internal pure returns (uint256) {
        return assets > marketAssets ? marketAssets : assets;
    }

    /// @dev Reduces `user`'s debt by at most `assets`, without moving any tokens.
    function _burnDebt(address user, uint256 assets) internal returns (uint256 repaidAssets, uint256 shares) {
        Line storage l = lines[user];
        uint256 userShares = l.debtShares;
        uint256 td = totalDebtAssetsStored;
        uint256 ts = totalDebtSharesStored;

        uint256 maxAssets = _capToMarket(_toAssetsUp(userShares, td, ts), td);
        if (assets >= maxAssets) {
            repaidAssets = maxAssets;
            shares = userShares;
        } else {
            repaidAssets = assets;
            shares = _toSharesDown(assets, td, ts);
        }

        // Every operand below was read out of uint128 storage and only ever shrinks, so none of
        // these narrowings can truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        l.debtShares = uint128(userShares - shares);
        // forge-lint: disable-next-line(unsafe-typecast)
        totalDebtSharesStored = uint128(ts - shares);
        // forge-lint: disable-next-line(unsafe-typecast)
        totalDebtAssetsStored = uint128(td - repaidAssets);
    }

    /// @dev Collects USDC from `payer` and applies it to `user`'s debt.
    function _repayFrom(address payer, address user, uint256 assets)
        internal
        returns (uint256 repaidAssets, uint256 repaidShares)
    {
        _accrue();

        if (assets == 0) revert ZeroAmount();
        if (lines[user].debtShares == 0) revert NoDebt(user);

        (repaidAssets, repaidShares) = _burnDebt(user, assets);
        // A repayment that moves neither assets nor shares is a no-op and is refused. A repayment
        // that moves shares but no assets is not: it is the last line closing itself out against a
        // market whose asset total has already been rounded away, and refusing it would be exactly
        // the trap `_capToMarket` exists to prevent.
        if (repaidAssets == 0 && repaidShares == 0) revert ZeroAmount();

        // A line with nothing left to owe has nothing left to seize, so the flag goes with it.
        Line storage l = lines[user];
        if (l.debtShares == 0 && l.flaggedAt != 0) {
            l.flaggedAt = 0;
            l.graceUntil = 0;
            emit LineCured(user, payer, 0, 0);
        }

        emit Repaid(user, payer, repaidAssets, repaidShares);

        usdc.safeTransferFrom(payer, address(this), repaidAssets);
        vaultContract.settle(address(this), repaidAssets);
    }

    /// @dev Writes off the residual debt of a line that has run out of collateral.
    function _realizeBadDebt(address user) internal {
        Line storage l = lines[user];
        uint256 shares = l.debtShares;
        uint256 residual = _toAssetsUp(shares, totalDebtAssetsStored, totalDebtSharesStored);

        l.debtShares = 0;
        // `shares` is the line's own uint128 balance and `residual` is bounded by the uint128
        // market total, so neither narrowing can truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        totalDebtSharesStored -= uint128(shares);
        // forge-lint: disable-next-line(unsafe-typecast)
        totalDebtAssetsStored -= uint128(residual);

        emit BadDebtRealized(user, residual, shares);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: SHARES AND LISTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Narrows to uint128, reverting rather than truncating. Posted collateral and market
    ///      totals are stored narrow so they pack, and a silent truncation there would corrupt
    ///      protocol-wide accounting rather than one position.
    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert Overflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    /// @dev `x * y / d` rounded down. Every product this contract forms is bounded far below 2^256
    ///      by the uint128 caps on posted collateral and on market totals, and Solidity checks the
    ///      multiplication anyway, so a full 512-bit intermediate would buy nothing but bytecode.
    function _mulDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    /// @dev `x * y / d` rounded up. Used wherever rounding must fall against the borrower.
    function _mulUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    function _toSharesUp(uint256 assets, uint256 tAssets, uint256 tShares) internal pure returns (uint256) {
        return _mulUp(assets, tShares + VIRTUAL_SHARES, tAssets + VIRTUAL_ASSETS);
    }

    function _toSharesDown(uint256 assets, uint256 tAssets, uint256 tShares) internal pure returns (uint256) {
        return _mulDown(assets, tShares + VIRTUAL_SHARES, tAssets + VIRTUAL_ASSETS);
    }

    function _toAssetsUp(uint256 shares, uint256 tAssets, uint256 tShares) internal pure returns (uint256) {
        return _mulUp(shares, tAssets + VIRTUAL_ASSETS, tShares + VIRTUAL_SHARES);
    }

    /// @dev Swap-and-pop removal from the bounded posted-asset list.
    function _dropPostedAsset(address user, address asset) internal {
        address[] storage list = postedAssets[user];
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == asset) {
                list[i] = list[n - 1];
                list.pop();
                return;
            }
        }
    }

    /// @dev Reads the B20 dividend multiplier.
    /// @return m  Current multiplier, WAD. Meaningless unless `ok`.
    /// @return ok False when the token exposes no multiplier, stopped answering, or answered zero.
    ///            "The read failed" and "the multiplier is 1.0" are different facts and are kept
    ///            apart deliberately: substituting WAD for a failed read let one transaction during
    ///            a transient B20 outage rewrite a checkpoint of 2.0 down to 1.0 and arm a sweep of
    ///            half the position against a distribution that never happened. Non-B20 collateral
    ///            is still listable; it simply never sweeps.
    function _multiplierOf(address asset) internal view returns (uint256 m, bool ok) {
        try IB20Asset(asset).multiplier() returns (uint256 current) {
            return (current, current != 0);
        } catch {
            return (0, false);
        }
    }

    /// @dev Moves the multiplier checkpoint when new collateral joins an existing position.
    ///
    ///      Naively resetting the checkpoint to the current multiplier would silently confiscate any
    ///      distribution that had accrued on the old balance but not yet been swept. Instead the
    ///      checkpoint is blended so the *sellable slice stays the same size in raw units*: we want
    ///      `newBalance * (m - m1) / m == oldBalance * (m - m0) / m`, which solves to
    ///      `m1 = m - oldBalance * (m - m0) / newBalance`. Depositing is then always safe, in any
    ///      order, with or without sweeping first.
    ///
    ///      The checkpoint never moves *down* on an existing position. It is a high-water mark of
    ///      value already accounted for, and lowering it fabricates a distribution out of thin air:
    ///      a reverse split takes the multiplier below the checkpoint, and a single one-wei deposit
    ///      at that trough used to rewrite the checkpoint to the lower number, so the multiplier
    ///      merely returning to where it started became a sweepable "dividend" of half the position.
    ///      A failed read moves nothing at all, for the same reason.
    function _rollMultiplierCheckpoint(address user, address asset, uint256 oldBalance, uint256 newBalance) internal {
        (uint256 m, bool ok) = _multiplierOf(asset);
        if (!ok) return;

        // A zero checkpoint is an absent one, not a multiplier of zero: `_removeCollateral` clears
        // it when a leg closes, and a first deposit made while the token was not answering leaves it
        // unset. Either way the position has no accounted-for baseline yet, so this is the baseline.
        uint256 m0 = multiplierCheckpoint[user][asset];
        if (oldBalance == 0 || m0 == 0) {
            multiplierCheckpoint[user][asset] = m;
            return;
        }

        if (m <= m0) return;
        multiplierCheckpoint[user][asset] = m - Math.mulDiv(oldBalance, m - m0, newBalance);
    }
}
