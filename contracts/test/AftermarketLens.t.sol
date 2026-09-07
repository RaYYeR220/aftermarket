// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAftermarketCredit} from "../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketLens} from "../src/interfaces/IAftermarketLens.sol";
import {IAftermarketOracle} from "../src/interfaces/IAftermarketOracle.sol";
import {Quote, Session} from "../src/libraries/Types.sol";

import {AgentFixture} from "./fixtures/AgentFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice An oracle that refuses everything, including the read that is documented never to fail.
/// @dev `AftermarketOracle.peek` is total by construction, but the lens reaches it through an
///      owner-settable address. The lens's promise is that it survives *any* behaviour there, so the
///      test needs a source of that behaviour.
contract DeadOracle is IAftermarketOracle {
    error Dead();

    address public immutable collateralToken;
    address public immutable loanToken;

    /// @dev The pair is still declared truthfully: `AftermarketCredit.setAsset` asserts that an
    ///      oracle prices the asset it is installed for, and a dead oracle is still an oracle for a
    ///      specific pair. What is being tested here is a refusal to quote, not a mis-wiring.
    constructor(address collateralToken_, address loanToken_) {
        collateralToken = collateralToken_;
        loanToken = loanToken_;
    }

    function price() external pure returns (uint256) {
        revert Dead();
    }

    function peek() external pure returns (Quote memory) {
        revert Dead();
    }

    function markBorrow() external pure returns (uint256) {
        revert Dead();
    }

    function markLiquidate() external pure returns (uint256) {
        revert Dead();
    }

    function calendar() external pure returns (address) {
        return address(0);
    }

    function feed() external pure returns (address) {
        return address(0);
    }

    function pool() external pure returns (address) {
        return address(0);
    }
}

