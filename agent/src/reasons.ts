/**
 * The agent's refusal vocabulary, mirrored from `IAutoRepayer.Reason` in
 * `contracts/src/interfaces/IAutoRepayer.sol`.
 *
 * The numbering is part of the deployed ABI: `simulate()` returns it as a `uint8` and `poke()`
 * emits it in `AutoRepayRefused`. Append, never reorder.
 */
export const Reason = {
  NONE: 0,
  NOT_ENROLLED: 1,
  POLICY_DISABLED: 2,
  INTERVAL_NOT_ELAPSED: 3,
  ORACLE_UNTRUSTED: 4,
  LINE_HEALTHY: 5,
  NOTHING_TO_REPAY: 6,
  ABOVE_MAX_PER_EXECUTION: 7,
  PERMISSION_UNAVAILABLE: 8,
} as const;
export type Reason = (typeof Reason)[keyof typeof Reason];

/** Machine-stable names for {@link Reason}, indexed by ordinal. */
export const REASON_NAMES: Record<Reason, string> = {
  [Reason.NONE]: "NONE",
  [Reason.NOT_ENROLLED]: "NOT_ENROLLED",
  [Reason.POLICY_DISABLED]: "POLICY_DISABLED",
  [Reason.INTERVAL_NOT_ELAPSED]: "INTERVAL_NOT_ELAPSED",
  [Reason.ORACLE_UNTRUSTED]: "ORACLE_UNTRUSTED",
  [Reason.LINE_HEALTHY]: "LINE_HEALTHY",
  [Reason.NOTHING_TO_REPAY]: "NOTHING_TO_REPAY",
  [Reason.ABOVE_MAX_PER_EXECUTION]: "ABOVE_MAX_PER_EXECUTION",
  [Reason.PERMISSION_UNAVAILABLE]: "PERMISSION_UNAVAILABLE",
};

/**
 * One sentence per reason, written for a human reading an audit trail rather than for a developer
 * reading a stack trace. These are the strings the HTTP endpoint and the `explain` command print,
 * so they have to stand on their own without the surrounding code.
 */
export const REASON_EXPLANATIONS: Record<Reason, string> = {
  [Reason.NONE]: "Every precondition holds. The agent will repay.",
  [Reason.NOT_ENROLLED]:
    "This account has no mandate: it has never enrolled, or it withdrew. The agent has no authority here at all.",
  [Reason.POLICY_DISABLED]:
    "The account is enrolled but has switched its mandate off. The agent stands down until the owner re-enables it.",
  [Reason.INTERVAL_NOT_ELAPSED]:
    "The agent acted for this account too recently. The account's own policy sets the minimum gap between two actions, and it has not elapsed.",
  [Reason.ORACLE_UNTRUSTED]:
    "The protocol will not produce a risk reading it stands behind, so there is no defensible mark. With no mark the agent can neither judge whether the line is in trouble nor size a repayment, so it does nothing.",
  [Reason.LINE_HEALTHY]:
    "The line is neither flagged nor below the health the account chose as its trigger. There is nothing to fix.",
  [Reason.NOTHING_TO_REPAY]:
    "The line is in the acting band, but the repayment needed to restore it computes to zero. Spending nothing is the correct amount.",
  [Reason.ABOVE_MAX_PER_EXECUTION]:
    "The repayment this line needs is larger than the per-action ceiling the account set. The agent refuses outright rather than spending the largest permitted slice, because a clamped repayment would not clear the trigger and would let the cap be drained a bite at a time.",
  [Reason.PERMISSION_UNAVAILABLE]:
    "The Base spend permission cannot fund this repayment: it is revoked, outside its validity window, or has too little allowance left in the current period. The cap is enforced by Coinbase's SpendPermissionManager, not by this keeper.",
};

/**
 * The order in which the deployed `AutoRepayer._evaluate` tests its preconditions.
 *
 * This is not the order the product brief lists them in, and the difference is load-bearing:
 * `ORACLE_UNTRUSTED` is decided *before* `LINE_HEALTHY`, because "the line is healthy" is itself a
 * claim about a price. With no mark the agent cannot tell a healthy line from a doomed one, so
 * reporting `LINE_HEALTHY` would assert something the protocol does not currently know.
 *
 * The keeper's own engine walks this array, and `checkOrder.test`-style reasoning aside, the array
 * is also what the README's reason table is generated against, so the two cannot drift.
 */
export const EVALUATION_ORDER: readonly Reason[] = [
  Reason.NOT_ENROLLED,
  Reason.POLICY_DISABLED,
  Reason.INTERVAL_NOT_ELAPSED,
  Reason.ORACLE_UNTRUSTED,
  Reason.LINE_HEALTHY,
  Reason.NOTHING_TO_REPAY,
  Reason.ABOVE_MAX_PER_EXECUTION,
  Reason.PERMISSION_UNAVAILABLE,
];

/** Narrows a `uint8` read off the chain into a {@link Reason}, or `undefined` if it is not one. */
export function toReason(value: number): Reason | undefined {
  return (Object.values(Reason) as number[]).includes(value) ? (value as Reason) : undefined;
}

/** The name of a reason, or a stable placeholder for a value this build does not know about. */
export function reasonName(value: number): string {
  const reason = toReason(value);
  return reason === undefined ? `UNKNOWN_REASON_${value}` : REASON_NAMES[reason];
}

/** The human explanation of a reason, or a stable placeholder for an unknown value. */
export function reasonExplanation(value: number): string {
  const reason = toReason(value);
  return reason === undefined
    ? `The contract returned reason code ${value}, which this build of the keeper does not recognise. It is refusing to act on a verdict it cannot read.`
    : REASON_EXPLANATIONS[reason];
}
