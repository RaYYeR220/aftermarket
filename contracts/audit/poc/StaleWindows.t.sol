// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {AuditHarness} from "./Harness.sol";
import {Session, Verdict} from "../../src/libraries/Types.sol";

/// @title  A-17 - the per-session staleness budgets ignore when the feed actually stops printing
/// @notice `AftermarketOracle` picks `stalenessBudget[session]` and compares it to
///         `block.timestamp - updatedAt`. But a Coinbase equity feed only prints during the REGULAR
///         session, so by the time the calendar reports PRE the feed has ALREADY been frozen since
///         the previous 16:00 close - at least 12 hours. The shipped PRE budget is 6 hours
///         (`script/config/base.json`). PRE is therefore `UNTRUSTED_STALE` every single weekday, by
///         construction, and the same arithmetic kills Monday 00:00-04:00 ET (about 56 hours frozen
///         against a 25-hour CLOSED_OVERNIGHT budget).
///
/// @dev In those windows `flag`, `cure`, `liquidate`, `draw` and `withdrawCollateral`-with-debt all
///      revert for every user of every asset. That is roughly 9.5 hours of every weekday plus the
///      Monday pre-dawn block - about 19% of the week - in which the protocol has no opinion at all.
contract StaleWindowsTest is AuditHarness {
    int256 internal constant PRICE_200 = 200e8;

    function setUp() public {
        _deploy(PRICE_200);
    }

    /// @notice PRE is dead every weekday: the feed's last print is the previous 16:00 close.
    function test_A17a_PreMarketIsAlwaysStale() public {
        // Monday's closing print.
        _warpTo(MON_2026_03_02, T_CLOSE - 1 minutes);
        feed.set(feedAnswer, block.timestamp);

        uint256 dead;
        for (uint256 h = T_PRE_OPEN; h < T_OPEN; h += 30 minutes) {
            vm.warp(_et(MON_2026_03_02 + 1, h)); // Tuesday pre-market
            if (calendar.session() != Session.PRE) continue;
            if (oracle.peek().verdict == Verdict.UNTRUSTED_STALE) ++dead;
        }
        vm.warp(_et(MON_2026_03_02 + 1, 9 hours));
        console2.log("Tuesday 09:00 ET session       :", uint256(calendar.session()));
        console2.log("Tuesday 09:00 ET feedAge       :", oracle.peek().feedAge);
        console2.log("Tuesday 09:00 ET budget        :", oracle.peek().stalenessBudget);
        console2.log("PRE half-hour slots, all stale :", dead);

        assertEq(dead, 11, "every PRE slot from 04:00 to 09:00 is UNTRUSTED_STALE");
        vm.expectRevert();
        oracle.markBorrow();
    }

    /// @notice Monday 00:00-04:00 ET is dead too: ~56h frozen against a 25h overnight budget.
    function test_A17b_MondayPreDawnIsAlwaysStale() public {
        _warpTo(MON_2026_03_02 + 4, T_CLOSE - 1 minutes); // Friday's close
        feed.set(feedAnswer, block.timestamp);

        vm.warp(_et(MON_2026_03_02 + 7, 2 hours)); // the following Monday, 02:00 ET
        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_OVERNIGHT), "overnight, not weekend");
        console2.log("Monday 02:00 ET feedAge :", oracle.peek().feedAge);
        console2.log("Monday 02:00 ET budget  :", oracle.peek().stalenessBudget);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_STALE), "stale");
        vm.expectRevert();
        oracle.markLiquidate();
    }

    /// @notice The consequence that matters for A-01: PRE is the ONLY session in which a flag would
    ///         produce a SAME-DAY grace expiry (`nextOpen` is today's 09:30). Because PRE is always
    ///         untrusted, that window is permanently unusable and every flag defers to tomorrow.
    function test_A17c_TheOneKeeperFavourableFlagWindowIsPermanentlyUnusable() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(12_900e6, alice);
        vm.stopPrank();
        _setPriceBoth(120e8); // unhealthy at every parameter set
        _warpTo(MON_2026_03_02, T_CLOSE - 1 minutes);
        feed.set(feedAnswer, block.timestamp);

        // Tuesday 05:00 ET. `nextOpen` is TODAY's 09:30, so a flag here would expire at 10:00 today.
        vm.warp(_et(MON_2026_03_02 + 1, 5 hours));
        uint64 wouldExpireAt = calendar.nextOpen(block.timestamp) + 30 minutes;
        console2.log("a PRE flag would expire at :", uint256(wouldExpireAt));
        console2.log("which is same-day 10:00 ET :", _et(MON_2026_03_02 + 1, T_OPEN + 30 minutes));
        assertEq(uint256(wouldExpireAt), _et(MON_2026_03_02 + 1, T_OPEN + 30 minutes), "same-day expiry");

        // But the flag cannot be raised, because the oracle refuses to mark.
        vm.prank(keeper);
        vm.expectRevert();
        credit.flag(alice);
    }
}
