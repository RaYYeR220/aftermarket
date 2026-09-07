// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {AftermarketOracle, OracleConfig} from "../src/AftermarketOracle.sol";
import {AftermarketOracleFactory} from "../src/AftermarketOracleFactory.sol";
import {IAftermarketOracle} from "../src/interfaces/IAftermarketOracle.sol";
import {Quote, Session, Verdict} from "../src/libraries/Types.sol";

import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockB20} from "./mocks/MockB20.sol";
import {MockCLPool} from "./mocks/MockCLPool.sol";
import {MockCalendar} from "./mocks/MockCalendar.sol";

/// @notice Minimal `Pausable` stand-in for the optional issuer registry probe.
contract MockIssuerRegistry {
    bool public paused;

    function setPaused(bool paused_) external {
        paused = paused_;
    }
}

/// @title AftermarketOracleTest
/// @notice The proof that the session policy behaves as specified, replayed against the live-market
///         state that motivated the contract: a Chainlink equity feed frozen 52 hours at Friday's
///         close while the Aerodrome pool keeps trading.
contract AftermarketOracleTest is Test {
    /*//////////////////////////////////////////////////////////////
                         LIVE BASE MAINNET STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev NVDAc, the Coinbase B20 tokenized NVDA share. 8 decimals.
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    /// @dev Circle USDC on Base. 6 decimals.
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev Chainlink "Coinbase NVDA" total-return feed on Base. 8 decimals, 24h heartbeat.
    address internal constant NVDA_FEED = 0x04689a41629776563E6822F76f2e57D148d28513;
    /// @dev Aerodrome Slipstream NVDAc/USDC pool. token0 = USDC, token1 = NVDAc, tickSpacing 10.
    address internal constant NVDAC_USDC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;

    /// @dev The frozen Friday close observed on mainnet: $229.9573 at 8 decimals.
    int256 internal constant FROZEN_ANSWER = 22995730000;
    /// @dev How stale that answer was when observed: Friday 16:00 ET seen from Sunday evening.
    uint256 internal constant FROZEN_AGE = 52 hours;
    /// @dev Mean tick putting the pool at ~$231.35 with USDC as token0 and NVDAc as token1.
    int24 internal constant TICK_NVDAC_231 = -8388;

    /*//////////////////////////////////////////////////////////////
                              DEFAULT CONFIG
    //////////////////////////////////////////////////////////////*/

    uint32 internal constant TWAP_WINDOW = 1800;
    uint128 internal constant MIN_POOL_LIQUIDITY_USD = 25_000e18;
    uint16 internal constant BASE_HAIRCUT_BPS = 25;
    uint16 internal constant HAIRCUT_SLOPE_BPS_PER_HOUR = 15;
    uint16 internal constant MAX_HAIRCUT_BPS = 500;

    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    MockB20 internal collateral;
    MockB20 internal loan;
    MockAggregatorV3 internal feed;
    MockCLPool internal pool;
    MockCalendar internal calendar;
    MockIssuerRegistry internal registry;
    AftermarketOracle internal oracle;

    function setUp() public {
        vm.warp(1_756_000_000);

        collateral = new MockB20("Coinbase NVDA", "NVDAc", 8, true);
        loan = new MockB20("USD Coin", "USDC", 6, false);
        feed = new MockAggregatorV3(8, FROZEN_ANSWER, block.timestamp);
        // Mirrors the live pool: USDC is token0, NVDAc is token1.
        pool = new MockCLPool(address(loan), address(collateral), 10);
        calendar = new MockCalendar(Session.REGULAR, 0);
        registry = new MockIssuerRegistry();

        oracle = new AftermarketOracle(_config(address(collateral), address(loan), address(pool)));

        pool.setMeanTick(TICK_NVDAC_231, TWAP_WINDOW);
        loan.mint(address(pool), 250_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                            MORPHO SCALE
    //////////////////////////////////////////////////////////////*/

    /// @notice The exact live number: $229.9573 from an 8-decimal feed, 8-decimal collateral,
    ///         6-decimal loan token, must land on 2.299573e36 to the wei.
    function test_MorphoScale_Nvdac8_Usdc6_Exact() public {
        _setRegularAnchorOnly();

        uint256 expected = 2299573e30;
        assertEq(oracle.price(), expected, "price must be exactly 2.299573e36");

        // Morpho's own invariant: collateralAmountRaw * price / 1e36 == loanAmountRaw.
        uint256 oneWholeCollateral = 1e8;
        assertEq(oneWholeCollateral * oracle.price() / 1e36, 229_957_300, "one NVDAc must quote 229.9573 USDC");
    }

    /// @notice Same anchor, 18-decimal collateral against an 18-decimal loan token.
    function test_MorphoScale_Coll18_Loan18() public {
        AftermarketOracle o = _deployWithDecimals(18, 18);
        assertEq(o.price(), 2299573e32, "18/18 must scale to 2.299573e38");
        assertEq(1e18 * o.price() / 1e36, 229_957_300_000_000_000_000, "one whole unit must quote 229.9573");
    }

    /// @notice Same anchor, 8-decimal collateral against an 18-decimal loan token.
    function test_MorphoScale_Coll8_Loan18() public {
        AftermarketOracle o = _deployWithDecimals(8, 18);
        assertEq(o.price(), 2299573e42, "8/18 must scale to 2.299573e48");
        assertEq(1e8 * o.price() / 1e36, 229_957_300_000_000_000_000, "one whole unit must quote 229.9573");
    }

    /// @notice Same anchor, 18-decimal collateral against a 6-decimal loan token.
    function test_MorphoScale_Coll18_Loan6() public {
        AftermarketOracle o = _deployWithDecimals(18, 6);
        assertEq(o.price(), 2299573e20, "18/6 must scale to 2.299573e26");
        assertEq(1e18 * o.price() / 1e36, 229_957_300, "one whole unit must quote 229.9573 USDC");
    }

    /*//////////////////////////////////////////////////////////////
                    THE SCENARIO THIS CONTRACT EXISTS FOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Sunday evening on Base: the NVDA feed has not moved in 52 hours and still reads
    ///         Friday's $229.9573, while the Aerodrome pool prints $231.35 against it. The oracle
    ///         must keep quoting - the divergence is inside the weekend band - but only behind a
    ///         gap haircut, and with the borrow and liquidation marks pulled apart.
    function test_RealWorld_FrozenWeekendFeed_StaysTrustedButHaircut() public {
        _setFrozenWeekend();

        Quote memory q = oracle.peek();

        assertEq(uint256(q.session), uint256(Session.CLOSED_WEEKEND), "session");
        assertEq(uint256(q.verdict), uint256(Verdict.TRUSTED_CLOSED), "verdict");
        assertEq(q.feedAge, FROZEN_AGE, "feed age");
        assertEq(q.stalenessBudget, 80 hours, "weekend staleness budget");
        assertEq(q.anchorPrice, 229.9573e18, "anchor");
        assertApproxEqRel(q.poolPrice, 231.35e18, 0.001e18, "pool TWAP");

        // 1.3927 / 229.9573 = 0.6055%.
        assertApproxEqAbs(q.divergenceBps, 60, 1, "divergence bps");
        assertEq(q.divergenceBand, 250, "weekend band");

        // 25 + 15 * 52 = 805, capped at 500.
        assertEq(q.haircutBps, MAX_HAIRCUT_BPS, "52 closed hours saturates the haircut cap");

        assertLt(q.markBorrow, q.markLiquidate, "the marks must be asymmetric");
        // markBorrow  = min(229.9573, 231.35) * 0.95
        // markLiquidate = max(229.9573, 231.35) * 1.05
        assertApproxEqRel(q.markBorrow, uint256(229.9573e18) * 9500 / 10_000 * 1e16, 0.0001e18, "markBorrow");
        assertApproxEqRel(q.markLiquidate, uint256(231.35e18) * 10_500 / 10_000 * 1e16, 0.001e18, "markLiquidate");

        assertEq(oracle.price(), q.markBorrow, "price() serves Morpho the pessimistic mark");
        assertEq(oracle.markBorrow(), q.markBorrow, "markBorrow()");
        assertEq(oracle.markLiquidate(), q.markLiquidate, "markLiquidate()");
    }

    /// @notice The negative control. Identical chain state, weekend band tightened to 25bps: the same
    ///         60bps of divergence that was tolerable above now freezes the market. Without this the
    ///         green check above would be vacuous.
    function test_NegativeControl_TightBandFreezesTheSameState() public {
        OracleConfig memory cfg = _config(address(collateral), address(loan), address(pool));
        cfg.divergenceBandBps[uint256(Session.CLOSED_WEEKEND)] = 25;
        AftermarketOracle tight = new AftermarketOracle(cfg);

        _setFrozenWeekend();

        Quote memory q = tight.peek();
        assertEq(uint256(q.verdict), uint256(Verdict.UNTRUSTED_DIVERGENT), "verdict");
        assertEq(q.divergenceBand, 25, "band");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAftermarketOracle.SourcesDiverged.selector, Session.CLOSED_WEEKEND, q.divergenceBps, uint256(25)
            )
        );
        tight.price();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAftermarketOracle.SourcesDiverged.selector, Session.CLOSED_WEEKEND, q.divergenceBps, uint256(25)
            )
        );
        tight.markLiquidate();
    }

    /*//////////////////////////////////////////////////////////////
                          VERDICT TRANSITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Regular session, live feed, empty pool: the anchor alone is enough. A shallow pool
    ///         during market hours is uninformative, not dangerous.
    function test_Verdict_RegularSessionThinPool_TrustedAnchorOnly() public {
        _setRegularAnchorOnly();

        Quote memory q = oracle.peek();
        assertEq(uint256(q.verdict), uint256(Verdict.TRUSTED), "verdict");
        assertEq(q.poolLiquidityUsd, 0, "pool depth");
        assertEq(q.divergenceBps, 0, "nothing to compare against");
        assertEq(q.haircutBps, 0, "no gap while the tape is running");
        assertEq(q.markBorrow, q.markLiquidate, "both marks collapse onto the anchor");
    }

    /// @notice Market closed and the pool cannot corroborate: the frozen feed has no live witness.
    function test_Verdict_ClosedThinPool_Thin() public {
        calendar.set(Session.CLOSED_WEEKEND, FROZEN_AGE, 0, 0);
        feed.set(FROZEN_ANSWER, block.timestamp - FROZEN_AGE);
        // Depth just under the configured floor.
        vm.mockCall(
            address(loan),
            abi.encodeWithSignature("balanceOf(address)", address(pool)),
            abi.encode(uint256(MIN_POOL_LIQUIDITY_USD / 1e12 - 1))
        );

        Quote memory q = oracle.peek();
        assertEq(uint256(q.verdict), uint256(Verdict.UNTRUSTED_THIN), "verdict");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAftermarketOracle.PoolTooThin.selector, q.poolLiquidityUsd, uint256(MIN_POOL_LIQUIDITY_USD)
            )
        );
        oracle.price();
    }

    /// @notice Past the session budget the feed stops being a reference at all.
    function test_Verdict_StaleFeed() public {
        calendar.set(Session.CLOSED_WEEKEND, 81 hours, 0, 0);
        feed.set(FROZEN_ANSWER, block.timestamp - 81 hours);

        Quote memory q = oracle.peek();
        assertEq(uint256(q.verdict), uint256(Verdict.UNTRUSTED_STALE), "verdict");
        assertEq(q.feedAge, 81 hours, "age");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAftermarketOracle.StaleFeed.selector, Session.CLOSED_WEEKEND, uint256(81 hours), uint256(80 hours)
            )
        );
        oracle.price();
    }

    /// @notice The staleness budget is per session: 2 hours is fine overnight and fatal at 10:00.
    function test_Verdict_StalenessBudgetIsPerSession() public {
        feed.set(FROZEN_ANSWER, block.timestamp - 2 hours);

        calendar.set(Session.CLOSED_OVERNIGHT, 18 hours, 0, 0);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED_CLOSED), "overnight tolerates 2h");

        calendar.set(Session.REGULAR, 0, 0, 0);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_STALE), "regular does not");
    }

    /// @notice A zeroed B20 multiplier is a corporate action in flight, not a price.
    function test_Verdict_MultiplierZero_Halted() public {
        collateral.setMultiplier(0);

        Quote memory q = oracle.peek();
        assertEq(uint256(q.verdict), uint256(Verdict.UNTRUSTED_HALTED), "verdict");
        assertEq(q.multiplier, 0, "multiplier");

        vm.expectRevert(abi.encodeWithSelector(IAftermarketOracle.MarketHalted.selector, uint256(0)));
        oracle.price();
    }

    /// @notice A multiplier outside the configured bounds is treated the same way.
    function test_Verdict_MultiplierOutOfBounds_Halted() public {
        collateral.setMultiplier(2000e18);

        Quote memory q = oracle.peek();
        assertEq(uint256(q.verdict), uint256(Verdict.UNTRUSTED_HALTED), "verdict");

        vm.expectRevert(abi.encodeWithSelector(IAftermarketOracle.MarketHalted.selector, uint256(2000e18)));
        oracle.price();
    }

    /// @notice A collateral token that answered `multiplier()` at deploy time and stops answering is
    ///         a halt, not a footnote.
    function test_Verdict_MultiplierDisappears_Halted() public {
        assertTrue(oracle.tracksMultiplier(), "collateral must be policed");
        collateral.setExposeMultiplier(false);

        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_HALTED), "verdict");
        vm.expectRevert(abi.encodeWithSelector(IAftermarketOracle.MarketHalted.selector, uint256(0)));
        oracle.price();
    }

    /// @notice Paused B20 transfers mean the collateral cannot move, so it must not be priced either.
    function test_Verdict_TransferPaused_Halted() public {
        collateral.setTransferPaused(true);

        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_HALTED), "verdict");
        vm.expectRevert(abi.encodeWithSelector(IAftermarketOracle.MarketHalted.selector, uint256(1e18)));
        oracle.price();
    }

    /// @notice The optional issuer registry can halt the oracle on its own.
    function test_Verdict_IssuerRegistryPaused_Halted() public {
        OracleConfig memory cfg = _config(address(collateral), address(loan), address(pool));
        cfg.multiplierRegistry = address(registry);
        AftermarketOracle o = new AftermarketOracle(cfg);

        assertEq(uint256(o.peek().verdict), uint256(Verdict.TRUSTED), "clean before the pause");
        registry.setPaused(true);
        assertEq(uint256(o.peek().verdict), uint256(Verdict.UNTRUSTED_HALTED), "halted after");

        vm.expectRevert(abi.encodeWithSelector(IAftermarketOracle.MarketHalted.selector, uint256(1e18)));
        o.price();
    }

    /// @notice A non-positive Chainlink answer is never a price.
    function test_Verdict_NonPositiveAnswer_InvalidFeedAnswer() public {
        feed.set(-1, block.timestamp);

        Quote memory q = oracle.peek();
        assertEq(uint256(q.verdict), uint256(Verdict.UNTRUSTED_HALTED), "verdict");
        assertEq(q.anchorPrice, 0, "anchor");
        assertEq(q.markBorrow, 0, "no mark without an anchor");

        vm.expectRevert(abi.encodeWithSelector(IAftermarketOracle.InvalidFeedAnswer.selector, int256(-1)));
        oracle.price();

        feed.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketOracle.InvalidFeedAnswer.selector, int256(0)));
        oracle.price();
    }

    /// @notice A reverting aggregator degrades identically, with a zero payload.
    function test_Verdict_FeedReverts_InvalidFeedAnswer() public {
        feed.setReverting(true);

        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_HALTED), "verdict");
        vm.expectRevert(abi.encodeWithSelector(IAftermarketOracle.InvalidFeedAnswer.selector, int256(0)));
        oracle.price();
    }

    /// @notice `observe()` reverting - the signature of insufficient observation cardinality - must
    ///         degrade the verdict, never break `peek()`.
    function test_ObserveReverts_PeekStillAnswers() public {
        _setFrozenWeekend();
        pool.setObserveReverting(true);

        Quote memory q = oracle.peek();
        assertEq(uint256(q.verdict), uint256(Verdict.UNTRUSTED_THIN), "closed market loses its witness");
        assertEq(q.poolPrice, 0, "no TWAP");
        assertGt(q.poolLiquidityUsd, 0, "depth is still readable");
        assertGt(q.anchorPrice, 0, "the anchor still reads");

        // The same failure during the regular session is survivable: the feed is live.
        calendar.set(Session.REGULAR, 0, 0, 0);
        feed.set(FROZEN_ANSWER, block.timestamp);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "open market falls back to the anchor");
    }

    /// @notice With no session view the oracle assumes nothing: tightest budgets, maximum haircut,
    ///         and the pool must corroborate.
    function test_CalendarReverts_PeekStillAnswers() public {
        calendar.setReverting(true);

        Quote memory q = oracle.peek();
        assertEq(uint256(q.session), uint256(Session.CLOSED_HOLIDAY), "unknown session reported as closed");
        assertEq(q.stalenessBudget, 1 hours, "tightest budget");
        assertEq(q.divergenceBand, 100, "tightest band");
        assertEq(q.haircutBps, MAX_HAIRCUT_BPS, "maximum haircut");
        assertEq(uint256(q.verdict), uint256(Verdict.TRUSTED_CLOSED), "pool corroborates, so still quotable");

        pool.setObserveReverting(true);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_THIN), "without the pool, nothing");
    }

    /// @notice Ordering of the verdict rules: a halt outranks staleness outranks thinness outranks
    ///         divergence.
    function test_VerdictPrecedence() public {
        // Stale, thin and divergent all at once, plus a halt: the halt wins.
        calendar.set(Session.CLOSED_WEEKEND, 200 hours, 0, 0);
        feed.set(FROZEN_ANSWER, block.timestamp - 200 hours);
        collateral.setMultiplier(0);
        pool.setObserveReverting(true);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_HALTED), "halt outranks all");

        // Remove the halt: staleness wins over thinness.
        collateral.setMultiplier(1e18);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_STALE), "stale outranks thin");

        // Remove the staleness: thinness wins over divergence.
        feed.set(FROZEN_ANSWER, block.timestamp - 1 hours);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_THIN), "thin outranks divergent");
    }

    /*//////////////////////////////////////////////////////////////
                             GAP HAIRCUT
    //////////////////////////////////////////////////////////////*/

    /// @notice The haircut is zero on the tape, opens at the base rate the moment the bell rings, and
    ///         climbs one slope per closed hour until it saturates.
    function test_HaircutSchedule() public {
        feed.set(FROZEN_ANSWER, block.timestamp);

        calendar.set(Session.REGULAR, 0, 0, 0);
        assertEq(oracle.peek().haircutBps, 0, "regular session has no gap to price");

        calendar.set(Session.POST, 1 minutes, 0, 0);
        assertEq(oracle.peek().haircutBps, BASE_HAIRCUT_BPS, "base rate at the bell");

        calendar.set(Session.CLOSED_OVERNIGHT, 10 hours, 0, 0);
        assertEq(oracle.peek().haircutBps, BASE_HAIRCUT_BPS + 10 * HAIRCUT_SLOPE_BPS_PER_HOUR, "10 hours in");

        calendar.set(Session.CLOSED_WEEKEND, 40 hours, 0, 0);
        assertEq(oracle.peek().haircutBps, MAX_HAIRCUT_BPS, "capped");

        calendar.set(Session.CLOSED_HOLIDAY, 100 hours, 0, 0);
        assertEq(oracle.peek().haircutBps, MAX_HAIRCUT_BPS, "still capped");
    }

    /*//////////////////////////////////////////////////////////////
                           POOL PLUMBING
    //////////////////////////////////////////////////////////////*/

    /// @notice The same economic price must come out whichever side of the pool the collateral is on.
    function test_TokenOrderingIsHandledGenerically() public {
        MockCLPool flipped = new MockCLPool(address(collateral), address(loan), 10);
        flipped.setMeanTick(-TICK_NVDAC_231, TWAP_WINDOW);
        loan.mint(address(flipped), 250_000e6);

        AftermarketOracle o = new AftermarketOracle(_config(address(collateral), address(loan), address(flipped)));
        assertTrue(o.collateralIsToken0(), "collateral is token0 here");
        assertFalse(oracle.collateralIsToken0(), "and token1 in the live layout");

        _setFrozenWeekend();
        assertApproxEqRel(o.peek().poolPrice, oracle.peek().poolPrice, 0.0001e18, "same price, either ordering");
    }

    /// @notice The oracle refuses to deploy against a pool that does not hold the pair.
    function test_Constructor_RejectsForeignPool() public {
        MockB20 stranger = new MockB20("Stranger", "STR", 18, false);
        MockCLPool wrong = new MockCLPool(address(stranger), address(loan), 10);

        OracleConfig memory cfg = _config(address(collateral), address(loan), address(wrong));
        vm.expectRevert(
            abi.encodeWithSelector(AftermarketOracle.PoolTokenMismatch.selector, address(stranger), address(loan))
        );
        new AftermarketOracle(cfg);
    }

    /// @notice Plain ERC-20 collateral with no `multiplier()` is supported and never policed on it.
    function test_CollateralWithoutMultiplierIsNotPoliced() public {
        MockB20 plain = new MockB20("Plain", "PLN", 8, false);
        MockCLPool p = new MockCLPool(address(loan), address(plain), 10);
        p.setMeanTick(TICK_NVDAC_231, TWAP_WINDOW);
        loan.mint(address(p), 250_000e6);

        AftermarketOracle o = new AftermarketOracle(_config(address(plain), address(loan), address(p)));
        assertFalse(o.tracksMultiplier(), "nothing to police");

        Quote memory q = o.peek();
        assertEq(q.multiplier, 1e18, "reported as a no-op multiplier");
        assertEq(uint256(q.verdict), uint256(Verdict.TRUSTED), "verdict");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice For any anchor, any pool tick and any amount of closed time, the borrow mark never
    ///         exceeds the liquidation mark, and neither collapses to zero on a real price.
    function testFuzz_MarksAreMonotonic(uint64 answer, int24 tick, uint32 closedSeconds, uint8 sessionRaw) public {
        answer = uint64(bound(answer, 1e6, 1e14)); // $0.01 .. $1,000,000 at 8 decimals
        tick = int24(bound(int256(tick), -200_000, 200_000));
        Session session = Session(bound(sessionRaw, 0, 5));

        feed.set(int256(uint256(answer)), block.timestamp);
        calendar.set(session, closedSeconds, 0, 0);
        pool.setMeanTick(tick, TWAP_WINDOW);

        Quote memory q = oracle.peek();

        assertLe(q.markBorrow, q.markLiquidate, "markBorrow <= markLiquidate");
        assertGt(q.anchorPrice, 0, "a positive answer is always an anchor");
        assertGt(q.markBorrow, 0, "a real anchor always yields a real mark");
        assertGt(q.markLiquidate, 0, "a real anchor always yields a real mark");
        assertLe(q.haircutBps, MAX_HAIRCUT_BPS, "haircut is capped");
    }

    /// @notice Both marks are zero exactly when there is no anchor to build them from.
    function testFuzz_MarksAreZeroOnlyWithoutAnAnchor(int256 answer) public {
        answer = bound(answer, type(int64).min, 0);
        feed.set(answer, block.timestamp);

        Quote memory q = oracle.peek();
        assertEq(q.anchorPrice, 0, "no anchor");
        assertEq(q.markBorrow, 0, "no borrow mark");
        assertEq(q.markLiquidate, 0, "no liquidation mark");
    }

    /// @notice `peek()` is total. Whatever the four sources say, a keeper always gets an answer.
    function testFuzz_PeekNeverReverts(
        int256 answer,
        uint64 updatedAt,
        int56 cumulativeOld,
        int56 cumulativeNow,
        uint128 poolBalance,
        uint256 multiplier,
        uint8 sessionRaw,
        uint64 closedSeconds,
        bool observeReverting,
        bool calendarReverting
    ) public {
        feed.set(answer, updatedAt);
        pool.setCumulatives(cumulativeOld, cumulativeNow);
        pool.setObserveReverting(observeReverting);
        loan.mint(address(pool), poolBalance);
        collateral.setMultiplier(multiplier);
        calendar.set(Session(bound(sessionRaw, 0, 5)), closedSeconds, 0, 0);
        calendar.setReverting(calendarReverting);

        Quote memory q = oracle.peek();
        assertLe(uint256(q.verdict), uint256(Verdict.UNTRUSTED_HALTED), "verdict is a valid enum member");
        assertLe(q.markBorrow, q.markLiquidate, "marks stay ordered under any input");
    }

    /*//////////////////////////////////////////////////////////////
                                FACTORY
    //////////////////////////////////////////////////////////////*/

    /// @notice One config, one salt, one address - and the prediction matches the deployment.
    function test_Factory_DeterministicDeployment() public {
        AftermarketOracleFactory factory = new AftermarketOracleFactory();
        OracleConfig memory cfg = _config(address(collateral), address(loan), address(pool));

        address predicted = factory.predictAddress(cfg);

        vm.expectEmit(true, true, true, true);
        emit AftermarketOracleFactory.OracleDeployed(
            predicted, address(collateral), address(loan), factory.saltFor(cfg)
        );
        AftermarketOracle deployed = factory.deploy(cfg);

        assertEq(address(deployed), predicted, "predicted address");
        assertEq(factory.oracleFor(address(collateral), address(loan)), predicted, "registry entry");
        assertEq(deployed.collateralToken(), address(collateral), "wired collateral");
        assertEq(uint256(deployed.peek().verdict), uint256(Verdict.TRUSTED), "the deployed oracle works");
    }

    /// @notice Identical configs collide on the same address, so redeploying is impossible.
    function test_Factory_SameConfigCannotBeDeployedTwice() public {
        AftermarketOracleFactory factory = new AftermarketOracleFactory();
        OracleConfig memory cfg = _config(address(collateral), address(loan), address(pool));

        factory.deploy(cfg);
        vm.expectRevert();
        factory.deploy(cfg);
    }

    /// @notice A different config is a different address, and the canonical registry entry stands.
    function test_Factory_RegistryIsFirstWriterWins() public {
        AftermarketOracleFactory factory = new AftermarketOracleFactory();
        OracleConfig memory cfg = _config(address(collateral), address(loan), address(pool));

        address first = address(factory.deploy(cfg));

        cfg.twapWindow = 3600;
        address second = address(factory.deploy(cfg));

        assertTrue(first != second, "different config, different address");
        assertEq(factory.oracleFor(address(collateral), address(loan)), first, "first deployment stays canonical");
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    /// @notice Both hot paths must stay cheap enough for Morpho to call them inline.
    function test_Gas_PriceAndPeek() public {
        _setFrozenWeekend();
        IAftermarketOracle o = IAftermarketOracle(address(oracle));
        o.peek(); // warm every account the read touches, so both numbers are steady-state

        uint256 before = gasleft();
        o.price();
        uint256 priceGas = before - gasleft();

        before = gasleft();
        o.peek();
        uint256 peekGas = before - gasleft();

        console2.log("price() gas:", priceGas);
        console2.log("peek()  gas:", peekGas);

        assertLt(priceGas, 100_000, "price() must stay well inside a Morpho borrow");
        assertLt(peekGas, 100_000, "peek() must stay cheap for keepers");
    }

    /*//////////////////////////////////////////////////////////////
                               FORK TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Against real Base mainnet state: the live NVDAc token, the live Chainlink feed and the
    ///         live Aerodrome pool. Skips cleanly when no RPC is configured.
    function testFork_BaseMainnet_LiveQuote() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("BASE_RPC_URL not set - skipping mainnet fork test");
            return;
        }
        vm.createSelectFork(rpc);

        // NVDAc is a Rust precompile. Stock `forge` cannot execute one - every call to it halts with
        // OpcodeNotFound - so its ERC-20 surface is shimmed here. Running under `base-forge` hosts the
        // real precompile and makes the shim unnecessary. Nothing on the price path touches the
        // collateral contract: the mark comes from the feed, the pool and the loan-side balance, all
        // of which are live mainnet state below.
        vm.etch(NVDAC, address(new MockB20("Coinbase NVDA", "NVDAc", 8, false)).code);

        // Forking wipes the fixture, so the calendar is redeployed here.
        MockCalendar liveCalendar = new MockCalendar(Session.CLOSED_WEEKEND, 52 hours);
        OracleConfig memory cfg = _config(NVDAC, USDC, NVDAC_USDC_POOL);
        cfg.feed = NVDA_FEED;
        cfg.calendar = address(liveCalendar);
        AftermarketOracle live = new AftermarketOracle(cfg);

        Quote memory q = live.peek();

        console2.log("verdict          :", uint256(q.verdict));
        console2.log("anchor  (1e18)   :", q.anchorPrice);
        console2.log("pool    (1e18)   :", q.poolPrice);
        console2.log("feedAge (s)      :", q.feedAge);
        console2.log("divergence (bps) :", q.divergenceBps);
        console2.log("poolLiquidityUsd :", q.poolLiquidityUsd);

        assertGt(q.anchorPrice, 1e18, "a real equity trades above $1");
        assertLt(q.anchorPrice, 100_000e18, "and below $100,000");
        assertEq(live.collateralIsToken0(), false, "USDC is token0 in the live pool");
        assertGt(q.poolPrice, 0, "the live pool holds enough observations for a 30-minute TWAP");
        assertGt(q.poolLiquidityUsd, 0, "the live pool holds USDC");
        assertApproxEqRel(q.poolPrice, q.anchorPrice, 0.25e18, "the two venues must be in the same ballpark");
        assertLe(q.markBorrow, q.markLiquidate, "the marks stay ordered on live state");
        assertLe(uint256(q.verdict), uint256(Verdict.UNTRUSTED_HALTED), "verdict is a valid enum member");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The deployment defaults: 1h regular staleness widening to 104h over a holiday, a 100bps
    ///      regular divergence band widening to 250bps once closed, and a 25bps + 15bps/h gap haircut
    ///      capped at 500bps.
    function _config(address collateral_, address loan_, address pool_) internal view returns (OracleConfig memory) {
        return OracleConfig({
            collateralToken: collateral_,
            loanToken: loan_,
            feed: address(feed),
            pool: pool_,
            calendar: address(calendar),
            multiplierRegistry: address(0),
            twapWindow: TWAP_WINDOW,
            stalenessBudget: [
                uint32(1 hours), // REGULAR
                uint32(6 hours), // PRE
                uint32(6 hours), // POST
                uint32(20 hours), // CLOSED_OVERNIGHT
                uint32(80 hours), // CLOSED_WEEKEND
                uint32(104 hours) // CLOSED_HOLIDAY
            ],
            divergenceBandBps: [uint16(100), uint16(150), uint16(150), uint16(250), uint16(250), uint16(250)],
            baseHaircutBps: BASE_HAIRCUT_BPS,
            haircutSlopeBpsPerHour: HAIRCUT_SLOPE_BPS_PER_HOUR,
            maxHaircutBps: MAX_HAIRCUT_BPS,
            minPoolLiquidityUsd: MIN_POOL_LIQUIDITY_USD,
            minMultiplier: 0.01e18,
            maxMultiplier: 1000e18
        });
    }

    /// @dev Sunday evening: weekend session, feed frozen 52 hours, deep pool trading away from it.
    function _setFrozenWeekend() internal {
        calendar.set(Session.CLOSED_WEEKEND, FROZEN_AGE, 0, 0);
        feed.set(FROZEN_ANSWER, block.timestamp - FROZEN_AGE);
        pool.setMeanTick(TICK_NVDAC_231, TWAP_WINDOW);
    }

    /// @dev Wednesday 11:00: live feed, regular session, and a pool too shallow to matter.
    function _setRegularAnchorOnly() internal {
        calendar.set(Session.REGULAR, 0, 0, 0);
        feed.set(FROZEN_ANSWER, block.timestamp);
        vm.mockCall(address(loan), abi.encodeWithSignature("balanceOf(address)", address(pool)), abi.encode(uint256(0)));
    }

    /// @dev Rebuilds the whole fixture at other token decimals, holding the anchor fixed.
    function _deployWithDecimals(uint8 collateralDecimals, uint8 loanDecimals) internal returns (AftermarketOracle) {
        MockB20 c = new MockB20("Collateral", "COLL", collateralDecimals, true);
        MockB20 l = new MockB20("Loan", "LOAN", loanDecimals, false);
        MockCLPool p = new MockCLPool(address(l), address(c), 10);

        OracleConfig memory cfg = _config(address(c), address(l), address(p));
        AftermarketOracle o = new AftermarketOracle(cfg);

        calendar.set(Session.REGULAR, 0, 0, 0);
        feed.set(FROZEN_ANSWER, block.timestamp);
        // No depth: the anchor stands alone, so the scale factor is the only thing under test.
        return o;
    }
}
