// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISpendPermissionManager, SpendPermission} from "../../src/interfaces/ISpendPermissionManager.sol";

/// @notice Stand-in for Coinbase's `SpendPermissionManager`, etched over the canonical address.
///
/// @dev The real manager reaches its dependencies through remappings that only resolve inside its
///      own project, so it cannot be compiled into this repository (see `ISpendPermissionManager`).
///      This double reimplements the behaviour `AutoRepayer` actually depends on, and nothing else:
///
///      - only the named `spender` may call `spend` or `revokeAsSpender`;
///      - the permission must be approved, unrevoked, and inside `[start, end)`;
///      - `used + value <= allowance`, checked before any token moves.
///
///      The last one is the invariant the whole agent design rests on, so it is reproduced exactly
///      rather than approximated. The one simplification is that a permission here has a single
///      period covering its whole validity window instead of a rolling one; nothing in `AutoRepayer`
///      distinguishes the two, because it only ever reads the accumulated spend of the *current*
///      period, which is what `getCurrentPeriod` returns either way.
contract MockSpendPermissionManager is ISpendPermissionManager {
    /// @notice The type hash the deployed manager reports, hardcoded so the double's `getHash` is
    ///         derived the same way the real one derives it.
    bytes32 public constant SPEND_PERMISSION_TYPEHASH =
        0xc9fa0f0252014cf89ab0539e3bb3adcb76f93e6bb6494e8cc61c14e2761ee2e4;

    mapping(bytes32 hash => bool) public approved;
    mapping(bytes32 hash => bool) public revoked;
    mapping(bytes32 hash => uint160) public used;

    error InvalidSender(address sender, address expected);
    error UnauthorizedSpendPermission();
    error ExceededSpendPermission(uint256 value, uint256 allowance);
    error BeforeSpendPermissionStart(uint48 currentTimestamp, uint48 start);
    error AfterSpendPermissionEnd(uint48 currentTimestamp, uint48 end);

    /// @notice Stands in for the account-side approval, which onchain arrives as a signature.
    function approve(SpendPermission memory spendPermission) external {
        approved[getHash(spendPermission)] = true;
    }

    /// @inheritdoc ISpendPermissionManager
    function spend(SpendPermission memory spendPermission, uint160 value) external {
        if (msg.sender != spendPermission.spender) revert InvalidSender(msg.sender, spendPermission.spender);

        bytes32 hash = getHash(spendPermission);
        if (!approved[hash] || revoked[hash]) revert UnauthorizedSpendPermission();
        _requireInWindow(spendPermission);

        uint256 total = uint256(used[hash]) + value;
        if (total > spendPermission.allowance) revert ExceededSpendPermission(total, spendPermission.allowance);
        // casting to 'uint160' is safe because the line above bounds `total` by a uint160 allowance
        // forge-lint: disable-next-line(unsafe-typecast)
        used[hash] = uint160(total);

        IERC20(spendPermission.token).transferFrom(spendPermission.account, spendPermission.spender, value);
    }

    /// @inheritdoc ISpendPermissionManager
    function isValid(SpendPermission memory spendPermission) external view returns (bool) {
        bytes32 hash = getHash(spendPermission);
        return approved[hash] && !revoked[hash];
    }

    /// @inheritdoc ISpendPermissionManager
    function getCurrentPeriod(SpendPermission memory spendPermission) external view returns (PeriodSpend memory) {
        _requireInWindow(spendPermission);
        return
            PeriodSpend({start: spendPermission.start, end: spendPermission.end, spend: used[getHash(spendPermission)]});
    }

    /// @inheritdoc ISpendPermissionManager
    function revokeAsSpender(SpendPermission calldata spendPermission) external {
        if (msg.sender != spendPermission.spender) revert InvalidSender(msg.sender, spendPermission.spender);
        revoked[getHash(spendPermission)] = true;
    }

    /// @inheritdoc ISpendPermissionManager
    /// @dev The real manager wraps this in an EIP-712 domain separator. The domain is irrelevant to
    ///      everything `AutoRepayer` does with the value - it stores it, emits it and looks records
    ///      up by it - so the double hashes the same struct encoding without the domain prefix.
    function getHash(SpendPermission memory spendPermission) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SPEND_PERMISSION_TYPEHASH,
                spendPermission.account,
                spendPermission.spender,
                spendPermission.token,
                spendPermission.allowance,
                spendPermission.period,
                spendPermission.start,
                spendPermission.end,
                spendPermission.salt,
                keccak256(spendPermission.extraData)
            )
        );
    }

    function _requireInWindow(SpendPermission memory spendPermission) internal view {
        // casting to 'uint48' is safe because the manager's own window fields are uint48
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 nowTs = uint48(block.timestamp);
        if (nowTs < spendPermission.start) revert BeforeSpendPermissionStart(nowTs, spendPermission.start);
        if (nowTs >= spendPermission.end) revert AfterSpendPermissionEnd(nowTs, spendPermission.end);
    }
}
