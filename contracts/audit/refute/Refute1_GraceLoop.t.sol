// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {RefuteBase} from "./RefuteBase.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {Session, Verdict} from "../../src/libraries/Types.sol";

/// @notice Hostile review of CLAIM 1 ("nightly cure loop"). Every test here is an attempt to BREAK
///         the claim, not to reproduce it.
///
/// @dev All clock movement in this file is MONOTONE and refreshes the Chainlink answer whenever a
///      regular session is running, exactly as a live Coinbase equity feed does. Time never runs
///      backwards, so no measurement is contaminated by a feed timestamp from the future.
///
///      `cure` now requires a regular session (see the doc comment on `AftermarketCredit.cure`),
///      which is the fix this review argued for and which closes the loop outright: the whole loop
///      depended on clearing a flag in the evening at closed parameters. Where a test below says
///      "curable" of a clock position, it means "healthy at the parameters live at that instant" -
///      a pricing fact, measured through `riskOf`. Actually calling `cure()` needs that AND an open
///      market, so the set of instants at which the flag can really be cleared is a strict subset
///      of the ones counted here, and an in-band line has none of them at all without a repayment.
contract Refute1_GraceLoop is RefuteBase {
    int256 internal constant P200 = 200e8;
    int256 internal constant P130 = 130e8;

    function setUp() public {
        _deploy(P200);
        _pinBriefDefaults();
    }

    /*//////////////////////////////////////////////////////////////
                          MONOTONE CLOCK HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Warps forward to an absolute unix second, publishing a fresh Chainlink print if the
    ///      regular session is running there.
    function _step(uint256 ts) internal {
        require(ts >= block.timestamp, "clock went backwards");
        vm.warp(ts);
        if (calendar.isOpen(ts)) feed.set(feedAnswer, ts);
    }

    /// @dev Walks forward to `day`/`sec` ET, stopping at 12:00 and 15:55 ET on every intervening
    ///      trading day so the reference feed is refreshed the way it would be in production (12:00
    ///      also covers half days, whose regular session ends at 13:00).
    function _walkTo(uint256 day, uint256 sec) internal {
        uint256 target = _et(day, sec);
        uint256 cursor = block.timestamp / 1 days;
        while (true) {
            uint256 mid = _et(cursor, 12 hours);
            uint256 late = _et(cursor, T_CLOSE - 5 minutes);
            if (mid >= target) break;
            if (mid > block.timestamp) _step(mid);
            if (late < target && late > block.timestamp) _step(late);
            ++cursor;
        }
        _step(target);
    }

    function _openBandLine(uint256 drawUsdc, int256 dropTo) internal {
        _step(_et(MON_2026_03_02, T_OPEN + 5 minutes));
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(drawUsdc, alice);
        vm.stopPrank();
        _setPriceBoth(dropTo);
    }

    /// @dev Opens the largest line the advance rate allows, then re-prices so the line lands at a
    ///      chosen LTV against the raw collateral value.
    function _openMaxLineAtPrice(int256 price) internal returns (uint256 drawn) {
        _step(_et(MON_2026_03_02, T_OPEN + 5 minutes));
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        drawn = credit.borrowPower(alice);
        credit.draw(drawn, alice);
        vm.stopPrank();
        _setPriceBoth(price);
    }

    /// @dev Borrower repays principal. A cure is measured at OPEN-session parameters, so getting
    ///      an in-band line back under its threshold takes money rather than a change of session.
    function _repay(uint256 assets) internal {
        vm.prank(alice);
        credit.repay(assets);
    }

    function _tryFlag(address who) internal returns (bool ok, uint64 deadline) {
        vm.prank(keeper);
        try credit.flag(who) {
            return (true, credit.graceUntil(who));
        } catch {
            return (false, 0);
        }
    }

    function _tryCure(address who) internal returns (bool ok) {
        vm.prank(alice);
        try credit.cure(who) {
            return true;
        } catch {
            return false;
        }
    }

    function _oracleLive() internal view returns (bool) {
        Verdict v = oracle.peek().verdict;
        return v == Verdict.TRUSTED || v == Verdict.TRUSTED_CLOSED;
    }

    /*//////////////////////////////////////////////////////////////
      R1 - EXHAUSTIVE CLOCK SWEEP
    //////////////////////////////////////////////////////////////*/

    /// @notice Walks every 15 minutes of a full week and, at each instant, asks: can a keeper flag
    ///         this in-band line, and if so does the grace deadline land BEFORE the next regular
    ///         close - i.e. with no closed window in between for the borrower to cure in?
    ///
    ///         `sessionAt(deadline)` returns the most recent regular close at or before the deadline.
    ///         If that close is at or before the flag instant then the whole grace period ran inside
    ///         one regular session and the borrower never got a cure window. That is the ONLY shape
    ///         of keeper win, and this test looks for it at 672 consecutive clock positions.
    function test_R1_ExhaustiveClockSweep() public {
        _openBandLine(9_900e6, P130);

        uint256 slots;
        uint256 flaggable;
        uint256 keeperWins;
        uint256 oracleDead;
        uint256 curableSlots;
        uint256 t0 = block.timestamp;

        for (uint256 i = 1; i <= 672; ++i) {
            _step(t0 + i * 15 minutes);
            ++slots;

            if (!_oracleLive()) ++oracleDead;

            bool curable;
            try credit.riskOf(alice) returns (uint256, uint256 thr) {
                curable = credit.debtOf(alice) <= thr;
            } catch {}
            if (curable) ++curableSlots;

            uint256 snap = vm.snapshotState();
            (bool ok, uint64 dl) = _tryFlag(alice);
            if (ok) {
                ++flaggable;
                (,, uint64 lastCloseBeforeDeadline) = calendar.sessionAt(uint256(dl));
                if (uint256(lastCloseBeforeDeadline) <= block.timestamp) {
                    ++keeperWins;
                    console2.log("KEEPER WIN at ts / deadline:", block.timestamp, uint256(dl));
                }
            }
            vm.revertToState(snap);
        }

        console2.log("slots swept                 :", slots);
        console2.log("oracle reverting            :", oracleDead);
        console2.log("flaggable slots             :", flaggable);
        console2.log("curable slots               :", curableSlots);
        console2.log("flags with NO cure window   :", keeperWins);

        assertGt(flaggable, 0, "line is flaggable somewhere");
        assertGt(curableSlots, 0, "line is curable somewhere");
        assertEq(keeperWins, 0, "CLAIM 1 REFUTED if this is non-zero");
    }

    /// @notice Disjointness: at no instant of the week is the line both flaggable and curable, and
    ///         whenever the oracle answers it is exactly one of the two.
    function test_R1b_FlaggableAndCurableArePerfectComplements() public {
        _openBandLine(9_900e6, P130);
        uint256 both;
        uint256 neitherWhileLive;
        uint256 flaggableWhileOpen;
        uint256 flaggableWhileClosed;
        uint256 curableWhileOpen;
        uint256 t0 = block.timestamp;

        for (uint256 i = 1; i <= 672; ++i) {
            _step(t0 + i * 15 minutes);
            bool live = _oracleLive();
            bool open = calendar.isOpen(block.timestamp);
            bool f;
            bool c;
            try credit.riskOf(alice) returns (uint256, uint256 thr) {
                uint256 debt = credit.debtOf(alice);
                f = debt > thr;
                c = debt <= thr;
            } catch {}
            if (f && c) ++both;
            if (live && !f && !c) ++neitherWhileLive;
            if (f && open) ++flaggableWhileOpen;
            if (f && !open) ++flaggableWhileClosed;
            if (c && open) ++curableWhileOpen;
        }
        console2.log("both flaggable+curable      :", both);
        console2.log("neither, oracle live        :", neitherWhileLive);
        console2.log("flaggable while REGULAR     :", flaggableWhileOpen);
        console2.log("flaggable while CLOSED      :", flaggableWhileClosed);
        console2.log("curable while REGULAR       :", curableWhileOpen);
        assertEq(both, 0, "flag and cure are mutually exclusive at any instant");
        assertEq(flaggableWhileClosed, 0, "an in-band line is never flaggable outside a regular session");
        assertEq(curableWhileOpen, 0, "an in-band line is never curable inside a regular session");
    }

    /*//////////////////////////////////////////////////////////////
      R2 - SAME-DAY DEADLINE WINDOWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The same-day-expiry window really does exist (00:00-04:00 ET on a trading day), and it
    ///         works - but only against a line that is under water at CLOSED parameters too, which is
    ///         precisely a line that could never have cured in the first place.
    function test_R2_SameDayDeadlineWindowExistsButNeedsAnOutOfBandLine() public {
        _openBandLine(9_900e6, 105e8);

        _walkTo(MON_2026_03_02 + 1, 2 hours);
        assertEq(uint256(calendar.session()), uint256(Session.CLOSED_OVERNIGHT), "overnight");
        (bool ok, uint64 dl) = _tryFlag(alice);
        console2.log("flag at Tue 02:00 ET ok?    :", ok);
        console2.log("deadline                    :", uint256(dl));
        console2.log("Tue 10:00 ET                :", _et(MON_2026_03_02 + 1, T_OPEN) + 30 minutes);
        assertTrue(ok, "deep-underwater line is flaggable overnight");
        assertEq(uint256(dl), _et(MON_2026_03_02 + 1, T_OPEN) + 30 minutes, "SAME-DAY 10:00 ET deadline");

        _walkTo(MON_2026_03_02 + 1, T_OPEN + 30 minutes);
        vm.prank(keeper);
        (uint256 seized,) = credit.liquidate(alice, address(nvda), 1_000e6);
        assertGt(seized, 0, "same-day seizure lands");
    }

    /// @notice The in-band line is NOT flaggable in that same window.
    function test_R2b_InBandLineCannotBeFlaggedOvernight() public {
        _openBandLine(9_900e6, P130);
        _walkTo(MON_2026_03_02, T_CLOSE + 30 minutes);
        uint256 t0 = block.timestamp;
        uint256 tried;
        for (uint256 i = 0; i < 30; ++i) {
            _step(t0 + i * 15 minutes);
            if (calendar.isOpen(block.timestamp)) break;
            uint256 snap = vm.snapshotState();
            (bool ok,) = _tryFlag(alice);
            assertFalse(ok, "in-band line refuses every closed-session flag");
            vm.revertToState(snap);
            ++tried;
        }
        console2.log("closed slots where flag was refused:", tried);
    }

    /// @notice The PRE window (04:00-09:30 ET) can never be used by EITHER side on an ordinary
    ///         weekday: the Chainlink feed has been frozen since 16:00 the previous day (>=12h) and
    ///         PRE's staleness budget is 6h.
    function test_R2c_PreSessionIsAlwaysOracleDead() public {
        _openBandLine(9_900e6, P130);
        _walkTo(MON_2026_03_02 + 1, 4 hours);
        uint256 t0 = block.timestamp;
        uint256 checked;
        for (uint256 i = 0; i * 15 minutes < 5 hours + 30 minutes; ++i) {
            _step(t0 + i * 15 minutes);
            assertEq(uint256(calendar.session()), uint256(Session.PRE), "PRE");
            assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_STALE), "stale in PRE");
            ++checked;
        }
        console2.log("PRE slots checked, all UNTRUSTED_STALE:", checked);
    }

    /*//////////////////////////////////////////////////////////////
      R3 - MEASURED BAND WIDTH
    //////////////////////////////////////////////////////////////*/

    /// @notice Measures `seizureThreshold / collateralValue` at every 5 minutes of a full week, i.e.
    ///         the true LTV ceiling at which a borrower may sit and still be able to cure.
    function test_R3_MeasuredBandWidth() public {
        _openBandLine(9_900e6, P130);
        uint256 collateralUsdc = 13_000e6;

        uint256 weekdayMax;
        uint256 weekdayMaxTs;
        uint256 weekendMax;
        uint256 weekendMaxTs;
        uint256 openMin = type(uint256).max;
        uint256 openMax;
        uint256 t0 = block.timestamp;

        for (uint256 i = 1; i <= 2016; ++i) {
            _step(t0 + i * 5 minutes);
            Session s = calendar.session();
            try credit.seizureThreshold(alice) returns (uint256 thr) {
                uint256 bps = thr * 10_000 / collateralUsdc;
                if (s == Session.REGULAR) {
                    if (bps < openMin) openMin = bps;
                    if (bps > openMax) openMax = bps;
                } else if (s == Session.CLOSED_WEEKEND || s == Session.CLOSED_HOLIDAY) {
                    if (bps > weekendMax) {
                        weekendMax = bps;
                        weekendMaxTs = block.timestamp;
                    }
                } else if (bps > weekdayMax) {
                    weekdayMax = bps;
                    weekdayMaxTs = block.timestamp;
                }
            } catch {}
        }

        console2.log("REGULAR LTV threshold  min/max bps:", openMin, openMax);
        console2.log("weekday LTV ceiling        bps/ts :", weekdayMax, weekdayMaxTs);
        console2.log("weekend LTV ceiling        bps/ts :", weekendMax, weekendMaxTs);
        console2.log("sustainable weekday band width bps:", weekdayMax - openMin);
        assertEq(openMin, 7_000, "open threshold is exactly 7000bps of raw collateral value");
    }

    /// @notice Where the closed-session cure window actually is on a weekday, minute by minute.
    function test_R3b_WeekdayCureWindowShape() public {
        _openBandLine(9_900e6, P130);
        uint256 collateralUsdc = 13_000e6;
        _walkTo(MON_2026_03_02 + 1, T_CLOSE); // Tuesday 16:00 ET
        uint256 t0 = block.timestamp;
        console2.log("hh:mm ET (from 16:00 Tue) -> LTV ceiling bps, 0 == oracle refuses");
        for (uint256 i = 0; i <= 36; ++i) {
            _step(t0 + i * 30 minutes);
            uint256 bps;
            try credit.seizureThreshold(alice) returns (uint256 thr) {
                bps = thr * 10_000 / collateralUsdc;
            } catch {}
            console2.log(" +minutes / session / bps:", i * 30, uint256(calendar.session()), bps);
        }
    }

    /// @notice How far the price has to fall from a maxed-out draw before the band is entered/left.
    function test_R3c_ReachabilityFromA5000BpsAdvance() public {
        uint256 drawn = _openMaxLineAtPrice(P200);
        console2.log("max draw at $200 (USDC)     :", drawn);
        console2.log("collateral value at $200    :", uint256(20_000e6));

        // The open threshold is 7000bps of the raw value, the weekday closed ceiling is what R3
        // measured. Solve for the price at each edge directly.
        console2.log("price at which LTV hits 7000bps (8dec):", drawn * 10_000 / 7_000 / 100);
        console2.log("price at which LTV hits 8152bps (8dec):", drawn * 10_000 / 8_152 / 100);
        console2.log("price at which LTV hits 8400bps (8dec):", drawn * 10_000 / 8_400 / 100);
        console2.log("drop from $200 to enter band       (%):", 100 - (drawn * 10_000 / 7_000 / 100) / 2000000);
    }

    /*//////////////////////////////////////////////////////////////
      R4 - DOES INTEREST EJECT THE BORROWER?
    //////////////////////////////////////////////////////////////*/

    function test_R4_InterestExit_NearFloor() public {
        _runLoopUntilEjected(142e8, 0, "entry just above the band floor, u ~ 1%");
    }

    function test_R4b_InterestExit_MidBand() public {
        _runLoopUntilEjected(131e8, 0, "entry mid band, u ~ 1%");
    }

    function test_R4c_InterestExit_NearCeiling() public {
        _runLoopUntilEjected(123e8, 0, "entry near the band ceiling, u ~ 1%");
    }

    function test_R4d_InterestExit_MidBand_U50() public {
        _runLoopUntilEjected(131e8, 5_000, "entry mid band, 50% utilisation");
    }

    function test_R4e_InterestExit_NearFloor_U50() public {
        _runLoopUntilEjected(142e8, 5_000, "entry just above band floor, 50% utilisation");
    }

    function test_R4f_InterestExit_MidBand_U80() public {
        _runLoopUntilEjected(131e8, 8_000, "entry mid band, 80% utilisation (the kink)");
    }

    function test_R4g_InterestExit_MidBand_U95() public {
        _runLoopUntilEjected(131e8, 9_500, "entry mid band, 95% utilisation");
    }

    /// @dev The borrower's best weekday cure instant is 03:59 ET (haircut 190bps, ceiling 8152bps),
    ///      so that is where curability is tested. Testing at 16:01 instead would understate the
    ///      band by 132bps.
    function _runLoopUntilEjected(int256 price, uint256 targetUtilBps, string memory label) internal {
        uint256 drawn = _openMaxLineAtPrice(price);
        if (targetUtilBps != 0) {
            // leave just enough idle USDC that utilisation sits at `targetUtilBps`
            uint256 keep = drawn * 10_000 / targetUtilBps - drawn;
            uint256 pull = vault.maxWithdraw(supplier) - keep;
            vm.prank(supplier);
            vault.withdraw(pull, supplier, supplier);
        }
        console2.log(label);
        console2.log("  drawn / debt at entry     :", drawn, credit.debtOf(alice));
        (, uint256 thrOpen) = credit.riskOf(alice);
        console2.log("  REGULAR threshold         :", thrOpen);
        console2.log("  entry LTV bps             :", credit.debtOf(alice) * 10_000 / (100 * uint256(price) / 100));
        console2.log("  vault idle assets         :", vault.idleAssets());
        assertGt(credit.debtOf(alice), thrOpen, "line starts inside the band");

        uint256 startDebt = credit.debtOf(alice);
        for (uint256 i = 1; i < 900; ++i) {
            uint256 d = MON_2026_03_02 + i;
            uint256 wd = (d + 4) % 7;
            if (wd == 0 || wd == 6) continue;
            _walkTo(d, 3 hours + 59 minutes);
            if (calendar.session() != Session.CLOSED_OVERNIGHT) continue;
            credit.accrue();
            uint256 debt = credit.debtOf(alice);
            uint256 thr;
            try credit.seizureThreshold(alice) returns (uint256 t) {
                thr = t;
            } catch {
                continue;
            }
            if (debt > thr) {
                console2.log("  EJECTED after N calendar days:", i);
                console2.log("  debt / closed threshold      :", debt, thr);
                console2.log("  realised APR bps             :", (debt - startDebt) * 10_000 * 365 / startDebt / i);
                return;
            }
        }
        uint256 endDebt = credit.debtOf(alice);
        console2.log("  survived 900 calendar days, final debt:", endDebt);
        console2.log("  realised APR bps             :", (endDebt - startDebt) * 10_000 * 365 / startDebt / 900);
    }

    /*//////////////////////////////////////////////////////////////
      R5 - KEEPER COUNTER-STRATEGIES
    //////////////////////////////////////////////////////////////*/

    /// @notice A keeper willing to hold the Aerodrome TWAP >250bps away from the anchor for the whole
    ///         closed window makes `cure` impossible and collects the liquidation at 10:00.
    function test_R5_KeeperDefeatsLoopByDivergingThePool() public {
        _openBandLine(9_900e6, P130);

        _walkTo(MON_2026_03_02, 11 hours);
        vm.prank(keeper);
        credit.flag(alice);
        uint64 dl = credit.graceUntil(alice);
        assertEq(uint256(dl), _et(MON_2026_03_02 + 1, T_OPEN) + 30 minutes, "Tue 10:00");

        _walkTo(MON_2026_03_02, T_CLOSE + 1 minutes);
        int24 low = _tickForPriceWad(uint256(P130) * 1e10 * 94 / 100);
        pool.setMeanTick(low, TWAP_WINDOW);
        _currentTick = low;

        console2.log("verdict during POST         :", uint256(oracle.peek().verdict));
        console2.log("divergenceBps               :", oracle.peek().divergenceBps);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_DIVERGENT), "diverged");

        uint256 blocked;
        uint256 attempts;
        uint256 t0 = block.timestamp;
        while (block.timestamp < uint256(dl)) {
            ++attempts;
            if (!_tryCure(alice)) ++blocked;
            _step(block.timestamp + 30 minutes);
            pool.setMeanTick(low, TWAP_WINDOW);
            if (block.timestamp > t0 + 1 days) break;
        }
        console2.log("cure attempts / blocked     :", attempts, blocked);
        assertEq(blocked, attempts, "every cure blocked");
        assertTrue(credit.isFlagged(alice), "flag survives the night");

        int24 back = _tickForPriceWad(uint256(P130) * 1e10);
        pool.setMeanTick(back, TWAP_WINDOW);
        _currentTick = back;
        _walkTo(MON_2026_03_02 + 1, T_OPEN + 35 minutes);
        vm.prank(keeper);
        (uint256 seized, uint256 repaid) = credit.liquidate(alice, address(nvda), 1_000e6);
        console2.log("keeper seized / repaid      :", seized, repaid);
        assertGt(seized, 0, "loop defeated by holding the pool diverged for one night");
    }

    /// @notice The CHEAPER keeper attack does not work. Draining the Aerodrome pool under
    ///         `minPoolLiquidityUsd` cannot close the cure window, because inside a regular session
    ///         - the only window `cure` runs in - a thin pool is treated as uninformative rather
    ///         than as a price: the verdict stays TRUSTED and the mark collapses cleanly onto the
    ///         Chainlink anchor. Only a sustained divergence (R5) closes the window.
    function test_R5d_ThinPoolDoesNotCloseTheCureWindow() public {
        _openBandLine(9_900e6, P130);
        _walkTo(MON_2026_03_02, 11 hours);
        vm.prank(keeper);
        credit.flag(alice);

        // The borrower does what the notice is for and brings the line back inside the OPEN
        // threshold, which is the only threshold a cure is ever measured against now.
        _repay(1_000e6);

        vm.mockCall(
            address(usdc), abi.encodeWithSignature("balanceOf(address)", address(pool)), abi.encode(uint256(1e6))
        );
        console2.log("REGULAR verdict with a drained pool:", uint256(oracle.peek().verdict));
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "a thin pool is ignored while open");
        assertTrue(_tryCure(alice), "cure still lands with the pool under the depth floor");
        assertFalse(credit.isFlagged(alice), "and the flag is gone");
    }

    /// @notice A keeper cannot seize by landing `liquidate` in the same block as the close, nor by
    ///         ordering ahead of the `cure`.
    function test_R5b_NoSameBlockOrFrontRunEscape() public {
        _openBandLine(9_900e6, P130);
        _walkTo(MON_2026_03_02, 11 hours);
        vm.prank(keeper);
        credit.flag(alice);
        uint64 grace = credit.graceUntil(alice);

        _walkTo(MON_2026_03_02, T_CLOSE - 1);
        assertEq(uint256(calendar.session()), uint256(Session.REGULAR), "still open at 15:59:59");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.GraceNotExpired.selector, grace));
        credit.liquidate(alice, address(nvda), 1_000e6);

        _step(_et(MON_2026_03_02, T_CLOSE));
        vm.prank(keeper);
        vm.expectRevert();
        credit.liquidate(alice, address(nvda), 1_000e6);

        // The bell freezes the borrower's side on the same condition, for the same reason: there is
        // no continuous price discovery after it, so neither seizing nor clearing a flag is allowed
        // to act on the mark. The flag simply survives the night; the window reopens with the
        // market, and until then nobody can take anything.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.POST));
        credit.cure(alice);
        assertTrue(credit.isFlagged(alice), "the flag survives the bell, and so does the collateral");
    }

    /// @notice A keeper cannot pre-emptively re-flag in the same block as the cure. Flag and cure
    ///         are exact complements at every instant, so the state that admits one forbids the
    ///         other, and there is no ordering that gets both into one block.
    function test_R5c_NoImmediateReflag() public {
        _openBandLine(9_900e6, P130);
        _walkTo(MON_2026_03_02, 11 hours);
        vm.prank(keeper);
        credit.flag(alice);

        // A cure now costs a real repayment inside the regular session. That is the point of the
        // open-market requirement: nothing about the passage of a closing bell clears a flag.
        _repay(1_000e6);
        assertTrue(_tryCure(alice), "cured");
        assertFalse(credit.isFlagged(alice), "flag cleared");

        (bool ok,) = _tryFlag(alice);
        assertFalse(ok, "keeper cannot re-flag in the same block");
    }

    /*//////////////////////////////////////////////////////////////
      R6 - WHAT THE BORROWER GIVES UP
    //////////////////////////////////////////////////////////////*/

    function test_R6_CampingLineIsFrozen() public {
        _openBandLine(9_900e6, P130);
        _walkTo(MON_2026_03_02 + 1, 11 hours);

        vm.prank(alice);
        vm.expectRevert();
        credit.draw(1e6, alice);

        vm.prank(alice);
        vm.expectRevert();
        credit.withdrawCollateral(address(nvda), 1e8, alice);

        _walkTo(MON_2026_03_02 + 1, T_CLOSE + 1 minutes);
        vm.prank(alice);
        vm.expectRevert();
        credit.draw(1e6, alice);
        vm.prank(alice);
        vm.expectRevert();
        credit.withdrawCollateral(address(nvda), 1e8, alice);

        console2.log("camping line: draw and withdrawCollateral revert in every session");
    }

    /*//////////////////////////////////////////////////////////////
      R7 - PRICE OF THE LOOP
    //////////////////////////////////////////////////////////////*/

    /// @notice What a cure costs, now that it costs something real. The loop this section was
    ///         written to price - one free `cure()` every evening, forever - no longer exists,
    ///         because a cure has to be paid for in principal inside a regular session. The gas
    ///         number is kept because it is the floor on what a genuine recovery costs.
    function test_R7_GasPerCure() public {
        _openBandLine(9_900e6, P130);
        _walkTo(MON_2026_03_02, 11 hours);
        vm.prank(keeper);
        credit.flag(alice);

        uint256 debtBefore = credit.debtOf(alice);
        _repay(1_000e6);

        uint256 g0 = gasleft();
        vm.prank(alice);
        credit.cure(alice);
        uint256 used = g0 - gasleft();
        console2.log("principal needed to cure    :", debtBefore - credit.debtOf(alice));
        console2.log("gas per cure()              :", used);
        console2.log("gas per trading year (252x) :", used * 252);
    }

    /*//////////////////////////////////////////////////////////////
      R8 - LENDER EXPOSURE WHILE LOOPING
    //////////////////////////////////////////////////////////////*/

    function test_R8_WorstCaseCollateralisationWhileLooping() public {
        _openBandLine(9_900e6, P130);
        uint256 collateralUsdc = 13_000e6;

        _walkTo(MON_2026_03_02 + 1, T_CLOSE + 1 minutes);
        uint256 thr16 = credit.seizureThreshold(alice);
        _walkTo(MON_2026_03_02 + 2, 3 hours + 59 minutes);
        uint256 thr0359 = credit.seizureThreshold(alice);
        _walkTo(MON_2026_03_02 + 5, 12 hours);
        uint256 thrSat = credit.seizureThreshold(alice);
        _walkTo(MON_2026_03_02 + 6, 23 hours + 30 minutes);
        uint256 thrSun = credit.seizureThreshold(alice);

        console2.log("collateral value USDC       :", collateralUsdc);
        console2.log("POST 16:01  thr / LTV bps   :", thr16, thr16 * 10_000 / collateralUsdc);
        console2.log("OVN  03:59  thr / LTV bps   :", thr0359, thr0359 * 10_000 / collateralUsdc);
        console2.log("SAT  12:00  thr / LTV bps   :", thrSat, thrSat * 10_000 / collateralUsdc);
        console2.log("SUN  23:30  thr / LTV bps   :", thrSun, thrSun * 10_000 / collateralUsdc);
    }
}
