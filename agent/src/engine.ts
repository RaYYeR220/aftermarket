import { BPS, RECOVERY_MARGIN_BPS } from "./addresses.js";
import { Reason, REASON_EXPLANATIONS } from "./reasons.js";
import type { AccountSnapshot, Decision } from "./types.js";

const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";

/** `type(uint256).max`: the sentinel `AutoRepayer` reports as the health of a line with no debt. */
const MAX_UINT256 = (1n << 256n) - 1n;

/**
 * The keeper's decision gate. It is a pure function of one {@link AccountSnapshot}, and there is no
 * model, no prompt and no language in it anywhere — the gate is code.
 *
 * That is not a stylistic preference. The value of `AutoRepayer` is that its refusals are
 * enforced by the contract rather than promised by the operator, and an off-chain component that
 * *asked something* whether to spend a user's USDC would put a non-deterministic step in front of a
 * deterministic guarantee. What this function does instead is reproduce, in TypeScript, the exact
 * eight checks `AutoRepayer._evaluate` performs in Solidity, in the exact same order, so that the
 * keeper can explain a refusal before it has spent a transaction finding out about it — and so that
 * the two implementations can be diffed against each other on every single tick.
 *
 * ## The order is the argument
 *
 * `ORACLE_UNTRUSTED` is tested *before* `LINE_HEALTHY`, and that inversion relative to how a person
 * would naturally list the checks is the whole point. "The line is healthy" is a claim about a
 * price. When the protocol refuses to produce a mark it will stand behind, the agent cannot tell a
 * healthy line from a doomed one, and it certainly cannot size a repayment — so it reports that it
 * has no mark rather than asserting a health it does not know.
 *
 * ## Arithmetic
 *
 * Every quantity is a `bigint` and every division truncates, which matches Solidity's
 * `Math.mulDiv` rounding-down exactly. Nothing here goes through `Number`; a float in a repayment
 * size is a bug waiting for a large position.
 */
export function decide(snapshot: AccountSnapshot): Decision {
  const { enrollment, position, spendable, blockTimestamp } = snapshot;
  const { policy } = enrollment;

  // 1. Enrolment. `permissionHash` is non-zero exactly when a mandate exists.
  if (enrollment.permissionHash === ZERO_HASH) {
    return refuse(Reason.NOT_ENROLLED);
  }

  // 2. The master switch on the mandate.
  if (!policy.enabled) {
    return refuse(Reason.POLICY_DISABLED);
  }

  // 3. The account's own rate limit. A never-executed enrolment starts its clock cold, so a fresh
  //    mandate may act immediately if the line already needs it.
  if (enrollment.lastExecutedAt !== 0n && blockTimestamp < enrollment.lastExecutedAt + BigInt(policy.minInterval)) {
    return refuse(Reason.INTERVAL_NOT_ELAPSED);
  }

  // 4. Trust in the mark, before any judgement that depends on one. `position === null` is the
  //    engine itself refusing to answer — the calendar or the rate model was unreachable — and
  //    `priced === false` is an oracle in the basket refusing to mark. To an agent these are the
  //    same fact: the protocol will not stand behind a number right now.
  if (position === null || !position.priced) {
    return refuse(Reason.ORACLE_UNTRUSTED);
  }

  const debt = position.debtAssets;
  const threshold = position.seizureThreshold;
  const healthBps = debt === 0n ? MAX_UINT256 : (threshold * BPS) / debt;

  // 5. Is the line actually in trouble? A flagged line is in trouble by the protocol's own
  //    judgement whatever the arithmetic says, so it is an independent trigger rather than a
  //    tightening of the health test — which matters during a grace window, where waiting for
  //    health to deteriorate further would waste the time the borrower was given.
  if (!position.flagged && healthBps >= BigInt(policy.triggerHealthBps)) {
    return refuse(Reason.LINE_HEALTHY, { healthBps });
  }

  // 6. Size the repayment: restore the line to a fixed margin past its own trigger, so one action
  //    finishes the job instead of leaving it on the boundary to re-trigger on the next tick.
  const targetDebt = (threshold * BPS) / (BigInt(policy.triggerHealthBps) + RECOVERY_MARGIN_BPS);
  if (debt <= targetDebt) {
    return refuse(Reason.NOTHING_TO_REPAY, { healthBps, targetDebt });
  }
  const amount = debt - targetDebt;

  // 7. The account's per-action ceiling. Refused outright, never clamped: a clamped repayment does
  //    not clear the trigger, so the line stays in the acting band and the cap could be drained a
  //    bite at a time. Refusing keeps "at most this much per action" meaning what it says.
  if (amount > policy.maxPerExecution) {
    return refuse(Reason.ABOVE_MAX_PER_EXECUTION, { healthBps, targetDebt, amount });
  }

  // 8. What the spend permission still allows this period. This is the one cap the keeper does not
  //    enforce and cannot subvert: `SpendPermissionManager.spend()` checks `used + value <=
  //    allowance` on chain, so the number below is a prediction of the manager's answer, not a
  //    substitute for it.
  if (amount > spendable) {
    return refuse(Reason.PERMISSION_UNAVAILABLE, { healthBps, targetDebt, amount });
  }

  return {
    willAct: true,
    reason: Reason.NONE,
    amount,
    healthBps,
    targetDebt,
    explanation: REASON_EXPLANATIONS[Reason.NONE],
  };

  function refuse(
    reason: Exclude<Reason, typeof Reason.NONE>,
    extra: { healthBps?: bigint; targetDebt?: bigint; amount?: bigint } = {},
  ): Decision {
    return {
      willAct: false,
      reason,
      amount: extra.amount ?? 0n,
      healthBps: extra.healthBps ?? null,
      targetDebt: extra.targetDebt ?? null,
      explanation: REASON_EXPLANATIONS[reason],
    };
  }
}

/**
 * Whether the keeper's engine and the contract's own `simulate()` reached the same verdict.
 *
 * They are two independent implementations of one specification, so a disagreement means one of
 * them is wrong and the keeper has no way to know which. The only safe response is to stand down
 * and say so, which is what {@link Keeper} does with this result.
 *
 * The amount is compared only when the contract says it will act. On a refusal the contract
 * deliberately reports a non-zero `amount` for `ABOVE_MAX_PER_EXECUTION` and
 * `PERMISSION_UNAVAILABLE` so a front end can show the user how far short their cap is, and the
 * keeper reproduces that — but a divergence there changes nothing about the refusal, so holding the
 * two to bit-equality on a number neither of them will spend would turn a cosmetic difference into
 * a false alarm.
 */
export function agreesWithContract(
  decision: Decision,
  contract: { willAct: boolean; reason: number; amount: bigint },
): boolean {
  if (decision.willAct !== contract.willAct) return false;
  if (decision.reason !== contract.reason) return false;
  if (contract.willAct && decision.amount !== contract.amount) return false;
  return true;
}

/** Health in bps rendered for humans; the no-debt sentinel prints as `∞` rather than a 78-digit number. */
export function formatHealthBps(healthBps: bigint | null): string {
  if (healthBps === null) return "unavailable";
  if (healthBps === MAX_UINT256) return "∞ (no debt)";
  return `${healthBps.toString()} bps`;
}

export { MAX_UINT256 };
