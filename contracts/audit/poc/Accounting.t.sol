// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {AuditHarness} from "./Harness.sol";
import {AftermarketOracle} from "../../src/AftermarketOracle.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketOracle} from "../../src/interfaces/IAftermarketOracle.sol";
import {Session} from "../../src/libraries/Types.sol";

import {MockAggregatorV3} from "../../test/mocks/MockAggregatorV3.sol";
import {MockCLPool} from "../../test/mocks/MockCLPool.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

/// @title  Accounting findings A-12 .. A-15
contract AccountingTest is AuditHarness {
    int256 internal constant PRICE_200 = 200e8;

    // An 18-decimal B20 equity, which `IB20` explicitly supports ("6-18, configurable per token")
    // and which the repo's own fixture already uses (`test/AftermarketCredit.t.sol` lists AAPLc at 18).
    MockERC20 internal aapl;
    MockAggregatorV3 internal aaplFeed;
    MockCLPool internal aaplPool;
    AftermarketOracle internal aaplOracle;

    address internal lp2 = makeAddr("lp2");

    function setUp() public {
        _deploy(PRICE_200);
        adapter.setRate(200e6, 1e8);
        usdc.mint(address(adapter), 10_000_000e6);
        _listAapl();
    }

    function _listAapl() internal {
        aapl = new MockERC20("Coinbase AAPL", "AAPLc", 18);
        aaplFeed = new MockAggregatorV3(8, 200e8, block.timestamp);
        aaplPool = new MockCLPool(address(usdc), address(aapl), 10);
        usdc.mint(address(aaplPool), 100_000e6);

        MockAggregatorV3 sf = feed;
        MockCLPool sp = pool;
        AftermarketOracle so = oracle;
        int24 st = _currentTick;

        feed = aaplFeed;
        pool = aaplPool;
        pool.setMeanTick(0, TWAP_WINDOW);
        _currentTick = 0;
        aaplOracle = new AftermarketOracle(_oracleConfig(address(aapl), address(usdc), address(aaplPool)));
        oracle = aaplOracle;
        int24 honest = _tickForPriceWad(200e18);
        aaplPool.setMeanTick(honest, TWAP_WINDOW);

        feed = sf;
        pool = sp;
        oracle = so;
        _currentTick = st;

        vm.prank(owner);
        credit.setAsset(
            address(aapl),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(aaplOracle)),
                advanceOpenBps: ADVANCE_OPEN_BPS,
                advanceClosedBps: ADVANCE_CLOSED_BPS,
                liqThresholdOpenBps: LIQ_THRESHOLD_OPEN_BPS,
                liqThresholdClosedBps: LIQ_THRESHOLD_CLOSED_BPS,
                liqBonusBps: LIQ_BONUS_BPS,
                cap: uint128(1_000_000e18),
                enabled: true
            })
        );
        aapl.mint(alice, 1_000e18);
        vm.prank(alice);
        aapl.approve(address(credit), type(uint256).max);
    }

    function _refreshFeeds() internal {
        if (calendar.isOpen(block.timestamp)) {
            feed.set(feedAnswer, block.timestamp);
            aaplFeed.set(200e8, block.timestamp);
        }
    }

    /*//////////////////////////////////////////////////////////////
       A-12 - FIXED: every leg clears, and the residue is written off
    //////////////////////////////////////////////////////////////*/

    /// @notice WAS: `_quoteSeizure` re-derived the liquidator's cost with a rounding-DOWN division
    ///         when the borrower's balance capped the seizure, so for any leg below
    ///         `(BPS + bonus) / mark` raw units the cost floored to zero and the whole call reverted
    ///         `ZeroAmount`. The leg could never leave `postedAssets`, so the length-zero gate on
    ///         `_realizeBadDebt` was unreachable and the vault compounded interest on debt nobody
    ///         would ever pay. An ordinary cascade against a fallen asset produced it unaided.
    ///
    ///         NOW: the cost is rounded UP - it is the liquidator's payment, so that is the correct
    ///         side - and therefore never floors to zero. One unit of USDC clears any crumb, the
    ///         posted-asset list empties, and the residual debt is written off in the same call.
    function test_A12a_EveryLegIsSeizableAndTheResidueIsWrittenOff() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        _refreshFeeds();

        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.depositCollateral(address(aapl), 1); // ONE raw unit: 1e-18 AAPLc, worth 2e-13 USDC
        credit.draw(9_900e6, alice);
        vm.stopPrank();

        _setPriceBoth(50e8); // NVDAc to $50 -> the line is hopelessly insolvent
        _warpTo(MON_2026_03_02, T_OPEN + 10 minutes);
        _refreshFeeds();

        vm.prank(keeper);
        credit.flag(alice);
        _warpTo(MON_2026_03_02 + 1, T_OPEN + 40 minutes);
        _refreshFeeds();

        // The 1e-18 AAPLc crumb - the leg that used to be permanently unseizable, because
        // `balance * mark / 1e36 * BPS / bonus` floored to zero - is quotable for exactly one unit
        // of USDC. That single rounding direction is what makes the whole position finishable.
        (uint256 crumbSeized, uint256 crumbCost) = credit.quoteSeizure(alice, address(aapl), 1_000e6);
        console2.log("AAPLc crumb: seized / cost   :", crumbSeized, crumbCost);
        assertEq(crumbSeized, 1, "the crumb is seizable");
        assertEq(crumbCost, 1, "for one unit of USDC");

        // An ordinary, well-behaved cascade: a keeper repeatedly taking whatever is quotable. Not
        // one call reverts, and the NVDAc leg drains to exactly nothing.
        for (uint256 i = 0; i < 30 && credit.collateral(alice, address(nvda)) > 0; ++i) {
            uint256 max = credit.debtOf(alice) * 5_000 / 10_000;
            (, uint256 cost) = credit.quoteSeizure(alice, address(nvda), max);
            vm.prank(keeper);
            credit.liquidate(alice, address(nvda), cost);
        }
        assertEq(credit.collateral(alice, address(nvda)), 0, "the NVDAc leg clears completely");

        // And the moment the only thing left is a leg worth a fraction of a millionth of a cent,
        // the residual debt is recognised on the spot rather than compounding forever.
        assertEq(credit.debtOf(alice), 0, "the residual debt is written off, not carried");
        assertEq(credit.totalDebtAssets(), 0, "the market total no longer counts it");
        assertEq(credit.totalDebtShares(), 0, "nor do the shares");
        assertFalse(credit.isFlagged(alice), "the flag goes with the debt");

        // The crumb is now unambiguously the borrower's, and they can walk out with it.
        vm.prank(alice);
        credit.withdrawCollateral(address(aapl), 1, alice);
        assertEq(credit.assetsOf(alice).length, 0, "postedAssets reaches zero");
    }

    /// @notice The other half of the fix, for the residue a liquidator would never bother with:
    ///         `realizeBadDebt` is permissionless once the line is flagged, its grace has run out,
    ///         the market is open, every leg is priceable, and the whole basket supports less than
    ///         `1 / BAD_DEBT_DUST_DIVISOR` of its own debt. Nobody has to wait for a liquidator to
    ///         spend more gas than the crumb is worth before the loss is recognised.
    function test_A12c_ResidueTooSmallToSeizeIsWrittenOffByAnybody() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        _refreshFeeds();

        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(aapl), 1e18); // one whole AAPLc, $200
        credit.draw(120e6, alice);
        vm.stopPrank();

        // AAPLc collapses to a fraction of a cent per whole token. The basket is now worth far less
        // than a liquidator's gas, and no seizure will ever be attempted.
        aaplFeed.set(1, block.timestamp); // $1e-8 per whole token
        int24 dust = _tickForAaplPriceWad(1e10);
        aaplPool.setMeanTick(dust, TWAP_WINDOW);

        _warpTo(MON_2026_03_02, T_OPEN + 10 minutes);
        _refreshFeeds();
        aaplFeed.set(1, block.timestamp);

        vm.prank(keeper);
        credit.flag(alice);

        // Before the grace period runs out nobody may write anything off, exactly as with a seizure.
        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketCredit.GraceNotExpired.selector);
        credit.realizeBadDebt(alice);

        _warpTo(MON_2026_03_02 + 1, T_OPEN + 40 minutes);
        _refreshFeeds();
        aaplFeed.set(1, block.timestamp);

        uint256 phantom = credit.debtOf(alice);
        assertGt(phantom, 0, "there is a debt to recognise");

        vm.expectEmit(true, false, false, false);
        emit IAftermarketCredit.BadDebtRealized(alice, 0, 0);
        vm.prank(keeper);
        credit.realizeBadDebt(alice);

        assertEq(credit.debtOf(alice), 0, "the loss is recognised at once");
        assertEq(credit.totalDebtAssets(), 0, "and leaves the market total");
        assertEq(credit.collateral(alice, address(aapl)), 1e18, "the worthless residue stays the borrower's");
    }

    /// @notice A healthy-ish line is never written off: `realizeBadDebt` refuses whenever the
    ///         remaining basket is still worth seizing, which is what stops it becoming a way to
    ///         cancel a recoverable debt.
    function test_A12d_RealizeBadDebtRefusesALineThatStillHasCollateral() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        _refreshFeeds();

        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(12_900e6, alice);
        vm.stopPrank();

        _setPriceBoth(120e8); // unhealthy, but the collateral is still worth $12,000
        _warpTo(MON_2026_03_02, T_OPEN + 10 minutes);
        _refreshFeeds();
        vm.prank(keeper);
        credit.flag(alice);

        _warpTo(MON_2026_03_02 + 1, T_OPEN + 40 minutes);
        _refreshFeeds();

        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketCredit.LineNotDust.selector);
        credit.realizeBadDebt(alice);
    }

    /// @notice The consequence the finding was really about: with the write-off reachable, the
    ///         vault stops quoting a share price backed by unrecoverable debt, and the race between
    ///         suppliers disappears. Both LPs eat the same loss at the same moment.
    function test_A12b_TheLossIsSocialisedImmediatelyAndThereIsNoRaceToTheDoor() public {
        // Two equal LPs. `_deploy` already put the harness supplier in for 1,000,000.
        _fund(lp2, 1_000_000e6, 0);
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.prank(lp2);
        vault.deposit(1_000_000e6, lp2);

        test_A12a_EveryLegIsSeizableAndTheResidueIsWrittenOff();

        uint256 idle = usdc.balanceOf(address(vault));
        console2.log("real idle USDC in the vault  :", idle);
        console2.log("vault.totalAssets() claims   :", vault.totalAssets());
        assertEq(credit.debtOf(alice), 0, "no phantom debt survives the cascade");
        assertEq(vault.totalAssets(), idle, "totalAssets is exactly the money the vault holds");

        // A year later there is still nothing phantom to compound.
        _warpTo(MON_2026_03_02 + 371, T_OPEN + 5 minutes);
        _refreshFeeds();
        credit.accrue();
        assertEq(vault.totalAssets(), idle, "and nothing accrues on debt that was written off");

        // The race is gone: both suppliers redeem at the same, honest share price.
        uint256 lp2Out = _redeemAll(lp2);
        uint256 supplierOut = _redeemAll(supplier);

        console2.log("lp2 redeemed                 :", lp2Out);
        console2.log("supplier redeemed            :", supplierOut);
        assertLt(lp2Out, 1_000_000e6, "the first LP out no longer walks away with a profit");
        assertLt(supplierOut, 1_000_000e6, "and the second one no longer eats the whole shortfall");
        assertApproxEqRel(lp2Out, supplierOut, 0.001e18, "the loss falls on both of them, equally");
    }

    function _redeemAll(address who) internal returns (uint256) {
        uint256 shares = vault.maxRedeem(who);
        if (shares == 0) return 0;
        vm.prank(who);
        return vault.redeem(shares, who, who);
    }

    /*//////////////////////////////////////////////////////////////
       A-13 - FIXED: the vault accrues before it changes its liquidity
    //////////////////////////////////////////////////////////////*/

    /// @notice WAS: `_accrue` samples the rate once, at the utilisation prevailing at the moment of
    ///         the call, and applies it to the whole elapsed window. `AftermarketVault.deposit` did
    ///         not accrue first, so a single-block deposit repriced a month of interest at a
    ///         utilisation that existed for one block - deposit, call the permissionless `accrue()`,
    ///         redeem, all in one transaction, on flash-loaned capital if you like.
    ///
    ///         NOW: `deposit`, `mint`, `withdraw` and `redeem` all close the accrual window before
    ///         they move a single USDC, exactly as Morpho Blue's `supply` and `withdraw` do. The
    ///         window is always charged at the utilisation that actually prevailed during it.
    function test_A13a_ADepositCannotRepriceInterestThatHasAlreadyElapsed() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 10_000e8);
        credit.draw(900_000e6, alice); // 90% utilisation of the 1,000,000 vault
        vm.stopPrank();

        uint256 snap = vm.snapshotState();

        // --- honest path: nobody interferes -------------------------------------------------------
        _warpTo(MON_2026_03_02 + 30, T_OPEN + 5 minutes);
        _refreshFeeds();
        credit.accrue();
        uint256 honestDebt = credit.debtOf(alice);

        vm.revertToState(snap);

        // --- the attempt: deposit / accrue / redeem, in one transaction ----------------------------
        _warpTo(MON_2026_03_02 + 30, T_OPEN + 5 minutes);
        _refreshFeeds();
        _fund(alice, 3_000_000e6, 0);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(3_000_000e6, alice);
        credit.accrue();
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 gamedDebt = credit.debtOf(alice);

        console2.log("honest debt after 30d :", honestDebt);
        console2.log("after the attempt     :", gamedDebt);
        assertEq(gamedDebt, honestDebt, "a one-block deposit cannot reprice a month of interest");
        assertLe(usdc.balanceOf(alice), usdcBefore, "and the round trip is not profitable");
    }

    /// @notice The capital-free variant: backrunning somebody else's ordinary large LP deposit with
    ///         a call to the permissionless `accrue()`. The deposit itself now accrues first, so
    ///         there is nothing left behind it to reprice.
    function test_A13b_BackrunningAnLpDepositErasesNothing() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 10_000e8);
        credit.draw(900_000e6, alice);
        vm.stopPrank();

        uint256 snap = vm.snapshotState();

        _warpTo(MON_2026_03_02 + 30, T_OPEN + 5 minutes);
        _refreshFeeds();
        credit.accrue();
        uint256 honestDebt = credit.debtOf(alice);

        vm.revertToState(snap);

        _warpTo(MON_2026_03_02 + 30, T_OPEN + 5 minutes);
        _refreshFeeds();
        _fund(lp2, 3_000_000e6, 0);
        vm.prank(lp2);
        vault.deposit(3_000_000e6, lp2); // an ordinary large LP deposit
        vm.prank(alice);
        credit.accrue(); // ... backrun it, for gas

        console2.log("honest debt :", honestDebt);
        console2.log("backrun debt:", credit.debtOf(alice));
        assertEq(credit.debtOf(alice), honestDebt, "the deposit closed the window before it landed");
    }

    /// @notice `lastAccrual` used to be written before the `interest == 0` bail-out, so every second
    ///         whose interest floored to zero was destroyed - and `accrue()` is permissionless, so a
    ///         small market could be pinned at exactly zero interest forever. The clock now only
    ///         advances once the elapsed time has actually been charged for.
    function test_A13c_PerBlockAccrualNoLongerDestroysTheClock() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(500e6, alice); // a small line, where per-second interest rounds to zero
        vm.stopPrank();

        uint256 snap = vm.snapshotState();
        uint256 start = block.timestamp;

        vm.warp(start + 2000);
        credit.accrue();
        uint256 lazy = credit.debtOf(alice) - 500e6;

        vm.revertToState(snap);
        for (uint256 t = start + 2; t <= start + 2000; t += 2) {
            vm.warp(t);
            credit.accrue();
        }
        uint256 pinned = credit.debtOf(alice) - 500e6;

        console2.log("interest over 2000s, one accrue      :", lazy);
        console2.log("interest over 2000s, accrued each 2s :", pinned);
        // Not merely non-zero: exactly equal. Interest too small to be worth a whole unit of USDC is
        // carried at WAD scale in `accrualRemainder` rather than discarded, so the accrual schedule
        // cannot change what a borrower owes at all.
        assertEq(pinned, lazy, "the accrual schedule no longer changes the interest charged");
    }

    /// @notice The same sweep on a sized market. Accruing every block now charges marginally MORE
    ///         than accruing once - a thousand small compoundings against one large one - which is
    ///         the direction that costs the protocol nothing, and the gap is under two hundredths of
    ///         a basis point of the interest charged.
    function test_A13d_OnASizedMarketTheAccrualScheduleBarelyMatters() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 10_000e8);
        credit.draw(900_000e6, alice);
        vm.stopPrank();

        uint256 snap = vm.snapshotState();
        uint256 start = block.timestamp;

        vm.warp(start + 2000);
        credit.accrue();
        uint256 lazy = credit.debtOf(alice);

        vm.revertToState(snap);
        for (uint256 t = start + 2; t <= start + 2000; t += 2) {
            vm.warp(t);
            credit.accrue();
        }
        console2.log("one accrue       :", lazy);
        console2.log("accrued every 2s :", credit.debtOf(alice));
        assertGe(credit.debtOf(alice), lazy, "no interest is lost to the accrual schedule");
        assertApproxEqRel(credit.debtOf(alice), lazy, 0.000002e18, "and none is invented by it either");
    }

    /// @notice The other half of closing the window every time. If `accrue()` were allowed to leave
    ///         the clock open whenever the interest floored to zero, a market pinned at a dust total
    ///         debt would hold it open indefinitely - and the next borrower's freshly-drawn
    ///         principal would then be charged for the whole of a window in which it did not exist.
    ///         One wei of debt at the shipped floor rate holds the clock open for decades.
    function test_A13e_ADustDebtCannotBankAWindowAgainstTheNextBorrower() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);

        // A one-wei line, opened and then left alone. Its own interest floors to zero forever.
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 1e8);
        credit.draw(1, alice);
        vm.stopPrank();

        _warpTo(MON_2026_03_02 + 371, T_OPEN + 5 minutes);
        _refreshFeeds();

        // A year later somebody draws properly. Their principal must not be charged for that year.
        _fund(lp2, 0, 10_000e8);
        vm.startPrank(lp2);
        credit.openLine();
        credit.depositCollateral(address(nvda), 10_000e8);
        credit.draw(500_000e6, lp2);
        vm.stopPrank();

        assertEq(credit.debtOf(lp2), 500_000e6, "a fresh draw owes exactly what it drew");
        credit.accrue();
        assertEq(credit.debtOf(lp2), 500_000e6, "and still does after the market is brought current");
    }

    /*//////////////////////////////////////////////////////////////
       A-14 - FIXED: the checkpoint is a high-water mark, never reset down
    //////////////////////////////////////////////////////////////*/

    /// @notice WAS: `_rollMultiplierCheckpoint` reset the checkpoint to the CURRENT multiplier
    ///         whenever `m <= m0`, so a round trip down and back up - a reverse split followed by
    ///         the ordinary re-rating - fabricated a distribution out of a net-zero corporate
    ///         action, and one 1-wei deposit at the trough was enough to arm it.
    ///
    ///         NOW: the checkpoint is a high-water mark of value already accounted for. It never
    ///         moves down on an existing position, so a multiplier merely returning to where it
    ///         started is not a dividend and there is nothing to sweep.
    function test_A14a_ANetZeroRoundTripFabricatesNothing() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(5_000e6, alice);
        credit.setAutoRepay(true);
        vm.stopPrank();
        assertEq(credit.multiplierCheckpoint(alice, address(nvda)), 1e18, "checkpoint at 1.0");

        // Reverse split 1:2. Nothing was distributed.
        nvda.setMultiplier(0.5e18);
        vm.prank(alice);
        credit.depositCollateral(address(nvda), 1); // one raw unit, at the trough
        assertEq(credit.multiplierCheckpoint(alice, address(nvda)), 1e18, "the checkpoint does not follow it down");

        // The action is unwound / the multiplier returns to 1.0. Still no distribution, ever.
        nvda.setMultiplier(1e18);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NothingToSweep.selector, alice, address(nvda)));
        credit.sweepYield(alice, address(nvda));
        assertEq(credit.collateral(alice, address(nvda)), 100e8 + 1, "not a unit of the position was sold");
    }

    /// @notice ACCEPTED LIMITATION, recorded rather than fixed. The mirror of A-14a: after a genuine
    ///         reverse split the checkpoint stays above the live multiplier, so a real distribution
    ///         declared afterwards can never be swept. The contract cannot tell a reverse split from
    ///         a fall in the multiplier, and the two demand opposite treatment - re-baselining on the
    ///         way down is exactly the hole A-14a closed. The cost is a bricked convenience feature
    ///         for one asset until the position is closed and reopened; the alternative is a
    ///         fabricated sale of half the position, which is a loss. `sweepYield` is opt-in and
    ///         nothing else depends on it.
    function test_A14b_AfterAReverseSplitDividendsStayUnsweepable_Accepted() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(5_000e6, alice);
        credit.setAutoRepay(true);
        vm.stopPrank();

        nvda.setMultiplier(0.5e18); // 1:2 reverse split
        nvda.setMultiplier(0.55e18); // a real 10% distribution afterwards

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NothingToSweep.selector, alice, address(nvda)));
        credit.sweepYield(alice, address(nvda));
        console2.log("checkpoint :", credit.multiplierCheckpoint(alice, address(nvda)));
        console2.log("live       :", nvda.multiplier());

        // The borrower is not harmed beyond the lost convenience: everything else still works.
        vm.prank(alice);
        credit.repay(type(uint256).max);
        vm.prank(alice);
        credit.withdrawCollateral(address(nvda), 100e8, alice);
        assertEq(credit.collateral(alice, address(nvda)), 0, "the position is not trapped by it");
    }

    /// @notice WAS: `_multiplierOf` swallowed a reverting `multiplier()` and returned WAD, and
    ///         `depositCollateral` reads no oracle, so one deposit during a transient B20 outage
    ///         rewrote a checkpoint of 2.0 down to 1.0 and armed a sweep of half the position.
    ///
    ///         NOW: a failed read and a multiplier of 1.0 are different facts. The read reports
    ///         failure and the checkpoint is not touched at all.
    function test_A14c_ATransientMultiplierOutageArmsNothing() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        nvda.setMultiplier(2e18);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(5_000e6, alice);
        credit.setAutoRepay(true);
        vm.stopPrank();
        assertEq(credit.multiplierCheckpoint(alice, address(nvda)), 2e18, "checkpoint at 2.0");

        // The B20 token stops answering `multiplier()` for one transaction.
        vm.mockCallRevert(address(nvda), abi.encodeWithSignature("multiplier()"), "outage");
        vm.prank(alice);
        credit.depositCollateral(address(nvda), 1);
        vm.clearMockedCalls();

        assertEq(credit.multiplierCheckpoint(alice, address(nvda)), 2e18, "the checkpoint survived the outage");
        assertEq(nvda.multiplier(), 2e18, "and the real multiplier never moved");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NothingToSweep.selector, alice, address(nvda)));
        credit.sweepYield(alice, address(nvda));
    }

    /*//////////////////////////////////////////////////////////////
       A-15 - FIXED: a withdrawal that leaves the line healthy cures it
    //////////////////////////////////////////////////////////////*/

    /// @notice WAS: `draw` refuses a flagged line but `withdrawCollateral` did not, so a borrower
    ///         whose line had recovered could pull collateral out while still carrying an
    ///         ALREADY-EXPIRED `graceUntil`, and the very next adverse tick was seizable with zero
    ///         notice. The grace guarantee was per flag, not per unhealthy episode.
    ///
    ///         NOW: surviving the post-withdrawal borrowing-power check is exactly what `cure`
    ///         demands, so the withdrawal clears the flag. The next unhealthy moment needs a fresh
    ///         flag and therefore a fresh, full grace period.
    function test_A15_WithdrawingWhileFlaggedClearsTheStaleGraceClock() public {
        _warpTo(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.draw(9_900e6, alice);
        vm.stopPrank();

        _setPriceBoth(120e8); // open threshold 0.80 * 100 * 120 = $9,600 < $9,900 debt
        _warpTo(MON_2026_03_02, T_OPEN + 10 minutes);
        vm.prank(keeper);
        credit.flag(alice);
        uint64 staleGrace = credit.graceUntil(alice);

        // The price recovers hard. The line is healthy again - but nobody cures it.
        _warpTo(MON_2026_03_02 + 1, T_OPEN + 40 minutes);
        _setPriceBoth(300e8);
        assertGt(block.timestamp, staleGrace, "the original grace has already expired");
        assertTrue(credit.isFlagged(alice), "and the flag is still standing");

        // The borrower withdraws down to their advance rate. That IS a cure, and is treated as one.
        vm.prank(alice);
        credit.withdrawCollateral(address(nvda), 30e8, alice);
        assertFalse(credit.isFlagged(alice), "the withdrawal cleared the flag");
        assertEq(credit.graceUntil(alice), 0, "and the expired clock with it");

        // One adverse tick later there is no flag to seize against.
        _setPriceBoth(150e8);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NotFlagged.selector, alice));
        credit.liquidate(alice, address(nvda), 1_000e6);

        // A keeper has to raise a fresh flag, which buys the borrower a fresh, full grace period.
        vm.prank(keeper);
        credit.flag(alice);
        assertGt(uint256(credit.graceUntil(alice)), block.timestamp, "notice starts again from scratch");
        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketCredit.GraceNotExpired.selector);
        credit.liquidate(alice, address(nvda), 1_000e6);
    }

    /// @dev The AAPLc pool tick for a target WAD price, driving the real AAPLc oracle decoder.
    function _tickForAaplPriceWad(uint256 targetWad) internal returns (int24) {
        AftermarketOracle savedOracle = oracle;
        MockCLPool savedPool = pool;
        int24 savedTick = _currentTick;
        oracle = aaplOracle;
        pool = aaplPool;
        int24 t = _tickForPriceWad(targetWad);
        oracle = savedOracle;
        pool = savedPool;
        _currentTick = savedTick;
        return t;
    }
}
