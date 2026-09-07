// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {AuditHarness} from "./Harness.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {Session} from "../../src/libraries/Types.sol";

/// @title  A-01 - FIXED: the nightly cure loop
/// @notice Any borrower whose loan-to-value sat between `liqThresholdOpenBps` and
///         `liqThresholdClosedBps` used to be able to postpone liquidation forever, for the price of
///         one `cure()` transaction per evening.
///
/// @dev The mechanism was four lines of the source:
///
///      1. `AftermarketCredit.flag` sets `graceUntil = max(now + 1h, calendar.nextOpen(now) + 30m)`.
///         `TradingCalendar.nextOpen` returns the first regular open *strictly after* its argument,
///         so a flag raised at any instant inside a regular session lands the grace deadline on the
///         NEXT trading day.
///      2. `AftermarketCredit.liquidate` refuses to run before `graceUntil` and refuses to run
///         unless `calendar.isOpen(now)`.
///      3. `cure` is permissionless and used to re-test health against the SEIZURE THRESHOLD, which
///         steps up twice at 16:00 ET - once because the policy switches to `liqThresholdClosedBps`,
///         and once because the oracle marks collateral UP by the gap haircut.
///      4. So the line was unhealthy every morning and healthy every evening, and the borrower
///         cleared each morning's flag before its deadline was ever reached.
///
///      The fix is step 3. `cure` now runs only while the US market is open and is measured at
///      open-session parameters, which removes both halves of the evening step at once: the gap
///      haircut is zero by construction during a regular session, and `liqThresholdOpenBps` is the
///      factor that applies. Curing is therefore the exact complement of flagging - every line is
///      either curable or seizable, never both and never neither - so a borrower who genuinely
///      recovers can always clear the flag, and one who has not cannot clear it by waiting for the
///      bell. The line below sits at 83.2% LTV against an 80% open threshold, so the evening cure
///      now fails and the seizure lands on schedule the next morning.
contract GraceLoopTest is AuditHarness {
    /// @dev $200.00 at 8 decimals, and the tick that puts the pool at the same price.
    int256 internal constant PRICE_200 = 200e8;

    /// @dev $155.00 at 8 decimals: LTV 83.2%, inside the 80.00%..85.85% trap band.
    int256 internal constant PRICE_155 = 155e8;

    function setUp() public {
        _deploy(PRICE_200);
    }

    /// @notice Sanity: the harness really is running the real oracle, the real calendar and the real
    ///         session-dependent risk policy, and the two marks are where they should be.
    function test_00_HarnessIsFaithful() public {
        // Monday 11:00 ET: regular session, no haircut.
        _warpTo(MON_2026_03_02, 11 hours);
        assertEq(uint256(calendar.session()), uint256(Session.REGULAR), "regular at 11:00 ET");
        assertTrue(calendar.isOpen(block.timestamp), "isOpen at 11:00 ET");

        uint256 openBorrow = oracle.markBorrow();
        uint256 openLiquidate = oracle.markLiquidate();
        console2.log("REGULAR  markBorrow    :", openBorrow);
        console2.log("REGULAR  markLiquidate :", openLiquidate);

        // Monday 16:01 ET: post-market. The credit engine treats this as CLOSED; the oracle applies
        // the base gap haircut in both directions.
        _warpTo(MON_2026_03_02, 16 hours + 1 minutes);
        assertEq(uint256(calendar.session()), uint256(Session.POST), "post at 16:01 ET");
        assertFalse(calendar.isOpen(block.timestamp), "not open at 16:01 ET");

        uint256 closedBorrow = oracle.markBorrow();
        uint256 closedLiquidate = oracle.markLiquidate();
        console2.log("POST     markBorrow    :", closedBorrow);
        console2.log("POST     markLiquidate :", closedLiquidate);

        assertLt(closedBorrow, openBorrow, "borrow mark is haircut down once closed");
        assertGt(closedLiquidate, openLiquidate, "liquidate mark is haircut up once closed");
    }

    /// @notice THE FIX. The same line, the same aggressive keeper, the same evening cure attempt -
    ///         and the loop closes after a single night, with the collateral seized the next morning.
    function test_01_TheEveningCureNoLongerClearsTheFlag() public {
        // --- day 0: open a maxed-out line at $200 -------------------------------------------------
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8); // 100 NVDAc == $20,000
        credit.draw(12_900e6, alice); // just inside the 6500bps advance rate
        vm.stopPrank();

        assertEq(credit.debtOf(alice), 12_900e6, "drew $12,900");

        // --- the price falls to $155, which is where the trap used to open ------------------------
        // open   threshold: 100 * 155          * 0.80 = $12,400  -> UNHEALTHY
        // closed threshold: 100 * 155*(1.01)   * 0.85 = $13,306  -> was enough to "cure"
        // advance power   : 100 * 155          * 0.65 = $10,075  -> never enough to cure
        _setPriceBoth(PRICE_155);

        (uint256 powerNow, uint256 thresholdNow) = credit.riskOf(alice);
        console2.log("after the drop, REGULAR power     :", powerNow);
        console2.log("after the drop, REGULAR threshold :", thresholdNow);
        assertLt(thresholdNow, credit.debtOf(alice), "line is unhealthy while the market is open");

        // --- 09:31 ET: the keeper flags the instant the bell rings --------------------------------
        _warpTo(MON_2026_03_02, T_OPEN + 30 minutes);
        vm.prank(keeper);
        credit.flag(alice);
        uint64 grace = credit.graceUntil(alice);
        console2.log("flagged at   :", block.timestamp);
        console2.log("graceUntil   :", uint256(grace));
        assertGt(uint256(grace), _et(MON_2026_03_02, T_CLOSE), "grace still runs past today's close");

        // Seizure is refused all day, exactly as designed: the borrower gets their notice period.
        for (uint256 h = T_OPEN + 90 minutes; h < T_CLOSE; h += 1 hours) {
            _warpTo(MON_2026_03_02, h);
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.GraceNotExpired.selector, grace));
            credit.liquidate(alice, address(nvda), 1_000e6);
        }

        // --- 16:01 ET: the bell rings, and the cure no longer works -------------------------------
        _warpTo(MON_2026_03_02, T_CLOSE + 1 minutes);
        (, uint256 closedThreshold) = credit.riskOf(alice);
        console2.log("POST threshold:", closedThreshold);
        console2.log("debt          :", credit.debtOf(alice));
        assertGe(closedThreshold, credit.debtOf(alice), "the market shutting still lifts the threshold");

        // ...but that threshold is no longer the one curing is measured against, and the window it
        // opens is no longer one in which curing is even possible.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.POST));
        credit.cure(alice);
        assertTrue(credit.isFlagged(alice), "the flag survives the evening");

        // Nor at any other hour of the night, or the next morning before the bell.
        _warpTo(MON_2026_03_02 + 1, 2 hours);
        vm.prank(alice);
        vm.expectPartialRevert(IAftermarketCredit.MarketClosed.selector);
        credit.cure(alice);

        // And at the bell, when a cure IS possible, the line is simply not healthy enough for one.
        _warpTo(MON_2026_03_02 + 1, T_OPEN + 5 minutes);
        vm.prank(alice);
        vm.expectPartialRevert(IAftermarketCredit.CureIncomplete.selector);
        credit.cure(alice);

        // --- the next morning: grace has expired and the seizure lands ----------------------------
        _warpTo(MON_2026_03_02 + 1, T_OPEN + 40 minutes);
        assertGt(block.timestamp, uint256(grace), "grace has expired");
        assertTrue(credit.isFlagged(alice), "and the flag is still the one raised yesterday");

        uint256 debtBefore = credit.debtOf(alice);
        vm.prank(keeper);
        (uint256 seized, uint256 repaid) = credit.liquidate(alice, address(nvda), 1_000e6);
        console2.log("seized :", seized);
        console2.log("repaid :", repaid);
        assertGt(seized, 0, "the delevering step the loop used to remove now happens");
        assertEq(debtBefore - credit.debtOf(alice), repaid, "and the line is actually delevered");
    }

    /// @notice A real cure still works, and is the only thing that does: repay down to the advance
    ///         rate - the state the line could have been opened in - and the flag clears.
    function test_01b_ARealCureStillClearsTheFlag() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(12_900e6, alice);
        vm.stopPrank();
        _setPriceBoth(PRICE_155);

        _warpTo(MON_2026_03_02, T_OPEN + 30 minutes);
        vm.prank(keeper);
        credit.flag(alice);

        // $155 * 100 * 0.65 = $10,075 of borrowing power. Repay down to it and the line is cured.
        vm.startPrank(alice);
        credit.repay(2_900e6);
        vm.stopPrank();
        assertLe(credit.debtOf(alice), credit.borrowPower(alice), "back inside the advance rate");

        credit.cure(alice);
        assertFalse(credit.isFlagged(alice), "a genuine cure still clears the flag");
        assertEq(credit.graceUntil(alice), 0, "and the clock with it");

        // Posting more collateral is the other way there, and it works too.
        _warpTo(MON_2026_03_02 + 1, T_OPEN + 30 minutes);
        _setPriceBoth(120e8); // 100 * 120 * 0.80 = $9,600 threshold against a $10,000 debt
        vm.prank(keeper);
        credit.flag(alice);
        vm.prank(alice);
        credit.depositCollateral(address(nvda), 100e8);
        credit.cure(alice);
        assertFalse(credit.isFlagged(alice), "topping up collateral cures the line as well");
    }

    /// @notice The weekend variant of the same loop: cure on Friday evening, and nothing is
    ///         liquidatable until Tuesday. It closes for the same reason - Friday evening is no
    ///         longer a cure - so the flag raised on Friday survives the whole weekend and the
    ///         seizure lands at Monday's bell.
    function test_02_TheWeekendVariantClosesToo() public {
        _warpTo(MON_2026_03_02, 11 hours);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(12_900e6, alice);
        vm.stopPrank();
        _setPriceBoth(PRICE_155);

        // Friday 2026-03-06, mid session. Flag it.
        uint256 friday = MON_2026_03_02 + 4;
        _warpTo(friday, 11 hours);
        vm.prank(keeper);
        credit.flag(alice);
        uint64 grace = credit.graceUntil(alice);
        console2.log("flagged Friday 11:00, grace until:", uint256(grace));
        assertEq(uint256(grace), _et(friday + 3, T_OPEN) + 30 minutes, "grace lands Monday 10:00 ET");

        // Friday 16:01: the evening cure fails, and so does every attempt over the weekend.
        _warpTo(friday, T_CLOSE + 1 minutes);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.POST));
        credit.cure(alice);

        // Saturday and Sunday: still flagged, still uncurable, and still unseizable - the borrower
        // keeps every hour of the notice the product promises.
        _warpTo(friday + 1, 12 hours);
        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_WEEKEND), "saturday");
        assertTrue(credit.isFlagged(alice), "the flag survives the weekend");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.CLOSED_WEEKEND));
        credit.cure(alice);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.GraceNotExpired.selector, grace));
        credit.liquidate(alice, address(nvda), 1_000e6);

        // Monday 10:00 ET - the instant the original grace expires - the seizure lands.
        _warpTo(friday + 3, T_OPEN + 30 minutes);
        assertGe(block.timestamp, uint256(grace), "grace has expired");
        vm.prank(keeper);
        (uint256 seized,) = credit.liquidate(alice, address(nvda), 1_000e6);
        console2.log("seized at Monday's bell :", seized);
        assertGt(seized, 0, "the weekend no longer converts a grace period into a parking space");
    }

    /// @notice Negative control. When the line is unhealthy at the CLOSED parameters too - i.e. it has
    ///         fallen through the whole 7000..8000 band - the loop stops working and liquidation lands
    ///         exactly as designed. This is what proves the finding is about the band, not about
    ///         liquidation being broken in general.
    function test_03_NegativeControl_DeeperUnderwaterLineIsLiquidated() public {
        _warpTo(MON_2026_03_02, 11 hours);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(12_900e6, alice);
        vm.stopPrank();

        // $140: closed threshold = 100 * 140 * 1.01 * 0.85 = $12,019 < $12,900 debt.
        _setPriceBoth(140e8);

        _warpTo(MON_2026_03_02, 11 hours + 1 minutes);
        vm.prank(keeper);
        credit.flag(alice);

        // The evening cure now fails.
        _warpTo(MON_2026_03_02, T_CLOSE + 1 minutes);
        (, uint256 closedThreshold) = credit.riskOf(alice);
        console2.log("deep-underwater POST threshold:", closedThreshold);
        assertLt(closedThreshold, credit.debtOf(alice), "still unhealthy even at closed parameters");
        vm.prank(alice);
        vm.expectRevert();
        credit.cure(alice);

        // Tuesday 10:00: grace expired, market open, seizure works.
        _warpTo(MON_2026_03_02 + 1, T_OPEN + 30 minutes);
        vm.prank(keeper);
        (uint256 seized, uint256 repaid) = credit.liquidate(alice, address(nvda), 1_000e6);
        console2.log("seized :", seized);
        console2.log("repaid :", repaid);
        assertGt(seized, 0, "liquidation works when the line is genuinely past the closed threshold");
    }
}
