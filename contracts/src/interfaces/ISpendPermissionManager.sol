// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A spend permission for an external entity to be able to spend an account's tokens.
///
/// @dev Copied field-for-field from Coinbase's `SpendPermissionManager.SpendPermission`
///      (`lib/spend-permissions/src/SpendPermissionManager.sol`, vendored in this repository at the
///      commit `forge install coinbase/spend-permissions` pinned). It is declared here rather than
///      imported because the library's own sources reach their transitive dependencies
///      (`magicspend/`, `smart-wallet/`) through remappings that only resolve inside that project,
///      and this repository's `remappings.txt` is frozen and cannot express the context-scoped
///      entries solc would need. Redeclaring the struct is therefore the only way to compile
///      against it, and the equivalence is not taken on trust: the EIP-712 type string below hashes
///      to the exact `SPEND_PERMISSION_TYPEHASH` the deployed manager reports, which pins every
///      field name, type and order. `AutoRepayer.SPEND_PERMISSION_TYPEHASH` asserts that value and
///      `AutoRepayerTest.test_typehashMatchesDeployedManager` re-derives it from the type string.
struct SpendPermission {
    /// @dev Smart account this spend permission is valid for.
    address account;
    /// @dev Entity that can spend `account`'s tokens.
    address spender;
    /// @dev Token address (ERC-7528 native token or ERC-20 contract).
    address token;
    /// @dev Maximum allowed value to spend within each `period`.
    uint160 allowance;
    /// @dev Time duration for resetting used `allowance` on a recurring basis (seconds).
    uint48 period;
    /// @dev Timestamp this spend permission is valid starting at (inclusive, unix seconds).
    uint48 start;
    /// @dev Timestamp this spend permission is valid until (exclusive, unix seconds).
    uint48 end;
    /// @dev Arbitrary data to differentiate unique spend permissions with otherwise identical fields.
    uint256 salt;
    /// @dev Arbitrary data to attach to a spend permission which may be consumed by the `spender`.
    bytes extraData;
}

/// @notice The subset of Coinbase's `SpendPermissionManager` that Aftermarket's agent layer needs.
///
/// @dev The manager is the authority that makes an autonomous repayment agent safe to run at all.
///      A user signs one permission naming a token, a spender, a per-period allowance and a validity
///      window; the manager then enforces `used + value <= allowance` inside `spend()` as an onchain
///      invariant. No amount of keeper misbehaviour, and no bug in `AutoRepayer`'s own sizing maths,
///      can move more than the user authorised, because the cap is checked by a contract neither the
///      keeper nor this protocol controls.
///
///      Deployed at `0xf85210B21cC50302F477BA56686d2019dC9b67Ad` on Base mainnet and Base Sepolia.
///      See `AutoRepayer` for the exact onchain reads that were used to confirm that.
interface ISpendPermissionManager {
    /// @notice Period parameters and spend usage.
    struct PeriodSpend {
        /// @dev Timestamp this period starts at (inclusive, unix seconds).
        uint48 start;
        /// @dev Timestamp this period ends before (exclusive, unix seconds).
        uint48 end;
        /// @dev Accumulated spend amount for the period.
        uint160 spend;
    }

    /// @notice Spends `value` of the permission's token, moving it from `account` to `spender`.
    /// @dev Callable only by `spendPermission.spender`. Reverts when the permission is unapproved,
    ///      revoked, outside its validity window, or when `value` would exceed the remaining
    ///      allowance for the current period.
    function spend(SpendPermission memory spendPermission, uint160 value) external;

    /// @notice Whether the permission is approved and not revoked.
    function isValid(SpendPermission memory spendPermission) external view returns (bool);

    /// @notice The permission's EIP-712 hash, the manager's identity for it.
    function getHash(SpendPermission memory spendPermission) external view returns (bytes32);

    /// @notice Start, end and accumulated spend of the period covering `block.timestamp`.
    /// @dev Reverts when the permission has not started yet or has already ended, which is why every
    ///      caller in this repository wraps it.
    function getCurrentPeriod(SpendPermission memory spendPermission) external view returns (PeriodSpend memory);

    /// @notice Permanently revokes the permission, called by its spender.
    /// @dev The spender-side revocation is what lets a contract hand back an authority it was given
    ///      without needing the user to send a second transaction.
    function revokeAsSpender(SpendPermission calldata spendPermission) external;

    /// @notice EIP-712 type hash of `SpendPermission`, used here to pin the struct layout.
    function SPEND_PERMISSION_TYPEHASH() external view returns (bytes32);
}