/// @notice Tests for the aggregate read layer.
///
/// @dev The whole suite is organised around one property: the lens must return a complete, honest
///      struct no matter what has failed underneath it. Every "down" scenario below is therefore
///      asserted twice - once that the call did not revert, and once that the flag it carries says
///      the data is not to be trusted.
contract AftermarketLensTest is AgentFixture {
    uint128 internal constant COLLATERAL = 100e8; // 100 NVDAc, $18,000 at the opening mark
    uint256 internal constant DRAW = 8_000e6;

    MockERC20 internal unlisted;

    function setUp() public {
        _deployProtocol();
        _openAndDraw(alice, COLLATERAL, DRAW);
        unlisted = new MockERC20("Coinbase MSFT", "MSFTc", 8);
    }

    /*//////////////////////////////////////////////////////////////
                                ASSET VIEW
    //////////////////////////////////////////////////////////////*/

    function test_assetViewReportsTheConfiguredAsset() public view {
        IAftermarketLens.AssetView memory v = lens.assetView(address(nvda));

        assertEq(v.asset, address(nvda));
        assertEq(v.symbol, "NVDAc");
        assertEq(v.decimals, 8);
        assertEq(v.oracle, address(oracle));
        assertTrue(v.quoteOk);
        assertEq(uint8(v.quote.verdict), uint8(0));
        assertEq(v.quote.markBorrow, MARK_180);
        assertEq(v.advanceBps, ADVANCE_OPEN_BPS);
        assertEq(v.liqThresholdBps, LIQ_THRESHOLD_OPEN_BPS);
        assertEq(v.cap, uint128(1_000_000e8));
        assertEq(v.posted, COLLATERAL);
        assertTrue(v.enabled);
        assertGt(v.borrowApr, 0);
        assertGt(v.supplyApr, 0);
        assertLt(v.supplyApr, v.borrowApr);
    }

    /// @notice While the market is shut the lens reports the closed-session risk parameters.
    function test_assetViewSwitchesToClosedSessionParameters() public {
        calendar.set(Session.CLOSED_WEEKEND, 40 hours, uint64(START_TIME + 2 days), uint64(START_TIME - 1 days));

        IAftermarketLens.AssetView memory v = lens.assetView(address(nvda));
        assertEq(v.advanceBps, 3_500);
        assertEq(v.liqThresholdBps, 8_000);
    }

    function test_assetViewSurvivesAnOracleThatRefusesEverything() public {
        _repointOracleTo(address(new DeadOracle(address(nvda), address(usdc))));

        IAftermarketLens.AssetView memory v = lens.assetView(address(nvda));
        assertFalse(v.quoteOk);
        assertEq(v.quote.markBorrow, 0);
        // Everything the engine itself knows is still reported.
        assertEq(v.symbol, "NVDAc");
        assertEq(v.posted, COLLATERAL);
        assertTrue(v.enabled);
    }

    function test_assetViewForATokenTheProtocolDoesNotAccept() public view {
        IAftermarketLens.AssetView memory v = lens.assetView(address(unlisted));

        assertEq(v.symbol, "MSFTc");
        assertEq(v.decimals, 8);
        assertEq(v.oracle, address(0));
        assertFalse(v.quoteOk);
        assertFalse(v.enabled);
        assertEq(v.cap, 0);
        assertEq(v.advanceBps, 0);
    }

    function test_assetViewForAnAddressWithNoCode() public {
        IAftermarketLens.AssetView memory v = lens.assetView(makeAddr("not a token"));

        assertEq(v.symbol, "");
        assertEq(v.decimals, 0);
        assertEq(v.oracle, address(0));
        assertFalse(v.quoteOk);
    }

    function test_assetViewsListsEveryConfiguredAsset() public view {
        IAftermarketLens.AssetView[] memory views = lens.assetViews();
        assertEq(views.length, 1);
        assertEq(views[0].asset, address(nvda));
        assertEq(lens.assets().length, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                USER VIEW
    //////////////////////////////////////////////////////////////*/

    function test_userViewReportsTheLine() public {
        _enroll(alice, 5_000e6, _policy(1_000e6, 1 hours, 12_000));

        IAftermarketLens.UserView memory v = lens.userView(alice);

        assertEq(v.user, alice);
        assertEq(v.collateral.length, 1);
        assertEq(v.collateral[0], address(nvda));
        assertEq(v.amounts[0], COLLATERAL);
        assertEq(v.debt, DRAW);
        assertEq(v.borrowPower, 9_000e6);
        assertEq(v.seizureThreshold, 12_600e6);
        assertEq(v.healthBps, 15_750);
        assertTrue(v.priced);
        assertEq(v.graceUntil, 0);
        assertEq(v.flaggedAt, 0);
        assertTrue(v.eligible);
        assertEq(v.country, bytes2("DE"));
        assertTrue(v.autoRepayEnrolled);
    }

    function test_userViewForAnAddressThatHasNeverInteracted() public {
        IAftermarketLens.UserView memory v = lens.userView(makeAddr("stranger"));

        assertEq(v.collateral.length, 0);
        assertEq(v.amounts.length, 0);
        assertEq(v.debt, 0);
        assertEq(v.borrowPower, 0);
        assertEq(v.healthBps, type(uint256).max);
        assertTrue(v.priced);
        assertFalse(v.autoRepayEnrolled);
    }

    function test_userViewSurvivesEveryOracleBeingDown() public {
        oracle.setReverting(true, true);

        IAftermarketLens.UserView memory v = lens.userView(alice);

        assertFalse(v.priced);
        assertEq(v.healthBps, 0, "an unpriced line reads zero, and `priced` says why");
        assertEq(v.borrowPower, 0);
        assertEq(v.seizureThreshold, 0);
        // The facts that do not depend on a price are still there.
        assertEq(v.debt, DRAW);
        assertEq(v.amounts[0], COLLATERAL);
        assertTrue(v.eligible);
    }

    function test_userViewSurvivesTheCalendarBeingDown() public {
        calendar.setReverting(true);

        IAftermarketLens.UserView memory v = lens.userView(alice);

        assertFalse(v.priced);
        assertEq(v.debt, 0, "debt cannot be projected without a session");
        assertEq(v.collateral[0], address(nvda));
        assertEq(v.amounts[0], COLLATERAL);
    }

    function test_userViewReportsAFlaggedLine() public {
        oracle.setMarks(MARK_90, MARK_90);
        vm.prank(keeper);
        credit.flag(alice);

        IAftermarketLens.UserView memory v = lens.userView(alice);
        assertEq(v.flaggedAt, uint64(block.timestamp));
        assertGt(v.graceUntil, block.timestamp);
    }

    function test_userViewReportsAnIneligibleAccount() public {
        eligibility.setEligible(alice, false);

        IAftermarketLens.UserView memory v = lens.userView(alice);
        assertFalse(v.eligible);
    }

    /*//////////////////////////////////////////////////////////////
                              PROTOCOL VIEW
    //////////////////////////////////////////////////////////////*/

    function test_protocolViewReportsTheMarket() public view {
        IAftermarketLens.ProtocolView memory v = lens.protocolView();

        assertEq(uint8(v.session), uint8(Session.REGULAR));
        assertEq(v.nextOpen, uint64(START_TIME + 1 days));
        assertEq(v.lastClose, uint64(START_TIME - 1 days));
        assertEq(v.totalDebt, DRAW);
        assertEq(v.totalSupplied, 1_000_000e6);
        assertEq(v.utilisation, 8e15); // 0.8%
        assertApproxEqAbs(v.vaultSharePrice, 1e6, 1);
        assertEq(v.assets.length, 1);
        assertEq(v.assets[0], address(nvda));
    }

    function test_protocolViewSurvivesTheCalendarBeingDown() public {
        calendar.setReverting(true);

        IAftermarketLens.ProtocolView memory v = lens.protocolView();

        // Closed is the conservative default: it understates borrowing power rather than inviting a
        // draw the engine would refuse.
        assertEq(uint8(v.session), uint8(Session.CLOSED_HOLIDAY));
        assertEq(v.totalDebt, 0);
        assertEq(v.totalSupplied, 0);
        assertEq(v.utilisation, 0);
        assertEq(v.vaultSharePrice, 0);
        assertEq(v.assets.length, 1);
    }

    /*//////////////////////////////////////////////////////////////
                              PREVIEW: DRAW
    //////////////////////////////////////////////////////////////*/

    function test_previewDrawAgreesWithTheEngine() public {
        IAftermarketLens.DrawPreview memory p = lens.previewDraw(alice, 500e6);

        assertTrue(p.ok);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.OK));
        assertEq(p.debtAfter, DRAW + 500e6);
        assertEq(p.borrowPower, 9_000e6);
        assertEq(p.healthBps, 12_600e6 * 10_000 / (DRAW + 500e6));

        vm.prank(alice);
        credit.draw(500e6, alice);
        assertEq(credit.debtOf(alice), p.debtAfter);
    }

    function test_previewDrawRejectsZero() public view {
        IAftermarketLens.DrawPreview memory p = lens.previewDraw(alice, 0);
        assertFalse(p.ok);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.ZERO_AMOUNT));
    }

    function test_previewDrawRejectsAnIneligibleAccount() public {
        eligibility.setEligible(alice, false);

        IAftermarketLens.DrawPreview memory p = lens.previewDraw(alice, 100e6);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.NOT_ELIGIBLE));
    }

    function test_previewDrawRejectsAnAccountWithNoLine() public view {
        IAftermarketLens.DrawPreview memory p = lens.previewDraw(bob, 100e6);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.LINE_NOT_OPEN));
    }

    function test_previewDrawRejectsAFlaggedLine() public {
        oracle.setMarks(MARK_90, MARK_90);
        vm.prank(keeper);
        credit.flag(alice);

        IAftermarketLens.DrawPreview memory p = lens.previewDraw(alice, 100e6);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.LINE_FLAGGED));
    }

    function test_previewDrawRejectsAnUnpricedLine() public {
        oracle.setReverting(true, true);

        IAftermarketLens.DrawPreview memory p = lens.previewDraw(alice, 100e6);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.UNPRICED));
        assertEq(p.healthBps, 0);

        vm.prank(alice);
        vm.expectRevert();
        credit.draw(100e6, alice);
    }

    function test_previewDrawRejectsAnUndercollateralizedDraw() public {
        IAftermarketLens.DrawPreview memory p = lens.previewDraw(alice, 5_000e6);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.UNDERCOLLATERALIZED));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAftermarketCredit.Undercollateralized.selector, DRAW + 5_000e6, 9_000e6)
        );
        credit.draw(5_000e6, alice);
    }

    function test_previewDrawRejectsADrawTheVaultCannotFund() public {
        _openAndDraw(bob, COLLATERAL, 0);
        _drainVaultTo(1_000e6);

        IAftermarketLens.DrawPreview memory p = lens.previewDraw(bob, 2_000e6);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.INSUFFICIENT_LIQUIDITY));

        vm.prank(bob);
        vm.expectRevert();
        credit.draw(2_000e6, bob);
    }

    /*//////////////////////////////////////////////////////////////
                            PREVIEW: WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_previewWithdrawAgreesWithTheEngine() public {
        IAftermarketLens.WithdrawPreview memory p = lens.previewWithdraw(alice, address(nvda), 10e8);

        assertTrue(p.ok);
        assertEq(p.borrowPowerAfter, 8_100e6);
        assertEq(p.seizureThresholdAfter, 11_340e6);
        assertEq(p.healthBps, 11_340e6 * 10_000 / DRAW);

        vm.prank(alice);
        credit.withdrawCollateral(address(nvda), 10e8, alice);
        assertEq(credit.borrowPower(alice), p.borrowPowerAfter);
        assertEq(credit.seizureThreshold(alice), p.seizureThresholdAfter);
    }

    function test_previewWithdrawRejectsZero() public view {
        IAftermarketLens.WithdrawPreview memory p = lens.previewWithdraw(alice, address(nvda), 0);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.ZERO_AMOUNT));
    }

    function test_previewWithdrawRejectsMoreThanIsPosted() public view {
        IAftermarketLens.WithdrawPreview memory p = lens.previewWithdraw(alice, address(nvda), COLLATERAL + 1);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.INSUFFICIENT_COLLATERAL));
    }

    function test_previewWithdrawRejectsAWithdrawalThatBreaksTheLine() public {
        IAftermarketLens.WithdrawPreview memory p = lens.previewWithdraw(alice, address(nvda), 50e8);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.UNDERCOLLATERALIZED));
        assertEq(p.borrowPowerAfter, 4_500e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAftermarketCredit.Undercollateralized.selector, DRAW, 4_500e6));
        credit.withdrawCollateral(address(nvda), 50e8, alice);
    }

    function test_previewWithdrawRejectsAnUnpricedLineThatStillOwes() public {
        oracle.setReverting(true, true);

        IAftermarketLens.WithdrawPreview memory p = lens.previewWithdraw(alice, address(nvda), 1e8);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.UNPRICED));
    }

    /// @notice A debt-free line may always take its collateral back, even with every oracle down.
    /// @dev This is the engine's most important asymmetry, so the lens has to reproduce it exactly:
    ///      neither a stale feed nor a change of compliance provider may hold somebody's own,
    ///      unencumbered securities hostage.
    function test_previewWithdrawAllowsADebtFreeLineWithEveryOracleDown() public {
        _openAndDraw(bob, COLLATERAL, 0);
        oracle.setReverting(true, true);

        IAftermarketLens.WithdrawPreview memory p = lens.previewWithdraw(bob, address(nvda), COLLATERAL);
        assertTrue(p.ok);
        assertEq(p.healthBps, type(uint256).max);

        vm.prank(bob);
        credit.withdrawCollateral(address(nvda), COLLATERAL, bob);
        assertEq(credit.collateral(bob, address(nvda)), 0);
    }

    /// @notice A position that could not be read at all is never mistaken for a debt-free one.
    /// @dev With the calendar down every field of the position struct is zero, which looks exactly
    ///      like "owes nothing". Waving a withdrawal through on that basis would send the user into
    ///      a transaction the engine is about to revert.
    function test_previewWithdrawDoesNotMistakeAnUnreadableLineForADebtFreeOne() public {
        calendar.setReverting(true);

        IAftermarketLens.WithdrawPreview memory p = lens.previewWithdraw(alice, address(nvda), COLLATERAL);
        assertFalse(p.ok);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.UNPRICED));
    }

    function test_previewDrawDoesNotMistakeAnUnreadableLineForAnOpenOne() public {
        calendar.setReverting(true);

        IAftermarketLens.DrawPreview memory p = lens.previewDraw(alice, 100e6);
        assertFalse(p.ok);
        assertEq(p.reason, uint8(IAftermarketLens.PreviewReason.UNPRICED));
    }

    /*//////////////////////////////////////////////////////////////
                        NOTHING BRINGS THE LENS DOWN
    //////////////////////////////////////////////////////////////*/

    /// @notice Every dependency failing at once, on every entry point.
    function test_theLensNeverRevertsWithEverythingDown() public {
        _repointOracleTo(address(new DeadOracle(address(nvda), address(usdc))));
        calendar.setReverting(true);

        lens.assetView(address(nvda));
        lens.assetView(address(unlisted));
        lens.assetView(makeAddr("not a token"));
        lens.assetViews();
        lens.userView(alice);
        lens.userView(makeAddr("stranger"));
        lens.protocolView();
        lens.previewDraw(alice, 100e6);
        lens.previewDraw(makeAddr("stranger"), 0);
        lens.previewWithdraw(alice, address(nvda), 1e8);
        lens.previewWithdraw(makeAddr("stranger"), address(unlisted), 1e8);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _repointOracleTo(address newOracle) internal {
        vm.prank(owner);
        credit.setAsset(
            address(nvda),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(newOracle),
                advanceOpenBps: ADVANCE_OPEN_BPS,
                advanceClosedBps: 3_500,
                liqThresholdOpenBps: LIQ_THRESHOLD_OPEN_BPS,
                liqThresholdClosedBps: 8_000,
                liqBonusBps: 700,
                cap: uint128(1_000_000e8),
                enabled: true
            })
        );
    }

    function _drainVaultTo(uint256 targetIdle) internal {
        uint256 idle = vault.idleAssets();
        vm.prank(supplier);
        vault.withdraw(idle - targetIdle, supplier, supplier);
        assertEq(vault.idleAssets(), targetIdle);
    }
}
