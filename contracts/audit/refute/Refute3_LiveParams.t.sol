// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {AuditHarness} from "../poc/Harness.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {Session, Verdict} from "../../src/libraries/Types.sol";

/// @notice Parameter-sensitivity check. Unlike the rest of the suite this file pins nothing: it
///         measures BOTH findings against whatever risk parameters `audit/poc/Harness.sol` carries,
///         which are the deployment defaults. It exists so the report can say which conclusions are
///         structural and which are just arithmetic on a particular parameter set.
contract Refute3_LiveParams is AuditHarness {
    int256 internal constant P200 = 200e8;

    function setUp() public {
        _deploy(P200);
    }

    function _step(uint256 ts) internal {
        require(ts >= block.timestamp, "clock went backwards");
        vm.warp(ts);
        if (calendar.isOpen(ts)) feed.set(feedAnswer, ts);
    }

    /// @notice Reports the live parameters and the resulting cure band.
    function test_L1_LiveBandWidth() public {
        console2.log("LIVE harness parameters");
        console2.log("  advance open / closed bps  :", ADVANCE_OPEN_BPS, ADVANCE_CLOSED_BPS);
        console2.log("  liq threshold open/closed  :", LIQ_THRESHOLD_OPEN_BPS, LIQ_THRESHOLD_CLOSED_BPS);
        console2.log("  haircut base/slope/cap bps :", BASE_HAIRCUT_BPS, HAIRCUT_SLOPE_BPS_PER_HOUR);
        console2.log("  haircut cap bps            :", MAX_HAIRCUT_BPS);

        _step(_et(MON_2026_03_02, T_OPEN + 5 minutes));
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        uint256 drawn = credit.borrowPower(alice);
        credit.draw(drawn, alice);
        vm.stopPrank();
        console2.log("  max draw on $20,000        :", drawn);

        uint256 collateralUsdc = 20_000e6;
        uint256 weekdayMax;
        uint256 weekendMax;
        uint256 openThr = type(uint256).max;
        uint256 t0 = block.timestamp;

        for (uint256 i = 1; i <= 2016; ++i) {
            _step(t0 + i * 5 minutes);
            Session s = calendar.session();
            try credit.seizureThreshold(alice) returns (uint256 thr) {
                uint256 bps = thr * 10_000 / collateralUsdc;
                if (s == Session.REGULAR) {
                    if (bps < openThr) openThr = bps;
                } else if (s == Session.CLOSED_WEEKEND || s == Session.CLOSED_HOLIDAY) {
                    if (bps > weekendMax) weekendMax = bps;
                } else if (bps > weekdayMax) {
                    weekdayMax = bps;
                }
            } catch {}
        }

        console2.log("  REGULAR LTV threshold  bps :", openThr);
        console2.log("  weekday cure ceiling   bps :", weekdayMax);
        console2.log("  weekend cure ceiling   bps :", weekendMax);
        console2.log("  weekday band width     bps :", weekdayMax - openThr);
        console2.log("  max draw LTV           bps :", drawn * 10_000 / collateralUsdc);
    }

    /// @notice Incidental: under the LIVE staleness budgets the oracle is still dead through the
    ///         whole PRE session and through Monday 00:00-04:00 ET.
    function test_L1b_LiveOracleDeadWindows() public {
        _step(_et(MON_2026_03_02, T_OPEN + 5 minutes));
        uint256 preDead;
        uint256 monDead;
        // Tuesday PRE
        for (uint256 sec = 4 hours; sec < 9 hours + 30 minutes; sec += 15 minutes) {
            _step(_et(MON_2026_03_02 + 1, sec));
            if (oracle.peek().verdict == Verdict.UNTRUSTED_STALE) ++preDead;
        }
        // Monday 00:00-04:00 after a weekend
        _step(_et(MON_2026_03_02 + 4, T_CLOSE - 5 minutes)); // Friday's closing print
        for (uint256 sec = 0; sec < 4 hours; sec += 15 minutes) {
            _step(_et(MON_2026_03_02 + 7, sec));
            if (oracle.peek().verdict == Verdict.UNTRUSTED_STALE) ++monDead;
        }
        console2.log("  PRE slots stale (of 22)    :", preDead);
        console2.log("  Mon 00-04 stale (of 16)    :", monDead);
        console2.log("  PRE staleness budget (s)   :", oracle.stalenessBudget(Session.PRE));
        console2.log("  OVN staleness budget (s)   :", oracle.stalenessBudget(Session.CLOSED_OVERNIGHT));
    }

    /// @notice Which multipliers the LIVE oracle bounds now reject.
    function test_L2_LiveMultiplierBounds() public {
        _step(_et(MON_2026_03_02, T_OPEN + 5 minutes));
        uint256[9] memory ms = [uint256(0.09e18), 0.1e18, 0.5e18, 0.51e18, 2e18, 4e18, 10e18, 100e18, 101e18];
        console2.log("verdict 0 == TRUSTED, 2 == UNTRUSTED_HALTED");
        for (uint256 i; i < ms.length; ++i) {
            uint256 snap = vm.snapshotState();
            nvda.setMultiplier(ms[i]);
            console2.log("  multiplier / verdict:", ms[i], uint256(oracle.peek().verdict));
            vm.revertToState(snap);
        }
    }

    /// @notice Does the 10:1 split sweep execute under the live parameters? No - and the reason is
    ///         a hard constant rather than a tuning, so it does not move with the parameter set.
    ///         `MAX_SWEEP_BPS` refuses any single sweep over a tenth of the position, which is
    ///         above every real distribution and far below every real split. The oracle is happy
    ///         at a 10x multiplier; the engine is the thing that says no.
    function test_L3_TenForOneSplitCannotSweepUnderLiveParams() public {
        adapter.setRate(200e6, 1e8);
        usdc.mint(address(adapter), 50_000_000e6);
        _step(_et(MON_2026_03_02, T_OPEN + 5 minutes));
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(5_000e6, alice);
        credit.setAutoRepay(true);
        vm.stopPrank();

        console2.log("live sweep cap bps          :", credit.MAX_SWEEP_BPS());

        nvda.setMultiplier(10e18);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "still trusted at 10e18");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.SweepTooLarge.selector, 90e8, 10e8));
        credit.sweepYield(alice, address(nvda));
        console2.log("live params: a 10:1 split is refused, not sold");

        // A distribution inside the cap still clears, so the guard is a size limit and not an
        // outage: 1e18 -> 1.1e18 sells 9.09% of the position, just inside the 10% ceiling.
        nvda.setMultiplier(1.1e18);
        vm.prank(keeper);
        (uint256 sold, uint256 proceeds,) = credit.sweepYield(alice, address(nvda));
        console2.log("live params: sold / proceeds:", sold, proceeds);
        assertEq(sold, uint256(100e8) * 0.1e18 / 1.1e18, "the largest distribution the cap admits");
    }
}
