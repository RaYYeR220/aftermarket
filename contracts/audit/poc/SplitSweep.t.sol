// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {AuditHarness} from "./Harness.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {Verdict} from "../../src/libraries/Types.sol";

/// @title  A-03 - MITIGATED: `sweepYield` still cannot tell a split from a dividend, but it can no
///         longer act on the difference
/// @notice B20 signals BOTH corporate actions through the same `multiplier()`. A dividend is
///         value-accretive to the raw token; a split is value-NEUTRAL to it (`IB20Asset.multiplier`
///         is documented as "similar in shape to wstETH wrapping stETH", so raw units are the
///         wstETH-like wrapper and a 2:1 split doubles the multiplier while halving the per-share
///         price, leaving the raw unit worth exactly what it was worth before).
///
///         `AftermarketCredit.sweepYield` computes the accreted slice as
///
///             sold = balance * (m - m0) / m
///
///         For a 10:1 split - which is what NVDA actually did in June 2024 and what the B20 NVDAc
///         token would mirror - that is `balance * 9/10`: ninety percent of the borrower's position,
///         sold on a market order, on an event that changed nobody's wealth by one cent.
///
///         The multiplier alone cannot distinguish the two events, so the contract no longer tries.
///         `MAX_SWEEP_BPS` refuses any slice larger than a distribution could plausibly be, which
///         turns a catastrophic misfire into a revert an operator can see and act on. A real
///         dividend still sweeps exactly as before.
///
/// @dev What is NOT fixed, and is recorded here rather than papered over: which unit the live
///      Chainlink "Coinbase <TICKER>" feed quotes is unknowable until the first corporate action,
///      and if it quotes the SHARE rather than the raw wrapper then a split moves the anchor
///      tenfold away from a pool that trades the wrapper. `test_03` and `test_04` pin that branch.
///      The oracle's response - refusing to quote - is the safe one, and the remedy is a new oracle
///      plus `setAsset`, which is an operational procedure rather than a code change. The static
///      multiplier bounds are now configured wide (`test_05`) precisely because they are the wrong
///      tool for detecting this and a narrow band turns a routine reverse split into a permanent
///      outage.
contract SplitSweepTest is AuditHarness {
    int256 internal constant PRICE_200 = 200e8;

    function setUp() public {
        _deploy(PRICE_200);
        // The venue fills at the oracle mark: 1e8 raw NVDAc -> 200e6 USDC.
        adapter.setRate(200e6, 1e8);
        usdc.mint(address(adapter), 10_000_000e6);
    }

    /// @notice Control: a genuine 1% cash dividend sweeps ~1% of the position. This is the intended
    ///         behaviour and it is correct.
    function test_00_Control_DividendSweepsTheRightSlice() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(5_000e6, alice);
        credit.setAutoRepay(true);
        vm.stopPrank();

        // 1% dividend reinvested: the raw unit now represents 1.01 shares, and a total-return feed
        // (and the pool that trades the raw unit) both move up 1% with it.
        nvda.setMultiplier(1.01e18);
        _setPriceBoth(202e8);

        vm.prank(keeper);
        (uint256 sold, uint256 proceeds, uint256 repaid) = credit.sweepYield(alice, address(nvda));
        console2.log("dividend: sold raw units :", sold);
        console2.log("dividend: proceeds USDC  :", proceeds);
        console2.log("dividend: repaid USDC    :", repaid);

        // 100e8 * 0.01/1.01 = 0.990099e8, i.e. ~0.99% of the position.
        assertApproxEqRel(sold, 0.990099e8, 0.001e18, "about 1% of the position");
        assertEq(credit.collateral(alice, address(nvda)), 100e8 - sold, "the rest is untouched");
    }

    /// @notice THE FIX. A 10:1 split - zero economic event - is refused instead of executed.
    function test_01_TenForOneSplitIsRefusedInsteadOfDumping90Percent() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8); // $20,000 of NVDAc
        credit.draw(5_000e6, alice);
        credit.setAutoRepay(true); // the flagship "self-repaying collateral" opt-in
        vm.stopPrank();

        uint256 collateralBefore = credit.collateral(alice, address(nvda));
        uint256 debtBefore = credit.debtOf(alice);
        uint256 walletBefore = usdc.balanceOf(alice);

        // 10:1 split. The multiplier goes 1e18 -> 10e18. The RAW unit is unchanged in value, so
        // NEITHER venue moves: the Chainlink total-return print and the Aerodrome TWAP both stay at
        // $200 per raw NVDAc. Nothing was distributed to anybody.
        nvda.setMultiplier(10e18);

        // The oracle is perfectly happy: 10e18 is inside [0.01e18, 1000e18].
        assertEq(oracle.peek().multiplier, 10e18, "oracle sees the split");
        assertGt(oracle.markBorrow(), 0, "and still marks the asset TRUSTED");

        // The slice the naive formula asks for is 100e8 * (10e18 - 1e18) / 10e18 = 90e8, against a
        // cap of MAX_SWEEP_BPS of the balance. Anyone may pull the trigger - the borrower opted into
        // auto-repay - and nobody can make it fire.
        uint256 cap = collateralBefore * credit.MAX_SWEEP_BPS() / 10_000;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.SweepTooLarge.selector, 90e8, cap));
        credit.sweepYield(alice, address(nvda));

        // The borrower cannot fire it by accident from a UI button labelled "collect dividend" either.
        vm.prank(alice);
        vm.expectPartialRevert(IAftermarketCredit.SweepTooLarge.selector);
        credit.sweepYield(alice, address(nvda));

        console2.log("split: collateral before :", collateralBefore);
        console2.log("split: slice the formula asks for :", uint256(90e8));
        console2.log("split: cap                        :", cap);

        assertEq(credit.collateral(alice, address(nvda)), collateralBefore, "not one unit was sold");
        assertEq(credit.debtOf(alice), debtBefore, "the debt is untouched");
        assertEq(usdc.balanceOf(alice), walletBefore, "and so is the wallet");
    }

    /// @notice UNFIXED AND RECORDED. `AftermarketOracle` never uses the multiplier in its price
    ///         math, so the anchor and the pool must already agree on which unit they quote - and the
    ///         multiplier is exactly the thing that can break that agreement. If the Chainlink
    ///         "Coinbase <TICKER>" feed quotes the SHARE while the Aerodrome pool trades the RAW
    ///         unit, a 10:1 split drops the anchor tenfold while the pool does not move, and the
    ///         oracle is permanently divergent. Which convention is live is not determinable from
    ///         the code: every B20 multiplier on Base is still exactly 1e18, so the two are
    ///         observationally identical until the first corporate action. The oracle's response -
    ///         refusing to quote - is the safe one, and the remedy is deploying a rescaled oracle
    ///         and calling `setAsset`.
    function test_03_IfTheFeedQuotesSharesInsteadOfRawUnitsTheOracleBricks() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(5_000e6, alice);
        vm.stopPrank();

        // 10:1 split under the share-quoting convention: the feed prints $20, the pool still prints
        // $200 per raw unit because a raw unit is now ten shares.
        nvda.setMultiplier(10e18);
        feed.set(20e8, block.timestamp);
        feedAnswer = 20e8;

        console2.log("verdict       :", uint256(oracle.peek().verdict));
        console2.log("divergenceBps :", oracle.peek().divergenceBps);
        console2.log("band          :", oracle.peek().divergenceBand);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_DIVERGENT), "permanently divergent");

        // Every risk path for this asset is frozen, for every holder, indefinitely.
        vm.prank(alice);
        vm.expectRevert();
        credit.draw(1e6, alice);
        vm.prank(alice);
        vm.expectRevert();
        credit.withdrawCollateral(address(nvda), 1e8, alice);
        vm.prank(keeper);
        vm.expectRevert();
        credit.flag(alice);
    }

    /// @notice UNFIXED AND RECORDED, the sharper half of the same branch: if the pool falls under
    ///         `minPoolLiquidityUsd` during an open session the divergence check stops applying and
    ///         the mark collapses straight onto the tenfold-lower anchor. Anchor-only pricing while
    ///         the reference feed is live is correct in general - it is what makes a thin pool
    ///         uninformative rather than authoritative - so the exposure here is entirely the
    ///         unresolved unit convention above, not the fallback.
    function test_04_OrWorse_TheMarkCollapsesAndEveryoneIsInstantlyUnderwater() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(9_000e6, alice);
        vm.stopPrank();

        (, uint256 before) = credit.riskOf(alice);
        console2.log("threshold before :", before);

        nvda.setMultiplier(10e18);
        feed.set(20e8, block.timestamp);
        feedAnswer = 20e8;
        // The pool can no longer corroborate: one large swap, or simply a quiet day, is enough.
        vm.mockCall(
            address(usdc), abi.encodeWithSignature("balanceOf(address)", address(pool)), abi.encode(uint256(1e6))
        );

        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "anchor-only, and trusted");
        (, uint256 after_) = credit.riskOf(alice);
        console2.log("threshold after  :", after_);
        console2.log("debt             :", credit.debtOf(alice));
        assertEq(after_, before / 10, "collateral marked down tenfold in one block");

        vm.prank(keeper);
        credit.flag(alice); // instantly flaggable on a value-neutral corporate action
        assertTrue(credit.isFlagged(alice), "flagged");
    }

    /// @notice The multiplier bounds are now configured as what they actually are - a garbage
    ///         filter - rather than as a corporate-action detector. `minMultiplierBps` shipped at
    ///         5000, so a routine 1:5 reverse split put the multiplier below the bound and halted
    ///         that asset's oracle PERMANENTLY, for every holder, with no owner and no setter
    ///         anywhere in `AftermarketOracle` to widen it again. The deployment config now ships
    ///         `[0.01e18, 1000e18]`, which no real corporate action reaches.
    function test_05_ARoutineReverseSplitNoLongerHaltsTheOracle() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(5_000e6, alice);
        vm.stopPrank();

        nvda.setMultiplier(0.5e18); // 1:2
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "1:2 survives");

        nvda.setMultiplier(0.2e18); // 1:5, which used to be a permanent outage
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "1:5 survives");

        nvda.setMultiplier(0.05e18); // 1:20, deeper than any listed name has ever done
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "1:20 survives");

        // Every path stays open through all of it.
        vm.prank(alice);
        credit.withdrawCollateral(address(nvda), 1e8, alice);
        assertGt(oracle.markBorrow(), 0, "the asset is still priceable");

        // The filter is still a filter: a multiplier outside a range no real action reaches is
        // treated as a broken read, which is the only job these bounds were ever suited for.
        nvda.setMultiplier(0.001e18);
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_HALTED), "garbage is still rejected");
    }

    /// @notice The cap holds across a top-up too. `_rollMultiplierCheckpoint` deliberately blends
    ///         the checkpoint on deposit so that the sellable slice stays the same size IN RAW UNITS
    ///         - which is the right thing for a dividend, and means that after a split posting more
    ///         collateral does not shrink the exposure by one unit. The cap is what stops it either
    ///         way, in both call orderings.
    function test_02_TheCapHoldsAcrossATopUp() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(5_000e6, alice);
        vm.stopPrank(); // note: auto-repay left OFF

        nvda.setMultiplier(10e18);

        // With auto-repay off, only the borrower can pull the trigger.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.AutoRepayDisabled.selector, alice));
        credit.sweepYield(alice, address(nvda));

        // Posting more collateral re-blends the checkpoint but PRESERVES the 90e8 raw slice exactly.
        vm.prank(alice);
        credit.depositCollateral(address(nvda), 1e8);
        uint256 m0 = credit.multiplierCheckpoint(alice, address(nvda));
        uint256 balance = credit.collateral(alice, address(nvda));
        uint256 sellable = balance * (10e18 - m0) / 10e18;
        console2.log("blended checkpoint :", m0);
        console2.log("balance now        :", balance);
        console2.log("still sellable     :", sellable);
        assertApproxEqAbs(sellable, 90e8, 1, "the 90e8 slice survives any top-up, by design (1 wei to the protocol)");

        // And the borrower still cannot fire it themselves.
        vm.prank(alice);
        vm.expectPartialRevert(IAftermarketCredit.SweepTooLarge.selector);
        credit.sweepYield(alice, address(nvda));
        assertEq(credit.collateral(alice, address(nvda)), balance, "the position survives intact");
    }
}
