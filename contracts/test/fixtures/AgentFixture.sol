// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AftermarketCredit} from "../../src/AftermarketCredit.sol";
import {AftermarketLens} from "../../src/AftermarketLens.sol";
import {AftermarketVault} from "../../src/AftermarketVault.sol";
import {AutoRepayer} from "../../src/AutoRepayer.sol";
import {ISessionRateModel, SessionRateModel} from "../../src/SessionRateModel.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketOracle} from "../../src/interfaces/IAftermarketOracle.sol";
import {IAutoRepayer} from "../../src/interfaces/IAutoRepayer.sol";
import {IEligibility} from "../../src/interfaces/IEligibility.sol";
import {ISpendPermissionManager, SpendPermission} from "../../src/interfaces/ISpendPermissionManager.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {ITradingCalendar} from "../../src/interfaces/ITradingCalendar.sol";
import {Session} from "../../src/libraries/Types.sol";

import {MockCalendar} from "../mocks/MockCalendar.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockEligibility} from "../mocks/MockEligibility.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSpendPermissionManager} from "../mocks/MockSpendPermissionManager.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";

/// @notice The full protocol plus its agent and lens, wired the way `DeployCore` wires it.
///
/// @dev Shared by `AutoRepayer.t.sol` and `AftermarketLens.t.sol` because both need a real credit
///      engine: the agent's central claim is that it stands down when the *engine* refuses to price
///      a line, and the lens's central claim is that it stays readable when the engine's strict
///      views revert. Neither claim can be tested against a stubbed engine, because the behaviour
///      under test lives in how those two contracts react to the real one.
abstract contract AgentFixture is Test {
    /// @dev Marks are Morpho-scaled: `collateralRaw * mark / 1e36 == loanRaw`. NVDAc has 8 decimals
    ///      and USDC has 6, so $180 per whole token is `180e6 * 1e36 / 1e8`.
    uint256 internal constant MARK_180 = 1.8e36;
    uint256 internal constant MARK_135 = 1.35e36;
    uint256 internal constant MARK_90 = 0.9e36;

    uint256 internal constant START_TIME = 1_800_000_000;

    uint16 internal constant ADVANCE_OPEN_BPS = 5_000;
    uint16 internal constant LIQ_THRESHOLD_OPEN_BPS = 7_000;

    /// @dev Coinbase's canonical `SpendPermissionManager`, mirrored from `AutoRepayer`.
    address internal constant SPEND_PERMISSION_MANAGER = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad;

    MockERC20 internal usdc;
    MockERC20 internal nvda;

    MockCalendar internal calendar;
    MockEligibility internal eligibility;
    MockOracle internal oracle;
    MockSwapAdapter internal adapter;
    SessionRateModel internal rateModel;

    AftermarketCredit internal credit;
    AftermarketVault internal vault;
    AutoRepayer internal repayer;
    AftermarketLens internal lens;
    MockSpendPermissionManager internal manager;

    address internal owner = makeAddr("owner");
    address internal supplier = makeAddr("supplier");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function _deployProtocol() internal {
        vm.warp(START_TIME);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvda = new MockERC20("Coinbase NVDA", "NVDAc", 8);

        calendar = new MockCalendar(Session.REGULAR, 0);
        // casting to 'uint64' is safe because START_TIME is a fixed 2027 timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        calendar.set(Session.REGULAR, 0, uint64(START_TIME + 1 days), uint64(START_TIME - 1 days));

        eligibility = new MockEligibility();
        oracle = new MockOracle(MARK_180, MARK_180);
        oracle.setTokens(address(nvda), address(usdc));
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
            100,
            owner
        );
        vault = new AftermarketVault(IERC20(address(usdc)), address(credit), "Aftermarket USDC", "amUSDC");
        require(address(vault) == predictedVault, "vault prediction");

        vm.prank(owner);
        credit.setAsset(
            address(nvda),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(oracle)),
                advanceOpenBps: ADVANCE_OPEN_BPS,
                advanceClosedBps: 3_500,
                liqThresholdOpenBps: LIQ_THRESHOLD_OPEN_BPS,
                liqThresholdClosedBps: 8_000,
                liqBonusBps: 700,
                cap: uint128(1_000_000e8),
                enabled: true
            })
        );

        // The agent's manager address is a constant, so the double is etched over it. That is
        // deliberate: it keeps the production bytecode free of a configurable manager, which is the
        // one setting that could silently void the allowance guarantee if it were wrong.
        MockSpendPermissionManager implementation = new MockSpendPermissionManager();
        vm.etch(SPEND_PERMISSION_MANAGER, address(implementation).code);
        manager = MockSpendPermissionManager(SPEND_PERMISSION_MANAGER);

        repayer = new AutoRepayer(credit);

        address[] memory assets = new address[](1);
        assets[0] = address(nvda);
        lens = new AftermarketLens(credit, repayer, assets);

        _fund(supplier, 5_000_000e6, 0);
        _fund(alice, 1_000_000e6, 10_000e8);
        _fund(bob, 1_000_000e6, 10_000e8);
        _fund(keeper, 1_000_000e6, 0);

        vm.prank(supplier);
        vault.deposit(1_000_000e6, supplier);
    }

    function _fund(address who, uint256 usdcAmount, uint256 nvdaAmount) internal {
        if (usdcAmount != 0) usdc.mint(who, usdcAmount);
        if (nvdaAmount != 0) nvda.mint(who, nvdaAmount);

        vm.startPrank(who);
        usdc.approve(address(credit), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(SPEND_PERMISSION_MANAGER, type(uint256).max);
        nvda.approve(address(credit), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Opens a line, posts `collateralAmount` raw NVDAc, and draws `drawAmount` USDC.
    function _openAndDraw(address user, uint256 collateralAmount, uint256 drawAmount) internal {
        vm.startPrank(user);
        credit.openLine();
        credit.depositCollateral(address(nvda), collateralAmount);
        if (drawAmount != 0) credit.draw(drawAmount, user);
        vm.stopPrank();
    }

    /// @dev A permission naming `account` as payer, the agent as spender, and USDC as the token.
    function _permission(address account, uint160 allowance) internal view returns (SpendPermission memory) {
        return SpendPermission({
            account: account,
            spender: address(repayer),
            token: address(usdc),
            allowance: allowance,
            // casting to 'uint48' is safe because every value below is a fixed 2027-era timestamp
            // forge-lint: disable-next-line(unsafe-typecast)
            period: uint48(30 days),
            // forge-lint: disable-next-line(unsafe-typecast)
            start: uint48(block.timestamp),
            // forge-lint: disable-next-line(unsafe-typecast)
            end: uint48(block.timestamp + 365 days),
            salt: 0,
            extraData: ""
        });
    }

    function _policy(uint128 maxPerExecution, uint32 minInterval, uint16 triggerHealthBps)
        internal
        pure
        returns (IAutoRepayer.Policy memory)
    {
        return IAutoRepayer.Policy({
            maxPerExecution: maxPerExecution,
            minInterval: minInterval,
            triggerHealthBps: triggerHealthBps,
            enabled: true
        });
    }

    /// @dev Approves a permission at the manager and enrols it, as a real user would.
    function _enroll(address account, uint160 allowance, IAutoRepayer.Policy memory policy)
        internal
        returns (SpendPermission memory permission)
    {
        permission = _permission(account, allowance);

        vm.startPrank(account);
        manager.approve(permission);
        repayer.enroll(permission, policy);
        vm.stopPrank();
    }

    /// @dev The agent is not a vault. Asserted after every path in `AutoRepayer.t.sol`.
    function _assertAgentHoldsNothing() internal view {
        assertEq(usdc.balanceOf(address(repayer)), 0, "agent holds USDC");
        assertEq(nvda.balanceOf(address(repayer)), 0, "agent holds collateral");
    }
}
