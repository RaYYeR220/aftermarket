// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AftermarketVault} from "../src/AftermarketVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Stand-in for the credit engine, so the vault can be tested on its own terms.
/// @dev The vault only ever asks the engine two questions - "what is your address" and "how much is
///      out on loan" - and only ever accepts two commands from it. That is a small enough surface to
///      fake exactly, which is the point of keeping it small.
contract MockCredit {
    address public vault;
    uint256 public totalDebtAssets;

    /// @dev Counts `accrue()` calls, and records the vault's idle balance at each one, so a test can
    ///      prove the vault closes the accrual window BEFORE it moves any USDC.
    uint256 public accrueCalls;
    uint256 public idleAtLastAccrual;

    function accrue() external {
        ++accrueCalls;
        idleAtLastAccrual = IERC20(AftermarketVault(vault).asset()).balanceOf(vault);
    }

    /// @dev Deploys the vault itself so the two immutable references can be wired without relying
    ///      on the test harness for address prediction: a contract's first `CREATE` is always at
    ///      nonce 1, which is derivable here and stable in every execution mode.
    function deployVault(IERC20 asset_, string memory name_, string memory symbol_)
        external
        returns (AftermarketVault deployed)
    {
        vault = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"01")))));
        deployed = new AftermarketVault(asset_, address(this), name_, symbol_);
        require(address(deployed) == vault, "vault address prediction");
    }

    function setVault(address vault_) external {
        vault = vault_;
    }

    function setTotalDebtAssets(uint256 assets) external {
        totalDebtAssets = assets;
    }

    function callLend(address to, uint256 assets) external {
        AftermarketVault(vault).lend(to, assets);
    }

    function callSettle(address from, uint256 assets) external {
        AftermarketVault(vault).settle(from, assets);
    }

    function approveVault(IERC20 token) external {
        token.approve(vault, type(uint256).max);
    }
}

