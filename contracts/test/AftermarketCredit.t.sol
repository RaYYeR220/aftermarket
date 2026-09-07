// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AftermarketCredit} from "../src/AftermarketCredit.sol";
import {AftermarketVault} from "../src/AftermarketVault.sol";
import {SessionRateModel, ISessionRateModel} from "../src/SessionRateModel.sol";
import {IAftermarketCredit} from "../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketOracle} from "../src/interfaces/IAftermarketOracle.sol";
import {IEligibility} from "../src/interfaces/IEligibility.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {ITradingCalendar} from "../src/interfaces/ITradingCalendar.sol";
import {Session} from "../src/libraries/Types.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockEligibility} from "./mocks/MockEligibility.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockSwapAdapter} from "./mocks/MockSwapAdapter.sol";

/// @notice A calendar the tests can put into any session at any moment.
/// @dev Named `StubCalendar` rather than `MockCalendar` so it cannot collide with the calendar
///      team's own fixtures. It is deliberately dumb: the credit engine's behaviour must depend only
///      on what the calendar says, never on how the calendar worked it out.
contract StubCalendar is ITradingCalendar {
    Session internal current = Session.REGULAR;
    uint64 internal nextOpenTs;
    uint64 internal lastCloseTs;

    function setSession(Session session_) external {
        current = session_;
    }

    function setNextOpen(uint64 nextOpen_) external {
        nextOpenTs = nextOpen_;
    }

    function setLastClose(uint64 lastClose_) external {
        lastCloseTs = lastClose_;
    }

    function sessionAt(uint256) external view returns (Session, uint64, uint64) {
        return (current, nextOpenTs, lastCloseTs);
    }

    function session() external view returns (Session) {
        return current;
    }

    function isOpen(uint256) external view returns (bool) {
        return current == Session.REGULAR;
    }

    function closedFor(uint256) external view returns (uint256) {
        return current == Session.REGULAR ? 0 : 6 hours;
    }

    function nextOpen(uint256) external view returns (uint64) {
        return nextOpenTs;
    }
}

/// @notice Shared fixture: a funded vault, two collateral assets with different decimals, and a
///         calendar and oracle the test can drive anywhere.
abstract contract AftermarketFixture is Test {
    // Marks are Morpho-scaled: `collateralRaw * mark / 1e36 == loanRaw`.
    // NVDAc has 8 decimals and USDC has 6, so $180 per whole token is 180e6 * 1e36 / 1e8.
    uint256 internal constant NVDA_MARK_180 = 1.8e36;
    // AAPLc has 18 decimals, so $200 per whole token is 200e6 * 1e36 / 1e18.
    uint256 internal constant AAPL_MARK_200 = 2e26;

    uint256 internal constant START_TIME = 1_800_000_000;

    MockERC20 internal usdc;
    MockERC20 internal nvda;
    MockERC20 internal aapl;

    StubCalendar internal calendar;
    MockEligibility internal eligibility;
    MockOracle internal nvdaOracle;
    MockOracle internal aaplOracle;
    MockSwapAdapter internal adapter;
    SessionRateModel internal rateModel;

    AftermarketCredit internal credit;
    AftermarketVault internal vault;

    address internal owner = makeAddr("owner");
    address internal supplier = makeAddr("supplier");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function _deployProtocol() internal {
        vm.warp(START_TIME);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvda = new MockERC20("Coinbase NVDA", "NVDAc", 8);
        aapl = new MockERC20("Coinbase AAPL", "AAPLc", 18);

        calendar = new StubCalendar();
        // casting to 'uint64' is safe because START_TIME is a fixed 2027 timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        calendar.setNextOpen(uint64(START_TIME + 1 days));

        eligibility = new MockEligibility();
        nvdaOracle = new MockOracle(NVDA_MARK_180, NVDA_MARK_180);
        nvdaOracle.setTokens(address(nvda), address(usdc));
        aaplOracle = new MockOracle(AAPL_MARK_200, AAPL_MARK_200);
        aaplOracle.setTokens(address(aapl), address(usdc));
        adapter = new MockSwapAdapter();

        uint256[6] memory multipliers =
            [uint256(1e18), uint256(1e18), uint256(1e18), uint256(1.25e18), uint256(1.5e18), uint256(1.6e18)];
        rateModel = new SessionRateModel(
            ITradingCalendar(address(calendar)),
            634_195_839, // 2% APR floor
            1_902_587_519, // +6% APR at the kink
            31_709_791_983, // +100% APR at full utilisation
            0.8e18,
            multipliers
        );

        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        credit = new AftermarketCredit(
            IERC20(address(usdc)),
            predictedVault,
            ITradingCalendar(address(calendar)),
            IEligibility(address(eligibility)),
            ISessionRateModel(address(rateModel)),
            ISwapAdapter(address(adapter)),
            100, // 1% slippage budget for sweepYield
            owner
        );
        vault = new AftermarketVault(IERC20(address(usdc)), address(credit), "Aftermarket USDC", "amUSDC");
        require(address(vault) == predictedVault, "vault prediction");

        vm.startPrank(owner);
        credit.setAsset(
            address(nvda),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(nvdaOracle)),
                advanceOpenBps: 5_000,
                advanceClosedBps: 3_500,
                liqThresholdOpenBps: 7_000,
                liqThresholdClosedBps: 8_000,
                liqBonusBps: 800,
                cap: uint128(1_000_000e8),
                enabled: true
            })
        );
        credit.setAsset(
            address(aapl),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(aaplOracle)),
                advanceOpenBps: 6_000,
                advanceClosedBps: 4_000,
                liqThresholdOpenBps: 7_500,
                liqThresholdClosedBps: 8_500,
                liqBonusBps: 500,
                cap: uint128(1_000_000e18),
                enabled: true
            })
        );
        vm.stopPrank();

        // The adapter prices NVDAc into USDC at the same $180 the oracle marks it at.
        adapter.setRate(180e6, 1e8);
        usdc.mint(address(adapter), 10_000_000e6);

        _fund(supplier, 5_000_000e6, 0, 0);
        _fund(alice, 1_000_000e6, 10_000e8, 10_000e18);
        _fund(bob, 1_000_000e6, 10_000e8, 10_000e18);
        _fund(keeper, 1_000_000e6, 0, 0);

        vm.prank(supplier);
        vault.deposit(1_000_000e6, supplier);
    }

    function _fund(address who, uint256 usdcAmount, uint256 nvdaAmount, uint256 aaplAmount) internal {
        if (usdcAmount != 0) usdc.mint(who, usdcAmount);
        if (nvdaAmount != 0) nvda.mint(who, nvdaAmount);
        if (aaplAmount != 0) aapl.mint(who, aaplAmount);

        vm.startPrank(who);
        usdc.approve(address(credit), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        nvda.approve(address(credit), type(uint256).max);
        aapl.approve(address(credit), type(uint256).max);
        vm.stopPrank();
    }

    function _posted(address asset) internal view returns (uint128 posted) {
        (,,,,,,, posted,) = credit.assetConfig(asset);
    }

    function _openAndDeposit(address who, address asset, uint256 amount) internal {
        vm.startPrank(who);
        credit.openLine();
        credit.depositCollateral(asset, amount);
        vm.stopPrank();
    }
}

