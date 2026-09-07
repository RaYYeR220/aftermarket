import type { Address, Hex } from "viem";
import type { Session, Verdict } from "@aftermarket/session-oracle";
import type { Reason } from "./reasons.js";

/** `IAutoRepayer.Policy`: the mandate an account sets over its own money. */
export interface Policy {
  readonly maxPerExecution: bigint;
  readonly minInterval: number;
  readonly triggerHealthBps: number;
  readonly enabled: boolean;
}

/** Coinbase's `SpendPermission`, as stored on the enrolment. */
export interface SpendPermission {
  readonly account: Address;
  readonly spender: Address;
  readonly token: Address;
  readonly allowance: bigint;
  readonly period: number;
  readonly start: number;
  readonly end: number;
  readonly salt: bigint;
  readonly extraData: Hex;
}

/** `IAutoRepayer.Enrollment`. `permissionHash` is non-zero exactly when enrolled. */
export interface Enrollment {
  readonly permissionHash: Hex;
  readonly lastExecutedAt: bigint;
  readonly policy: Policy;
  readonly permission: SpendPermission;
}

/** `IAftermarketCredit.Position`, plus the derived health the engine actually reasons about. */
export interface Position {
  readonly debtAssets: bigint;
  readonly debtShares: bigint;
  readonly borrowPower: bigint;
  readonly seizureThreshold: bigint;
  readonly healthFactor: bigint;
  readonly priced: boolean;
  readonly flagged: boolean;
  readonly openedAt: bigint;
  readonly flaggedAt: bigint;
  readonly graceUntil: bigint;
  readonly autoRepayEnabled: boolean;
  readonly session: Session;
}

/**
 * One collateral asset's oracle state as the keeper saw it, so a refusal can name the feed that
 * caused it rather than saying "unpriced" and stopping there.
 */
export interface OracleSnapshot {
  readonly asset: Address;
  readonly symbol: string;
  readonly oracle: Address;
  /** False when the oracle did not answer `peek()` at all. */
  readonly quoteOk: boolean;
  readonly verdict: Verdict | null;
  readonly session: Session | null;
  readonly divergenceBps: bigint | null;
  readonly divergenceBand: bigint | null;
  readonly feedAge: bigint | null;
  readonly stalenessBudget: bigint | null;
  readonly poolLiquidityUsd: bigint | null;
  readonly multiplier: bigint | null;
  /** Plain-English rendering of `verdict`, from `@aftermarket/session-oracle`. */
  readonly explanation: string | null;
  /**
   * The typed revert `price()` produced, decoded by `@aftermarket/session-oracle`. Present only
   * when the mark is untrusted — this is the sentence the whole product is about.
   */
  readonly priceError: string | null;
}

/**
 * Everything one tick read for one account, before any judgement is applied.
 *
 * The type is deliberately total: an oracle that will not answer shows up as `position === null`
 * and a set of {@link OracleSnapshot}s that say why, never as a zeroed position.
 */
export interface AccountSnapshot {
  readonly account: Address;
  readonly blockNumber: bigint;
  readonly blockTimestamp: bigint;
  readonly enrollment: Enrollment;
  /** `null` when `AftermarketCredit.positionOf` itself reverted — calendar or rate model unreachable. */
  readonly position: Position | null;
  /** USDC still spendable under the permission this period, as `AutoRepayer.spendableFor` reports it. */
  readonly spendable: bigint;
  readonly oracles: readonly OracleSnapshot[];
}

/** The engine's verdict for one account: what it decided, and everything it needed to decide it. */
export interface Decision {
  readonly willAct: boolean;
  readonly reason: Reason;
  readonly amount: bigint;
  /** Health in bps of the seizure threshold; `null` when the line cannot be priced. */
  readonly healthBps: bigint | null;
  /** Debt the repayment would restore the line to; `null` when it was never computed. */
  readonly targetDebt: bigint | null;
  readonly explanation: string;
}

/** What the deployed contract's own `simulate()` said, for the cross-check. */
export interface ContractSimulation {
  readonly willAct: boolean;
  readonly reason: number;
  readonly amount: bigint;
}

/** What the keeper did about a verdict. */
export type ActionKind = "none" | "execute" | "poke";

export interface ActionOutcome {
  readonly kind: ActionKind;
  readonly sent: boolean;
  readonly txHash: Hex | null;
  readonly repaid: bigint | null;
  readonly note: string;
}

/**
 * The status of a decision record, which is the field a dashboard filters on.
 *
 * `engine-mismatch` is the interesting one. The keeper's own rule engine and the contract's
 * `simulate()` are two independent implementations of the same eight checks, and when they disagree
 * the keeper does not pick a winner: it stands down and records the disagreement, because a keeper
 * that resolves a mismatch in favour of acting is a keeper with discretion.
 */
export type DecisionStatus = "acted" | "refused" | "would-act" | "unavailable" | "engine-mismatch" | "failed";

/** One line of the JSONL audit trail. Everything is JSON-native; `bigint`s are decimal strings. */
export interface DecisionRecord {
  readonly schema: "aftermarket.keeper.decision/1";
  readonly timestamp: string;
  readonly chainId: number;
  readonly blockNumber: string | null;
  readonly blockTimestamp: string | null;
  readonly account: Address;
  readonly status: DecisionStatus;
  readonly reason: number | null;
  readonly reasonName: string;
  readonly explanation: string;
  readonly inputs: DecisionInputs;
  readonly contract: { willAct: boolean; reason: number; reasonName: string; amount: string } | null;
  readonly action: { kind: ActionKind; sent: boolean; txHash: Hex | null; repaid: string | null; note: string };
  readonly dryRun: boolean;
}

/** The inputs a reader needs to check the verdict by hand. */
export interface DecisionInputs {
  readonly enrolled: boolean;
  readonly policyEnabled: boolean | null;
  readonly triggerHealthBps: number | null;
  readonly maxPerExecution: string | null;
  readonly minInterval: number | null;
  readonly lastExecutedAt: string | null;
  readonly session: string | null;
  readonly priced: boolean | null;
  readonly flagged: boolean | null;
  readonly graceUntil: string | null;
  readonly debtAssets: string | null;
  readonly seizureThreshold: string | null;
  readonly healthBps: string | null;
  readonly amount: string | null;
  readonly allowanceRemaining: string | null;
  readonly allowance: string | null;
  readonly permissionEnd: number | null;
  readonly oracles: readonly {
    symbol: string;
    oracle: Address;
    verdict: string | null;
    session: string | null;
    divergenceBps: string | null;
    divergenceBand: string | null;
    explanation: string | null;
    priceError: string | null;
  }[];
  /** Set instead of everything else when the chain could not be read at all. */
  readonly unavailable: string | null;
}

/** One completed pass over every watched account. */
export interface TickResult {
  readonly startedAt: string;
  readonly finishedAt: string;
  readonly blockNumber: bigint | null;
  readonly records: readonly DecisionRecord[];
  readonly transactionsSent: number;
}