contract AftermarketVaultTest is Test {
    MockERC20 internal usdc;
    MockCredit internal credit;
    AftermarketVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        credit = new MockCredit();

        vault = credit.deployVault(IERC20(address(usdc)), "Aftermarket USDC", "amUSDC");
        credit.approveVault(IERC20(address(usdc)));

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(attacker, 1_000_000e6);
        usdc.mint(address(credit), 1_000_000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                 WIRING
    //////////////////////////////////////////////////////////////*/

    function test_constructor_rejectsCreditPointingElsewhere() public {
        MockCredit stray = new MockCredit();
        stray.setVault(address(0xdead));

        vm.expectRevert();
        new AftermarketVault(IERC20(address(usdc)), address(stray), "x", "x");
    }

    function test_decimals_matchAssetPlusOffset() public view {
        assertEq(vault.decimals(), 12, "6 asset decimals + 6 offset");
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.credit(), address(credit));
    }

    /*//////////////////////////////////////////////////////////////
                              ROUND TRIPS
    //////////////////////////////////////////////////////////////*/

    function test_depositWithdrawRoundTrip() public {
        uint256 amount = 250_000e6;

        vm.startPrank(alice);
        uint256 shares = vault.deposit(amount, alice);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), amount);
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - amount);

        uint256 burned = vault.withdraw(amount, alice, alice);
        vm.stopPrank();

        assertEq(burned, shares, "withdraw burns exactly the deposit shares");
        assertEq(vault.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 1_000_000e6);
    }

    function test_mintRedeemRoundTrip() public {
        uint256 shares = 100_000e12;

        vm.startPrank(alice);
        uint256 paid = vault.mint(shares, alice);
        assertEq(vault.balanceOf(alice), shares);

        uint256 got = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertLe(got, paid, "redeeming immediately never yields more than was paid");
        assertGe(got + 2, paid, "and rounding costs at most a couple of wei");
    }

    /*//////////////////////////////////////////////////////////////
                          ACCOUNTING WITH DEBT
    //////////////////////////////////////////////////////////////*/

    function test_totalAssets_includesOutstandingDebt() public {
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        vm.prank(address(credit));
        vault.lend(bob, 40_000e6);
        credit.setTotalDebtAssets(40_000e6);

        assertEq(usdc.balanceOf(address(vault)), 60_000e6);
        assertEq(vault.idleAssets(), 60_000e6);
        assertEq(vault.totalAssets(), 100_000e6, "idle plus loans out");
    }

    /// @notice A-13 regression. Every ERC-4626 entry point closes the engine's accrual window
    ///         BEFORE it moves a single USDC. Without that ordering the engine samples the borrow
    ///         rate at a utilisation an attacker controls for one block and applies it backwards
    ///         over the whole elapsed window, so a deposit-accrue-redeem round trip - flash-loanable,
    ///         or simply backrun onto somebody else's deposit - reprices a month of interest.
    function test_everyLiquidityChangeAccruesBeforeItMovesMoney() public {
        vm.prank(alice);
        vault.deposit(100_000e6, alice);
        assertEq(credit.accrueCalls(), 1, "deposit accrues");
        assertEq(credit.idleAtLastAccrual(), 0, "and does it before the money lands");

        vm.prank(alice);
        vault.mint(1_000e12, alice);
        assertEq(credit.accrueCalls(), 2, "mint accrues");
        assertEq(credit.idleAtLastAccrual(), 100_000e6, "before the money lands");

        uint256 idleBeforeWithdraw = vault.idleAssets();
        vm.prank(alice);
        vault.withdraw(1_000e6, alice, alice);
        assertEq(credit.accrueCalls(), 3, "withdraw accrues");
        assertEq(credit.idleAtLastAccrual(), idleBeforeWithdraw, "before the money leaves");

        uint256 idleBeforeRedeem = vault.idleAssets();
        vm.prank(alice);
        vault.redeem(1_000e12, alice, alice);
        assertEq(credit.accrueCalls(), 4, "redeem accrues");
        assertEq(credit.idleAtLastAccrual(), idleBeforeRedeem, "before the money leaves");
    }

    function test_sharePriceRisesWithAccruedInterest() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100_000e6, alice);

        uint256 before = vault.convertToAssets(shares);

        vm.prank(address(credit));
        vault.lend(bob, 50_000e6);
        credit.setTotalDebtAssets(50_000e6);
        assertEq(vault.convertToAssets(shares), before, "lending alone moves no value");

        credit.setTotalDebtAssets(55_000e6);
        assertGt(vault.convertToAssets(shares), before, "accrued interest lifts the share price");
        assertApproxEqAbs(vault.convertToAssets(shares), 105_000e6, 2);
    }

    /*//////////////////////////////////////////////////////////////
                             LEND / SETTLE
    //////////////////////////////////////////////////////////////*/

    function test_lend_onlyCredit() public {
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        vm.expectRevert(abi.encodeWithSelector(AftermarketVault.NotCredit.selector, alice));
        vm.prank(alice);
        vault.lend(alice, 1e6);
    }

    function test_settle_onlyCredit() public {
        vm.expectRevert(abi.encodeWithSelector(AftermarketVault.NotCredit.selector, alice));
        vm.prank(alice);
        vault.settle(alice, 1e6);
    }

    function test_lend_revertsBeyondIdleLiquidity() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        vm.expectRevert(abi.encodeWithSelector(AftermarketVault.InsufficientLiquidity.selector, 10_001e6, 10_000e6));
        credit.callLend(bob, 10_001e6);

        credit.callLend(bob, 10_000e6);
        assertEq(usdc.balanceOf(bob), 1_000_000e6 + 10_000e6);
    }

    function test_settle_pullsExactlyWhatItWasTold() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        credit.callLend(bob, 4_000e6);
        credit.setTotalDebtAssets(4_000e6);

        uint256 creditBalanceBefore = usdc.balanceOf(address(credit));
        credit.callSettle(address(credit), 4_000e6);
        credit.setTotalDebtAssets(0);

        assertEq(usdc.balanceOf(address(credit)), creditBalanceBefore - 4_000e6);
        assertEq(vault.idleAssets(), 10_000e6);
        assertEq(vault.totalAssets(), 10_000e6);
    }

    /// @dev A stray transfer into the vault is a gift, never a repayment: the vault's own record of
    ///      what is on loan does not move, so nobody can rewrite the debt ledger with an ERC20
    ///      transfer.
    function test_donationIsNotMistakenForRepayment() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        credit.callLend(bob, 4_000e6);
        credit.setTotalDebtAssets(4_000e6);

        vm.prank(bob);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(vault), 1_000e6);

        assertEq(credit.totalDebtAssets(), 4_000e6, "debt untouched by a raw transfer");
        assertEq(vault.totalAssets(), 11_000e6, "the donation simply accrues to suppliers");
    }

    /*//////////////////////////////////////////////////////////////
                             LIQUIDITY LIMITS
    //////////////////////////////////////////////////////////////*/

    function test_maxWithdrawAndMaxRedeemBoundedByIdle() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100_000e6, alice);

        credit.callLend(bob, 90_000e6);
        credit.setTotalDebtAssets(90_000e6);

        assertEq(vault.maxWithdraw(alice), 10_000e6, "cannot withdraw what is on loan");
        assertLt(vault.maxRedeem(alice), shares);

        vm.expectRevert();
        vm.prank(alice);
        vault.withdraw(20_000e6, alice, alice);

        vm.prank(alice);
        vault.withdraw(10_000e6, alice, alice);
        assertEq(vault.idleAssets(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            INFLATION ATTACK
    //////////////////////////////////////////////////////////////*/

    /// @dev The classic first-depositor attack: mint one wei of shares, donate a large balance, and
    ///      hope the next depositor rounds down to zero shares. With a decimals offset of 6 the
    ///      virtual shares dominate the rounding, so the victim keeps essentially all of their money
    ///      and the attacker's donation is simply lost to the pool.
    function test_firstDepositorInflationAttackFails() public {
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(1, attacker);
        assertGt(attackerShares, 0);

        vm.prank(attacker);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(vault), 10_000e6);

        vm.prank(alice);
        uint256 victimShares = vault.deposit(10_000e6, alice);
        assertGt(victimShares, 0, "victim is not rounded down to zero shares");

        vm.prank(alice);
        uint256 recovered = vault.redeem(victimShares, alice, alice);
        assertGe(recovered, 9_990e6, "victim recovers at least 99.9% of the deposit");

        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);
        assertLt(attackerOut, 10_000e6 + 1, "the attack costs the attacker money");
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_depositThenRedeemNeverMintsValue(uint256 assets) public {
        assets = bound(assets, 1, 500_000e6);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(assets, alice);
        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertLe(out, assets, "a round trip can never create assets");
    }

    function testFuzz_previewsMatchExecution(uint256 assets) public {
        assets = bound(assets, 1e6, 500_000e6);

        uint256 predicted = vault.previewDeposit(assets);
        vm.prank(alice);
        uint256 actual = vault.deposit(assets, alice);
        assertEq(actual, predicted, "previewDeposit is exact");

        uint256 predictedOut = vault.previewRedeem(actual);
        vm.prank(alice);
        uint256 actualOut = vault.redeem(actual, alice, alice);
        assertEq(actualOut, predictedOut, "previewRedeem is exact");
    }
}
