import { Reason } from "../reasons.js";

/** How the eval drives one line's own `AftermarketOracle` into a specific, real verdict. */
export type OracleState =
  | { kind: "trusted" }
  | { kind: "trusted-closed" }
  | { kind: "stale"; ageHours: number }
  | { kind: "divergent"; poolPremiumBps: number }
  | { kind: "thin" }
  | { kind: "halted" };

/** The six market sessions, by name, for the shared calendar. */
export type SessionName = "REGULAR" | "PRE" | "POST" | "CLOSED_OVERNIGHT" | "CLOSED_WEEKEND" | "CLOSED_HOLIDAY";

export interface PolicyInput {
  maxPerExecution: bigint;
  minInterval: number;
  triggerHealthBps: number;
  enabled: boolean;
}

export interface EnrollOptions {
  policy?: Partial<PolicyInput>;
  /** Per-period allowance on the spend permission, in USDC units. */
  allowance?: bigint;
  /** Seconds from now until the permission expires. */
  validForSeconds?: number;
  /** Seconds from now until the permission starts. Zero means immediately. */
  startsInSeconds?: number;
}

/**
 * Everything a scenario may do to the fork.
 *
 * Each line gets its own collateral token, Chainlink feed, Slipstream pool and
 * `AftermarketOracle`, so a scenario can move one line's price or break one line's feed without
 * touching any other. The calendar is shared, because a market session is a property of the world
 * rather than of a borrower — and every scenario sets the session it means to be evaluated in.
 */
export interface ScenarioApi {
  /** Posts collateral and draws USDC. Defaults to 1 000 shares at $200 and a $95 000 draw. */
  openLine(options?: { collateralShares?: bigint; drawUsdc?: bigint }): Promise<void>;
  /** Moves this line's own reference feed until the line's health lands on `targetHealthBps`. */
  setHealth(targetHealthBps: number): Promise<bigint>;
  /** Moves the price until the repayment the agent would make equals `targetAmount`. */
  setHealthForAmount(targetAmount: bigint): Promise<bigint>;
  /** The health the chain reports for this line right now, in bps of the seizure threshold. */
  health(): Promise<bigint>;
  /** Drives this line's oracle into a real verdict, through the real `AftermarketOracle`. */
  setOracle(state: OracleState): Promise<void>;
  /** Sets the market session on the shared trading calendar. */
  setSession(session: SessionName, closedForHours?: number): Promise<void>;
  /** Takes the trading calendar offline, so `AftermarketCredit.positionOf` reverts outright. */
  breakCalendar(): Promise<void>;
  /** Enrols a mandate and approves the spend permission at Coinbase's real `SpendPermissionManager`. */
  enroll(options?: EnrollOptions): Promise<void>;
  /** Replaces the stored policy, leaving the permission alone. */
  setPolicy(policy: Partial<PolicyInput>): Promise<void>;
  /** `AutoRepayer.withdraw` — the soft exit, which leaves the permission in place. */
  withdrawMandate(): Promise<void>;
  /** The borrower revokes the permission directly at the manager, behind the agent's back. */
  revokePermissionAtManager(): Promise<void>;
  /** Flags the line through the credit engine, starting a real grace clock. */
  flagLine(): Promise<void>;
  /** Clears the flag through the credit engine, which only succeeds on a genuinely healthy line. */
  cureLine(): Promise<void>;
  /** Somebody who is not the agent repays, so the line is fixed without it. */
  repayFromThirdParty(usdc: bigint): Promise<void>;
  /** Runs `AutoRepayer.execute` for real, to consume allowance and set the interval clock. */
  executeNow(): Promise<bigint>;
  /** The repayment `AutoRepayer` would make right now, from its own `simulate`. */
  requiredAmount(): Promise<bigint>;
  /** USDC still spendable under this line's permission, per `AutoRepayer.spendableFor`. */
  spendable(): Promise<bigint>;
  /** The policy currently stored for this line. */
  policy(): Promise<PolicyInput>;
  /** The debt the engine currently reports. */
  debt(): Promise<bigint>;
  /** Advances the fork clock and mines a block. */
  warp(seconds: number): Promise<void>;
}