contract AftermarketCreditTest is AftermarketFixture {
    function setUp() public {
        _deployProtocol();
    }

    /*//////////////////////////////////////////////////////////////
                               HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_happyPath_openDepositDrawAccrueRepayWithdraw() public {
        _openAndDeposit(alice, address(nvda), 100e8);

        assertEq(credit.collateral(alice, address(nvda)), 100e8);
        assertEq(_posted(address(nvda)), 100e8);
        assertEq(nvda.balanceOf(address(credit)), 100e8);
        assertEq(credit.multiplierCheckpoint(alice, address(nvda)), 1e18);

        // 100 NVDAc at $180 is $18,000; the open-session advance is 50%.
        assertEq(credit.borrowPower(alice), 9_000e6);
        assertEq(credit.seizureThreshold(alice), 12_600e6);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        credit.draw(5_000e6, alice);

        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 5_000e6);
        assertEq(vault.idleAssets(), 995_000e6);
        assertEq(credit.totalDebtAssets(), 5_000e6);
        assertEq(credit.debtOf(alice), 5_000e6);
        assertEq(vault.totalAssets(), 1_000_000e6, "lending moves no value on its own");

        vm.warp(block.timestamp + 30 days);
        credit.accrue();

        uint256 debt = credit.debtOf(alice);
        assertGt(debt, 5_000e6, "interest accrued");
        assertLt(debt, 5_100e6, "and it is a sane amount for a month at low utilisation");
        assertEq(vault.totalAssets(), 995_000e6 + credit.totalDebtAssets());

        vm.prank(alice);
        (uint256 repaidAssets,) = credit.repay(type(uint256).max);

        assertEq(repaidAssets, debt, "max repay clears the line exactly");
        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.totalDebtAssets(), 0);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 5_000e6 - debt);
        assertEq(vault.idleAssets(), 995_000e6 + debt);

        vm.prank(alice);
        credit.withdrawCollateral(address(nvda), 100e8, alice);

        assertEq(nvda.balanceOf(alice), 10_000e8);
        assertEq(credit.collateral(alice, address(nvda)), 0);
        assertEq(_posted(address(nvda)), 0);
        assertEq(credit.assetsOf(alice).length, 0);
    }

    function test_multiAsset_borrowPowerSumsAcrossDecimalsAndAdvances() public {
        _openAndDeposit(alice, address(nvda), 100e8);
        vm.prank(alice);
        credit.depositCollateral(address(aapl), 50e18);

        // 100 NVDAc * $180 * 50%  = $9,000
        //  50 AAPLc * $200 * 60%  = $6,000
        assertEq(credit.borrowPower(alice), 15_000e6);
        // 100 NVDAc * $180 * 70%  = $12,600
        //  50 AAPLc * $200 * 75%  = $7,500
        assertEq(credit.seizureThreshold(alice), 20_100e6);
        assertEq(credit.assetsOf(alice).length, 2);

        vm.prank(alice);
        credit.draw(15_000e6, alice);

        vm.prank(alice);
        vm.expectRevert();
        credit.draw(1e6, alice);
    }

    function test_maxAssets_isBounded() public {
        MockERC20[] memory extra = new MockERC20[](7);
        MockOracle[] memory extraOracles = new MockOracle[](7);
        vm.startPrank(alice);
        credit.openLine();
        vm.stopPrank();

        for (uint256 i; i < 7; ++i) {
            extra[i] = new MockERC20("Extra", "EXT", 8);
            extra[i].mint(alice, 1e8);
            MockOracle extraOracle = new MockOracle(NVDA_MARK_180, NVDA_MARK_180);
            extraOracle.setTokens(address(extra[i]), address(usdc));
            extraOracles[i] = extraOracle;
            vm.prank(owner);
            credit.setAsset(
                address(extra[i]),
                IAftermarketCredit.AssetParams({
                    oracle: IAftermarketOracle(address(extraOracle)),
                    advanceOpenBps: 5_000,
                    advanceClosedBps: 3_500,
                    liqThresholdOpenBps: 7_000,
                    liqThresholdClosedBps: 8_000,
                    liqBonusBps: 800,
                    cap: type(uint128).max,
                    enabled: true
                })
            );
            vm.startPrank(alice);
            extra[i].approve(address(credit), type(uint256).max);
            credit.depositCollateral(address(extra[i]), 1e8);
            vm.stopPrank();
        }

        vm.prank(alice);
        credit.depositCollateral(address(nvda), 1e8);
        assertEq(credit.assetsOf(alice).length, 8);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.TooManyAssets.selector, 8));
        credit.depositCollateral(address(aapl), 1e18);

        // `MAX_ASSETS` is sized to keep a seizure inside a block, and the bad-debt check added a
        // second walk of the basket to `liquidate`. Measure it at the cap rather than assume it.
        vm.prank(alice);
        credit.draw(700e6, alice); // the full advance rate across all eight legs
        for (uint256 i; i < 7; ++i) {
            extraOracles[i].setMarks(0.9e36, 0.9e36);
        }
        nvdaOracle.setMarks(0.9e36, 0.9e36);

        vm.prank(keeper);
        credit.flag(alice);
        vm.warp(credit.graceUntil(alice) + 1);
        calendar.setSession(Session.REGULAR);

        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        credit.liquidate(alice, address(nvda), 100e6);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("liquidate gas, 8-asset basket", used);
        assertLt(used, 3_000_000, "a seizure on a maxed basket must stay far inside a block");
    }

    /*//////////////////////////////////////////////////////////////
                          THE ORACLE-OUTAGE MATRIX
    //////////////////////////////////////////////////////////////*/
    //
    // The single most important behaviour in the repository. With both marks reverting, every
    // risk-increasing and every seizure path must be frozen, while every path a borrower needs to
    // rescue themselves must stay open.

    function _positionWithDebt(address who, uint256 collateralAmount, uint256 drawAmount) internal {
        _openAndDeposit(who, address(nvda), collateralAmount);
        vm.prank(who);
        credit.draw(drawAmount, who);
    }

    function test_oracleOutage_drawIsFrozen() public {
        _positionWithDebt(alice, 100e8, 2_000e6);
        nvdaOracle.setReverting(true, true);

        // Unpriceable collateral carries no borrowing power, so there is nothing to draw against.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.Undercollateralized.selector, 2_001e6, 0));
        credit.draw(1e6, alice);
    }

    /// @dev A basket in which NOTHING can be priced yields a seizure threshold of zero for the
    ///      vacuous reason that nothing was counted. Acting on it would turn an oracle outage into
    ///      universal insolvency, so the flag path rejects it outright rather than starting a grace
    ///      clock against every borrower at once.
    function test_oracleOutage_flagIsFrozen() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        nvdaOracle.setMarks(NVDA_MARK_180 / 10, NVDA_MARK_180 / 10);
        nvdaOracle.setReverting(true, true);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.UnpricedCollateral.selector, 1));
        credit.flag(alice);
    }

    function test_oracleOutage_liquidateIsFrozen() public {
        _positionWithDebt(alice, 100e8, 8_000e6);

        // The line goes underwater and is flagged while the oracle still works.
        nvdaOracle.setMarks(NVDA_MARK_180 / 10, NVDA_MARK_180 / 10);
        vm.prank(keeper);
        credit.flag(alice);

        vm.warp(credit.graceUntil(alice) + 1);
        calendar.setSession(Session.REGULAR);

        // Then the oracle loses confidence. Seizure must stop dead.
        nvdaOracle.setReverting(true, true);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.UnpricedCollateral.selector, 1));
        credit.liquidate(alice, address(nvda), 100e6);
    }

    function test_oracleOutage_repayStillWorks() public {
        _positionWithDebt(alice, 100e8, 2_000e6);
        nvdaOracle.setReverting(true, true);

        vm.prank(alice);
        credit.repay(1_000e6);
        assertApproxEqAbs(credit.debtOf(alice), 1_000e6, 1);

        vm.prank(bob);
        credit.repayOnBehalf(alice, type(uint256).max);
        assertEq(credit.debtOf(alice), 0, "anyone can rescue a line during an outage");
    }

    function test_oracleOutage_depositStillWorks() public {
        _positionWithDebt(alice, 100e8, 2_000e6);
        nvdaOracle.setReverting(true, true);

        vm.prank(alice);
        credit.depositCollateral(address(nvda), 50e8);
        assertEq(credit.collateral(alice, address(nvda)), 150e8, "adding collateral only reduces risk");
    }

    function test_oracleOutage_debtClearingWithdrawStillWorks() public {
        _positionWithDebt(alice, 100e8, 2_000e6);
        nvdaOracle.setReverting(true, true);

        // With debt outstanding the withdrawal still needs a price, and collateral the engine
        // cannot price is worth nothing to it, so the borrowing power behind the debt is zero.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.Undercollateralized.selector, 2_000e6, 0));
        credit.withdrawCollateral(address(nvda), 1e8, alice);

        // Once the debt is gone the collateral is unconditionally the user's.
        vm.startPrank(alice);
        credit.repay(type(uint256).max);
        credit.withdrawCollateral(address(nvda), 100e8, alice);
        vm.stopPrank();

        assertEq(nvda.balanceOf(alice), 10_000e8);
    }

    function test_oracleOutage_viewsDoNotRevert() public {
        _positionWithDebt(alice, 100e8, 2_000e6);
        nvdaOracle.setReverting(true, true);

        (uint256 hf, bool priced) = credit.healthFactor(alice);
        assertFalse(priced, "the engine admits it cannot price the line");
        assertEq(hf, credit.HEALTH_UNKNOWN());

        IAftermarketCredit.Position memory p = credit.positionOf(alice);
        assertFalse(p.priced);
        assertGt(p.debtAssets, 0);
        assertEq(p.borrowPower, 0);

        vm.expectRevert();
        credit.healthFactorStrict(alice);
    }

    /*//////////////////////////////////////////////////////////////
                           SESSION SENSITIVITY
    //////////////////////////////////////////////////////////////*/

    function test_session_closedMarketLowersBorrowPowerAndRaisesThreshold() public {
        _openAndDeposit(alice, address(nvda), 100e8);

        assertEq(credit.borrowPower(alice), 9_000e6);
        assertEq(credit.seizureThreshold(alice), 12_600e6);

        calendar.setSession(Session.CLOSED_WEEKEND);

        assertEq(credit.borrowPower(alice), 6_300e6, "35% advance while closed");
        assertEq(credit.seizureThreshold(alice), 14_400e6, "80% threshold while closed: harder to seize");
        assertGt(credit.seizureThreshold(alice), 12_600e6);
    }

    function test_session_drawShrinksWhenTheMarketCloses() public {
        _openAndDeposit(alice, address(nvda), 100e8);
        calendar.setSession(Session.CLOSED_WEEKEND);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.Undercollateralized.selector, 7_000e6, 6_300e6));
        credit.draw(7_000e6, alice);

        vm.prank(alice);
        credit.draw(6_300e6, alice);
        assertEq(credit.debtOf(alice), 6_300e6);
    }

    function test_session_closedMarketCostsMoreInterest() public {
        uint256 openRate = rateModel.ratePerSecondAt(500_000e6, 1_000_000e6, Session.REGULAR);
        uint256 overnightRate = rateModel.ratePerSecondAt(500_000e6, 1_000_000e6, Session.CLOSED_OVERNIGHT);
        uint256 weekendRate = rateModel.ratePerSecondAt(500_000e6, 1_000_000e6, Session.CLOSED_WEEKEND);
        uint256 holidayRate = rateModel.ratePerSecondAt(500_000e6, 1_000_000e6, Session.CLOSED_HOLIDAY);

        assertEq(rateModel.ratePerSecondAt(500_000e6, 1_000_000e6, Session.PRE), openRate);
        assertEq(rateModel.ratePerSecondAt(500_000e6, 1_000_000e6, Session.POST), openRate);
        assertEq(overnightRate, openRate * 125 / 100);
        assertEq(weekendRate, openRate * 150 / 100);
        assertEq(holidayRate, openRate * 160 / 100);

        // Above the kink the curve steepens.
        assertGt(
            rateModel.curveRatePerSecond(950_000e6, 1_000_000e6), rateModel.curveRatePerSecond(800_000e6, 1_000_000e6)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          GRACE, NOT LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Friday evening: the position goes underwater with the US market shut until Monday. The
    ///      grace clock must land after Monday's open, and nothing may be seized before then.
    function test_grace_flaggedOnFridayEveningRunsPastMondayOpen() public {
        _positionWithDebt(alice, 100e8, 8_000e6);

        uint64 mondayOpen = uint64(block.timestamp + 3 days);
        calendar.setSession(Session.CLOSED_WEEKEND);
        calendar.setNextOpen(mondayOpen);

        // $180 -> $110 wipes out the cushion: debt 8,000 vs a closed-session threshold of 8,800...
        nvdaOracle.setMarks(1.1e36, 1.1e36);
        assertEq(credit.seizureThreshold(alice), 8_800e6);
        // ...so drop it further to actually breach.
        nvdaOracle.setMarks(0.9e36, 0.9e36);
        assertEq(credit.seizureThreshold(alice), 7_200e6);

        vm.expectEmit(true, true, false, false);
        emit IAftermarketCredit.LineFlagged(alice, keeper, 0, 0, 0, 0, Session.CLOSED_WEEKEND);
        vm.prank(keeper);
        credit.flag(alice);

        assertTrue(credit.isFlagged(alice));
        assertEq(credit.graceUntil(alice), mondayOpen + credit.CURE_WINDOW(), "grace runs past the opening bell");

        // Cannot be flagged twice.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAftermarketCredit.AlreadyFlagged.selector, alice, uint64(mondayOpen + credit.CURE_WINDOW())
            )
        );
        credit.flag(alice);

        // Before the deadline: no seizure.
        vm.warp(mondayOpen);
        calendar.setSession(Session.REGULAR);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAftermarketCredit.GraceNotExpired.selector, uint64(mondayOpen + credit.CURE_WINDOW())
            )
        );
        credit.liquidate(alice, address(nvda), 100e6);

        // After the deadline but with the market shut again: still no seizure. This is the promise.
        vm.warp(mondayOpen + credit.CURE_WINDOW() + 1);
        calendar.setSession(Session.CLOSED_HOLIDAY);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.CLOSED_HOLIDAY));
        credit.liquidate(alice, address(nvda), 100e6);

        // Deadline passed, market open, still unhealthy: now it may be seized.
        calendar.setSession(Session.REGULAR);
        uint256 debtBefore = credit.debtOf(alice);
        vm.prank(keeper);
        (uint256 seized, uint256 repaid) = credit.liquidate(alice, address(nvda), 100e6);

        assertGt(seized, 0);
        assertEq(repaid, 100e6);
        assertApproxEqAbs(credit.debtOf(alice), debtBefore - 100e6, 1);
    }

    function test_grace_cureAfterRepayBlocksLaterLiquidation() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        nvdaOracle.setMarks(0.9e36, 0.9e36);

        vm.prank(keeper);
        credit.flag(alice);
        assertTrue(credit.isFlagged(alice));

        // Curing while still underwater is impossible.
        vm.expectRevert();
        credit.cure(alice);

        vm.prank(alice);
        credit.repay(4_000e6);

        vm.expectEmit(true, true, false, false);
        emit IAftermarketCredit.LineCured(alice, address(this), 0, 0);
        credit.cure(alice);

        assertFalse(credit.isFlagged(alice));
        assertEq(credit.graceUntil(alice), 0);

        vm.warp(block.timestamp + 30 days);
        calendar.setSession(Session.REGULAR);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NotFlagged.selector, alice));
        credit.liquidate(alice, address(nvda), 100e6);
    }

    function test_grace_fullRepayClearsTheFlagByItself() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        nvdaOracle.setMarks(0.9e36, 0.9e36);

        vm.prank(keeper);
        credit.flag(alice);

        vm.prank(alice);
        credit.repay(type(uint256).max);

        assertFalse(credit.isFlagged(alice), "nothing owed means nothing to seize");
    }

    function test_grace_minimumIsOneHourEvenWithAnImmediateOpen() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        nvdaOracle.setMarks(0.9e36, 0.9e36);
        calendar.setNextOpen(uint64(block.timestamp));

        vm.prank(keeper);
        credit.flag(alice);
        assertEq(credit.graceUntil(alice), block.timestamp + credit.MIN_GRACE());
    }

    function test_flag_requiresAnUnhealthyLine() public {
        _positionWithDebt(alice, 100e8, 2_000e6);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.LineHealthy.selector, 2_000e6, 12_600e6));
        credit.flag(alice);
    }

    function test_draw_isBlockedWhileFlagged() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        nvdaOracle.setMarks(0.9e36, 0.9e36);
        vm.prank(keeper);
        credit.flag(alice);

        nvdaOracle.setMarks(NVDA_MARK_180, NVDA_MARK_180);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.LineIsFlagged.selector, alice));
        credit.draw(1e6, alice);
    }

    /*//////////////////////////////////////////////////////////////
                      CLOSE FACTOR AND SEIZURE MATHS
    //////////////////////////////////////////////////////////////*/

    function _flagAndReachSeizure(uint256 markAfter) internal {
        nvdaOracle.setMarks(markAfter, markAfter);
        vm.prank(keeper);
        credit.flag(alice);
        vm.warp(credit.graceUntil(alice) + 1);
        calendar.setSession(Session.REGULAR);
    }

    function test_liquidate_enforcesTheCloseFactor() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        _flagAndReachSeizure(0.9e36);

        uint256 debt = credit.debtOf(alice);
        uint256 maxRepay = debt / 2;

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.CloseFactorExceeded.selector, maxRepay + 1, maxRepay));
        credit.liquidate(alice, address(nvda), maxRepay + 1);

        vm.prank(keeper);
        credit.liquidate(alice, address(nvda), maxRepay);
    }

    function test_liquidate_seizureAndBonusAreExact() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        _flagAndReachSeizure(0.9e36);

        uint256 repayAssets = 1_000e6;
        // 1,000 USDC of debt at a $90 mark is 11.111... NVDAc, plus an 8% bonus.
        uint256 expectedSeized = repayAssets * 1e36 / 0.9e36 * 10_800 / 10_000;

        (uint256 quotedSeized, uint256 quotedCost) = credit.quoteSeizure(alice, address(nvda), repayAssets);
        assertEq(quotedSeized, expectedSeized);
        assertEq(quotedCost, repayAssets);

        uint256 keeperNvdaBefore = nvda.balanceOf(keeper);
        uint256 keeperUsdcBefore = usdc.balanceOf(keeper);

        vm.prank(keeper);
        (uint256 seized, uint256 repaid) = credit.liquidate(alice, address(nvda), repayAssets);

        assertEq(seized, expectedSeized, "seizure is markLiquidate plus the configured bonus");
        assertEq(repaid, repayAssets);
        assertEq(nvda.balanceOf(keeper), keeperNvdaBefore + expectedSeized);
        assertEq(usdc.balanceOf(keeper), keeperUsdcBefore - repayAssets);
        assertEq(credit.collateral(alice, address(nvda)), 100e8 - expectedSeized);
        assertEq(_posted(address(nvda)), 100e8 - expectedSeized);
    }

    function test_liquidate_seizureIsCappedByTheUserBalance() public {
        _positionWithDebt(alice, 10e8, 800e6);
        _flagAndReachSeizure(0.1e36);

        uint256 debt = credit.debtOf(alice);
        uint256 repayAssets = debt / 2;

        // At a $10 mark, 400 USDC of debt would claim 43.2 NVDAc but only 10 exist. The cost of
        // the capped seizure is rounded UP: it is the liquidator's payment, and a cost that floors
        // to zero is what used to strand an unseizable crumb on the ledger.
        uint256 collateralValue = uint256(10e8) * 0.1e36 / 1e36;
        uint256 expectedCost = (collateralValue * 10_000 + 10_799) / 10_800;

        vm.prank(keeper);
        (uint256 seized, uint256 repaid) = credit.liquidate(alice, address(nvda), repayAssets);

        assertEq(seized, 10e8, "capped at the entire balance");
        assertEq(repaid, expectedCost, "and the liquidator pays only for what exists");
        assertLt(repaid, repayAssets);
        assertEq(credit.collateral(alice, address(nvda)), 0);
    }

    function test_liquidate_healthyLineIsRefused() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        _flagAndReachSeizure(0.9e36);

        nvdaOracle.setMarks(NVDA_MARK_180, NVDA_MARK_180);
        vm.prank(keeper);
        vm.expectRevert();
        credit.liquidate(alice, address(nvda), 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                                BAD DEBT
    //////////////////////////////////////////////////////////////*/

    function test_badDebt_isRealizedAndWrittenDown() public {
        _positionWithDebt(alice, 10e8, 900e6);

        _flagAndReachSeizure(0.1e36);
        credit.accrue();

        // Measured after the grace period so that the only thing left to move the share price is
        // the write-off itself.
        uint256 supplierShares = vault.balanceOf(supplier);
        uint256 supplierValueBefore = vault.convertToAssets(supplierShares);
        uint256 debtBefore = credit.debtOf(alice);
        uint256 collateralValue = uint256(10e8) * 0.1e36 / 1e36;
        uint256 expectedRepaid = collateralValue * 10_000 / 10_800;
        uint256 expectedBadDebt = debtBefore - expectedRepaid;

        vm.expectEmit(true, false, false, false);
        emit IAftermarketCredit.BadDebtRealized(alice, 0, 0);

        vm.prank(keeper);
        credit.liquidate(alice, address(nvda), debtBefore / 2);

        assertEq(credit.debtOf(alice), 0, "phantom debt is not left on the books");
        assertEq(credit.totalDebtAssets(), 0);
        assertEq(credit.totalDebtShares(), 0);
        assertFalse(credit.isFlagged(alice));

        uint256 supplierValueAfter = vault.convertToAssets(supplierShares);
        assertLt(supplierValueAfter, supplierValueBefore, "the loss lands on suppliers, immediately");
        assertApproxEqAbs(supplierValueBefore - supplierValueAfter, expectedBadDebt, 2);
    }

    /*//////////////////////////////////////////////////////////////
                              ELIGIBILITY
    //////////////////////////////////////////////////////////////*/

    function test_eligibility_gatesOnlyRiskIncreasingActions() public {
        _positionWithDebt(alice, 100e8, 2_000e6);

        eligibility.setEligible(alice, false);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IEligibility.NotEligible.selector, alice));
        credit.depositCollateral(address(nvda), 1e8);

        vm.expectRevert(abi.encodeWithSelector(IEligibility.NotEligible.selector, alice));
        credit.draw(1e6, alice);

        // Curing is never gated: a compliance rule must not be able to trap someone's assets.
        credit.repay(type(uint256).max);
        credit.withdrawCollateral(address(nvda), 100e8, alice);
        vm.stopPrank();

        assertEq(nvda.balanceOf(alice), 10_000e8);
    }

    function test_eligibility_blocksOpeningALine() public {
        eligibility.setEligible(bob, false);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IEligibility.NotEligible.selector, bob));
        credit.openLine();
    }

    function test_openLine_isRequiredAndSingleUse() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.LineNotOpen.selector, alice));
        credit.depositCollateral(address(nvda), 1e8);

        vm.startPrank(alice);
        credit.openLine();
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.LineAlreadyOpen.selector, alice));
        credit.openLine();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        SELF-REPAYING COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function test_sweepYield_sellsExactlyTheAccruedSlice() public {
        _positionWithDebt(alice, 100e8, 1_000e6);

        nvda.setMultiplier(1.01e18);

        uint256 posted = 100e8;
        uint256 newMultiplier = 1.01e18;
        uint256 expectedSold = posted * (newMultiplier - 1e18) / newMultiplier;
        uint256 expectedProceeds = expectedSold * 180e6 / 1e8;

        vm.prank(alice);
        (uint256 sold, uint256 proceeds, uint256 repaid) = credit.sweepYield(alice, address(nvda));

        assertEq(sold, expectedSold, "sells (m - m0) / m of the position");
        assertEq(proceeds, expectedProceeds);
        assertEq(repaid, expectedProceeds);
        assertEq(credit.collateral(alice, address(nvda)), posted - expectedSold);
        // casting to 'uint128' is safe because both operands are small test constants
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(_posted(address(nvda)), uint128(posted - expectedSold));
        assertEq(credit.multiplierCheckpoint(alice, address(nvda)), 1.01e18);
        assertApproxEqAbs(credit.debtOf(alice), 1_000e6 - expectedProceeds, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NothingToSweep.selector, alice, address(nvda)));
        credit.sweepYield(alice, address(nvda));
    }

    function test_sweepYield_isPermissionlessOnlyWhenOptedIn() public {
        _positionWithDebt(alice, 100e8, 1_000e6);
        nvda.setMultiplier(1.01e18);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.AutoRepayDisabled.selector, alice));
        credit.sweepYield(alice, address(nvda));

        vm.prank(alice);
        credit.setAutoRepay(true);

        vm.prank(keeper);
        credit.sweepYield(alice, address(nvda));
        assertLt(credit.debtOf(alice), 1_000e6);
    }

    function test_sweepYield_surplusGoesToTheUser() public {
        _positionWithDebt(alice, 100e8, 50e6);
        nvda.setMultiplier(1.01e18);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 debt = credit.debtOf(alice);

        vm.prank(alice);
        (, uint256 proceeds, uint256 repaid) = credit.sweepYield(alice, address(nvda));

        assertEq(repaid, debt, "debt first");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + proceeds - repaid, "then the surplus, straight to the user");
        assertEq(credit.debtOf(alice), 0);
    }

    function test_sweepYield_slippageGuardRejectsABadFill() public {
        _positionWithDebt(alice, 100e8, 1_000e6);
        nvda.setMultiplier(1.01e18);

        // A 3% haircut against a 1% budget: the venue itself refuses first.
        adapter.setHaircutBps(300);
        vm.prank(alice);
        vm.expectRevert();
        credit.sweepYield(alice, address(nvda));

        // And if the venue lies about honouring minOut, the credit engine still refuses.
        adapter.setEnforceMinOut(false);
        vm.prank(alice);
        vm.expectRevert();
        credit.sweepYield(alice, address(nvda));

        // Inside the budget it goes through.
        adapter.setHaircutBps(50);
        adapter.setEnforceMinOut(true);
        vm.prank(alice);
        credit.sweepYield(alice, address(nvda));
    }

    function test_sweepYield_requiresATrustedMark() public {
        _positionWithDebt(alice, 100e8, 1_000e6);
        nvda.setMultiplier(1.01e18);
        nvdaOracle.setReverting(true, true);

        vm.prank(alice);
        vm.expectRevert();
        credit.sweepYield(alice, address(nvda));
    }

    /// @dev Depositing more collateral must not quietly confiscate a distribution that accrued on
    ///      the existing balance but has not been swept yet.
    function test_sweepYield_checkpointSurvivesAFurtherDeposit() public {
        _positionWithDebt(alice, 100e8, 1_000e6);
        nvda.setMultiplier(1.01e18);

        uint256 posted = 100e8;
        uint256 newMultiplier = 1.01e18;
        uint256 sliceBefore = posted * (newMultiplier - 1e18) / newMultiplier;

        vm.prank(alice);
        credit.depositCollateral(address(nvda), 100e8);

        vm.prank(alice);
        (uint256 sold,,) = credit.sweepYield(alice, address(nvda));
        assertApproxEqAbs(sold, sliceBefore, 2, "the accrued slice is preserved across the deposit");
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER CONTROLS
    //////////////////////////////////////////////////////////////*/

    function test_setAsset_validatesThePolicyShape() public {
        IAftermarketCredit.AssetParams memory p = IAftermarketCredit.AssetParams({
            oracle: IAftermarketOracle(address(nvdaOracle)),
            advanceOpenBps: 5_000,
            advanceClosedBps: 3_500,
            liqThresholdOpenBps: 7_000,
            liqThresholdClosedBps: 8_000,
            liqBonusBps: 800,
            cap: 1_000e8,
            enabled: true
        });

        vm.startPrank(owner);

        p.advanceClosedBps = 6_000; // closed advance above open advance
        vm.expectRevert(IAftermarketCredit.InvalidAssetConfig.selector);
        credit.setAsset(address(nvda), p);
        p.advanceClosedBps = 3_500;

        p.liqThresholdClosedBps = 6_000; // closed threshold below open threshold
        vm.expectRevert(IAftermarketCredit.InvalidAssetConfig.selector);
        credit.setAsset(address(nvda), p);
        p.liqThresholdClosedBps = 8_000;

        p.advanceOpenBps = 9_600; // above the 9500 ceiling
        vm.expectRevert(IAftermarketCredit.InvalidAssetConfig.selector);
        credit.setAsset(address(nvda), p);
        p.advanceOpenBps = 5_000;

        p.liqBonusBps = 2_100; // above the 2000 ceiling
        vm.expectRevert(IAftermarketCredit.InvalidAssetConfig.selector);
        credit.setAsset(address(nvda), p);
        p.liqBonusBps = 800;

        p.advanceOpenBps = 7_500; // advance above the liquidation threshold
        vm.expectRevert(IAftermarketCredit.InvalidAssetConfig.selector);
        credit.setAsset(address(nvda), p);
        p.advanceOpenBps = 5_000;

        credit.setAsset(address(nvda), p);
        vm.stopPrank();
    }

    function test_setAsset_isOwnerOnlyAndTwoStep() public {
        IAftermarketCredit.AssetParams memory p = IAftermarketCredit.AssetParams({
            oracle: IAftermarketOracle(address(nvdaOracle)),
            advanceOpenBps: 5_000,
            advanceClosedBps: 3_500,
            liqThresholdOpenBps: 7_000,
            liqThresholdClosedBps: 8_000,
            liqBonusBps: 800,
            cap: 1_000e8,
            enabled: true
        });

        vm.prank(alice);
        vm.expectRevert();
        credit.setAsset(address(nvda), p);

        vm.prank(owner);
        credit.transferOwnership(bob);
        assertEq(credit.owner(), owner, "ownership does not move until accepted");

        vm.prank(bob);
        credit.acceptOwnership();
        assertEq(credit.owner(), bob);
    }

    function test_cap_isEnforcedAndCannotBeSetBelowWhatIsPosted() public {
        vm.prank(owner);
        credit.setAsset(
            address(nvda),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(nvdaOracle)),
                advanceOpenBps: 5_000,
                advanceClosedBps: 3_500,
                liqThresholdOpenBps: 7_000,
                liqThresholdClosedBps: 8_000,
                liqBonusBps: 800,
                cap: 100e8,
                enabled: true
            })
        );

        _openAndDeposit(alice, address(nvda), 100e8);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAftermarketCredit.AssetCapExceeded.selector, address(nvda), uint256(101e8), 100e8)
        );
        credit.depositCollateral(address(nvda), 1e8);
    }

    function test_disabledAssetBlocksDepositsButNotExits() public {
        _positionWithDebt(alice, 100e8, 1_000e6);

        vm.prank(owner);
        credit.setAsset(
            address(nvda),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(nvdaOracle)),
                advanceOpenBps: 5_000,
                advanceClosedBps: 3_500,
                liqThresholdOpenBps: 7_000,
                liqThresholdClosedBps: 8_000,
                liqBonusBps: 800,
                cap: uint128(1_000_000e8),
                enabled: false
            })
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.AssetNotEnabled.selector, address(nvda)));
        credit.depositCollateral(address(nvda), 1e8);

        // Existing holders keep every exit.
        assertEq(credit.borrowPower(alice), 9_000e6);
        vm.startPrank(alice);
        credit.repay(type(uint256).max);
        credit.withdrawCollateral(address(nvda), 100e8, alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_borrowPowerIsMonotoneInCollateral(uint256 first, uint256 second) public {
        first = bound(first, 1e6, 5_000e8);
        second = bound(second, 1e6, 5_000e8);

        _openAndDeposit(alice, address(nvda), first);
        uint256 powerAfterFirst = credit.borrowPower(alice);

        vm.prank(alice);
        credit.depositCollateral(address(nvda), second);
        uint256 powerAfterSecond = credit.borrowPower(alice);

        assertGe(powerAfterSecond, powerAfterFirst, "more collateral never means less credit");
    }

    function testFuzz_userCanAlwaysRepayTheirFullDebt(uint256 drawAmount, uint256 elapsed) public {
        drawAmount = bound(drawAmount, 1e6, 9_000e6);
        elapsed = bound(elapsed, 0, 3 * 365 days);

        _openAndDeposit(alice, address(nvda), 100e8);
        vm.prank(alice);
        credit.draw(drawAmount, alice);

        vm.warp(block.timestamp + elapsed);

        // Fund whatever the interest turned out to be, then clear the line.
        uint256 owed = credit.debtOf(alice);
        usdc.mint(alice, owed);

        vm.prank(alice);
        credit.repay(type(uint256).max);

        assertEq(credit.debtOf(alice), 0);
        assertEq(credit.totalDebtAssets(), 0);
        assertEq(credit.totalDebtShares(), 0);
    }

    function testFuzz_healthFactorNeverReverts(uint256 drawAmount, uint8 rawSession, bool borrowDown, bool liqDown)
        public
    {
        drawAmount = bound(drawAmount, 1e6, 9_000e6);
        calendar.setSession(Session(bound(rawSession, 0, 5)));

        _openAndDeposit(alice, address(nvda), 100e8);
        calendar.setSession(Session.REGULAR);
        vm.prank(alice);
        credit.draw(drawAmount, alice);
        calendar.setSession(Session(bound(rawSession, 0, 5)));

        nvdaOracle.setReverting(borrowDown, liqDown);

        (uint256 hf, bool priced) = credit.healthFactor(alice);
        IAftermarketCredit.Position memory p = credit.positionOf(alice);

        if (liqDown || borrowDown) {
            assertFalse(p.priced, "an unpriceable basket is reported as unpriceable, never guessed");
            if (liqDown) {
                assertFalse(priced);
                assertEq(hf, credit.HEALTH_UNKNOWN());
            }
        } else {
            assertTrue(priced);
            assertTrue(p.priced);
            assertGt(hf, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    REGRESSIONS: A-02, A-12, A-13
    //////////////////////////////////////////////////////////////*/

    /// @notice A-02. An asset whose oracle refuses to mark contributes nothing to either side of the
    ///         risk calculation instead of aborting it, so one leg of a basket can no longer switch
    ///         the risk engine off for the whole line.
    /// @dev The paired half is `test_regression_A02_theUnpriceableAssetItselfIsNeverSeizable`: the
    ///      valuation change is only safe because the dark leg cannot be taken by anybody.
    function test_regression_A02_oneDarkLegDoesNotVetoTheBasket() public {
        _openAndDeposit(alice, address(nvda), 100e8);
        vm.startPrank(alice);
        credit.depositCollateral(address(aapl), 1); // one raw unit of an 18-decimal equity
        credit.draw(8_000e6, alice);
        vm.stopPrank();

        // The dust leg goes dark. The NVDAc leg is untouched and still marks at $180.
        aaplOracle.setReverting(true, true);
        nvdaOracle.setMarks(0.9e36, 0.9e36); // NVDAc to $90: 100 * 90 * 0.70 = $6,300 < $8,000 debt

        // The public views still refuse a partially-priced basket, so `priced` keeps its meaning.
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.UnpricedCollateral.selector, 1));
        credit.seizureThreshold(alice);
        assertFalse(credit.positionOf(alice).priced, "positionOf still reports it as unpriced");

        // The engine acts on the collateral it can price.
        vm.prank(keeper);
        credit.flag(alice);
        assertTrue(credit.isFlagged(alice), "the dust leg does not veto the flag");

        vm.warp(credit.graceUntil(alice) + 1);
        calendar.setSession(Session.REGULAR);
        vm.prank(keeper);
        (uint256 seized,) = credit.liquidate(alice, address(nvda), 1_000e6);
        assertGt(seized, 0, "nor the seizure");
    }

    /// @notice A-02, the half that keeps the valuation change safe: an unpriceable asset is worth
    ///         nothing to the borrower AND cannot be taken by anybody, at any price.
    function test_regression_A02_theUnpriceableAssetItselfIsNeverSeizable() public {
        _openAndDeposit(alice, address(nvda), 100e8);
        vm.startPrank(alice);
        credit.depositCollateral(address(aapl), 100e18);
        credit.draw(8_000e6, alice);
        vm.stopPrank();

        aaplOracle.setReverting(true, true);

        // The AAPLc leg stops carrying any borrowing power at all.
        nvdaOracle.setMarks(0.9e36, 0.9e36);
        vm.prank(keeper);
        credit.flag(alice);
        vm.warp(credit.graceUntil(alice) + 1);
        calendar.setSession(Session.REGULAR);

        vm.prank(keeper);
        vm.expectRevert();
        credit.liquidate(alice, address(aapl), 1_000e6);
        assertEq(credit.collateral(alice, address(aapl)), 100e18, "the dark leg is untouched");

        // ...and when it comes back, it counts again: 100 NVDAc at $90 x 0.50 plus 100 AAPLc at
        // $200 x 0.60. While it was dark only the first term existed.
        aaplOracle.setReverting(false, false);
        assertEq(credit.borrowPower(alice), 4_500e6 + 12_000e6, "AAPLc counts once priceable again");
    }

    /// @notice A-02. A basket in which nothing at all can be priced is an outage, not insolvency.
    function test_regression_A02_aTotalOutageIsNotInsolvency() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        nvdaOracle.setReverting(true, true);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.UnpricedCollateral.selector, 1));
        credit.flag(alice);
    }

    /// @notice A-12. When the borrower's balance caps a seizure the liquidator's cost is rounded UP,
    ///         so it never floors to zero and no leg can strand below the seizure floor.
    function test_regression_A12_aSubDustLegIsAlwaysSeizable() public {
        _openAndDeposit(alice, address(nvda), 100e8);
        vm.startPrank(alice);
        credit.depositCollateral(address(aapl), 1); // 1e-18 AAPLc: worth 2e-13 USDC at $200
        credit.draw(8_000e6, alice);
        vm.stopPrank();

        (uint256 seized, uint256 cost) = credit.quoteSeizure(alice, address(aapl), 1_000e6);
        assertEq(seized, 1, "the crumb is seizable");
        assertEq(cost, 1, "for one unit of the loan token, never for zero");
    }

    /// @notice A-12. The write-off is reachable: a cascade that empties the basket recognises the
    ///         residual loss in the same call instead of leaving it to compound forever.
    function test_regression_A12_theWriteOffIsReachable() public {
        _positionWithDebt(alice, 10e8, 900e6);
        _flagAndReachSeizure(0.1e36);
        credit.accrue();

        uint256 debtBefore = credit.debtOf(alice);

        vm.expectEmit(true, false, false, false);
        emit IAftermarketCredit.BadDebtRealized(alice, 0, 0);
        vm.prank(keeper);
        credit.liquidate(alice, address(nvda), debtBefore / 2);

        assertEq(credit.collateral(alice, address(nvda)), 0, "the leg clears entirely");
        assertEq(credit.debtOf(alice), 0, "and the residual is written off");
        assertEq(credit.totalDebtAssets(), 0);
    }

    /// @notice A-12. `realizeBadDebt` is permissionless once a flagged line's grace has run out and
    ///         what is left of its basket is worth less than the gas of taking it - but it inherits
    ///         every one of `liquidate`'s guarantees, and refuses a line that still has collateral.
    function test_regression_A12_realizeBadDebtIsGuardedLikeASeizure() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        nvdaOracle.setMarks(0.9e36, 0.9e36);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.NotFlagged.selector, alice));
        credit.realizeBadDebt(alice);

        vm.prank(keeper);
        credit.flag(alice);

        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketCredit.GraceNotExpired.selector);
        credit.realizeBadDebt(alice);

        vm.warp(credit.graceUntil(alice) + 1);
        calendar.setSession(Session.CLOSED_WEEKEND);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.CLOSED_WEEKEND));
        credit.realizeBadDebt(alice);

        calendar.setSession(Session.REGULAR);
        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketCredit.LineNotDust.selector);
        credit.realizeBadDebt(alice);

        // An oracle outage must never be able to trigger a permanent write-off either.
        nvdaOracle.setMarks(1, 1);
        nvdaOracle.setReverting(true, true);
        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketCredit.UnpricedCollateral.selector);
        credit.realizeBadDebt(alice);

        // With the collateral marked to nothing, anybody may recognise the loss.
        nvdaOracle.setReverting(false, false);
        uint256 supplierValueBefore = vault.convertToAssets(vault.balanceOf(supplier));
        vm.prank(keeper);
        credit.realizeBadDebt(alice);
        assertEq(credit.debtOf(alice), 0, "the loss is recognised");
        assertFalse(credit.isFlagged(alice), "and the flag goes with it");
        assertLt(vault.convertToAssets(vault.balanceOf(supplier)), supplierValueBefore, "on the suppliers, at once");
    }

    /// @notice A-13. The vault closes the accrual window before it changes its own liquidity, so a
    ///         one-block deposit cannot reprice interest that has already elapsed.
    function test_regression_A13_aDepositCannotRepriceElapsedInterest() public {
        _positionWithDebt(alice, 10_000e8, 900_000e6);

        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 30 days);
        credit.accrue();
        uint256 honestDebt = credit.debtOf(alice);

        vm.revertToState(snap);

        vm.warp(block.timestamp + 30 days);
        usdc.mint(bob, 3_000_000e6);
        vm.startPrank(bob);
        uint256 shares = vault.deposit(3_000_000e6, bob);
        credit.accrue();
        vault.redeem(shares, bob, bob);
        vm.stopPrank();

        assertEq(credit.debtOf(alice), honestDebt, "a one-block deposit reprices nothing");
    }

    /// @notice A-13. The same, from the other side: `withdraw` and `redeem` accrue first too, so a
    ///         large exit cannot retroactively overcharge the remaining borrowers either.
    function test_regression_A13_everyLiquidityChangeAccruesFirst() public {
        _positionWithDebt(alice, 10_000e8, 500_000e6);

        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 30 days);
        credit.accrue();
        uint256 honestDebt = credit.debtOf(alice);

        vm.revertToState(snap);

        vm.warp(block.timestamp + 30 days);
        vm.prank(supplier);
        vault.withdraw(400_000e6, supplier, supplier);
        credit.accrue();

        assertEq(credit.debtOf(alice), honestDebt, "a large exit reprices nothing either");
    }

    /// @notice A-13c. Interest too small to be worth a whole unit of the loan token is carried
    ///         rather than discarded, so the accrual schedule cannot change what a borrower owes and
    ///         nobody can pin a small market at zero interest by calling `accrue()` every block.
    function test_regression_A13_theAccrualScheduleDoesNotChangeTheInterest() public {
        _positionWithDebt(alice, 100e8, 500e6);

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

        assertGt(lazy, 500e6, "interest accrued at all");
        assertEq(credit.debtOf(alice), lazy, "and accruing every block charges exactly the same");
    }

    /// @notice A-13, the mirror of the above. The accrual window must close on EVERY call, or a
    ///         market parked at a dust total debt holds it open indefinitely and then charges the
    ///         whole of it against the next borrower's freshly-drawn principal.
    function test_regression_A13_aDustDebtCannotBankAWindow() public {
        _openAndDeposit(alice, address(nvda), 1e8);
        vm.prank(alice);
        credit.draw(1, alice); // one wei: its own interest floors to zero for decades

        vm.warp(block.timestamp + 365 days);

        _openAndDeposit(bob, address(nvda), 10_000e8);
        vm.prank(bob);
        credit.draw(500_000e6, bob);

        assertEq(credit.debtOf(bob), 500_000e6, "a fresh draw owes exactly what it drew");
        credit.accrue();
        assertEq(credit.debtOf(bob), 500_000e6, "and still does once the market is brought current");
    }

    /// @notice A-01/A-15. Curing is the exact complement of flagging: measured at open-session
    ///         parameters and only while the market is open, so in any session a seizure could
    ///         happen in, a line is either curable or seizable and never both or neither. That is
    ///         what stops a flag outliving the condition that raised it and seizing on an expired
    ///         clock, without handing the borrower a free reset at every closing bell.
    function test_regression_A01_cureAndSeizureAreExactComplements() public {
        _positionWithDebt(alice, 100e8, 8_000e6);
        nvdaOracle.setMarks(0.9e36, 0.9e36); // threshold 100e8 * 0.9 * 0.70 = $6,300 < $8,000

        vm.prank(keeper);
        credit.flag(alice);
        vm.warp(credit.graceUntil(alice) + 1);

        // Closed: neither curable nor seizable. Nothing can happen either way.
        calendar.setSession(Session.CLOSED_WEEKEND);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.CLOSED_WEEKEND));
        credit.cure(alice);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.MarketClosed.selector, Session.CLOSED_WEEKEND));
        credit.liquidate(alice, address(nvda), 100e6);

        // Open and unhealthy: seizable, not curable.
        calendar.setSession(Session.REGULAR);
        vm.expectPartialRevert(IAftermarketCredit.CureIncomplete.selector);
        credit.cure(alice);
        vm.prank(keeper);
        credit.liquidate(alice, address(nvda), 100e6);

        // Open and healthy again: curable, not seizable - and the flag goes, so the next unhealthy
        // episode needs a fresh flag and therefore a fresh grace period.
        nvdaOracle.setMarks(1.8e36, 1.8e36);
        vm.prank(keeper);
        vm.expectPartialRevert(IAftermarketCredit.LineHealthy.selector);
        credit.liquidate(alice, address(nvda), 100e6);

        credit.cure(alice);
        assertFalse(credit.isFlagged(alice), "a recovered line can always clear its flag");
        assertEq(credit.graceUntil(alice), 0, "and its expired clock with it");
    }

    /// @notice A-06. The calendar failing closed has to close origination too, or past the horizon
    ///         the protocol becomes a one-way ratchet: new debt against collateral that can never be
    ///         flagged, cured or seized.
    function test_regression_A06_drawIsRefusedPastTheCalendarHorizon() public {
        _openAndDeposit(alice, address(nvda), 100e8);
        calendar.setNextOpen(0);

        vm.prank(alice);
        vm.expectRevert(IAftermarketCredit.CalendarHorizon.selector);
        credit.draw(1e6, alice);

        // Repayment and collateral top-up are untouched, as everywhere else.
        vm.prank(alice);
        credit.depositCollateral(address(nvda), 1e8);
        vm.prank(alice);
        credit.withdrawCollateral(address(nvda), 101e8, alice);
    }
}

