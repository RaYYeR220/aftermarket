// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {AuditHarness} from "./Harness.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {Session, Verdict} from "../../src/libraries/Types.sol";

/// @title  A-06 - FIXED: the calendar fails closed past its seeded horizon
/// @notice `TradingCalendar` seeds exchange holidays and half days for a finite range. `_dayFlag`
///         used to read every unseeded day as `FLAG_NORMAL`, the contract has no owner and no
///         setter, and `AftermarketCredit.calendar` / `AftermarketOracle.calendar` are both
///         `immutable`. From the first unseeded day the protocol's single source of "is the US
///         market open" was silently, permanently wrong on every holiday and every half day.
///
///         The sharpest case was a 1pm early close: between the real 13:00 bell and 14:00 the
///         Chainlink feed is still inside the REGULAR one-hour staleness budget, so the oracle
///         stayed fully TRUSTED with a ZERO gap haircut while the tape was dead - and `liquidate`
///         ran, because `isOpen()` said the market was open. That is the protocol's central product
///         promise, broken by a lookup table running out.
///
/// @dev The fix is an explicit horizon, not a longer table. `SEEDED_FROM_DAY` and
///      `SEEDED_UNTIL_DAY` bound the range the flag table actually describes; outside it every
///      instant reports `CLOSED_HOLIDAY`, `isOpen` is false, and the day scans answer zero instead
///      of guessing. The protocol then degrades the way it degrades on any other day it cannot
///      price: no seizure, no new borrowing power beyond the closed-market advance rate, and
///      repayment and collateral top-up untouched.
///
///      A/B: the identical situation on a SEEDED half day is still handled correctly.
contract CalendarDriftTest is AuditHarness {
    int256 internal constant PRICE_200 = 200e8;

    // Seeded (correct) half day: Friday 2026-11-27, 13:00 ET close.
    uint256 internal constant WED_2026_11_25 = 20_782;
    uint256 internal constant FRI_2026_11_27 = 20_784;

    // The first unseeded half day: Friday 2028-11-24, the real NYSE 13:00 ET close after
    // Thanksgiving, and the exact date the original PoC seized collateral on.
    uint256 internal constant WED_2028_11_22 = 21_510;
    uint256 internal constant FRI_2028_11_24 = 21_512;

    /// @dev 2027-12-31, the last day the shipped holiday table describes.
    uint256 internal constant SEEDED_UNTIL = 21_183;

    function setUp() public {
        _deploy(PRICE_200);
    }

    /// @dev Opens two maxed lines on `openDay` at 11:00 ET and crashes the price. Alice's line is
    ///      flagged so that its grace clock is already long expired by the time we reach the half
    ///      day; the keeper's is left unflagged, so a fresh flag can be attempted past the horizon.
    function _armAFlaggedLine(uint256 openDay) internal {
        vm.warp(_et(openDay, 11 hours));
        feed.set(200e8, block.timestamp);
        feedAnswer = 200e8;
        _fund(keeper, 0, 200e8);

        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(9_900e6, alice);
        vm.stopPrank();

        vm.startPrank(keeper);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(9_900e6, keeper);
        vm.stopPrank();

        _setPriceBoth(100e8); // $10,000 basket, $9,900 debt: seizable at every parameter set
        vm.prank(keeper);
        credit.flag(alice);
        console2.log("flagged, graceUntil:", uint256(credit.graceUntil(alice)));
    }

    /// @notice CONTROL - on the SEEDED 2026 half day the protocol behaves exactly as advertised:
    ///         13:30 ET is POST, the market is closed, the gap haircut is live, seizure is refused.
    function test_00_SeededHalfDay_IsHandledCorrectly() public {
        _armAFlaggedLine(WED_2026_11_25);

        // 12:55 ET - genuinely open, feed printing.
        vm.warp(_et(FRI_2026_11_27, 12 hours + 55 minutes));
        feed.set(100e8, block.timestamp);
        assertEq(uint256(calendar.session()), uint256(Session.REGULAR), "12:55 is still the regular session");
        assertTrue(calendar.isOpen(block.timestamp), "open at 12:55");

        // 13:30 ET - the real close was at 13:00 and the calendar knows it.
        vm.warp(_et(FRI_2026_11_27, 13 hours + 30 minutes));
        assertEq(uint256(calendar.session()), uint256(Session.POST), "13:30 is POST on a half day");
        assertFalse(calendar.isOpen(block.timestamp), "correctly closed");
        console2.log("2026 half day, 13:30 ET haircutBps:", oracle.peek().haircutBps);
        assertGt(oracle.peek().haircutBps, 0, "gap haircut is live");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.POST));
        credit.liquidate(alice, address(nvda), 1_000e6);
    }

    /// @notice THE FIX - the identical 2028 half day is outside the seeded horizon, and the calendar
    ///         says so instead of guessing. At 13:30 ET, thirty minutes after the real closing bell,
    ///         the market reads as shut, the gap haircut is at its cap, and no collateral moves.
    function test_01_UnseededHalfDay_ReadsAsClosedInsteadOfSeizing() public {
        // The line has to be opened inside the seeded range, because past the horizon the closed
        // advance rate and the capped haircut are all a borrower can get - which is the point.
        _armAFlaggedLine(WED_2026_11_25);

        // 12:55 ET on Friday 2028-11-24: the day the old table called a full trading session.
        vm.warp(_et(FRI_2028_11_24, 12 hours + 55 minutes));
        feed.set(100e8, block.timestamp);

        // 13:30 ET. NYSE shut half an hour ago, and so, as far as this contract is concerned, it
        // has been shut since the end of 2027.
        vm.warp(_et(FRI_2028_11_24, 13 hours + 30 minutes));

        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_HOLIDAY), "past the horizon: permanently shut");
        assertFalse(calendar.isOpen(block.timestamp), "and never open");
        assertGt(calendar.closedFor(block.timestamp), 0, "with a live closed-for measure");
        assertEq(calendar.nextOpen(block.timestamp), 0, "and no opening bell it is willing to promise");

        assertEq(oracle.peek().haircutBps, MAX_HAIRCUT_BPS, "the gap haircut sits at its cap");

        // Seizure is refused by the calendar itself, which is where the promise is supposed to live.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.CLOSED_HOLIDAY));
        credit.liquidate(alice, address(nvda), 1_000e6);

        // And no fresh grace clock can be started either, because there is no bell to anchor it to.
        // The keeper's line is just as underwater as alice's and has never been flagged.
        vm.expectRevert(IAftermarketCredit.CalendarHorizon.selector);
        credit.flag(keeper);
    }

    /// @notice A full 2028 holiday is now handled by the calendar rather than masked by the
    ///         staleness guard, which is where the defence belongs. Repayment still works, and the
    ///         borrower still walks out with their collateral.
    function test_02_UnseededFullHoliday_ReadsAsClosedAndTheExitStillWorks() public {
        _armAFlaggedLine(WED_2026_11_25);

        // Thanksgiving Thursday 2028-11-23, 11:00 ET - a day the old table traded in full.
        vm.warp(_et(WED_2028_11_22 + 1, 11 hours));

        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_HOLIDAY), "shut, not trading");
        assertFalse(calendar.isOpen(block.timestamp), "and not open");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.CLOSED_HOLIDAY));
        credit.liquidate(alice, address(nvda), 1_000e6);

        // The borrower is not trapped: repayment reads no oracle and no calendar scan.
        vm.prank(alice);
        credit.repay(type(uint256).max);
        assertEq(credit.debtOf(alice), 0, "cure path survives");
        vm.prank(alice);
        credit.withdrawCollateral(address(nvda), 100e8, alice);
        assertEq(credit.collateral(alice, address(nvda)), 0, "and so does the exit");
    }

    /// @notice The horizon itself: the last seeded session trades normally, and the very next
    ///         calendar day past it is shut. The sunset is a published date, not a silent drift.
    function test_03_TheHorizonIsExplicitAndTheLastSeededSessionStillTrades() public {
        // 2027-12-31 15:00 ET, the last regular session the table describes.
        vm.warp(_et(SEEDED_UNTIL, 15 hours));
        assertEq(uint256(calendar.session()), uint256(Session.REGULAR), "the last seeded session trades");
        assertTrue(calendar.isOpen(block.timestamp), "and is open");
        assertEq(calendar.nextOpen(block.timestamp), 0, "with no 2028 bell it is prepared to guess at");

        // The next calendar day is past the horizon.
        vm.warp(_et(SEEDED_UNTIL + 3, 15 hours));
        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_HOLIDAY), "and the day after is shut");
        assertFalse(calendar.isOpen(block.timestamp), "permanently");

        assertEq(calendar.SEEDED_UNTIL_DAY(), SEEDED_UNTIL, "the horizon is a public constant");
    }
}
