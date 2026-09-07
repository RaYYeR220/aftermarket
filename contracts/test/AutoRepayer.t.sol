// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAutoRepayer} from "../src/interfaces/IAutoRepayer.sol";
import {SpendPermission} from "../src/interfaces/ISpendPermissionManager.sol";
import {Session} from "../src/libraries/Types.sol";

import {AgentFixture} from "./fixtures/AgentFixture.sol";

/// @notice Tests for the agent layer, organised around the thing that makes it safe: every reason
///         it might decline to act is a separate, provable path.
///
/// @dev Three properties are asserted over and over, because they are the whole product:
///
///      1. An untrustworthy price means the agent does nothing at all. Not a smaller repayment, not
///         a best-effort guess - nothing.
///      2. A request that exceeds a user's cap or their remaining allowance is refused, never
///         quietly clamped down to what would fit.
///      3. The agent holds no balance between calls, on every path, including the failing ones.
contract AutoRepayerTest is AgentFixture {
    uint128 internal constant COLLATERAL = 100e8; // 100 NVDAc, $18,000 at the opening mark
    uint256 internal constant DRAW = 8_000e6;

    uint16 internal constant TRIGGER_BPS = 12_000;
    uint128 internal constant MAX_PER_EXECUTION = 1_000e6;
    uint160 internal constant ALLOWANCE = 5_000e6;
    uint32 internal constant MIN_INTERVAL = 1 hours;

    /// @dev At a $135 mark the line's health is 11,812 bps, so a 12,000 bps trigger fires and the
    ///      agent sizes a repayment back up to 12,500 bps: `8,000 - 9,450 * 10_000 / 12_500`.
    uint256 internal constant EXPECTED_REPAYMENT = 440e6;
    uint256 internal constant HEALTH_BEFORE_BPS = 11_812;
    uint256 internal constant HEALTH_AFTER_BPS = 12_500;

    function setUp() public {
        _deployProtocol();
        _openAndDraw(alice, COLLATERAL, DRAW);
    }

    /*//////////////////////////////////////////////////////////////
                          THE STRUCT IS THE REAL ONE
    //////////////////////////////////////////////////////////////*/

    /// @notice The redeclared `SpendPermission` is ABI-identical to the deployed manager's.
    /// @dev `AutoRepayer.SPEND_PERMISSION_TYPEHASH` is the value
    ///      `cast call 0xf85210B21cC50302F477BA56686d2019dC9b67Ad "SPEND_PERMISSION_TYPEHASH()"`
    ///      returns on Base mainnet. Re-deriving it here from the EIP-712 type string pins the field
    ///      names, types and order of the struct this repository compiles against, so a future edit
    ///      to that struct fails here rather than on a live `spend()`.
    function test_typehashMatchesDeployedManager() public view {
        assertEq(
            repayer.SPEND_PERMISSION_TYPEHASH(),
            keccak256(
                "SpendPermission(address account,address spender,address token,uint160 allowance,uint48 period,uint48 start,uint48 end,uint256 salt,bytes extraData)"
            )
        );
    }

    function test_managerIsTheCanonicalAddress() public view {
        assertEq(repayer.SPEND_PERMISSION_MANAGER(), SPEND_PERMISSION_MANAGER);
        assertEq(address(repayer.manager()), SPEND_PERMISSION_MANAGER);
    }

    /*//////////////////////////////////////////////////////////////
                                ENROLMENT
    //////////////////////////////////////////////////////////////*/

    function test_enrollStoresHashAndPolicy() public {
        SpendPermission memory permission =
            _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));

        IAutoRepayer.Enrollment memory enrollment = repayer.enrollmentOf(alice);
        assertEq(enrollment.permissionHash, manager.getHash(permission));
        assertEq(enrollment.policy.maxPerExecution, MAX_PER_EXECUTION);
        assertEq(enrollment.policy.minInterval, MIN_INTERVAL);
        assertEq(enrollment.policy.triggerHealthBps, TRIGGER_BPS);
        assertTrue(enrollment.policy.enabled);
        assertEq(enrollment.lastExecutedAt, 0);
        assertEq(enrollment.permission.account, alice);
        assertTrue(repayer.isEnrolled(alice));
        _assertAgentHoldsNothing();
    }

    function test_enrollRejectsAPermissionBelongingToSomebodyElse() public {
        SpendPermission memory permission = _permission(alice, ALLOWANCE);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAutoRepayer.PermissionAccountMismatch.selector, alice, bob));
        repayer.enroll(permission, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
    }

    function test_enrollRejectsAForeignSpender() public {
        SpendPermission memory permission = _permission(alice, ALLOWANCE);
        permission.spender = keeper;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAutoRepayer.PermissionSpenderMismatch.selector, keeper, address(repayer))
        );
        repayer.enroll(permission, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
    }

    function test_enrollRejectsATokenThatIsNotTheLoanAsset() public {
        SpendPermission memory permission = _permission(alice, ALLOWANCE);
        permission.token = address(nvda);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAutoRepayer.PermissionTokenMismatch.selector, address(nvda), address(usdc))
        );
        repayer.enroll(permission, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
    }

    function test_enrollRejectsAZeroAllowance() public {
        SpendPermission memory permission = _permission(alice, 0);

        vm.prank(alice);
        vm.expectRevert(IAutoRepayer.PermissionAllowanceZero.selector);
        repayer.enroll(permission, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
    }

    function test_enrollRejectsAnExpiredPermission() public {
        SpendPermission memory permission = _permission(alice, ALLOWANCE);
        // casting to 'uint48' is safe because the timestamp is a fixed 2027-era value
        // forge-lint: disable-next-line(unsafe-typecast)
        permission.end = uint48(block.timestamp);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAutoRepayer.PermissionExpired.selector, permission.end));
        repayer.enroll(permission, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
    }

    function test_enrollRejectsAMandateThatCouldNeverAuthoriseAnything() public {
        SpendPermission memory permission = _permission(alice, ALLOWANCE);

        IAutoRepayer.Policy memory noCap = _policy(0, MIN_INTERVAL, TRIGGER_BPS);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAutoRepayer.InvalidPolicy.selector, noCap));
        repayer.enroll(permission, noCap);

        IAutoRepayer.Policy memory noTrigger = _policy(MAX_PER_EXECUTION, MIN_INTERVAL, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAutoRepayer.InvalidPolicy.selector, noTrigger));
        repayer.enroll(permission, noTrigger);
    }

    function test_setPolicyUpdatesTheMandateWithoutANewPermission() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        bytes32 hashBefore = repayer.enrollmentOf(alice).permissionHash;

        IAutoRepayer.Policy memory tightened = _policy(1e6, 2 hours, 13_000);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(repayer));
        emit IAutoRepayer.PolicyUpdated(alice, tightened);
        repayer.setPolicy(tightened);

        IAutoRepayer.Enrollment memory enrollment = repayer.enrollmentOf(alice);
        assertEq(enrollment.permissionHash, hashBefore);
        assertEq(enrollment.policy.maxPerExecution, 1e6);
        assertEq(enrollment.policy.triggerHealthBps, 13_000);
    }

    function test_setPolicyRequiresAnEnrolment() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAutoRepayer.NotEnrolled.selector, bob));
        repayer.setPolicy(_policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
    }

    /*//////////////////////////////////////////////////////////////
                                 LEAVING
    //////////////////////////////////////////////////////////////*/

    function test_withdrawEndsTheMandateAndLeavesThePermissionAlone() public {
        SpendPermission memory permission = _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, 0, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);
        bytes32 permissionHash = manager.getHash(permission);

        vm.expectEmit(true, true, false, false, address(repayer));
        emit IAutoRepayer.Withdrawn(alice, permissionHash);
        vm.prank(alice);
        repayer.withdraw();

        assertFalse(repayer.isEnrolled(alice));
        assertEq(repayer.enrollmentOf(alice).permissionHash, bytes32(0));
        // The permission survives, ready to be re-enrolled without another signature.
        assertTrue(manager.isValid(permission));

        vm.expectRevert(abi.encodeWithSelector(IAutoRepayer.NotEnrolled.selector, alice));
        repayer.execute(alice);
        _assertAgentHoldsNothing();
    }

    function test_cancelEndsTheMandateAndHandsThePermissionBack() public {
        SpendPermission memory permission = _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, 0, TRIGGER_BPS));
        bytes32 permissionHash = manager.getHash(permission);

        vm.expectEmit(true, true, false, true, address(repayer));
        emit IAutoRepayer.Cancelled(alice, permissionHash, true);
        vm.prank(alice);
        repayer.cancel();

        assertFalse(repayer.isEnrolled(alice));
        assertFalse(manager.isValid(permission));
        _assertAgentHoldsNothing();
    }

    function test_leavingRequiresAnEnrolment() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAutoRepayer.NotEnrolled.selector, bob));
        repayer.withdraw();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAutoRepayer.NotEnrolled.selector, bob));
        repayer.cancel();
    }

    /*//////////////////////////////////////////////////////////////
                              THE HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_executeRepaysAndRestoresHealth() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        assertEq(repayer.healthBpsOf(alice), HEALTH_BEFORE_BPS);
        (bool willAct, uint8 reason, uint256 amount) = repayer.simulate(alice);
        assertTrue(willAct);
        assertEq(reason, uint8(IAutoRepayer.Reason.NONE));
        assertEq(amount, EXPECTED_REPAYMENT);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 debtBefore = credit.debtOf(alice);

        // Permissionless: a keeper with no relationship to alice drives it.
        vm.expectEmit(true, false, false, true, address(repayer));
        emit IAutoRepayer.AutoRepaid(alice, EXPECTED_REPAYMENT, HEALTH_BEFORE_BPS, HEALTH_AFTER_BPS, Session.REGULAR);
        vm.prank(keeper);
        uint256 repaid = repayer.execute(alice);

        assertEq(repaid, EXPECTED_REPAYMENT);
        assertEq(usdc.balanceOf(alice), aliceBefore - EXPECTED_REPAYMENT);
        assertEq(credit.debtOf(alice), debtBefore - EXPECTED_REPAYMENT);
        assertEq(repayer.healthBpsOf(alice), HEALTH_AFTER_BPS);
        assertEq(repayer.enrollmentOf(alice).lastExecutedAt, uint64(block.timestamp));
        assertEq(repayer.spendableFor(alice), ALLOWANCE - EXPECTED_REPAYMENT);
        _assertAgentHoldsNothing();
    }

    function test_pokeActsWhenEveryConditionHolds() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        vm.prank(keeper);
        (bool acted, uint8 reason) = repayer.poke(alice);

        assertTrue(acted);
        assertEq(reason, uint8(IAutoRepayer.Reason.NONE));
        assertEq(credit.debtOf(alice), DRAW - EXPECTED_REPAYMENT);
        _assertAgentHoldsNothing();
    }

    function test_aSecondExecutionIsAllowedOnceTheIntervalElapses() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        vm.prank(keeper);
        repayer.execute(alice);

        vm.warp(block.timestamp + MIN_INTERVAL);
        // A further slide in the mark puts the line back under the trigger.
        oracle.setMarks(1.25e36, 1.25e36);

        (bool willAct,, uint256 amount) = repayer.simulate(alice);
        assertTrue(willAct);
        assertGt(amount, 0);

        vm.prank(keeper);
        assertEq(repayer.execute(alice), amount);
        assertEq(repayer.spendableFor(alice), ALLOWANCE - EXPECTED_REPAYMENT - amount);
        _assertAgentHoldsNothing();
    }

    /*//////////////////////////////////////////////////////////////
                            EVERY REFUSAL PATH
    //////////////////////////////////////////////////////////////*/

    function test_refusesWhenTheAccountIsNotEnrolled() public {
        _expectRefusal(
            bob, IAutoRepayer.Reason.NOT_ENROLLED, abi.encodeWithSelector(IAutoRepayer.NotEnrolled.selector, bob)
        );
    }

    function test_refusesWhenTheMandateIsSwitchedOff() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        IAutoRepayer.Policy memory off = _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS);
        off.enabled = false;
        vm.prank(alice);
        repayer.setPolicy(off);

        assertFalse(repayer.isEnrolled(alice));
        _expectRefusal(
            alice,
            IAutoRepayer.Reason.POLICY_DISABLED,
            abi.encodeWithSelector(IAutoRepayer.PolicyDisabled.selector, alice)
        );
    }

    function test_refusesBeforeTheIntervalHasElapsed() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        vm.prank(keeper);
        repayer.execute(alice);

        uint64 lastExecutedAt = uint64(block.timestamp);
        vm.warp(block.timestamp + MIN_INTERVAL - 1);

        _expectRefusal(
            alice,
            IAutoRepayer.Reason.INTERVAL_NOT_ELAPSED,
            abi.encodeWithSelector(IAutoRepayer.IntervalNotElapsed.selector, alice, lastExecutedAt, MIN_INTERVAL)
        );
    }

    /// @notice The load-bearing refusal: no defensible mark means the agent does nothing.
    /// @dev Not a smaller repayment and not a cached price - nothing. Spending a user's USDC to fix
    ///      a health factor derived from a number the protocol itself will not quote is precisely
    ///      the failure mode an autonomous agent must not have.
    function test_refusesWhenTheOracleWillNotMark() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);
        oracle.setReverting(true, true);

        uint256 debtBefore = credit.debtOf(alice);
        uint256 aliceBefore = usdc.balanceOf(alice);

        (bool willAct, uint8 reason, uint256 amount) = repayer.simulate(alice);
        assertFalse(willAct);
        assertEq(reason, uint8(IAutoRepayer.Reason.ORACLE_UNTRUSTED));
        assertEq(amount, 0, "no amount may be computed from a price nobody will defend");

        vm.expectRevert(abi.encodeWithSelector(IAutoRepayer.OracleUntrusted.selector, alice));
        repayer.execute(alice);

        vm.expectEmit(true, false, false, true, address(repayer));
        emit IAutoRepayer.AutoRepayRefused(alice, uint8(IAutoRepayer.Reason.ORACLE_UNTRUSTED));
        repayer.poke(alice);

        assertEq(credit.debtOf(alice), debtBefore, "debt moved");
        assertEq(usdc.balanceOf(alice), aliceBefore, "funds moved");
        assertEq(repayer.spendableFor(alice), ALLOWANCE, "allowance consumed");
        _assertAgentHoldsNothing();
    }

    /// @notice The same refusal when the engine's read reverts outright rather than reporting
    ///         `priced == false`.
    function test_refusesWhenTheEngineCannotBeReadAtAll() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);
        calendar.setReverting(true);

        _expectRefusal(
            alice,
            IAutoRepayer.Reason.ORACLE_UNTRUSTED,
            abi.encodeWithSelector(IAutoRepayer.OracleUntrusted.selector, alice)
        );
    }

    function test_refusesWhileTheLineIsHealthy() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));

        uint256 healthBps = repayer.healthBpsOf(alice);
        assertGt(healthBps, TRIGGER_BPS);

        _expectRefusal(
            alice,
            IAutoRepayer.Reason.LINE_HEALTHY,
            abi.encodeWithSelector(IAutoRepayer.LineHealthy.selector, alice, healthBps, TRIGGER_BPS)
        );
    }

    /// @notice A flagged line the borrower has already repaid past the recovery target.
    /// @dev The only way to be in trouble and still have nothing to repay: the flag is still on -
    ///      it is cleared by `cure`, not by a partial repayment - while health is already above
    ///      `trigger + RECOVERY_MARGIN_BPS`. Spending more of the user's USDC here would achieve
    ///      nothing; what the line needs is `cure`, which is the borrower's call to make.
    function test_refusesWhenThereIsNothingLeftToRepay() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_90, MARK_90);

        vm.prank(keeper);
        credit.flag(alice);

        vm.prank(alice);
        credit.repay(5_000e6);

        assertTrue(credit.isFlagged(alice));
        assertGt(repayer.healthBpsOf(alice), TRIGGER_BPS + repayer.RECOVERY_MARGIN_BPS());

        _expectRefusal(
            alice,
            IAutoRepayer.Reason.NOTHING_TO_REPAY,
            abi.encodeWithSelector(IAutoRepayer.NothingToRepay.selector, alice)
        );
    }

    /// @notice A repayment larger than the user's per-execution cap is refused, never clamped.
    /// @dev Clamping would let the keeper come back every `minInterval` and drain the whole
    ///      allowance in bites that each individually respect the cap. Refusing keeps "at most this
    ///      much per action" meaning what the user thought it meant.
    function test_refusesAboveMaxPerExecutionRatherThanClamping() public {
        _enroll(alice, ALLOWANCE, _policy(100e6, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        uint256 debtBefore = credit.debtOf(alice);
        uint256 aliceBefore = usdc.balanceOf(alice);

        (bool willAct, uint8 reason, uint256 amount) = repayer.simulate(alice);
        assertFalse(willAct);
        assertEq(reason, uint8(IAutoRepayer.Reason.ABOVE_MAX_PER_EXECUTION));
        assertEq(amount, EXPECTED_REPAYMENT, "the shortfall is still reported so a UI can explain it");

        vm.expectRevert(
            abi.encodeWithSelector(IAutoRepayer.AboveMaxPerExecution.selector, alice, EXPECTED_REPAYMENT, 100e6)
        );
        repayer.execute(alice);

        vm.expectEmit(true, false, false, true, address(repayer));
        emit IAutoRepayer.AutoRepayRefused(alice, uint8(IAutoRepayer.Reason.ABOVE_MAX_PER_EXECUTION));
        repayer.poke(alice);

        assertEq(credit.debtOf(alice), debtBefore, "a clamped repayment slipped through");
        assertEq(usdc.balanceOf(alice), aliceBefore);
        assertEq(repayer.spendableFor(alice), ALLOWANCE);
        _assertAgentHoldsNothing();
    }

    /// @notice The same rule against the permission's remaining allowance.
    function test_refusesAbovePermissionAllowanceRatherThanClamping() public {
        _enroll(alice, 200e6, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        uint256 debtBefore = credit.debtOf(alice);

        (bool willAct, uint8 reason, uint256 amount) = repayer.simulate(alice);
        assertFalse(willAct);
        assertEq(reason, uint8(IAutoRepayer.Reason.PERMISSION_UNAVAILABLE));
        assertEq(amount, EXPECTED_REPAYMENT);

        vm.expectRevert(
            abi.encodeWithSelector(IAutoRepayer.PermissionUnavailable.selector, alice, EXPECTED_REPAYMENT, 200e6)
        );
        repayer.execute(alice);

        assertEq(credit.debtOf(alice), debtBefore, "a clamped repayment slipped through");
        _assertAgentHoldsNothing();
    }

    function test_refusesOnceThePermissionIsRevoked() public {
        SpendPermission memory permission =
            _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        vm.prank(address(repayer));
        manager.revokeAsSpender(permission);

        assertEq(repayer.spendableFor(alice), 0);
        _expectRefusal(
            alice,
            IAutoRepayer.Reason.PERMISSION_UNAVAILABLE,
            abi.encodeWithSelector(IAutoRepayer.PermissionUnavailable.selector, alice, EXPECTED_REPAYMENT, uint256(0))
        );
    }

    function test_refusesOnceThePermissionWindowHasClosed() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        vm.warp(block.timestamp + 366 days);
        assertEq(repayer.spendableFor(alice), 0);

        (bool willAct, uint8 reason, uint256 amount) = repayer.simulate(alice);
        assertFalse(willAct);
        assertEq(reason, uint8(IAutoRepayer.Reason.PERMISSION_UNAVAILABLE));
        assertGt(amount, 0);
        _assertAgentHoldsNothing();
    }

    /*//////////////////////////////////////////////////////////////
                             THE FLAG BRANCH
    //////////////////////////////////////////////////////////////*/

    /// @notice A flagged line is in trouble by the protocol's own judgement, whatever the trigger
    ///         says, because its grace clock is already running.
    function test_aflaggedLineTriggersEvenWhenHealthIsAboveTheTrigger() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_90, MARK_90);

        vm.prank(keeper);
        credit.flag(alice);

        // Set the trigger to exactly the current health, so the health test alone cannot fire and
        // only the flag can carry the decision.
        uint256 healthBps = repayer.healthBpsOf(alice);
        // casting to 'uint16' is safe because the health of this fixture line is 7,875 bps
        // forge-lint: disable-next-line(unsafe-typecast)
        IAutoRepayer.Policy memory onFlag = _policy(MAX_PER_EXECUTION, MIN_INTERVAL, uint16(healthBps));
        vm.prank(alice);
        repayer.setPolicy(onFlag);

        (bool willAct,, uint256 amount) = repayer.simulate(alice);
        assertTrue(willAct, "a flagged line must be actionable");
        assertGt(amount, 0);

        vm.prank(keeper);
        assertEq(repayer.execute(alice), amount);
        assertGt(repayer.healthBpsOf(alice), healthBps);
        _assertAgentHoldsNothing();
    }

    /*//////////////////////////////////////////////////////////////
                          THE ZERO-BALANCE INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @notice Anything stranded in the agent leaves in the next action, so it never accumulates.
    function test_donatedDustLeavesWithTheNextExecution() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setMarks(MARK_135, MARK_135);

        uint256 donation = 123e6;
        usdc.mint(address(repayer), donation);
        assertEq(usdc.balanceOf(address(repayer)), donation);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(repayer));
        emit IAutoRepayer.Refunded(alice, donation);
        vm.prank(keeper);
        repayer.execute(alice);

        assertEq(usdc.balanceOf(alice), aliceBefore - EXPECTED_REPAYMENT + donation);
        _assertAgentHoldsNothing();
    }

    /*//////////////////////////////////////////////////////////////
                        SIMULATE IS A TOTAL FUNCTION
    //////////////////////////////////////////////////////////////*/

    function test_simulateNeverRevertsForAnAddressThatHasNeverInteracted() public {
        (bool willAct, uint8 reason, uint256 amount) = repayer.simulate(makeAddr("stranger"));
        assertFalse(willAct);
        assertEq(reason, uint8(IAutoRepayer.Reason.NOT_ENROLLED));
        assertEq(amount, 0);
    }

    function test_simulateNeverRevertsWithEveryDependencyDown() public {
        _enroll(alice, ALLOWANCE, _policy(MAX_PER_EXECUTION, MIN_INTERVAL, TRIGGER_BPS));
        oracle.setReverting(true, true);
        calendar.setReverting(true);

        (bool willAct, uint8 reason,) = repayer.simulate(alice);
        assertFalse(willAct);
        assertEq(reason, uint8(IAutoRepayer.Reason.ORACLE_UNTRUSTED));
        assertEq(repayer.healthBpsOf(alice), 0);
        assertEq(repayer.spendableFor(makeAddr("stranger")), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Asserts one refusal through all three entry points at once: `simulate` reports it
    ///      without reverting, `execute` reverts with the matching typed error, and `poke` records
    ///      it onchain. Every path ends with the agent holding nothing.
    function _expectRefusal(address user, IAutoRepayer.Reason reason, bytes memory expectedError) internal {
        (bool willAct, uint8 got,) = repayer.simulate(user);
        assertFalse(willAct);
        assertEq(got, uint8(reason));

        vm.expectRevert(expectedError);
        repayer.execute(user);

        vm.expectEmit(true, false, false, true, address(repayer));
        emit IAutoRepayer.AutoRepayRefused(user, uint8(reason));
        (bool acted, uint8 pokeReason) = repayer.poke(user);
        assertFalse(acted);
        assertEq(pokeReason, uint8(reason));

        _assertAgentHoldsNothing();
    }
}