/*//////////////////////////////////////////////////////////////////
                          INVARIANT TESTING
//////////////////////////////////////////////////////////////////*/

/// @notice Drives the protocol through random but always-legal sequences.
/// @dev Liquidation is deliberately excluded: the handler is here to prove that ordinary borrower
///      and supplier traffic can never break the ledger, and mixing in seizure would make the
///      solvency bound depend on realised bad debt rather than on the accounting itself.
contract CreditHandler is Test {
    AftermarketCredit internal credit;
    AftermarketVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal nvda;
    StubCalendar internal calendar;

    address[] public actors;

    uint256 public ghostSupplied;
    uint256 public ghostRedeemed;
    bool public ghostDebtFellWithoutRepayment;

    uint256 internal debtBeforeAction;

    constructor(
        AftermarketCredit credit_,
        AftermarketVault vault_,
        MockERC20 usdc_,
        MockERC20 nvda_,
        StubCalendar calendar_,
        address[] memory actors_
    ) {
        credit = credit_;
        vault = vault_;
        usdc = usdc_;
        nvda = nvda_;
        calendar = calendar_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    modifier tracksDebt(bool mayFall) {
        debtBeforeAction = credit.totalDebtAssets();
        _;
        if (!mayFall && credit.totalDebtAssets() + 1 < debtBeforeAction) {
            ghostDebtFellWithoutRepayment = true;
        }
    }

    function supply(uint256 seed, uint256 amount) external tracksDebt(false) {
        address who = _actor(seed);
        amount = bound(amount, 1e6, 100_000e6);
        usdc.mint(who, amount);

        vm.prank(who);
        vault.deposit(amount, who);
        ghostSupplied += amount;
    }

    function redeem(uint256 seed, uint256 shares) external tracksDebt(false) {
        address who = _actor(seed);
        uint256 max = vault.maxRedeem(who);
        if (max == 0) return;
        shares = bound(shares, 1, max);

        vm.prank(who);
        ghostRedeemed += vault.redeem(shares, who, who);
    }

    function depositCollateral(uint256 seed, uint256 amount) external tracksDebt(false) {
        address who = _actor(seed);
        amount = bound(amount, 1e6, 1_000e8);
        nvda.mint(who, amount);

        vm.prank(who);
        credit.depositCollateral(address(nvda), amount);
    }

    function draw(uint256 seed, uint256 amount) external tracksDebt(false) {
        address who = _actor(seed);
        uint256 power = credit.borrowPower(who);
        uint256 debt = credit.debtOf(who);
        uint256 idle = vault.idleAssets();
        if (power <= debt || idle == 0) return;

        uint256 headroom = power - debt;
        if (headroom > idle) headroom = idle;
        if (headroom < 1e6) return;
        amount = bound(amount, 1e6, headroom);

        vm.prank(who);
        credit.draw(amount, who);
    }

    function repay(uint256 seed, uint256 amount) external tracksDebt(true) {
        address who = _actor(seed);
        uint256 debt = credit.debtOf(who);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        usdc.mint(who, amount);

        vm.prank(who);
        credit.repay(amount);
    }

    function withdrawCollateral(uint256 seed, uint256 amount) external tracksDebt(false) {
        address who = _actor(seed);
        uint256 balance = credit.collateral(who, address(nvda));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        uint256 debt = credit.debtOf(who);
        if (debt != 0) {
            uint256 power = credit.borrowPower(who);
            // Only attempt withdrawals the engine will actually allow.
            uint256 perUnit = power / balance;
            if (perUnit == 0) return;
            uint256 maxByPower = (power - debt) / perUnit;
            if (maxByPower == 0) return;
            if (amount > maxByPower) amount = maxByPower;
        }

        vm.prank(who);
        credit.withdrawCollateral(address(nvda), amount, who);
    }

    function passTime(uint256 secondsAhead, uint8 rawSession) external tracksDebt(false) {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 7 days));
        calendar.setSession(Session(bound(rawSession, 0, 5)));
        credit.accrue();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}