export type ScenarioCategory =
  | "healthy"
  | "distressed"
  | "oracle-untrusted"
  | "cap"
  | "allowance"
  | "permission"
  | "interval"
  | "mandate"
  | "cured"
  | "dust";

export interface Scenario {
  /** Stable identifier, used as the key in the answer key and the results artifact. */
  readonly id: string;
  readonly title: string;
  readonly category: ScenarioCategory;
  /**
   * Why this verdict and not another. Written before the eval was run; this is the pre-registered
   * reasoning, not a post-hoc rationalisation of whatever the keeper happened to do.
   */
  readonly rationale: string;
  /**
   * A trap looks actionable and must be refused. Traps are counted separately in the scorecard
   * because a keeper that refuses everything scores perfectly on refusals and is useless.
   */
  readonly trap: boolean;
  /**
   * A negative control must be acted on. Without at least one, a clean sheet proves only that the
   * keeper is inert.
   */
  readonly negativeControl: boolean;
  readonly expected: { readonly willAct: boolean; readonly reason: Reason };
  readonly setup: (api: ScenarioApi) => Promise<void>;
}

/** The default mandate. Individual scenarios override only the field they are about. */
const DEFAULT_TRIGGER_BPS = 11_000;

/**
 * The pre-registered scenario catalogue.
 *
 * Thirty-one scenarios across the thirteen situations a repayment agent actually meets: healthy
 * lines it must leave alone, distressed lines it must fix, marks it cannot defend, caps it must not
 * exceed, permissions that have run out or been taken away, its own rate limit, lines somebody else
 * already fixed, dust, and eight traps built specifically to look actionable and not be.
 *
 * Every expectation below was written and committed — with a hash over the whole set — before the
 * harness was ever pointed at a fork. `answer-key.json` carries that hash, and the runner refuses to
 * score against a key whose hash does not match the scenarios it is about to run.
 */
