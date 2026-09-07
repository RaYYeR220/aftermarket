/**
 * The six states the oracle can be in, mirroring the `Verdict` enum in
 * `contracts/src/libraries/Types.sol`.
 *
 * Two of them are marks the protocol will publish. The other four are refusals,
 * and each says something different about why the price in front of you cannot
 * be defended -- which is why they are six states and not one error.
 */

export const Verdict = {
  TRUSTED: "TRUSTED",
  TRUSTED_CLOSED: "TRUSTED_CLOSED",
  UNTRUSTED_STALE: "UNTRUSTED_STALE",
  UNTRUSTED_DIVERGENT: "UNTRUSTED_DIVERGENT",
  UNTRUSTED_THIN: "UNTRUSTED_THIN",
  UNTRUSTED_HALTED: "UNTRUSTED_HALTED",
} as const;

export type Verdict = (typeof Verdict)[keyof typeof Verdict];

export function isTrusted(verdict: Verdict): boolean {
  return verdict === Verdict.TRUSTED || verdict === Verdict.TRUSTED_CLOSED;
}

/** The word this state prints as. Lower case: it is a reading, not a shout. */
export const VERDICT_WORD: Record<Verdict, string> = {
  [Verdict.TRUSTED]: "trusted, open",
  [Verdict.TRUSTED_CLOSED]: "trusted, closed",
  [Verdict.UNTRUSTED_STALE]: "stale",
  [Verdict.UNTRUSTED_DIVERGENT]: "divergent",
  [Verdict.UNTRUSTED_THIN]: "thin",
  [Verdict.UNTRUSTED_HALTED]: "halted",
};

/** What each state means for someone holding a line, in one sentence. */
export const VERDICT_MEANING: Record<Verdict, string> = {
  [Verdict.TRUSTED]: "Both sources agree and the market is open. The mark is the live price.",
  [Verdict.TRUSTED_CLOSED]:
    "Both sources still agree with the market shut. The mark holds at the last print and the advance rate drops.",
  [Verdict.UNTRUSTED_STALE]:
    "The reference feed has not printed for longer than this session allows. No mark is published.",
  [Verdict.UNTRUSTED_DIVERGENT]:
    "The feed and the pool disagree by more than this session tolerates. No mark is published.",
  [Verdict.UNTRUSTED_THIN]:
    "There is not enough depth behind the pool price to check the feed against it. No mark is published.",
  [Verdict.UNTRUSTED_HALTED]:
    "The reference feed did not answer at all. No mark is published, and nothing is liquidated.",
};