contract AftermarketCreditInvariantTest is AftermarketFixture {
    CreditHandler internal handler;

    function setUp() public {
        _deployProtocol();

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = keeper;

        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            credit.openLine();
            usdc.approve(address(credit), type(uint256).max);
            usdc.approve(address(vault), type(uint256).max);
            nvda.approve(address(credit), type(uint256).max);
            vm.stopPrank();
        }

        handler = new CreditHandler(credit, vault, usdc, nvda, calendar, actors);

        targetContract(address(handler));
    }

    /// @notice Every debt share belongs to exactly one line.
    /// @notice `_burnDebt`'s final-repay path computes `totalDebtAssetsStored - _toAssetsUp(...)`,
    ///         which is underflow-safe only while the share total stays under `VIRTUAL_SHARES` times
    ///         the asset total. `_realizeBadDebt` burns shares exactly while rounding the residual
    ///         assets up, so it is the one writer that moves this ratio the wrong way; if it ever
    ///         crossed, `repay` would revert permanently, which is the single outcome the design
    ///         says is impossible.
    function invariant_debtSharesNeverOutrunTheAssetCeiling() public view {
        assertLe(
            credit.totalDebtShares(),
            1e6 * credit.totalDebtAssets(),
            "debt shares must stay under the virtual-share ceiling on assets"
        );
    }

    function invariant_debtSharesSumToTheTotal() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += credit.debtSharesOf(handler.actorAt(i));
        }
        assertEq(sum, credit.totalDebtShares());
    }

    /// @notice Outstanding debt only ever falls through a repayment.
    function invariant_debtOnlyFallsOnRepayment() public view {
        assertFalse(handler.ghostDebtFellWithoutRepayment());
    }

    /// @notice The vault always holds at least what suppliers put in, net of redemptions. No
    ///         liquidation runs in this handler, so there is no realised bad debt to subtract.
    function invariant_vaultIsNeverInsolvent() public view {
        assertGe(vault.totalAssets() + handler.ghostRedeemed(), handler.ghostSupplied() + 1_000_000e6);
    }

    /// @notice Idle plus lent is exactly what the vault reports.
    function invariant_vaultAccountingIsClosed() public view {
        assertEq(vault.totalAssets(), vault.idleAssets() + credit.totalDebtAssets());
    }
}
