// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ICLPool} from "../../src/interfaces/ICLPool.sol";
import {Quote, Session, Verdict} from "../../src/libraries/Types.sol";

import {ForkBase} from "./ForkBase.sol";

/// @notice The Slipstream `slot0` read used to anchor the simulated price shock to the live tick.
interface ICLPoolSlot0 {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );
}

/// @title  WeekendReplayTest
/// @notice The mechanism, replayed over the real Labor Day weekend of 2026 at real Base blocks.
///
/// @dev Every row of the timeline below is a separate fork of Base mainnet pinned to a real block
///      number, so the Chainlink feed really is that stale at that instant and the Aerodrome pool
///      really did print that price. Nothing is synthesised until the table runs out of chain: the
///      last two rows are produced by `vm.warp` on top of the final pinned block, because Monday
///      2026-09-07 is Labor Day and Tuesday's opening bell has not happened yet.
///
///      The weekend under replay is deliberately the interesting one. The US market closed on
///      Friday 2026-09-04 at 16:00 ET and does not reopen until Tuesday 2026-09-08 at 09:30 ET,
///      because Monday is an exchange holiday. That is an 89.5-hour gap between two real prints,
///      which is exactly the window in which a naive oracle liquidates people against a price
///      nobody can defend.
///
///      Run with `base-forge test`. See `test/fork/README.md`.
contract WeekendReplayTest is ForkBase {
    /*//////////////////////////////////////////////////////////////
                    PINNED BASE MAINNET BLOCK NUMBERS
    //////////////////////////////////////////////////////////////*/

    // Base produces a block every two seconds with no gaps, so a block number and a unix timestamp
    // are interchangeable through `block = head - (headTs - ts) / 2`. These six were located by
    // binary-searching `block.timestamp` from the chain head with `base-cast block <n> --field
    // timestamp`, and every one of them is re-asserted at the top of the sampling loop: if an
    // archive node ever hands back a different timestamp for these heights, the test fails loudly
    // instead of quietly replaying the wrong weekend.

    /// @notice 2026-09-04 17:00:01 UTC = Friday 13:00:01 ET. Mid-session, feed live.
    uint256 internal constant BLOCK_FRI_MID = 50_875_927;
    uint256 internal constant TS_FRI_MID = 1_788_541_201;

    /// @notice 2026-09-04 20:05:01 UTC = Friday 16:05:01 ET. Five minutes after the closing bell.
    uint256 internal constant BLOCK_FRI_POST = 50_881_477;
    uint256 internal constant TS_FRI_POST = 1_788_552_301;

    /// @notice 2026-09-05 00:05:01 UTC = Friday 20:05:01 ET. Post-market is over too.
    uint256 internal constant BLOCK_FRI_NIGHT = 50_888_677;
    uint256 internal constant TS_FRI_NIGHT = 1_788_566_701;

    /// @notice 2026-09-05 12:00:01 UTC = Saturday 08:00:01 ET.
    uint256 internal constant BLOCK_SAT = 50_910_127;
    uint256 internal constant TS_SAT = 1_788_609_601;

    /// @notice 2026-09-06 12:00:01 UTC = Sunday 08:00:01 ET.
    uint256 internal constant BLOCK_SUN = 50_953_327;
    uint256 internal constant TS_SUN = 1_788_696_001;

    /// @notice 2026-09-07 00:00:01 UTC = Sunday 20:00:01 ET. The deepest point of the weekend that
    ///         a real block exists for at the time of writing.
    uint256 internal constant BLOCK_SUN_LATE = 50_974_927;
    uint256 internal constant TS_SUN_LATE = 1_788_739_201;

    /*//////////////////////////////////////////////////////////////
                     TIMESTAMPS REACHED BY vm.warp ONLY
    //////////////////////////////////////////////////////////////*/

    /// @notice Friday's regular close, 2026-09-04 20:00:00 UTC = 16:00:00 ET. The instant every
    ///         haircut in this file is measured from.
    uint256 internal constant TS_FRI_CLOSE = 1_788_552_000;

    /// @notice 2026-09-07 16:00:00 UTC = Monday 12:00:00 ET. Labor Day: the exchange is shut and
    ///         there is no opening bell at all. Reached by warping; no block exists here yet.
    uint256 internal constant TS_MON_HOLIDAY = 1_788_796_800;

    /// @notice 2026-09-08 13:30:00 UTC = Tuesday 09:30:00 ET. The next real opening bell.
    uint256 internal constant TS_TUE_OPEN = 1_788_874_200;

    /// @notice Tuesday's bell plus the 30-minute cure window: where a weekend flag's grace lands.
    uint256 internal constant TS_TUE_CURE_END = TS_TUE_OPEN + 30 minutes;

    /// @notice 2026-09-09 00:30:00 UTC = Tuesday 20:30:00 ET, after post-market. Market shut again.
    uint256 internal constant TS_TUE_EVENING = 1_788_913_800;

    /// @notice 2026-09-09 14:00:00 UTC = Wednesday 10:00:00 ET. Market open, half an hour in.
    uint256 internal constant TS_WED_OPEN = 1_788_962_400;

    /*//////////////////////////////////////////////////////////////
                                 SHAPE
    //////////////////////////////////////////////////////////////*/

    /// @notice The fixed basket the timeline prices: 100 whole NVDAc, in raw 8-decimal units.
    uint256 internal constant BASKET = 100e8;

    /// @notice Divides an NVDAc/USDC Morpho-scale mark back into WAD USD.
    /// @dev `_morphoScale` for this pair is `10 ** (18 + 6 - 8)`.
    uint256 internal constant NVDA_MARK_TO_WAD = 1e16;

    /// @notice Tick offset that halves the NVDAc price: `1.0001 ** -6932 == 0.49998`.
    /// @dev Slipstream prices token1 (NVDAc) against token0 (USDC), so a higher tick is a cheaper
    ///      equity. Used only by the labelled shock in the mechanism test.
    int24 internal constant SHOCK_TICKS = 6932;

    uint256 internal constant TIMELINE_ROWS = 8;

    struct Row {
        string label;
        string source;
        uint256 timestamp;
        Session session;
        Verdict verdict;
        uint256 feedAge;
        uint256 divergenceBps;
        uint256 band;
        uint256 haircutBps;
        uint256 markWad;
        uint256 power;
        bool priced;
        Verdict amznVerdict;
        uint256 amznDivergenceBps;
    }

    /// @dev Captured before the price mock is installed so the mock can later be re-issued with a
    ///      fresh `updatedAt` without losing the shocked answer.
    int256 internal shockedAnswer;
    uint80 internal shockedRoundId;

    /*//////////////////////////////////////////////////////////////
                            1. THE TIMELINE
    //////////////////////////////////////////////////////////////*/

    /// @notice Prices the same basket at six real historical blocks and two warped instants, and
    ///         proves borrowing power contracts monotonically as the weekend deepens while the gap
    ///         haircut climbs to its ceiling and saturates.
    function test_weekendTimelineContractsBorrowingPower() public {
        Row[] memory rows = new Row[](TIMELINE_ROWS);

        rows[0] = _sampleAt(BLOCK_FRI_MID, TS_FRI_MID, "Fri 13:00 ET  mid-session");
        rows[1] = _sampleAt(BLOCK_FRI_POST, TS_FRI_POST, "Fri 16:05 ET  bell + 5m");
        rows[2] = _sampleAt(BLOCK_FRI_NIGHT, TS_FRI_NIGHT, "Fri 20:05 ET  post over");
        rows[3] = _sampleAt(BLOCK_SAT, TS_SAT, "Sat 08:00 ET");
        rows[4] = _sampleAt(BLOCK_SUN, TS_SUN, "Sun 08:00 ET");
        rows[5] = _sampleAt(BLOCK_SUN_LATE, TS_SUN_LATE, "Sun 20:00 ET  last block");

        // Beyond here the chain has not happened yet, so time is moved by hand. State - the feed's
        // `updatedAt`, the pool's observations, the pool's USDC depth - stays exactly as it stood at
        // block 50,974,927; only `block.timestamp` advances. That is the honest shape of the
        // question being asked: what would this oracle say about Monday's and Tuesday's clock if
        // nothing else changed?
        vm.warp(TS_MON_HOLIDAY);
        rows[6] = _sample("Mon 12:00 ET  Labor Day", "warp");

        vm.warp(TS_TUE_OPEN);
        rows[7] = _sample("Tue 09:30 ET  next bell", "warp");

        string memory table = _render(rows);
        console2.log(table);
        vm.writeFile(_timelinePath(), table);

        // --- what the table has to prove ------------------------------------------------------

        assertEq(uint256(rows[0].session), uint256(Session.REGULAR), "Friday 13:00 ET is a regular session");
        assertEq(uint256(rows[1].session), uint256(Session.POST), "Friday 16:05 ET is post-market");
        assertEq(uint256(rows[2].session), uint256(Session.CLOSED_OVERNIGHT), "Friday 20:05 ET is the overnight gap");
        assertEq(uint256(rows[3].session), uint256(Session.CLOSED_WEEKEND), "Saturday is the weekend");
        assertEq(uint256(rows[4].session), uint256(Session.CLOSED_WEEKEND), "Sunday is the weekend");
        assertEq(uint256(rows[5].session), uint256(Session.CLOSED_WEEKEND), "Sunday night is the weekend");
        assertEq(uint256(rows[6].session), uint256(Session.CLOSED_HOLIDAY), "Labor Day is an exchange holiday");
        assertEq(uint256(rows[7].session), uint256(Session.REGULAR), "Tuesday 09:30 ET is the opening bell");

        // The feed ages continuously across the whole window: it is one frozen print, not a series.
        for (uint256 i = 1; i < TIMELINE_ROWS; ++i) {
            assertGt(rows[i].feedAge, rows[i - 1].feedAge, "the Chainlink anchor must keep ageing");
        }
        assertGt(rows[5].feedAge, 50 hours, "by Sunday night the anchor is more than two days old");

        // The haircut is zero while the tape is live, then climbs every hour the market stays shut,
        // and stops climbing at its ceiling. That ceiling is reached on the Labor Day Monday.
        assertEq(rows[0].haircutBps, 0, "no gap haircut while a regular session runs");
        for (uint256 i = 2; i < 7; ++i) {
            assertGt(rows[i].haircutBps, rows[i - 1].haircutBps, "the gap haircut must widen hour by hour");
        }
        assertEq(rows[6].haircutBps, MAX_HAIRCUT_BPS, "the haircut must saturate at its ceiling");

        // Borrowing power against an unchanged basket contracts at every step of the weekend.
        for (uint256 i = 1; i < 7; ++i) {
            assertTrue(rows[i].priced, "NVDAc must stay quotable through the weekend");
            assertLt(rows[i].power, rows[i - 1].power, "borrowing power must contract as the weekend deepens");
        }
        assertLt((rows[6].power * BPS) / rows[0].power, 6_000, "power must fall by more than 40% across the weekend");

        // At Tuesday's bell the session flips back to REGULAR, and a feed that is still carrying
        // Friday's print is now four days past a six-hour budget. The oracle refuses to quote
        // rather than pretending the reopening print already happened.
        assertEq(uint256(rows[7].verdict), uint256(Verdict.UNTRUSTED_STALE), "a REGULAR session demands a live feed");
        assertFalse(rows[7].priced, "no borrowing power against a stale reopening");

        // The AMZNc market is the one that actually broke, and it broke on Sunday morning rather
        // than at the closing bell: the thin pool drifted away from the frozen anchor overnight.
        assertEq(uint256(rows[3].amznVerdict), uint256(Verdict.TRUSTED_CLOSED), "AMZNc still corroborated on Saturday");
        assertEq(uint256(rows[4].amznVerdict), uint256(Verdict.UNTRUSTED_DIVERGENT), "AMZNc diverged by Sunday");
        assertGt(rows[4].amznDivergenceBps, WEEKEND_BAND_BPS, "AMZNc must be outside the weekend band");
        assertLt(rows[3].amznDivergenceBps, WEEKEND_BAND_BPS, "AMZNc was inside the band a day earlier");
    }

    /*//////////////////////////////////////////////////////////////
                          2. THE MECHANISM, END TO END
    //////////////////////////////////////////////////////////////*/

    /// @notice A line drawn on Friday, carried through the whole Labor Day weekend.
    ///
    /// @dev Pinned once, at Friday 13:00 ET, and then moved through time with `vm.warp`. Carrying a
    ///      live position across separate pinned forks is not possible - a fresh fork has mainnet's
    ///      token balances, not the ones this test created - so every instant after the first is
    ///      warped, and the Friday block's feed and pool state is what the oracle keeps reading.
    ///      That is the conservative direction: the anchor genuinely would not have moved.
    ///
    ///      The first half of the test is entirely real and makes the protocol's central claim:
    ///      **a weekend cannot make you liquidatable.** The seizure threshold rises when the market
    ///      shuts, because the optimistic mark carries the gap haircut upwards and the closed-market
    ///      liquidation threshold is more forgiving than the open one. A line that was healthy at
    ///      Friday's close is strictly healthier on Saturday, on Sunday and on the Labor Day Monday.
    ///
    ///      The second half needs a line that actually is underwater, and there is no honest way to
    ///      get one out of this weekend's real data, so it applies a single clearly labelled shock:
    ///      both price sources marked down 50%. Everything after that - the flag, the grace clock
    ///      landing past Tuesday's bell, `liquidate` refusing to run while the market is shut, and
    ///      the eventual seizure of real NVDAc - is the production contracts reacting to it.
    function test_weekendMechanismFlagGraceAndSeizure() public {
        _forkAt(BLOCK_FRI_MID);
        assertEq(block.timestamp, TS_FRI_MID, "Friday mid-session pin moved");

        _deployStackWith("NVDAc", NVDA, NVDA_FEED);
        _attest(lender);
        _attest(borrower);

        _seedUsdc(lender, 1_000_000e6);
        vm.prank(lender);
        vault.deposit(1_000_000e6, lender);

        uint256 collateralAmount = _buyCollateral(NVDA, 60_000e6, borrower);
        _approveUsdc(borrower);

        vm.startPrank(borrower);
        credit.openLine();
        credit.depositCollateral(NVDA, collateralAmount);
        uint256 drawn = credit.borrowPower(borrower);
        credit.draw(drawn, borrower);
        vm.stopPrank();

        // --- Friday, live tape, real marks ----------------------------------------------------
        assertEq(uint256(calendar.session()), uint256(Session.REGULAR), "expected a live Friday session");
        assertTrue(calendar.isOpen(block.timestamp), "Friday 13:00 ET must be open");

        uint256 thresholdFriday = credit.seizureThreshold(borrower);
        assertGt(thresholdFriday, drawn, "a freshly maxed line must not be liquidatable");
        _expectHealthy();

        // --- the bell rings, and then the whole weekend passes - all of it real pricing --------
        vm.warp(TS_FRI_POST);
        _expectHealthy();

        vm.warp(TS_SAT);
        uint256 thresholdSaturday = credit.seizureThreshold(borrower);
        assertGt(thresholdSaturday, thresholdFriday, "seizure must get harder, not easier, once the market shuts");
        _expectHealthy();

        vm.warp(TS_SUN);
        _expectHealthy();

        vm.warp(TS_MON_HOLIDAY);
        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_HOLIDAY), "Labor Day");
        assertGt(credit.seizureThreshold(borrower), thresholdSaturday, "the holiday makes seizure harder still");
        _expectHealthy();

        console2.log("debt drawn on Friday        ", drawn);
        console2.log("seizure threshold Friday    ", thresholdFriday);
        console2.log("seizure threshold Saturday  ", thresholdSaturday);
        console2.log("seizure threshold Labor Day ", credit.seizureThreshold(borrower));

        // ---- SIMULATED INPUT: a 50% adverse move in NVDA, applied to both price sources -------
        // Real weekend data cannot produce an unhealthy line here, by construction - that is the
        // product. To exercise the rest of the mechanism the anchor and the pool are both marked
        // down together, which is how a real gap behaves: the pool tracks the underlying, so the
        // two sources stay in agreement while both fall.
        vm.warp(TS_SAT);
        _applyPriceShock();
        // ---------------------------------------------------------------------------------------

        assertLt(credit.seizureThreshold(borrower), credit.debtOf(borrower), "the shock must put the line underwater");

        // --- the flag, and where its grace lands ----------------------------------------------
        uint64 nextOpen = calendar.nextOpen(block.timestamp);
        assertEq(uint256(nextOpen), TS_TUE_OPEN, "the next bell skips the Labor Day Monday entirely");

        credit.flag(borrower);
        assertTrue(credit.isFlagged(borrower), "the line should be flagged");
        assertEq(uint256(credit.graceUntil(borrower)), TS_TUE_CURE_END, "grace must land 30 minutes after the bell");
        assertGt(uint256(credit.graceUntil(borrower)), TS_MON_HOLIDAY, "grace must outlast the holiday");
        assertGt(uint256(credit.graceUntil(borrower)), uint256(nextOpen), "grace must outlast the bell itself");

        // --- nobody can seize, at any point of the weekend ------------------------------------
        _seedUsdc(liquidator, 200_000e6);
        _expectSeizureBlocked(IAftermarketCredit.GraceNotExpired.selector); // Saturday

        vm.warp(TS_SUN);
        assertFalse(calendar.isOpen(block.timestamp), "Sunday must be shut");
        _expectSeizureBlocked(IAftermarketCredit.GraceNotExpired.selector);

        // The borrower, meanwhile, can always act. Repayment reads no oracle and checks no flag.
        vm.prank(borrower);
        (uint256 repaidWhileFlagged,) = credit.repay(500e6);
        assertEq(repaidWhileFlagged, 500e6, "a flagged borrower must still be able to cure");
        assertTrue(credit.isFlagged(borrower), "a partial repayment does not clear the flag");

        vm.warp(TS_MON_HOLIDAY);
        _expectSeizureBlocked(IAftermarketCredit.GraceNotExpired.selector);

        vm.warp(TS_TUE_OPEN + 5 minutes);
        assertTrue(calendar.isOpen(block.timestamp), "Tuesday 09:35 ET must be open");
        _expectSeizureBlocked(IAftermarketCredit.GraceNotExpired.selector);

        // --- grace expires, but the calendar still governs ------------------------------------
        vm.warp(TS_TUE_EVENING);
        assertGt(block.timestamp, TS_TUE_CURE_END, "grace has expired by Tuesday evening");
        assertFalse(calendar.isOpen(block.timestamp), "Tuesday 20:30 ET is shut again");
        _expectSeizureBlocked(IAftermarketCredit.MarketClosed.selector);

        // --- and finally, in a real open market, seizure works ---------------------------------
        vm.warp(TS_WED_OPEN);
        assertTrue(calendar.isOpen(block.timestamp), "Wednesday 10:00 ET must be open");
        // SIMULATED INPUT: the reopening print. At a fork pinned to Friday there is no Wednesday
        // round to read, so the shocked answer is re-issued with a fresh `updatedAt`.
        _refreshShockedFeed();

        uint256 debtBefore = credit.debtOf(borrower);
        uint256 collateralBefore = credit.collateral(borrower, NVDA);
        uint256 repayAssets = (debtBefore * credit.CLOSE_FACTOR_BPS()) / BPS;
        (uint256 quotedSeize, uint256 quotedCost) = credit.quoteSeizure(borrower, NVDA, repayAssets);

        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) = credit.liquidate(borrower, NVDA, repayAssets);

        assertEq(seized, quotedSeize, "quoteSeizure must price exactly what liquidate executes");
        assertEq(repaid, quotedCost, "quoteSeizure must price exactly what liquidate charges");
        assertGt(seized, 0, "nothing was seized");
        assertEq(IERC20(NVDA).balanceOf(liquidator), seized, "the liquidator did not receive real NVDAc");
        assertEq(collateralBefore - credit.collateral(borrower, NVDA), seized, "collateral not debited");
        assertEq(debtBefore - credit.debtOf(borrower), repaid, "debt not reduced by the repayment");
        assertGt(credit.collateral(borrower, NVDA), 0, "the close factor must leave the borrower a position");

        console2.log("repaid by liquidator (USDC) ", repaid);
        console2.log("seized NVDAc (1e8)          ", seized);
    }

    /*//////////////////////////////////////////////////////////////
                              SAMPLING
    //////////////////////////////////////////////////////////////*/

    /// @notice Pins a fork to `blockNumber`, redeploys the stack there, and reads one timeline row.
    /// @dev The whole protocol is redeployed at every pinned block because contracts created on one
    ///      fork simply do not exist on the next one.
    function _sampleAt(uint256 blockNumber, uint256 expectedTimestamp, string memory label)
        private
        returns (Row memory)
    {
        _forkAt(blockNumber);
        assertEq(block.timestamp, expectedTimestamp, "pinned block timestamp moved");

        _deployStackWith("NVDAc", NVDA, NVDA_FEED);
        _listAsset("AMZNc", AMZN, AMZN_FEED);

        // Every row past the bell must be measuring its haircut from the same real Friday close.
        if (block.timestamp > TS_FRI_CLOSE) {
            (,, uint64 lastClose) = calendar.sessionAt(block.timestamp);
            assertEq(uint256(lastClose), TS_FRI_CLOSE, "the calendar lost Friday's closing bell");
        }

        return _sample(label, string.concat("pin ", vm.toString(blockNumber)));
    }

    /// @notice Reads the NVDAc and AMZNc oracles at the current instant, without ever reverting.
    function _sample(string memory label, string memory source) private view returns (Row memory r) {
        Quote memory q = oracleOf[NVDA].peek();

        r.label = label;
        r.source = source;
        r.timestamp = block.timestamp;
        r.session = q.session;
        r.verdict = q.verdict;
        r.feedAge = q.feedAge;
        r.divergenceBps = q.divergenceBps;
        r.band = q.divergenceBand;
        r.haircutBps = q.haircutBps;
        r.markWad = q.markBorrow / NVDA_MARK_TO_WAD;
        // `price()` hands out `markBorrow` only for these two verdicts; every other one reverts, so
        // "priced" here is exactly "the credit engine could size a draw right now".
        r.priced = q.verdict == Verdict.TRUSTED || q.verdict == Verdict.TRUSTED_CLOSED;
        r.power = r.priced ? _expectedPower(BASKET, q.markBorrow, q.session) : 0;

        Quote memory amzn = oracleOf[AMZN].peek();
        r.amznVerdict = amzn.verdict;
        r.amznDivergenceBps = amzn.divergenceBps;
    }

    /*//////////////////////////////////////////////////////////////
                          THE SIMULATED SHOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Marks both price sources down 50%, keeping them in agreement with each other.
    /// @dev Labelled at every call site. The Chainlink `updatedAt` is left exactly as it stands on
    ///      the pinned block, so the staleness half of the oracle keeps running on real data.
    function _applyPriceShock() private {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(NVDA_FEED).latestRoundData();

        shockedRoundId = roundId;
        shockedAnswer = answer / 2;
        vm.mockCall(
            NVDA_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(roundId, shockedAnswer, startedAt, updatedAt, answeredInRound)
        );

        address pool = oracleOf[NVDA].pool();
        (, int24 tick,,,,) = ICLPoolSlot0(pool).slot0();
        _mockTwap(pool, tick + SHOCK_TICKS);
    }

    /// @notice Re-issues the shocked answer with a fresh `updatedAt`, standing in for the print the
    ///         aggregator would publish at the next opening bell.
    function _refreshShockedFeed() private {
        vm.mockCall(
            NVDA_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(
                shockedRoundId + 1,
                shockedAnswer,
                block.timestamp - 5 minutes,
                block.timestamp - 5 minutes,
                shockedRoundId + 1
            )
        );
    }

    /// @notice Forces the Slipstream TWAP to a chosen arithmetic-mean tick.
    /// @dev Two cumulatives whose difference is exactly `tick * twapWindow` reproduce that tick with
    ///      no rounding, which keeps the shocked pool price a clean function of the shocked anchor.
    function _mockTwap(address pool, int24 tick) private {
        // Only the price is being simulated. The pool's real seconds-per-liquidity cumulatives are
        // read first and handed straight back, because the oracle inverts that same pair to measure
        // the in-range depth backing the window - substituting zeros there would simulate a pool
        // with no liquidity at all rather than a pool at a different price.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;
        (, uint160[] memory secondsPerLiquidity) = ICLPool(pool).observe(secondsAgos);

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(int256(tick) * int256(uint256(TWAP_WINDOW)));

        vm.mockCall(
            pool, abi.encodeWithSelector(ICLPool.observe.selector), abi.encode(tickCumulatives, secondsPerLiquidity)
        );
    }

    /*//////////////////////////////////////////////////////////////
                                ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev The line is healthy right now: `flag` refuses on the merits.
    function _expectHealthy() private {
        vm.expectPartialRevert(IAftermarketCredit.LineHealthy.selector);
        credit.flag(borrower);
    }

    /// @dev A seizure attempt at the current instant is refused with `expectedError`.
    function _expectSeizureBlocked(bytes4 expectedError) private {
        vm.prank(liquidator);
        vm.expectPartialRevert(expectedError);
        credit.liquidate(borrower, NVDA, 1_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                               RENDERING
    //////////////////////////////////////////////////////////////*/

    function _timelinePath() private view returns (string memory) {
        // The project's `foundry.toml` grants tests write access to `./deployments` and nothing
        // else, and it is not this harness's file to edit. Override the destination with
        // `WEEKEND_TIMELINE_OUT` once a wider `fs_permissions` entry exists.
        return vm.envOr("WEEKEND_TIMELINE_OUT", string("deployments/weekend-timeline.txt"));
    }

    function _render(Row[] memory rows) private returns (string memory out) {
        vm.createDir("deployments", true);

        out = "Aftermarket - Labor Day weekend replay, Base mainnet\n";
        out = string.concat(out, "US market closed Fri 2026-09-04 16:00 ET, reopened Tue 2026-09-08 09:30 ET.\n");
        out = string.concat(out, "Monday 2026-09-07 is Labor Day, so the gap between two real prints is 89h 30m.\n");
        out = string.concat(out, "Collateral basket held fixed at 100 NVDAc. Power is USDC drawable against it.\n");
        out = string.concat(out, "Rows marked 'pin <n>' are real Base blocks; rows marked 'warp' advance the clock\n");
        out = string.concat(out, "on top of block 50,974,927 without changing any chain state.\n\n");

        out = string.concat(out, _header(), "\n", _rule(), "\n");
        for (uint256 i; i < rows.length; ++i) {
            out = string.concat(out, _row(rows[i]), "\n");
        }
        out = string.concat(out, _rule(), "\n\n", _footer(rows));
    }

    function _header() private pure returns (string memory) {
        string memory head = string.concat(_pad("when", 26), _pad("source", 15), _padLeft("unix", 12), "  ");
        head = string.concat(head, _pad("session", 18), _pad("NVDAc verdict", 21), _padLeft("feed age", 12));
        head = string.concat(head, _padLeft("div", 6));
        return string.concat(
            head, _padLeft("band", 6), _padLeft("hcut", 6), _padLeft("mark USD", 11), _padLeft("power USDC", 13)
        );
    }

    function _rule() private pure returns (string memory) {
        string memory line = "";
        for (uint256 i; i < 148; ++i) {
            line = string.concat(line, "-");
        }
        return line;
    }

    function _row(Row memory r) private pure returns (string memory row) {
        row = string.concat(_pad(r.label, 26), _pad(r.source, 15), _padLeft(vm.toString(r.timestamp), 12), "  ");
        row = string.concat(row, _pad(_sessionName(r.session), 18), _pad(_verdictName(r.verdict), 21));
        row = string.concat(row, _padLeft(_hoursMinutes(r.feedAge), 12));
        row = string.concat(row, _padLeft(vm.toString(r.divergenceBps), 6), _padLeft(vm.toString(r.band), 6));
        row = string.concat(row, _padLeft(vm.toString(r.haircutBps), 6), _padLeft(_fixed(r.markWad, 18, 2), 11));
        row = string.concat(row, _padLeft(r.priced ? _fixed(r.power, 6, 2) : "blocked", 13));
    }

    function _footer(Row[] memory rows) private pure returns (string memory out) {
        out = "AMZNc, same instants - the market that actually broke:\n";
        out = string.concat(out, _pad("when", 26), _pad("AMZNc verdict", 21), _padLeft("div bps", 9), "\n");
        for (uint256 i; i < rows.length; ++i) {
            out = string.concat(
                out,
                _pad(rows[i].label, 26),
                _pad(_verdictName(rows[i].amznVerdict), 21),
                _padLeft(vm.toString(rows[i].amznDivergenceBps), 9),
                "\n"
            );
        }
    }
}
