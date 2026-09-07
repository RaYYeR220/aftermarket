// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAftermarketCredit} from "./interfaces/IAftermarketCredit.sol";

/// @title  AftermarketVault
/// @notice The supply side of Aftermarket: an ERC-4626 vault over USDC whose idle balance is the
///         only place borrowers can draw from.
///
/// @dev Three decisions are worth spelling out.
///
///      **The vault never infers a transfer.** `lend` and `settle` both name a counterparty and an
///      exact amount, and the vault performs the token movement itself. It never reads its own
///      balance before and after a call and treats the difference as a deposit. A balance-delta
///      accounting model would let anyone donate USDC to move the share price, and would let a
///      buggy credit engine silently under-repay. Because every movement is authorised explicitly,
///      `totalAssets` is always exactly "what I hold plus what I have been told is out on loan".
///
///      **Exactly one address may move money out.** `credit` is immutable and is checked against
///      the engine at construction time, so the lending path cannot be re-pointed later.
///
///      **`totalAssets` includes accrued interest.** `credit.totalDebtAssets()` projects interest to
///      `block.timestamp` without writing storage, so the share price moves continuously rather than
///      jumping whenever a keeper happens to call `accrue()`. That removes the sandwich where
///      someone deposits just before an accrual and redeems just after.
contract AftermarketVault is ERC4626, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The single credit engine allowed to draw on and repay into this vault.
    address public immutable credit;

    /// @notice Emitted when the credit engine pushes USDC out to a borrower.
    event Lent(address indexed to, uint256 assets);
    /// @notice Emitted when the credit engine settles USDC back into the vault.
    event Settled(address indexed from, uint256 assets);

    error ZeroAddress();
    error NotCredit(address caller);
    error InsufficientLiquidity(uint256 requested, uint256 idle);
    error CreditMismatch(address expected, address actual);

    /// @param asset_  The loan asset. Aftermarket ships with USDC (6 decimals).
    /// @param credit_ The credit engine. It must already point back at this vault, which is checked
    ///                here: the two contracts reference each other immutably, so the deployment
    ///                order is "predict the vault address, deploy the engine, deploy the vault" and
    ///                this check is what turns a mistake in that dance into a failed deployment
    ///                rather than a silently broken protocol.
    constructor(IERC20 asset_, address credit_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {
        if (address(asset_) == address(0) || credit_ == address(0)) revert ZeroAddress();

        address boundVault = IAftermarketCredit(credit_).vault();
        if (boundVault != address(this)) revert CreditMismatch(address(this), boundVault);

        credit = credit_;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERC-4626
    //////////////////////////////////////////////////////////////*/

    /// @notice Idle USDC plus every dollar of principal and accrued interest owed by borrowers.
    /// @dev The debt leg is read live from the engine rather than cached here. A cache would need an
    ///      update path, and an update path is a place for the two accounting systems to disagree.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + IAftermarketCredit(credit).totalDebtAssets();
    }

    /// @notice Virtual-share offset used against the classic first-depositor inflation attack.
    /// @dev USDC has 6 decimals, so an offset of 6 makes the vault behave as if it had 12: an
    ///      attacker who mints one wei-share and donates a large balance still cannot round a
    ///      subsequent depositor down to zero shares, because the virtual 1e6 shares dominate the
    ///      rounding. The donation simply becomes a gift to the pool.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice Withdrawals are bounded by idle liquidity, not by the supplier balance.
    /// @dev ERC-4626 requires `maxWithdraw` to be an amount that would actually succeed. Reporting
    ///      the full share value while borrowers hold the USDC would make integrators build
    ///      transactions that revert, so the borrowed leg is excluded here instead.
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 owned = super.maxWithdraw(owner);
        return owned < idle ? owned : idle;
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 redeemableFromIdle = _convertToShares(idle, Math.Rounding.Floor);
        uint256 owned = super.maxRedeem(owner);
        return owned < redeemableFromIdle ? owned : redeemableFromIdle;
    }

    /// @notice Closes the engine's accrual window before this vault changes its own liquidity.
    ///
    /// @dev The single most important ordering rule in the protocol, and the reason every ERC-4626
    ///      entry point below is overridden.
    ///
    ///      `AftermarketCredit._accrue` samples the borrow rate once, at the utilisation prevailing
    ///      when it is called, and applies it to the entire elapsed window - Morpho Blue's model.
    ///      Morpho gets away with it because `supply` and `withdraw` accrue *before* they touch the
    ///      market's liquidity, so the window always closes at the utilisation that actually
    ///      prevailed during it. Without that, utilisation becomes a value an attacker controls for
    ///      one block and the protocol applies backwards: deposit, call the permissionless
    ///      `accrue()`, redeem, and a month of interest on every open loan is repriced at a
    ///      utilisation that existed for a single block. The capital need not even be theirs - the
    ///      three calls are atomic and USDC flash loans are freely available - and the cheapest
    ///      version needs no capital at all, just a call to `accrue()` behind somebody else's
    ///      ordinary large deposit.
    function _accrueCredit() internal {
        IAftermarketCredit(credit).accrue();
    }

    /// @inheritdoc ERC4626
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrueCredit();
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrueCredit();
        return super.mint(shares, receiver);
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _accrueCredit();
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _accrueCredit();
        return super.redeem(shares, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                              CREDIT ENGINE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pushes `assets` of USDC to `to` on behalf of a borrower.
    /// @dev The vault does not know or care who the borrower is; solvency is the engine's job. What
    ///      the vault enforces is that it can only ever be drained down to zero idle balance, so
    ///      suppliers who got in before a draw are never handed an obligation the vault cannot meet
    ///      from tokens it actually holds.
    /// @param to     Recipient of the USDC.
    /// @param assets Amount to send, in USDC units.
    function lend(address to, uint256 assets) external nonReentrant {
        if (msg.sender != credit) revert NotCredit(msg.sender);

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) revert InsufficientLiquidity(assets, idle);

        IERC20(asset()).safeTransfer(to, assets);
        emit Lent(to, assets);
    }

    /// @notice Pulls `assets` of USDC from `from` back into the vault.
    /// @dev The pull direction is the point. The engine tells the vault "take exactly this much from
    ///      exactly this address", and the vault performs the `transferFrom` itself. A push model
    ///      would require the vault to trust a balance delta, and any stray transfer into the vault
    ///      would then be indistinguishable from a repayment.
    /// @param from   Address the USDC is taken from; in practice the credit engine, which has
    ///               already collected from the borrower, liquidator, or swap adapter.
    /// @param assets Amount to pull, in USDC units.
    function settle(address from, uint256 assets) external nonReentrant {
        if (msg.sender != credit) revert NotCredit(msg.sender);

        IERC20(asset()).safeTransferFrom(from, address(this), assets);
        emit Settled(from, assets);
    }

    /// @notice USDC sitting in the vault right now, i.e. the most that can be drawn or withdrawn.
    function idleAssets() external view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}