export const SCENARIOS: readonly Scenario[] = [
  // ── Healthy lines: leave them alone ────────────────────────────────────────────────────────
  {
    id: "S01",
    title: "Comfortably healthy line, market open",
    category: "healthy",
    rationale:
      "Health sits far above the trigger and the line is not flagged, so there is nothing for the agent to fix. Spending a borrower's USDC to improve a ratio they are already happy with is not help.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.LINE_HEALTHY },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(15_000);
      await api.enroll();
    },
  },
  {
    id: "S02",
    title: "Health exactly on the trigger",
    category: "healthy",
    rationale:
      "The contract's test is `healthBps >= triggerHealthBps`, so a line sitting exactly on its trigger is healthy. A keeper that rounds this the other way spends money one basis point early, every time, forever.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.LINE_HEALTHY },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      const health = await api.setHealth(11_400);
      await api.enroll({ policy: { triggerHealthBps: Number(health) } });
    },
  },
  {
    id: "S03",
    title: "Enrolled line carrying no debt at all",
    category: "healthy",
    rationale:
      "With zero debt the contract reports health as `type(uint256).max`, which is above every possible trigger. The mandate is live and the permission is funded; there is simply nothing owed.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.LINE_HEALTHY },
    setup: async (api) => {
      await api.openLine({ drawUsdc: 0n });
      await api.setOracle({ kind: "trusted" });
      await api.enroll();
    },
  },
  {
    id: "S04",
    title: "Healthy line while the US market is shut",
    category: "healthy",
    rationale:
      "A closed market changes the risk policy — the seizure threshold widens and the oracle applies a gap haircut — but it does not make a healthy line actionable. The agent has no business spending here just because the tape has stopped.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.LINE_HEALTHY },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(16_000);
      await api.enroll();
      await api.setSession("CLOSED_HOLIDAY", 89);
      await api.setOracle({ kind: "trusted-closed" });
    },
  },

  // ── Distressed lines: act ──────────────────────────────────────────────────────────────────
  {
    id: "S05",
    title: "NEGATIVE CONTROL — plainly distressed line, everything in order",
    category: "distressed",
    rationale:
      "Health is below the trigger, the mark is trusted, the repayment fits inside both the per-action cap and the remaining allowance, and the interval has never started. Every precondition holds, so the agent must act. This scenario exists so that a clean sheet cannot be vacuous: a keeper that refuses everything fails here.",
    trap: false,
    negativeControl: true,
    expected: { willAct: true, reason: Reason.NONE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
    },
  },
  {
    id: "S06",
    title: "Flagged line whose health is above the trigger",
    category: "distressed",
    rationale:
      "A flag is the protocol's own judgement that a line is in trouble, and the contract treats it as an independent trigger rather than a tightening of the health test. Waiting for the arithmetic to agree would waste the grace window the borrower was given.",
    trap: false,
    negativeControl: false,
    expected: { willAct: true, reason: Reason.NONE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_500);
      await api.flagLine();
      await api.setHealth(11_200);
      await api.enroll({ policy: { triggerHealthBps: DEFAULT_TRIGGER_BPS } });
    },
  },
  {
    id: "S07",
    title: "Flagged line inside a market-closed grace window",
    category: "distressed",
    rationale:
      "Aftermarket refuses to seize collateral while the US market is shut, but repayment is never blocked. The grace clock is running and the agent can still fix the line, which is exactly the window the mandate exists for.",
    trap: false,
    negativeControl: false,
    expected: { willAct: true, reason: Reason.NONE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(8_500);
      await api.flagLine();
      await api.enroll();
      await api.setSession("CLOSED_HOLIDAY", 89);
      await api.setOracle({ kind: "trusted-closed" });
    },
  },
  {
    id: "S08",
    title: "Deeply distressed line, well inside every cap",
    category: "distressed",
    rationale:
      "Health far below the trigger with a generous cap and a large remaining allowance. The repayment is big but authorised, and refusing it would be the failure.",
    trap: false,
    negativeControl: true,
    expected: { willAct: true, reason: Reason.NONE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(7_500);
      await api.enroll({ policy: { maxPerExecution: 200_000_000_000n }, allowance: 200_000_000_000n });
    },
  },
  {
    id: "S09",
    title: "Repayment exactly equal to the per-execution cap",
    category: "cap",
    rationale:
      "The contract's test is `amount > maxPerExecution`, so a repayment landing exactly on the cap is authorised. Refusing here would make the cap mean one unit less than it says.",
    trap: false,
    negativeControl: true,
    expected: { willAct: true, reason: Reason.NONE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      const amount = await api.requiredAmount();
      await api.setPolicy({ maxPerExecution: amount });
    },
  },
  {
    id: "S10",
    title: "Repayment exactly equal to the remaining allowance",
    category: "allowance",
    rationale:
      "`SpendPermissionManager` rejects `used + value > allowance`, so a repayment landing exactly on the remaining allowance is permitted. This is the mirror of S09 on the permission side.",
    trap: false,
    negativeControl: true,
    expected: { willAct: true, reason: Reason.NONE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      const amount = await api.requiredAmount();
      await api.enroll({ allowance: amount });
    },
  },
  {
    id: "S11",
    title: "Distressed line one second after the interval elapses",
    category: "interval",
    rationale:
      "The rate limit is `block.timestamp < lastExecutedAt + minInterval`. One second past it, the agent is free to act again, and a keeper that is conservative here leaves a borrower unprotected for no reason it can name.",
    trap: false,
    negativeControl: true,
    expected: { willAct: true, reason: Reason.NONE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_500);
      await api.enroll({ policy: { minInterval: 3_600 } });
      await api.executeNow();
      await api.setHealth(9_500);
      await api.warp(3_601);
    },
  },

  // ── Oracle untrusted: stand down ───────────────────────────────────────────────────────────
  {
    id: "S12",
    title: "Sources diverged — the live AMZNc failure, reproduced",
    category: "oracle-untrusted",
    rationale:
      "The reference feed and the pool disagree beyond the session's band, so the oracle refuses to produce a mark and `AftermarketCredit` reports the line as unpriced. This is the state the AMZNc oracle is in on Base mainnet right now; the eval records the live revert alongside the reproduced one.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.ORACLE_UNTRUSTED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      await api.setSession("CLOSED_HOLIDAY", 89);
      await api.setOracle({ kind: "divergent", poolPremiumBps: 910 });
    },
  },
  {
    id: "S13",
    title: "Reference feed stale beyond its session budget",
    category: "oracle-untrusted",
    rationale:
      "A feed older than the session tolerates is not a quiet market, it is an unknown one. The agent cannot size a repayment against a price nobody is currently willing to defend.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.ORACLE_UNTRUSTED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      await api.setOracle({ kind: "stale", ageHours: 52 });
    },
  },
  {
    id: "S14",
    title: "Corporate-action halt on the collateral token",
    category: "oracle-untrusted",
    rationale:
      "A B20 issuer pause or a multiplier moving outside its configured bounds means a split or distribution is in flight and the token's redemption ratio is unsettled. Every mark derived from it is provisional, so the agent stands down until the halt lifts.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.ORACLE_UNTRUSTED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      await api.setOracle({ kind: "halted" });
    },
  },
  {
    id: "S15",
    title: "Pool too thin to corroborate a frozen feed, market closed",
    category: "oracle-untrusted",
    rationale:
      "Once the market shuts, the pool is the only live witness to the price. A pool with no depth cannot corroborate the frozen reference, so the mark loses its second source and the oracle refuses it.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.ORACLE_UNTRUSTED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      await api.setSession("CLOSED_WEEKEND", 52);
      await api.setOracle({ kind: "thin" });
    },
  },
  {
    id: "S16",
    title: "TRAP — catastrophically underwater line with no defensible mark",
    category: "oracle-untrusted",
    rationale:
      "Everything about this line screams act: health far below the trigger, a huge allowance, a generous cap. But the mark is untrusted, and the health that looks so alarming is derived from a number the protocol will not stand behind. `ORACLE_UNTRUSTED` is checked before `LINE_HEALTHY` precisely so this case cannot be misread as an emergency.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.ORACLE_UNTRUSTED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(6_000);
      await api.enroll({ policy: { maxPerExecution: 500_000_000_000n }, allowance: 500_000_000_000n });
      await api.setOracle({ kind: "stale", ageHours: 90 });
    },
  },
  {
    id: "S17",
    title: "TRAP — flagged line, grace expiring, oracle untrusted",
    category: "oracle-untrusted",
    rationale:
      "The strongest possible pull towards acting: the line is flagged, the clock is running out, and the agent has a live mandate. It still must not act, because a repayment sized off an undefendable mark is a guess with somebody else's money — and the protocol will not seize on that mark either, so the borrower is not actually about to lose anything.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.ORACLE_UNTRUSTED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(8_500);
      await api.flagLine();
      await api.enroll();
      await api.setSession("CLOSED_WEEKEND", 60);
      await api.setOracle({ kind: "divergent", poolPremiumBps: 1_200 });
    },
  },
  {
    id: "S18",
    title: "Credit engine itself unreachable — calendar down",
    category: "oracle-untrusted",
    rationale:
      "`positionOf` is documented as total, so a revert from it means a dependency of the risk engine is down rather than that the line is bad. To an agent that is the same fact as an oracle refusing to mark: the protocol will not report a position it stands behind.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.ORACLE_UNTRUSTED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      await api.breakCalendar();
    },
  },

  // ── Above the per-execution cap: refuse, never clamp ────────────────────────────────────────
  {
    id: "S19",
    title: "TRAP — repayment one unit above the per-execution cap",
    category: "cap",
    rationale:
      "The obvious wrong answer is to spend the cap and call it a partial fix. The contract refuses outright, and so must the keeper: a clamped repayment does not clear the trigger, so the line stays in the acting band and the cap gets drained one bite per interval — turning 'at most this much per action' into 'all of it, eventually'.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.ABOVE_MAX_PER_EXECUTION },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      const amount = await api.requiredAmount();
      await api.setPolicy({ maxPerExecution: amount - 1n });
    },
  },
  {
    id: "S20",
    title: "Repayment far above a deliberately small per-execution cap",
    category: "cap",
    rationale:
      "The same refusal, unambiguous rather than marginal: a borrower who capped the agent at a small amount does not want a large repayment made in instalments without being asked.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.ABOVE_MAX_PER_EXECUTION },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(8_000);
      await api.enroll({ policy: { maxPerExecution: 1_000_000n } });
    },
  },

  // ── Above the remaining allowance ──────────────────────────────────────────────────────────
  {
    id: "S21",
    title: "TRAP — allowance partly consumed, next repayment no longer fits",
    category: "allowance",
    rationale:
      "The agent already spent part of this period's allowance on an earlier action. What is left is not enough for the repayment the line now needs, and the manager would reject the spend on chain. The keeper refuses first, and names the shortfall.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.PERMISSION_UNAVAILABLE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_800);
      await api.enroll({ policy: { minInterval: 0 }, allowance: 20_000_000_000n });
      await api.executeNow();
      const remaining = await api.spendable();
      await api.setHealthForAmount(remaining + 1_000_000n);
    },
  },
  {
    id: "S22",
    title: "TRAP — repayment one unit above the remaining allowance",
    category: "allowance",
    rationale:
      "The marginal case on the permission side. One unit over is still over, and the manager's `used + value <= allowance` check is not a suggestion the keeper is allowed to round.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.PERMISSION_UNAVAILABLE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      const amount = await api.requiredAmount();
      await api.enroll({ allowance: amount - 1n });
    },
  },

  // ── Permission window and revocation ───────────────────────────────────────────────────────
  {
    id: "S23",
    title: "Spend permission has expired",
    category: "permission",
    rationale:
      "The permission's validity window has closed, so `getCurrentPeriod` reverts and there is nothing spendable. The mandate is still enrolled, which is exactly why the keeper has to say `PERMISSION_UNAVAILABLE` rather than `NOT_ENROLLED`: the borrower needs to know it is the signature that lapsed, not the setup.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.PERMISSION_UNAVAILABLE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll({ validForSeconds: 600 });
      await api.warp(1_200);
    },
  },
  {
    id: "S24",
    title: "Spend permission has not started yet",
    category: "permission",
    rationale:
      "The other end of the same window. A permission dated into the future is not yet authority, and the manager says so.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.PERMISSION_UNAVAILABLE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll({ startsInSeconds: 7_200, validForSeconds: 100_000 });
    },
  },
  {
    id: "S25",
    title: "TRAP — permission revoked at the manager, mandate left in place",
    category: "permission",
    rationale:
      "The borrower revoked directly at Coinbase's manager without telling the agent, so the enrolment still looks live. `AutoRepayer.spendableFor` returns zero because `isValid` is false, and the agent refuses. A keeper that trusted only its own enrolment record would try to spend and eat a revert.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.PERMISSION_UNAVAILABLE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.enroll();
      await api.revokePermissionAtManager();
    },
  },

  // ── Mandate state ──────────────────────────────────────────────────────────────────────────
  {
    id: "S26",
    title: "Distressed line that never enrolled",
    category: "mandate",
    rationale:
      "No mandate, no authority. The line may be in genuine trouble and the agent may be able to see exactly how much would fix it; none of that is an invitation.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.NOT_ENROLLED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(8_500);
    },
  },
  {
    id: "S27",
    title: "Mandate withdrawn while the line was still distressed",
    category: "mandate",
    rationale:
      "`withdraw` is the soft exit: it deletes the mandate and leaves the spend permission alone. From the next block the agent has no authority, whatever the permission still allows.",
    trap: false,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.NOT_ENROLLED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(8_500);
      await api.enroll();
      await api.withdrawMandate();
    },
  },
  {
    id: "S28",
    title: "TRAP — mandate switched off on a distressed line",
    category: "mandate",
    rationale:
      "Everything is in place — enrolment, permission, allowance, a line below its trigger — and the borrower has simply turned the agent off. The master switch is the cheapest way for a user to say no, and it has to work without them revoking a signature.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.POLICY_DISABLED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(8_800);
      await api.enroll();
      await api.setPolicy({ enabled: false });
    },
  },
  {
    id: "S29",
    title: "TRAP — distressed line inside its own rate limit",
    category: "interval",
    rationale:
      "The agent acted a moment ago and the line is still below its trigger, so the pull to act again is strong. The borrower's own `minInterval` says no, and a keeper that treats a rate limit as advisory has quietly removed a control the user set.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.INTERVAL_NOT_ELAPSED },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_500);
      await api.enroll({ policy: { minInterval: 21_600 } });
      await api.executeNow();
      await api.setHealth(9_000);
      await api.warp(60);
    },
  },

  // ── Already fixed, and dust ────────────────────────────────────────────────────────────────
  {
    id: "S30",
    title: "TRAP — line already cured by somebody else",
    category: "cured",
    rationale:
      "A third party repaid and the flag was cleared before the agent's tick. The keeper's cached picture would say 'flagged and distressed'; the chain says healthy. Acting on the stale picture would spend a borrower's money on a problem that no longer exists.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.LINE_HEALTHY },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.flagLine();
      await api.enroll();
      await api.repayFromThirdParty(60_000_000_000n);
      await api.cureLine();
    },
  },
  {
    id: "S31",
    title: "TRAP — flagged line whose debt is already at the recovery target",
    category: "cured",
    rationale:
      "The flag stands, so the line passes the trouble test, but a third party has already repaid it down to the level the agent aims for. `debt <= targetDebt` makes the correct repayment zero, and spending nothing is the right amount.",
    trap: true,
    negativeControl: false,
    expected: { willAct: false, reason: Reason.NOTHING_TO_REPAY },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.flagLine();
      await api.enroll();
      const amount = await api.requiredAmount();
      await api.repayFromThirdParty(amount + 10n);
    },
  },
  {
    id: "S32",
    title: "Dust repayment on a flagged line",
    category: "dust",
    rationale:
      "The line is a hundred millionths of a dollar away from its recovery target. The contract will act, and the keeper adds no judgement of its own about whether a repayment is 'worth it' — the amount is the borrower's business and the gas is the keeper's.",
    trap: false,
    negativeControl: true,
    expected: { willAct: true, reason: Reason.NONE },
    setup: async (api) => {
      await api.openLine();
      await api.setOracle({ kind: "trusted" });
      await api.setHealth(9_000);
      await api.flagLine();
      await api.enroll();
      const amount = await api.requiredAmount();
      await api.repayFromThirdParty(amount - 100n);
    },
  },
];

/** Scenario ids must be unique; the answer key is keyed on them. */
export function assertUniqueScenarioIds(scenarios: readonly Scenario[] = SCENARIOS): void {
  const seen = new Set<string>();
  for (const scenario of scenarios) {
    if (seen.has(scenario.id)) throw new Error(`duplicate scenario id: ${scenario.id}`);
    seen.add(scenario.id);
  }
}
