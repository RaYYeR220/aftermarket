// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Session} from "../libraries/Types.sol";
import {SpendPermission} from "./ISpendPermissionManager.sol";

/// @notice The external surface of Aftermarket's autonomous repayment agent.
///
/// @dev Kept in its own file so a keeper, a front end and the lens can all compile against one ABI
///      that carries the full refusal vocabulary. The refusal vocabulary is the interesting part:
///      an agent that acts is unremarkable, an agent that can explain precisely why it is *not*
///      acting is what makes it safe to point at somebody's collateral.
interface IAutoRepayer {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice The user-set mandate that bounds every autonomous action taken on their behalf.
    /// @dev Deliberately four fields. Everything the keeper could otherwise decide for itself - how
    ///      much, how often, how bad it has to get - is fixed here by the account that will pay.
    struct Policy {
        /// @dev Ceiling on a single repayment, in USDC units. Zero disables enrolment entirely.
        uint128 maxPerExecution;
        /// @dev Minimum seconds between two executions for this account.
        uint32 minInterval;
        /// @dev Act once health drops below this, in bps of the seizure threshold. 10_000 bps is
        ///      exactly at the threshold, so a value above 10_000 buys a margin before seizure
        ///      becomes possible at all.
        uint16 triggerHealthBps;
        /// @dev Master switch. False means the agent stands down without the user un-enrolling.
        bool enabled;
    }

    /// @notice Everything stored about one enrolled account.
    struct Enrollment {
        /// @dev The manager's EIP-712 hash of `permission`. Non-zero exactly when enrolled.
        bytes32 permissionHash;
        /// @dev Unix seconds of the last successful `execute`, zero when it has never run.
        uint64 lastExecutedAt;
        /// @dev The mandate.
        Policy policy;
        /// @dev The full permission, kept because `spend()` takes the struct, not the hash.
        SpendPermission permission;
    }

    /// @notice Why the agent is standing down, or `NONE` when it will act.
    /// @dev Returned as a `uint8` from `simulate` and emitted by `poke` so that a refusal is onchain
    ///      evidence rather than a line in a keeper's log file. The numbering is part of the ABI;
    ///      append, never reorder.
    enum Reason {
        /// @dev 0: every precondition holds and `execute` would succeed.
        NONE,
        /// @dev 1: the account has never enrolled, or has withdrawn.
        NOT_ENROLLED,
        /// @dev 2: enrolled, but the mandate is switched off.
        POLICY_DISABLED,
        /// @dev 3: `minInterval` has not elapsed since the last execution.
        INTERVAL_NOT_ELAPSED,
        /// @dev 4: the protocol will not produce a risk reading it stands behind.
        ORACLE_UNTRUSTED,
        /// @dev 5: the line is neither flagged nor below its trigger health.
        LINE_HEALTHY,
        /// @dev 6: the repayment that would restore the line computes to zero.
        NOTHING_TO_REPAY,
        /// @dev 7: the repayment needed exceeds `maxPerExecution`. Refused, never clamped.
        ABOVE_MAX_PER_EXECUTION,
        /// @dev 8: the spend permission is revoked, outside its window, or has too little allowance
        ///         left in the current period.
        PERMISSION_UNAVAILABLE
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice An account granted the agent a mandate, or replaced an existing one.
    event Enrolled(address indexed user, bytes32 indexed permissionHash, Policy policy);

    /// @notice An enrolled account changed its mandate without re-supplying the permission.
    event PolicyUpdated(address indexed user, Policy policy);

    /// @notice An account withdrew its mandate. The spend permission itself is untouched.
    event Withdrawn(address indexed user, bytes32 indexed permissionHash);

    /// @notice An account withdrew its mandate and the agent handed the spend permission back.
    /// @param revoked Whether the manager accepted the spender-side revocation. A false value means
    ///                the user's exit still completed and they should revoke at the manager
    ///                themselves; the exit is never allowed to depend on an external call.
    event Cancelled(address indexed user, bytes32 indexed permissionHash, bool revoked);

    /// @notice The agent repaid part of a line.
    /// @param user         The borrower.
    /// @param amount       USDC spent under the permission.
    /// @param healthBefore Health in bps of the seizure threshold, before the repayment.
    /// @param healthAfter  Health in bps of the seizure threshold, after the repayment.
    /// @param session      Market session the calendar reported at the moment of the decision.
    event AutoRepaid(address indexed user, uint256 amount, uint256 healthBefore, uint256 healthAfter, Session session);

    /// @notice The agent declined to act, with the reason recorded onchain.
    event AutoRepayRefused(address indexed user, uint8 reason);

    /// @notice Dust returned to the borrower so the agent ends every call holding nothing.
    event Refunded(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error NotEnrolled(address user);
    error PolicyDisabled(address user);
    error IntervalNotElapsed(address user, uint64 lastExecutedAt, uint32 minInterval);
    error OracleUntrusted(address user);
    error LineHealthy(address user, uint256 healthBps, uint16 triggerHealthBps);
    error NothingToRepay(address user);
    error AboveMaxPerExecution(address user, uint256 amount, uint128 maxPerExecution);
    error PermissionUnavailable(address user, uint256 amount, uint256 available);

    error PermissionAccountMismatch(address account, address caller);
    error PermissionSpenderMismatch(address spender, address expected);
    error PermissionTokenMismatch(address token, address expected);
    error PermissionAllowanceZero();
    error PermissionExpired(uint48 end);
    error InvalidPolicy(Policy policy);

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Grants the agent a mandate over `permission`, bounded by `policy`.
    function enroll(SpendPermission calldata permission, Policy calldata policy) external;

    /// @notice Replaces the mandate of an already enrolled account.
    function setPolicy(Policy calldata policy) external;

    /// @notice Withdraws the caller's mandate, leaving the spend permission itself in place.
    function withdraw() external;

    /// @notice Withdraws the caller's mandate and hands the spend permission back to the manager.
    function cancel() external;

    /// @notice Repays on `user`'s behalf, reverting with a typed error at the first failed check.
    function execute(address user) external returns (uint256 amount);

    /// @notice Repays on `user`'s behalf, or emits `AutoRepayRefused` instead of reverting.
    function poke(address user) external returns (bool acted, uint8 reason);

    /// @notice What `execute(user)` would do right now. Never reverts.
    function simulate(address user) external view returns (bool willAct, uint8 reason, uint256 amount);

    /// @notice The stored mandate for `user`.
    function enrollmentOf(address user) external view returns (Enrollment memory);

    /// @notice Whether `user` has a live, enabled mandate.
    function isEnrolled(address user) external view returns (bool);
}
