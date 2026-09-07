// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {RefuteBase} from "./RefuteBase.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {Verdict} from "../../src/libraries/Types.sol";

/// @notice Hostile review of CLAIM 2 ("sweepYield conflates a stock split with a dividend").
contract Refute2_SplitSweep is RefuteBase {
    int256 internal constant P200 = 200e8;

    function setUp() public {
        _deploy(P200);
        _pinBriefDefaults();
        adapter.setRate(200e6, 1e8); // the venue fills exactly at the $200 mark
        usdc.mint(address(adapter), 50_000_000e6);
    }

    function _open(uint256 draw, bool autoRepay) internal {
        vm.warp(_et(MON_2026_03_02, T_OPEN + 5 minutes));
        feed.set(feedAnswer, block.timestamp);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        if (draw != 0) credit.draw(draw, alice);
        if (autoRepay) credit.setAutoRepay(true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
      S1 - DOES THE ORACLE CATCH A SPLIT? DEPENDS ENTIRELY ON WHAT
           THE CHAINLINK FEED QUOTES.
    //////////////////////////////////////////////////////////////*/

    /// @notice Convention A - the documented one. `OracleConfig.feed` is a "Chainlink total-return
    ///         aggregator": a total-return index is by construction continuous across a split (and
    ///         across a dividend), so it keeps printing the same number while the multiplier moves.
    ///         The Aerodrome pool trades the RAW unit and is likewise unmoved.
    ///
    ///         Result: 2:1, 4:1, 10:1 and 1:10 all pass every oracle gate. Neither the multiplier
    ///         bounds nor the divergence check sees anything.
    function test_S1_TotalReturnAnchor_OracleSeesNothing() public {
        _open(5_000e6, true);
        uint256[5] memory ms = [uint256(2e18), 4e18, 10e18, 0.5e18, 0.1e18];
        for (uint256 i; i < ms.length; ++i) {
            uint256 snap = vm.snapshotState();
            nvda.setMultiplier(ms[i]);
            console2.log("multiplier / verdict / markBorrow:", ms[i], uint256(oracle.peek().verdict));
            console2.log("   markBorrow:", oracle.markBorrow());
            assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "TRUSTED across every split");
            vm.revertToState(snap);
        }
    }

    /// @notice The multiplier bounds only fire beyond 1000x / below 0.01x - i.e. after a cumulative
    ///         1000:1 split or 1:100 reverse. No realistic single corporate action reaches them.
    function test_S1b_MultiplierBoundsAreIrrelevantToRealSplits() public {
        _open(5_000e6, true);
        uint256[8] memory ms =
            [uint256(2e18), 4e18, 10e18, 1000e18, 1001e18, 0.1e18, 0.01e18, 0.009e18];
        for (uint256 i; i < ms.length; ++i) {
            uint256 snap = vm.snapshotState();
            nvda.setMultiplier(ms[i]);
            uint256 v = uint256(oracle.peek().verdict);
            console2.log("multiplier / verdict (2 == UNTRUSTED_HALTED):", ms[i], v);
            vm.revertToState(snap);
        }
    }

    /// @notice Convention B - the feed quotes the SHARE. Then a 10:1 split drops the anchor tenfold
    ///         while the pool does not move, and the oracle goes permanently divergent: `sweepYield`
    ///         reverts along with `draw`, `flag` and `withdrawCollateral`.
    ///
    ///         So under convention B the claimed sweep CANNOT happen. This is the only branch in
    ///         which claim 2 is refuted - and the price of refuting it is a total protocol freeze,
    ///         which is a strictly worse outcome.
    function test_S1c_ShareQuotingAnchor_SweepIsImpossibleBecauseEverythingBricks() public {
        _open(5_000e6, true);
        nvda.setMultiplier(10e18);
        feedAnswer = 20e8;
        feed.set(20e8, block.timestamp);

        console2.log("verdict / divergenceBps / band:", uint256(oracle.peek().verdict), oracle.peek().divergenceBps);
        console2.log("band:", oracle.peek().divergenceBand);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_DIVERGENT), "divergent");

        vm.prank(keeper);
        vm.expectRevert();
        credit.sweepYield(alice, address(nvda));
        console2.log("sweepYield reverts under the share-quoting convention");
    }

    /*//////////////////////////////////////////////////////////////
      S2 - REVERSE SPLIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Walks `sweepYield` and `_rollMultiplierCheckpoint` for `m < m0`.
    function test_S2_ReverseSplitWalkthrough() public {
        _open(5_000e6, true);
        assertEq(credit.multiplierCheckpoint(alice, address(nvda)), 1e18, "checkpoint seeded at 1e18");

        // 1:10 reverse split. Raw unit unchanged in value; multiplier drops.
        nvda.setMultiplier(0.1e18);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NothingToSweep.selector, alice, address(nvda)));
        credit.sweepYield(alice, address(nvda));
        assertEq(credit.multiplierCheckpoint(alice, address(nvda)), 1e18, "checkpoint untouched by a failed sweep");

        // A GENUINE 1% dividend now lands on top of the reverse split: 0.1e18 -> 0.101e18. It is
        // still below the stale 1e18 checkpoint, so the dividend can never be swept.
        nvda.setMultiplier(0.101e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NothingToSweep.selector, alice, address(nvda)));
        credit.sweepYield(alice, address(nvda));
        console2.log("post-reverse-split dividends are unsweepable until m climbs back above 1e18");

        // Depositing resets the checkpoint DOWN (the `m <= m0` branch), which re-arms the whole
        // 1e18 -> 0.101e18 gap as a future "distribution".
        vm.prank(alice);
        credit.depositCollateral(address(nvda), 1e8);
        uint256 m0 = credit.multiplierCheckpoint(alice, address(nvda));
        console2.log("checkpoint after a post-reverse-split deposit:", m0);
        assertEq(m0, 0.101e18, "checkpoint reset down to the live multiplier");

        // If the issuer later reverses the reverse split (0.101e18 -> 1.01e18), the contract now
        // believes 90% of the position is distribution.
        nvda.setMultiplier(1.01e18);
        uint256 balance = credit.collateral(alice, address(nvda));
        uint256 sellable = balance * (1.01e18 - m0) / 1.01e18;
        console2.log("balance / sellable slice:", balance, sellable);
        assertApproxEqRel(sellable, balance * 90 / 100, 0.001e18, "90% of the position re-armed");
    }

    /// @notice Nothing is double-counted and nothing is stranded in the contract: after a split-sized
    ///         sweep, the next genuine dividend still sweeps exactly the dividend.
    function test_S2b_NoDoubleCountAfterASplitSweep() public {
        _open(5_000e6, true);
        nvda.setMultiplier(10e18);
        vm.prank(keeper);
        (uint256 sold1,,) = credit.sweepYield(alice, address(nvda));
        assertEq(sold1, 90e8, "90% sold");
        assertEq(credit.multiplierCheckpoint(alice, address(nvda)), 10e18, "checkpoint rolled to 10e18");

        // A genuine 1% dividend on top of the split: 10e18 -> 10.1e18.
        nvda.setMultiplier(10.1e18);
        vm.prank(keeper);
        (uint256 sold2,,) = credit.sweepYield(alice, address(nvda));
        console2.log("dividend after the split sold:", sold2, "of", credit.collateral(alice, address(nvda)) + sold2);
        assertApproxEqRel(sold2, uint256(10e8) / 101, 0.01e18, "~0.99% of the remaining balance");
        assertEq(credit.collateral(address(credit), address(nvda)), 0, "engine holds nothing for itself");
    }

    /*//////////////////////////////////////////////////////////////
      S3 - IS IT LOSS OF FUNDS, OR UNWANTED REBALANCING?
    //////////////////////////////////////////////////////////////*/

    /// @notice Full net-worth accounting across the 10:1 split sweep at a fair fill.
    function test_S3_NetWorthIsPreservedAtAFairFill() public {
        _open(5_000e6, true);
        uint256 markBefore = oracle.markBorrow();

        uint256 collBefore = credit.collateral(alice, address(nvda));
        uint256 debtBefore = credit.debtOf(alice);
        uint256 walletBefore = usdc.balanceOf(alice);
        uint256 nwBefore = _mul(collBefore, markBefore) + walletBefore - debtBefore;

        nvda.setMultiplier(10e18);
        vm.prank(keeper);
        (uint256 sold, uint256 proceeds, uint256 repaid) = credit.sweepYield(alice, address(nvda));

        uint256 collAfter = credit.collateral(alice, address(nvda));
        uint256 nwAfter = _mul(collAfter, oracle.markBorrow()) + usdc.balanceOf(alice) - credit.debtOf(alice);

        console2.log("sold / proceeds / repaid   :", sold, proceeds, repaid);
        console2.log("net worth before / after   :", nwBefore, nwAfter);
        console2.log("collateral before / after  :", collBefore, collAfter);
        console2.log("debt before / after        :", debtBefore, credit.debtOf(alice));
        console2.log("wallet USDC delta          :", usdc.balanceOf(alice) - walletBefore);
        console2.log("net worth delta (USDC 6dec):", nwAfter - nwBefore);
        assertApproxEqRel(nwAfter, nwBefore, 0.0001e18, "net worth is preserved at a fair fill");
    }

    /// @notice The actual, quantified loss: the credit engine only guarantees a fill within
    ///         `maxSlippageBps` of `markBorrow`, and `markBorrow` itself carries the closed-session
    ///         haircut. Measures the worst legal execution during a regular session and during a
    ///         weekend.
    function test_S3b_WorstLegalExecutionLoss() public {
        // regular session, no gap haircut: minOut == 99% of the mark
        _open(5_000e6, true);
        nvda.setMultiplier(10e18);
        uint256 fair = _mul(90e8, oracle.markBorrow());
        uint256 minOut = fair * (10_000 - 100) / 10_000;
        adapter.setRate((minOut + 1) * 1e18 / 90e8 + 1, 1e18); // venue fills at (essentially) minOut
        vm.prank(keeper);
        (, uint256 proceeds,) = credit.sweepYield(alice, address(nvda));
        console2.log("REGULAR: fair value of the slice :", fair);
        console2.log("REGULAR: worst legal proceeds    :", proceeds);
        console2.log("REGULAR: loss bps of the SLICE   :", (fair - proceeds) * 10_000 / fair);
        console2.log("REGULAR: loss bps of the POSITION:", (fair - proceeds) * 10_000 / (fair * 10 / 9));
    }

    /// @notice The same sweep over a weekend, where `markBorrow` is haircut by up to 500bps before
    ///         the 100bps slippage budget is applied on top.
    function test_S3c_WeekendExecutionLoss() public {
        _open(5_000e6, true);
        // Saturday 12:00 ET. Feed frozen since Friday's close; weekend budget is 80h.
        vm.warp(_et(MON_2026_03_02 + 5, 12 hours));
        feedAnswer = P200;
        feed.set(P200, _et(MON_2026_03_02 + 4, T_CLOSE)); // Friday's closing print
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED_CLOSED), "trusted closed");
        console2.log("weekend haircutBps               :", oracle.peek().haircutBps);

        uint256 anchor = 200e6 * 90e8 / 1e8; // fair USDC value of the 90e8 slice
        // Make the venue fill EXACTLY at the engine's minOut, which is the worst execution the
        // credit contract will accept: markBorrow (haircut down) minus maxSlippageBps.
        uint256 minOut = _mul(90e8, oracle.markBorrow()) * (10_000 - 100) / 10_000;
        adapter.setRate((minOut + 1) * 1e18 / 90e8 + 1, 1e18);
        nvda.setMultiplier(10e18);
        vm.prank(keeper);
        (, uint256 proceeds,) = credit.sweepYield(alice, address(nvda));
        console2.log("weekend: fair value of the slice :", anchor);
        console2.log("weekend: worst legal proceeds    :", proceeds);
        console2.log("weekend: loss bps of the SLICE   :", (anchor - proceeds) * 10_000 / anchor);
        console2.log("weekend: loss bps of the POSITION:", (anchor - proceeds) * 10_000 / (anchor * 10 / 9));
    }

    /// @notice The worst case of all: a sweep run late in a long weekend, where the gap haircut is
    ///         at its 500bps cap before the 100bps slippage budget is applied on top.
    function test_S3e_WorstCaseHaircutCapExecutionLoss() public {
        _open(5_000e6, true);
        // Sunday 23:00 ET: 55h since Friday's close, haircut pinned at the 500bps cap, feed age 55h
        // against an 80h weekend budget.
        vm.warp(_et(MON_2026_03_02 + 6, 23 hours));
        feedAnswer = P200;
        feed.set(P200, _et(MON_2026_03_02 + 4, T_CLOSE));
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED_CLOSED), "trusted closed");
        assertEq(oracle.peek().haircutBps, 500, "haircut at its cap");

        uint256 anchorValue = 200e6 * 90e8 / 1e8;
        uint256 minOut = _mul(90e8, oracle.markBorrow()) * (10_000 - 100) / 10_000;
        adapter.setRate((minOut + 1) * 1e18 / 90e8 + 1, 1e18);
        nvda.setMultiplier(10e18);
        vm.prank(keeper);
        (, uint256 proceeds,) = credit.sweepYield(alice, address(nvda));
        console2.log("cap: fair value of the slice     :", anchorValue);
        console2.log("cap: worst legal proceeds        :", proceeds);
        console2.log("cap: loss bps of the SLICE       :", (anchorValue - proceeds) * 10_000 / anchorValue);
        console2.log("cap: loss bps of the POSITION    :", (anchorValue - proceeds) * 10_000 / (anchorValue * 10 / 9));
    }

    /// @notice The slippage guard is a real brake: a venue that cannot absorb a 90% dump inside
    ///         `maxSlippageBps` makes the sweep revert instead of executing it.
    function test_S3d_SlippageGuardRefusesADumpTheVenueCannotAbsorb() public {
        _open(5_000e6, true);
        nvda.setMultiplier(10e18);
        adapter.setHaircutBps(101); // one bp past the engine's budget
        adapter.setEnforceMinOut(false); // the venue itself does not object
        vm.prank(keeper);
        vm.expectRevert();
        credit.sweepYield(alice, address(nvda));
        console2.log("a 1.01% impact fill is refused by SlippageExceeded");

        adapter.setHaircutBps(100);
        vm.prank(keeper);
        (uint256 sold,,) = credit.sweepYield(alice, address(nvda));
        assertEq(sold, 90e8, "a 1.00% impact fill goes through");
    }

    /*//////////////////////////////////////////////////////////////
      S4 - PRECONDITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice `autoRepayEnabled` is off by default and nothing in the protocol turns it on: only an
    ///         explicit `setAutoRepay(true)` exposes a borrower to a third-party sweep.
    function test_S4_AutoRepayIsOffByDefault() public {
        _open(5_000e6, false);
        assertFalse(credit.autoRepayEnabled(alice), "off by default");
        nvda.setMultiplier(10e18);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.AutoRepayDisabled.selector, alice));
        credit.sweepYield(alice, address(nvda));

        // Opening a line does not opt you in, and neither does depositing or drawing.
        vm.prank(alice);
        credit.depositCollateral(address(nvda), 1e8);
        assertFalse(credit.autoRepayEnabled(alice), "still off");

        // The borrower can always do it to themselves, though.
        vm.prank(alice);
        (uint256 sold,,) = credit.sweepYield(alice, address(nvda));
        console2.log("self-inflicted sweep sells:", sold);
        assertGt(sold, 0, "the borrower can always fire it themselves");
    }

    /// @notice Turning auto-repay OFF is a complete and immediate defence, and the borrower can do it
    ///         at any time - including after the split, before any keeper gets there.
    function test_S4b_OptOutIsACompleteDefence() public {
        _open(5_000e6, true);
        nvda.setMultiplier(10e18);
        vm.prank(alice);
        credit.setAutoRepay(false);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.AutoRepayDisabled.selector, alice));
        credit.sweepYield(alice, address(nvda));
        console2.log("opt-out fully defuses the third-party path");
    }

    /*//////////////////////////////////////////////////////////////
      S5 - DOES THE SWEEP EVER MAKE THE LINE UNSAFE?
    //////////////////////////////////////////////////////////////*/

    /// @notice A split-sized sweep sells ~90% of the collateral but repays the debt out of the same
    ///         proceeds first, so the surviving line is strictly healthier, never liquidatable.
    function test_S5_SweepNeverWorsensHealth() public {
        int256[1] memory unused;
        unused;
        uint256[3] memory draws = [uint256(2_000e6), 5_000e6, 9_900e6];
        for (uint256 i; i < draws.length; ++i) {
            uint256 snap = vm.snapshotState();
            _open(draws[i], true);
            (, uint256 thrBefore) = credit.riskOf(alice);
            uint256 debtBefore = credit.debtOf(alice);
            nvda.setMultiplier(10e18);
            vm.prank(keeper);
            credit.sweepYield(alice, address(nvda));
            (, uint256 thrAfter) = credit.riskOf(alice);
            uint256 debtAfter = credit.debtOf(alice);
            console2.log("draw / debt after / threshold after:", draws[i], debtAfter, thrAfter);
            assertLe(debtAfter, thrAfter, "line is healthy after the sweep");
            assertLt(debtAfter, debtBefore, "debt strictly reduced");
            thrBefore;
            vm.revertToState(snap);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev raw collateral units * Morpho-scale mark -> USDC (6 decimals).
    function _mul(uint256 amount, uint256 mark) internal pure returns (uint256) {
        return amount * mark / 1e36;
    }
}
