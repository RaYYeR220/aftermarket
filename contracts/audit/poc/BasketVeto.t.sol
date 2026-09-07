// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {AuditHarness} from "./Harness.sol";
import {AftermarketOracle} from "../../src/AftermarketOracle.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketOracle} from "../../src/interfaces/IAftermarketOracle.sol";
import {Session, Verdict} from "../../src/libraries/Types.sol";

import {MockAggregatorV3} from "../../test/mocks/MockAggregatorV3.sol";
import {MockCLPool} from "../../test/mocks/MockCLPool.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

/// @title  A-02 - FIXED: an unpriceable asset no longer vetoes the whole basket
/// @notice `AftermarketCredit._borrowPower` and `_seizureRisk` walk the borrower's posted-asset
///         list. They used to call `oracle.markBorrow()` / `oracle.markLiquidate()` for every entry
///         with a non-zero balance - including a balance of ONE RAW UNIT - and let the revert
///         propagate, so the health of an eight-asset basket was a logical AND over eight
///         independent oracles and the weakest one won. A single wei of a collateral asset whose
///         oracle was untrusted made the entire line unflaggable and unliquidatable, no matter how
///         healthy the other oracles were or how deeply underwater the line was.
///
///         An asset that cannot be priced now contributes NOTHING to either side of the
///         calculation, and the asset itself stays unseizable. This file asserts both halves,
///         against both of the triggers the original finding demonstrated.
///
/// @dev The semantics, and why this shape and not another.
///
///      Crediting an unpriceable asset let it do two jobs at once: support the debt that made a
///      seizure necessary, and then block the seizure. Valuing it at zero on the borrowing side is
///      plainly conservative. Valuing it at zero on the SEIZURE side is not conservative on its own
///      - it lowers the threshold, so on its own it would make deflating one leg a way to
///      force-liquidate a healthy line, which is strictly worse than the veto it replaces.
///
///      What makes it safe is the asymmetry, not the valuation: `_quoteSeizure` still reads
///      `markLiquidate` directly and still reverts, so the unpriceable asset can never be taken by
///      anybody at any price. A borrower whose basket goes partly dark is therefore exposed to
///      losing PRICEABLE collateral at a DEFENSIBLE price, behind the full flag-and-grace notice
///      period, with `repay`, `depositCollateral` and `cure` all still open to them - never to
///      losing the dark leg itself. Against that: the veto it replaces was an unbounded, silent,
///      unrecoverable loss for every supplier in the vault, arranged for the cost of one wei.
///
///      One guard remains on top of it. A basket in which NOTHING can be priced also yields a
///      threshold of zero, but for the vacuous reason that nothing was counted, so `flag` and
///      `liquidate` reject that case outright rather than turning a total oracle outage into
///      universal insolvency. `test_04` pins it.
///
///      Two independent triggers are exercised, one adversarial and one not:
///
///      (a) `UNTRUSTED_DIVERGENT` - the borrower pushes the dust asset Aerodrome TWAP more than
///          200 bps (the REGULAR divergence band) away from its Chainlink anchor. They can pick the
///          shallowest listed pool in the whole protocol to do it in, because they only hold one wei
///          of it and do not care what it is worth.
///
///      (b) `UNTRUSTED_HALTED` - the B20 issuer pauses transfers on the dust asset, e.g. around a
///          corporate action. Nobody attacked anything; the veto used to apply anyway.
contract BasketVetoTest is AuditHarness {
    int256 internal constant PRICE_200 = 200e8;

    MockERC20 internal tsla;
    MockAggregatorV3 internal tslaFeed;
    MockCLPool internal tslaPool;
    AftermarketOracle internal tslaOracle;

    /// @dev The tick the poison pool sits at while it agrees with its anchor.
    int24 internal tslaHonestTick;

    function setUp() public {
        _deploy(PRICE_200);
        _listPoisonAsset();
    }

    /// @dev Lists a second B20 equity with its own oracle, feed and Slipstream pool. Everything is a
    ///      real `AftermarketOracle` on the deployment-default parameters - nothing is stubbed.
    function _listPoisonAsset() internal {
        tsla = new MockERC20("Coinbase TSLA", "TSLAc", 8);
        tslaFeed = new MockAggregatorV3(8, 400e8, block.timestamp);
        tslaPool = new MockCLPool(address(usdc), address(tsla), 10);
        // A THIN pool - $30k, barely over the $25k corroboration floor. This is the pool an attacker
        // picks, and on Base today the shallowest live B20 pool is about $61k.
        usdc.mint(address(tslaPool), 30_000e6);

        // Swap the harness feed/pool pointers so `_oracleConfig` and `_tickForPriceWad` build the
        // second oracle, then swap them back.
        MockAggregatorV3 savedFeed = feed;
        MockCLPool savedPool = pool;
        AftermarketOracle savedOracle = oracle;
        int24 savedTick = _currentTick;

        feed = tslaFeed;
        pool = tslaPool;
        pool.setMeanTick(0, TWAP_WINDOW);
        _currentTick = 0;
        tslaOracle = new AftermarketOracle(_oracleConfig(address(tsla), address(usdc), address(tslaPool)));
        oracle = tslaOracle;
        tslaHonestTick = _tickForPriceWad(400e18);
        tslaPool.setMeanTick(tslaHonestTick, TWAP_WINDOW);
        _currentTick = tslaHonestTick;

        feed = savedFeed;
        pool = savedPool;
        oracle = savedOracle;
        _currentTick = savedTick;

        vm.prank(owner);
        credit.setAsset(
            address(tsla),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(tslaOracle)),
                advanceOpenBps: ADVANCE_OPEN_BPS,
                advanceClosedBps: ADVANCE_CLOSED_BPS,
                liqThresholdOpenBps: LIQ_THRESHOLD_OPEN_BPS,
                liqThresholdClosedBps: LIQ_THRESHOLD_CLOSED_BPS,
                liqBonusBps: LIQ_BONUS_BPS,
                cap: uint128(1_000_000e8),
                enabled: true
            })
        );

        tsla.mint(alice, 1e8);
        vm.prank(alice);
        tsla.approve(address(credit), type(uint256).max);
    }

    /// @dev Opens a line, posts 100 NVDAc plus ONE RAW UNIT of TSLAc, draws, then crashes NVDAc so the
    ///      line is unambiguously seizable at both open AND closed parameters.
    function _openDeeplyUnderwaterLineWithDust() internal {
        _warpBoth(MON_2026_03_02, T_OPEN + 5 minutes);
        vm.startPrank(alice);
        credit.openLine();
        credit.depositCollateral(address(nvda), 100e8);
        credit.depositCollateral(address(tsla), 1); // one raw unit == 1e-8 TSLAc == $0.000004
        credit.draw(9_900e6, alice);
        vm.stopPrank();

        // NVDAc collapses to $100. Open threshold = 100 * 100 * 0.70 = $7,000; closed threshold at the
        // maximum 500bps haircut = 100 * 105 * 0.80 = $8,400. Both far under the $9,900 debt.
        _setPriceBoth(100e8);
        _warpBoth(MON_2026_03_02, T_OPEN + 30 minutes);
    }

    /// @notice Control: with both oracles honest, the line flags and liquidates exactly as designed.
    function test_00_Control_LineIsFlaggableAndLiquidatable() public {
        _openDeeplyUnderwaterLineWithDust();

        (uint256 power, uint256 threshold) = credit.riskOf(alice);
        console2.log("power     :", power);
        console2.log("threshold :", threshold);
        console2.log("debt      :", credit.debtOf(alice));
        assertLt(threshold, credit.debtOf(alice), "line is seizable");

        vm.prank(keeper);
        credit.flag(alice);

        _warpBoth(MON_2026_03_02 + 1, T_OPEN + 40 minutes);
        vm.prank(keeper);
        (uint256 seized,) = credit.liquidate(alice, address(nvda), 1_000e6);
        assertGt(seized, 0, "control liquidation succeeds");
    }

    /// @notice THE FIX (a). One wei of a second asset, whose thin pool has been pushed 3% off its
    ///         anchor, no longer makes the line untouchable. The NVDAc leg alone still justifies the
    ///         seizure, so the seizure happens - and the TSLAc wei stays where it is.
    function test_01_DustAssetDivergence_NoLongerVetoesTheSeizure() public {
        _openDeeplyUnderwaterLineWithDust();

        // Flag first, so the grace clock is already running and the ONLY thing standing between the
        // keeper and the collateral is the oracle.
        vm.prank(keeper);
        credit.flag(alice);
        _warpBoth(MON_2026_03_02 + 1, T_OPEN + 40 minutes);

        // The borrower moves the TSLAc pool's 30-minute TWAP ~3% off its Chainlink anchor. The
        // REGULAR divergence band is 200 bps, so the TSLAc oracle refuses to mark.
        int24 poisonTick = _tickForTslaPriceWad(412e18); // +3.0%
        tslaPool.setMeanTick(poisonTick, TWAP_WINDOW);

        assertEq(uint256(tslaOracle.peek().verdict), uint256(Verdict.UNTRUSTED_DIVERGENT), "poison oracle is divergent");
        console2.log("TSLAc divergenceBps :", tslaOracle.peek().divergenceBps);
        console2.log("TSLAc band          :", tslaOracle.peek().divergenceBand);

        // The NVDAc oracle is untouched and perfectly healthy.
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.TRUSTED), "NVDAc oracle still trusted");

        // The public views still refuse a partially-priced basket, so `positionOf().priced` keeps
        // meaning what a keeper and a UI think it means.
        IAftermarketCredit.Position memory p = credit.positionOf(alice);
        assertFalse(p.priced, "positionOf still reports the basket as unpriced");
        vm.expectPartialRevert(IAftermarketCredit.UnpricedCollateral.selector);
        credit.seizureThreshold(alice);

        // The seizure the priceable collateral already justifies goes ahead.
        uint256 debtBefore = credit.debtOf(alice);
        vm.prank(keeper);
        (uint256 seized, uint256 repaid) = credit.liquidate(alice, address(nvda), 1_000e6);
        console2.log("seized NVDAc        :", seized);
        console2.log("repaid USDC         :", repaid);
        assertGt(seized, 0, "the dust asset no longer vetoes a seizure the good collateral justifies");
        assertEq(debtBefore - credit.debtOf(alice), repaid, "and the debt actually falls");

        // The unpriceable asset itself is still untouchable, which is the half that keeps this safe.
        vm.expectPartialRevert(IAftermarketOracle.SourcesDiverged.selector);
        credit.quoteSeizure(alice, address(tsla), 1_000e6);
        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketOracle.SourcesDiverged.selector);
        credit.liquidate(alice, address(tsla), 1_000e6);
        assertEq(credit.collateral(alice, address(tsla)), 1, "nobody may be paid in a price we cannot defend");
    }

    /// @notice THE FIX (b). No attacker at all: the B20 issuer pauses transfers on the dust asset,
    ///         which is what happens around a corporate action. The line is flaggable and seizable
    ///         on its priceable collateral throughout.
    function test_02_DustAssetIssuerPause_NoLongerVetoesTheFlag() public {
        _openDeeplyUnderwaterLineWithDust();

        // `AftermarketOracle._readMultiplier` staticcalls `isPaused(PausableFeature.TRANSFER)` on
        // the collateral token. A true answer is an unconditional UNTRUSTED_HALTED.
        vm.mockCall(address(tsla), abi.encodeWithSignature("isPaused(uint8)", uint8(0)), abi.encode(true));
        assertEq(uint256(tslaOracle.peek().verdict), uint256(Verdict.UNTRUSTED_HALTED), "poison oracle is halted");

        vm.prank(keeper);
        credit.flag(alice);
        assertTrue(credit.isFlagged(alice), "a $0.000004 halted position no longer blocks the flag");

        _warpBoth(MON_2026_03_02 + 1, T_OPEN + 40 minutes);
        vm.prank(keeper);
        (uint256 seized,) = credit.liquidate(alice, address(nvda), 1_000e6);
        assertGt(seized, 0, "nor the seizure");

        // And the halted asset is still not distributable, pause or no pause.
        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketOracle.MarketHalted.selector);
        credit.liquidate(alice, address(tsla), 1_000e6);
    }

    /// @notice The guard that keeps the fix from over-reaching. When NOTHING in the basket can be
    ///         priced the threshold is zero for the vacuous reason that nothing was counted, so the
    ///         flag path refuses rather than declaring every borrower insolvent at once.
    function test_04_ATotalOutageIsStillNotInsolvency() public {
        _openDeeplyUnderwaterLineWithDust();

        vm.mockCall(address(tsla), abi.encodeWithSignature("isPaused(uint8)", uint8(0)), abi.encode(true));
        vm.mockCall(address(nvda), abi.encodeWithSignature("isPaused(uint8)", uint8(0)), abi.encode(true));
        assertEq(uint256(oracle.peek().verdict), uint256(Verdict.UNTRUSTED_HALTED), "NVDAc halted too");

        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketCredit.UnpricedCollateral.selector);
        credit.flag(alice);
    }

    /// @notice The good news, and it is worth stating in the report: the veto does NOT trap the
    ///         borrower. `repay` reads no oracle, and `withdrawCollateral` reads one only while debt
    ///         remains, so the exit path survives a total oracle outage exactly as documented.
    function test_03_ThePartialOutageDoesNotTrapTheBorrower() public {
        _openDeeplyUnderwaterLineWithDust();
        vm.mockCall(address(tsla), abi.encodeWithSignature("isPaused(uint8)", uint8(0)), abi.encode(true));

        // Repay in full with no oracle available anywhere.
        vm.prank(alice);
        credit.repay(type(uint256).max);
        assertEq(credit.debtOf(alice), 0, "repaid to zero through the outage");

        // And walk out with the collateral.
        vm.startPrank(alice);
        credit.withdrawCollateral(address(nvda), 100e8, alice);
        credit.withdrawCollateral(address(tsla), 1, alice);
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 10_000e8, "collateral returned in full");
    }

    /// @dev Warps and refreshes BOTH Chainlink feeds, since both equities trade the same session.
    function _warpBoth(uint256 dayNumber, uint256 secondOfDay) internal {
        _warpTo(dayNumber, secondOfDay);
        if (calendar.isOpen(block.timestamp)) tslaFeed.set(400e8, block.timestamp);
    }

    /// @dev The poison pool tick for a target WAD price, driving the real TSLAc oracle decoder.
    function _tickForTslaPriceWad(uint256 targetWad) internal returns (int24) {
        AftermarketOracle savedOracle = oracle;
        MockCLPool savedPool = pool;
        int24 savedTick = _currentTick;
        oracle = tslaOracle;
        pool = tslaPool;
        _currentTick = tslaHonestTick;
        int24 t = _tickForPriceWad(targetWad);
        oracle = savedOracle;
        pool = savedPool;
        _currentTick = savedTick;
        return t;
    }
}
