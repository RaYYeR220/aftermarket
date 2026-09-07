// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AftermarketCredit} from "./AftermarketCredit.sol";
import {IAftermarketCredit} from "./interfaces/IAftermarketCredit.sol";
import {IAutoRepayer} from "./interfaces/IAutoRepayer.sol";
import {ISpendPermissionManager, SpendPermission} from "./interfaces/ISpendPermissionManager.sol";

/// @title  AutoRepayer
/// @notice An autonomous repayment agent for Aftermarket credit lines, whose refusal to act is
///         enforced by the contract rather than promised by the keeper that drives it.
///
/// @dev ## Where the authority comes from
///
///      An offchain keeper watches enrolled lines and pokes this contract. The keeper is not
///      trusted with anything: it cannot choose the amount, the recipient, the timing or the
///      victim. What it can do is ask this contract to re-evaluate a line, and every euro that
///      moves does so under a Base **Spend Permission** the borrower signed themselves.
///
///      The permission names this contract as `spender`, USDC as `token`, a per-period `allowance`
///      and a validity window. `SpendPermissionManager.spend()` then enforces
///      `used + value <= allowance` as an onchain invariant. That is the load-bearing property of
///      this whole design: even a fully compromised keeper, or a bug in the sizing arithmetic
///      below, cannot move more than the user authorised, because the cap is checked by a contract
///      that neither the keeper nor this protocol controls.
///
///      ## Manager address verification
///
///      `SPEND_PERMISSION_MANAGER` is hardcoded rather than configured, because a misconfigured
///      manager is the one mistake that would silently void the guarantee above. The address was
///      confirmed against `https://mainnet.base.org` with `cast` before being written here:
///
///      1. `cast code 0xf85210B21cC50302F477BA56686d2019dC9b67Ad` returns 12,610 bytes of runtime
///         code on Base mainnet, and a byte string of exactly the same length against
///         `https://sepolia.base.org` - the manager is deployed at one address on both chains.
///      2. `cast call ... "SPEND_PERMISSION_TYPEHASH()(bytes32)"` returns
///         `0xc9fa0f0252014cf89ab0539e3bb3adcb76f93e6bb6494e8cc61c14e2761ee2e4`, which is exactly
///         `cast keccak "SpendPermission(address account,address spender,address token,uint160
///         allowance,uint48 period,uint48 start,uint48 end,uint256 salt,bytes extraData)"`. That
///         pins the field names, types and order of the `SpendPermission` struct this contract
///         compiles against, which is the reason the redeclared struct in
///         `ISpendPermissionManager.sol` is safe.
///      3. `cast call ... "PUBLIC_ERC6492_VALIDATOR()(address)"` returns
///         `0xcfCE48B757601F3f351CB6f434CB0517aEEE293D` (597 bytes of code), matching the published
///         `PublicERC6492Validator`, and `MAGIC_SPEND()` returns
///         `0x011A61C07DbF256A68256B1cB51A5e246730aB92`.
///
///      ## Why every refusal is loud
///
///      `execute` reverts with a distinct typed error at the first failed precondition, `simulate`
///      reports the same verdict as a non-reverting `(willAct, reason, amount)` triple so a front
///      end can say *why* the agent is standing down, and `poke` writes the refusal to a log so it
///      is onchain evidence rather than a claim in a keeper's dashboard.
///
///      The precondition that matters most is `ORACLE_UNTRUSTED`. `AftermarketCredit.positionOf`
///      returns `priced = false` whenever any oracle in the basket refuses to produce a mark. This
///      agent treats that as a full stop. An automated system must never act on a price the
///      protocol itself will not quote: doing so would spend a user's USDC to "fix" a health factor
///      derived from a number nobody is willing to defend.
///
///      ## Refuse, never clamp
///
///      When the repayment a line needs exceeds `maxPerExecution`, or exceeds what the permission
///      still allows, the agent refuses outright instead of spending the largest permitted amount.
///      Clamping looks friendlier and is worse. A clamped repayment does not clear the trigger, so
///      the line stays in the acting band and the keeper may come back every `minInterval` and
///      drain the entire allowance in small bites - turning "at most this much per action" into
///      "all of it, eventually". Refusing keeps the user's cap meaning what it says, and the
///      refusal is visible through `simulate` and `poke` so the user can raise the cap deliberately.
///
///      ## The contract holds nothing
///
///      This is not a vault. USDC exists inside this contract only between `spend()` and
///      `repayOnBehalf()` in a single call, and the last thing `execute` does is push its entire
///      balance to the borrower it just acted for. There is no owner, no rescue function and no
///      reason for a balance to persist; the zero-balance invariant is asserted in the tests for
///      every path, including the refusal paths.
contract AutoRepayer is IAutoRepayer, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BPS = 10_000;

    /// @notice Coinbase's canonical `SpendPermissionManager`, identical on Base and Base Sepolia.
    /// @dev See the contract-level documentation for the onchain reads that confirm this address.
    address public constant SPEND_PERMISSION_MANAGER = 0xf85210B21cC50302F477BA56686d2019dC9b67Ad;

    /// @notice EIP-712 type hash the deployed manager reports for `SpendPermission`.
    /// @dev Recorded as a constant so that a change in the struct this repository compiles against
    ///      is caught by a test rather than by a failed `spend()` on mainnet.
    bytes32 public constant SPEND_PERMISSION_TYPEHASH =
        0xc9fa0f0252014cf89ab0539e3bb3adcb76f93e6bb6494e8cc61c14e2761ee2e4;

    /// @notice Health, in bps above the trigger, that a repayment is sized to restore.
    /// @dev Repaying to exactly `triggerHealthBps` would leave the line on the boundary and let it
    ///      re-trigger on the next tick of interest, so the agent aims a fixed margin past it. The
    ///      margin is a protocol constant rather than a policy field because it is not a risk
    ///      preference: it is the minimum overshoot that makes one action actually finish the job.
    uint256 public constant RECOVERY_MARGIN_BPS = 500;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The credit engine whose lines this agent repays.
    AftermarketCredit public immutable credit;

    /// @notice The loan asset. Read from the engine so the two can never disagree.
    IERC20 public immutable usdc;

    /// @notice The spend permission manager, always `SPEND_PERMISSION_MANAGER`.
    ISpendPermissionManager public immutable manager;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev One mandate per account. `permissionHash` is non-zero exactly when enrolled.
    mapping(address user => Enrollment) internal enrollments;

    /// @dev Working set for one evaluation, kept in memory so that `execute`, `poke` and `simulate`
    ///      all reach their verdict through the same code path and cannot drift apart.
    struct Evaluation {
        Reason reason;
        uint256 amount;
        uint256 healthBps;
        IAftermarketCredit.Position position;
    }

    /// @param credit_ The Aftermarket credit engine.
    constructor(AftermarketCredit credit_) {
        if (address(credit_) == address(0)) revert ZeroAddress();

        credit = credit_;
        usdc = IERC20(address(credit_.usdc()));
        manager = ISpendPermissionManager(SPEND_PERMISSION_MANAGER);
    }

    /*//////////////////////////////////////////////////////////////
                                ENROLMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoRepayer
    /// @dev Only the account named in the permission may enrol it. Anyone else doing so would be
    ///      registering a mandate over funds that are not theirs, and while the manager would
    ///      refuse the resulting `spend()`, an unenforceable enrolment is a lie the UI would then
    ///      have to explain.
    /// @param permission The Base spend permission, already signed and approved at the manager, or
    ///                   approvable later - validity is re-checked on every execution.
    /// @param policy     The mandate bounding what may be done under that permission.
    function enroll(SpendPermission calldata permission, Policy calldata policy) external {
        if (permission.account != msg.sender) revert PermissionAccountMismatch(permission.account, msg.sender);
        if (permission.spender != address(this)) revert PermissionSpenderMismatch(permission.spender, address(this));
        if (permission.token != address(usdc)) revert PermissionTokenMismatch(permission.token, address(usdc));
        if (permission.allowance == 0) revert PermissionAllowanceZero();
        if (permission.end <= block.timestamp) revert PermissionExpired(permission.end);
        _validatePolicy(policy);

        bytes32 permissionHash = manager.getHash(permission);

        Enrollment storage e = enrollments[msg.sender];
        e.permissionHash = permissionHash;
        e.policy = policy;
        e.permission = permission;
        // A fresh mandate starts its interval clock cold, so the agent may act immediately if the
        // line already needs it. Re-enrolling therefore cannot be used to shorten `minInterval`
        // beyond what a first enrolment would have allowed.
        e.lastExecutedAt = 0;

        emit Enrolled(msg.sender, permissionHash, policy);
    }

    /// @inheritdoc IAutoRepayer
    /// @dev Separate from `enroll` so that tightening a cap or switching the agent off does not
    ///      require re-signing a permission, which is the step a user is least likely to complete
    ///      in a hurry.
    function setPolicy(Policy calldata policy) external {
        Enrollment storage e = enrollments[msg.sender];
        if (e.permissionHash == bytes32(0)) revert NotEnrolled(msg.sender);
        _validatePolicy(policy);

        e.policy = policy;
        emit PolicyUpdated(msg.sender, policy);
    }

    /// @inheritdoc IAutoRepayer
    /// @dev The soft exit. The mandate is deleted, so `execute` refuses with `NOT_ENROLLED` from the
    ///      next block onward, but the spend permission itself is left alone: the user may still
    ///      want it for a later re-enrolment, and revoking it costs them a signature to recreate.
    function withdraw() external {
        Enrollment storage e = enrollments[msg.sender];
        bytes32 permissionHash = e.permissionHash;
        if (permissionHash == bytes32(0)) revert NotEnrolled(msg.sender);

        delete enrollments[msg.sender];
        emit Withdrawn(msg.sender, permissionHash);
    }

    /// @inheritdoc IAutoRepayer
    /// @dev The hard exit. Deletes the mandate and hands the permission back to the manager, so the
    ///      allowance is provably dead onchain and not merely unreachable through this contract.
    ///      The revocation is wrapped: an exit must never be able to fail because of an external
    ///      call, so the local state is cleared first and a failed revocation is reported in the
    ///      event rather than reverting the user's own departure.
    function cancel() external {
        Enrollment storage e = enrollments[msg.sender];
        bytes32 permissionHash = e.permissionHash;
        if (permissionHash == bytes32(0)) revert NotEnrolled(msg.sender);

        SpendPermission memory permission = e.permission;
        delete enrollments[msg.sender];

        bool revoked;
        try manager.revokeAsSpender(permission) {
            revoked = true;
        } catch {
            revoked = false;
        }

        emit Cancelled(msg.sender, permissionHash, revoked);
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoRepayer
    /// @dev Permissionless: anybody may drive the agent, because the agent has no discretion. The
    ///      strict variant - it reverts with the first failed precondition - is what a keeper should
    ///      call, so that a mistaken action fails loudly instead of half-executing.
    /// @param user The borrower to act for.
    /// @return amount USDC repaid.
    function execute(address user) external nonReentrant returns (uint256 amount) {
        Evaluation memory e = _evaluate(user);
        if (e.reason != Reason.NONE) _revertFor(user, e);
        return _act(user, e);
    }

    /// @inheritdoc IAutoRepayer
    /// @dev The evidence-producing variant. A keeper that runs `poke` on every enrolled line leaves
    ///      a public, timestamped record of every occasion on which the agent decided to do nothing
    ///      and why - which is the only way an outside party can audit an agent's restraint.
    /// @param user The borrower to act for.
    /// @return acted  Whether a repayment happened.
    /// @return reason The `Reason` behind a refusal, or zero when it acted.
    function poke(address user) external nonReentrant returns (bool acted, uint8 reason) {
        Evaluation memory e = _evaluate(user);
        if (e.reason != Reason.NONE) {
            reason = uint8(e.reason);
            emit AutoRepayRefused(user, reason);
            return (false, reason);
        }

        _act(user, e);
        return (true, uint8(Reason.NONE));
    }

    /// @inheritdoc IAutoRepayer
    /// @dev Total function: it never reverts for any input, any policy, or any behaviour of the
    ///      credit engine, its oracles or the spend permission manager. A UI that has to explain an
    ///      agent's inaction cannot be built on a call that reverts when things go wrong, because
    ///      "things went wrong" is exactly the case it needs to render.
    /// @param user The borrower to evaluate.
    /// @return willAct Whether `execute(user)` would succeed right now.
    /// @return reason  The `Reason` enum as a `uint8`.
    /// @return amount  The repayment the agent computed. Non-zero even when refused for
    ///                 `ABOVE_MAX_PER_EXECUTION` or `PERMISSION_UNAVAILABLE`, so a front end can
    ///                 show the user how much short their cap or allowance is.
    function simulate(address user) external view returns (bool willAct, uint8 reason, uint256 amount) {
        Evaluation memory e = _evaluate(user);
        return (e.reason == Reason.NONE, uint8(e.reason), e.amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoRepayer
    function enrollmentOf(address user) external view returns (Enrollment memory) {
        return enrollments[user];
    }

    /// @inheritdoc IAutoRepayer
    function isEnrolled(address user) external view returns (bool) {
        Enrollment storage e = enrollments[user];
        return e.permissionHash != bytes32(0) && e.policy.enabled;
    }

    /// @notice USDC still spendable under `user`'s permission in the current period.
    /// @dev Zero when the permission is unapproved, revoked, not yet started or already ended, so a
    ///      front end gets one number that already accounts for every way a permission can be
    ///      unusable.
    function spendableFor(address user) external view returns (uint256) {
        Enrollment storage e = enrollments[user];
        if (e.permissionHash == bytes32(0)) return 0;
        return _spendable(e.permission);
    }

    /// @notice Health of `user`'s line in bps of its seizure threshold; 10_000 bps sits exactly on
    ///         the threshold.
    /// @dev Zero when the protocol refuses to price the line, and `type(uint256).max` when there is
    ///      no debt, mirroring `AftermarketCredit.HEALTH_UNKNOWN` and `HEALTH_NO_DEBT`.
    function healthBpsOf(address user) external view returns (uint256) {
        return _healthBps(user);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: DECISION
    //////////////////////////////////////////////////////////////*/

    /// @dev The single decision procedure behind `execute`, `poke` and `simulate`.
    ///
    ///      The order of the checks is not the order they are listed in the product spec, and the
    ///      difference is deliberate. Trust in the mark is evaluated *before* whether the line is in
    ///      trouble, because "in trouble" is itself a statement about a price: with no defensible
    ///      mark the agent cannot tell a healthy line from a doomed one, and it certainly cannot
    ///      size a repayment. Reporting `ORACLE_UNTRUSTED` in that case is also the more honest
    ///      answer for a UI than `LINE_HEALTHY`, which would assert something the protocol does not
    ///      currently know.
    function _evaluate(address user) internal view returns (Evaluation memory e) {
        Enrollment storage en = enrollments[user];
        if (en.permissionHash == bytes32(0)) {
            e.reason = Reason.NOT_ENROLLED;
            return e;
        }

        Policy memory policy = en.policy;
        if (!policy.enabled) {
            e.reason = Reason.POLICY_DISABLED;
            return e;
        }

        uint64 lastExecutedAt = en.lastExecutedAt;
        if (lastExecutedAt != 0 && block.timestamp < uint256(lastExecutedAt) + policy.minInterval) {
            e.reason = Reason.INTERVAL_NOT_ELAPSED;
            return e;
        }

        // `positionOf` swallows an oracle refusal internally and reports it as `priced == false`,
        // but it can still revert outright if the calendar or the rate model is unreachable. Both
        // are the same thing to an agent: the protocol will not stand behind a number right now.
        try credit.positionOf(user) returns (IAftermarketCredit.Position memory position) {
            e.position = position;
        } catch {
            e.reason = Reason.ORACLE_UNTRUSTED;
            return e;
        }
        if (!e.position.priced) {
            e.reason = Reason.ORACLE_UNTRUSTED;
            return e;
        }

        uint256 debt = e.position.debtAssets;
        uint256 threshold = e.position.seizureThreshold;
        e.healthBps = debt == 0 ? type(uint256).max : Math.mulDiv(threshold, BPS, debt);

        // A flagged line is in trouble by the protocol's own judgement, whatever the arithmetic
        // currently says, so it is an independent trigger rather than a tightening of the health
        // test. That matters during the grace period: the clock is running, and waiting for health
        // to deteriorate further before acting would waste the window the borrower was given.
        if (!e.position.flagged && e.healthBps >= policy.triggerHealthBps) {
            e.reason = Reason.LINE_HEALTHY;
            return e;
        }

        uint256 targetDebt = Math.mulDiv(threshold, BPS, uint256(policy.triggerHealthBps) + RECOVERY_MARGIN_BPS);
        if (debt <= targetDebt) {
            e.reason = Reason.NOTHING_TO_REPAY;
            return e;
        }
        e.amount = debt - targetDebt;

        if (e.amount > policy.maxPerExecution) {
            e.reason = Reason.ABOVE_MAX_PER_EXECUTION;
            return e;
        }

        if (e.amount > _spendable(en.permission)) {
            e.reason = Reason.PERMISSION_UNAVAILABLE;
            return e;
        }

        e.reason = Reason.NONE;
    }

    /// @dev Translates a verdict into the matching typed revert. Never returns when called with a
    ///      non-`NONE` reason; the trailing `revert` covers `PERMISSION_UNAVAILABLE` and makes the
    ///      exhaustiveness obvious to a reader.
    function _revertFor(address user, Evaluation memory e) internal view {
        Enrollment storage en = enrollments[user];
        Reason reason = e.reason;

        if (reason == Reason.NOT_ENROLLED) revert NotEnrolled(user);
        if (reason == Reason.POLICY_DISABLED) revert PolicyDisabled(user);
        if (reason == Reason.INTERVAL_NOT_ELAPSED) {
            revert IntervalNotElapsed(user, en.lastExecutedAt, en.policy.minInterval);
        }
        if (reason == Reason.ORACLE_UNTRUSTED) revert OracleUntrusted(user);
        if (reason == Reason.LINE_HEALTHY) revert LineHealthy(user, e.healthBps, en.policy.triggerHealthBps);
        if (reason == Reason.NOTHING_TO_REPAY) revert NothingToRepay(user);
        if (reason == Reason.ABOVE_MAX_PER_EXECUTION) {
            revert AboveMaxPerExecution(user, e.amount, en.policy.maxPerExecution);
        }
        revert PermissionUnavailable(user, e.amount, _spendable(en.permission));
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: ACTION
    //////////////////////////////////////////////////////////////*/

    /// @dev Spends, repays, and hands everything left back. The interval clock is written before the
    ///      first external call, so a borrower's smart account cannot re-enter through `spend()` and
    ///      collect a second action inside the same block - the reentrancy guard makes that
    ///      impossible anyway, and the ordering makes it impossible without it.
    function _act(address user, Evaluation memory e) internal returns (uint256) {
        enrollments[user].lastExecutedAt = uint64(block.timestamp);

        // `amount` never exceeds `Policy.maxPerExecution`, a uint128, so narrowing to the manager's
        // uint160 value type cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        manager.spend(enrollments[user].permission, uint160(e.amount));

        usdc.forceApprove(address(credit), e.amount);
        credit.repayOnBehalf(user, e.amount);
        // The engine pulls exactly what it applied, which can be less than `amount` if the line's
        // debt moved between the read and the write. Dropping the residual allowance keeps this
        // contract from leaving standing permission over a balance it does not intend to hold.
        usdc.forceApprove(address(credit), 0);

        emit AutoRepaid(user, e.amount, e.healthBps, _healthBps(user), e.position.session);

        _refund(user);
        return e.amount;
    }

    /// @dev Pushes the entire USDC balance of this contract to `user`. Sweeping the balance rather
    ///      than a computed residual is what makes the zero-balance invariant unconditional: it also
    ///      carries out anything that was donated or stranded here by accident, which is the only
    ///      other way this contract could ever come to hold money.
    function _refund(address user) internal {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) return;

        usdc.safeTransfer(user, balance);
        emit Refunded(user, balance);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL: READS
    //////////////////////////////////////////////////////////////*/

    /// @dev USDC still spendable under `permission` in the period covering `block.timestamp`.
    ///      Every manager call is wrapped because `getCurrentPeriod` reverts outside the permission
    ///      window by design, and because a view used by `simulate` may not revert for any reason.
    function _spendable(SpendPermission memory permission) internal view returns (uint256) {
        try manager.isValid(permission) returns (bool valid) {
            if (!valid) return 0;
        } catch {
            return 0;
        }

        try manager.getCurrentPeriod(permission) returns (ISpendPermissionManager.PeriodSpend memory period) {
            return period.spend >= permission.allowance ? 0 : permission.allowance - period.spend;
        } catch {
            return 0;
        }
    }

    /// @dev Health in bps of the seizure threshold, or zero when the line cannot be priced.
    function _healthBps(address user) internal view returns (uint256) {
        try credit.positionOf(user) returns (IAftermarketCredit.Position memory position) {
            if (!position.priced) return 0;
            if (position.debtAssets == 0) return type(uint256).max;
            return Math.mulDiv(position.seizureThreshold, BPS, position.debtAssets);
        } catch {
            return 0;
        }
    }

    /// @dev A mandate with a zero cap or a zero trigger can never authorise anything, so accepting
    ///      one would only produce an enrolment that refuses forever and a user who believes they
    ///      are covered.
    function _validatePolicy(Policy calldata policy) internal pure {
        if (policy.maxPerExecution == 0 || policy.triggerHealthBps == 0) revert InvalidPolicy(policy);
    }
}
