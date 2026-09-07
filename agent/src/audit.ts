import { appendFile, mkdir, readFile, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import type { Address } from "viem";
import { reasonName } from "./reasons.js";
import { sessionLabel, verdictName } from "./reader.js";
import type {
  AccountSnapshot,
  ActionOutcome,
  ContractSimulation,
  Decision,
  DecisionInputs,
  DecisionRecord,
  DecisionStatus,
} from "./types.js";

/**
 * Where the audit trail lives unless the operator says otherwise.
 *
 * Relative to the working directory, not to this module: a keeper is normally run from its own
 * deployment directory, and a log that silently followed the installed code around would be the
 * wrong shape for a service. Override with `--audit` or `KEEPER_AUDIT_PATH`.
 */
export const DEFAULT_AUDIT_PATH = "audit/decisions.jsonl";

/**
 * The append-only decision log.
 *
 * A refusal is the keeper's primary output, so it is written down with the same care an action
 * would be: same schema, same inputs, same block. The format is JSONL rather than a database
 * because the point of the artefact is that somebody else can read it — `tail -f`, `jq`, or an
 * HTTP GET — without running any of this code.
 */
export class AuditTrail {
  readonly path: string;
  private ensured = false;

  constructor(path: string = DEFAULT_AUDIT_PATH) {
    this.path = resolve(path);
  }

  /** Appends one record. Creates the directory on first use. */
  async append(record: DecisionRecord): Promise<void> {
    if (!this.ensured) {
      await mkdir(dirname(this.path), { recursive: true });
      this.ensured = true;
    }
    await appendFile(this.path, `${JSON.stringify(record)}\n`, "utf8");
  }

  /** Appends a whole tick's worth of records in one write. */
  async appendAll(records: readonly DecisionRecord[]): Promise<void> {
    if (records.length === 0) return;
    if (!this.ensured) {
      await mkdir(dirname(this.path), { recursive: true });
      this.ensured = true;
    }
    await appendFile(this.path, `${records.map((record) => JSON.stringify(record)).join("\n")}\n`, "utf8");
  }

  /**
   * The most recent `limit` records, newest first, optionally narrowed to one account.
   *
   * Reads the whole file. That is the right trade for an audit trail a human is going to read:
   * correctness under concurrent appends matters, throughput at a million lines does not, and a
   * partially written trailing line is skipped rather than crashing the endpoint.
   */
  async read(options: { limit?: number; account?: Address } = {}): Promise<DecisionRecord[]> {
    const limit = options.limit ?? 100;
    const account = options.account?.toLowerCase();

    let contents: string;
    try {
      contents = await readFile(this.path, "utf8");
    } catch {
      return [];
    }

    const records: DecisionRecord[] = [];
    for (const line of contents.split("\n")) {
      if (line.trim() === "") continue;
      let parsed: DecisionRecord;
      try {
        parsed = JSON.parse(line) as DecisionRecord;
      } catch {
        continue;
      }
      if (account && parsed.account.toLowerCase() !== account) continue;
      records.push(parsed);
    }

    return records.slice(-limit).reverse();
  }

  /** Size and modification time of the trail, or `null` when it does not exist yet. */
  async info(): Promise<{ bytes: number; modified: string } | null> {
    try {
      const stats = await stat(this.path);
      return { bytes: stats.size, modified: stats.mtime.toISOString() };
    } catch {
      return null;
    }
  }
}

/** Builds the record for an account the keeper managed to read. */
export function buildRecord(args: {
  chainId: number;
  snapshot: AccountSnapshot;
  decision: Decision;
  contract: ContractSimulation | null;
  status: DecisionStatus;
  action: ActionOutcome;
  dryRun: boolean;
  explanation?: string;
}): DecisionRecord {
  const { chainId, snapshot, decision, contract, status, action, dryRun } = args;
  const { enrollment, position } = snapshot;

  return {
    schema: "aftermarket.keeper.decision/1",
    timestamp: new Date().toISOString(),
    chainId,
    blockNumber: snapshot.blockNumber.toString(),
    blockTimestamp: snapshot.blockTimestamp.toString(),
    account: snapshot.account,
    status,
    reason: decision.reason,
    reasonName: reasonName(decision.reason),
    explanation: args.explanation ?? decision.explanation,
    inputs: buildInputs(snapshot, decision),
    contract: contract
      ? {
          willAct: contract.willAct,
          reason: contract.reason,
          reasonName: reasonName(contract.reason),
          amount: contract.amount.toString(),
        }
      : null,
    action: {
      kind: action.kind,
      sent: action.sent,
      txHash: action.txHash,
      repaid: action.repaid === null ? null : action.repaid.toString(),
      note: action.note,
    },
    dryRun,
  };

  function buildInputs(snap: AccountSnapshot, verdict: Decision): DecisionInputs {
    const enrolled = enrollment.permissionHash !== ZERO_HASH;
    return {
      enrolled,
      policyEnabled: enrolled ? enrollment.policy.enabled : null,
      triggerHealthBps: enrolled ? enrollment.policy.triggerHealthBps : null,
      maxPerExecution: enrolled ? enrollment.policy.maxPerExecution.toString() : null,
      minInterval: enrolled ? enrollment.policy.minInterval : null,
      lastExecutedAt: enrolled ? enrollment.lastExecutedAt.toString() : null,
      session: position ? (sessionLabel(position.session) ?? null) : null,
      priced: position ? position.priced : null,
      flagged: position ? position.flagged : null,
      graceUntil: position ? position.graceUntil.toString() : null,
      debtAssets: position ? position.debtAssets.toString() : null,
      seizureThreshold: position ? position.seizureThreshold.toString() : null,
      healthBps: verdict.healthBps === null ? null : verdict.healthBps.toString(),
      amount: verdict.amount === 0n && !verdict.willAct ? null : verdict.amount.toString(),
      allowanceRemaining: enrolled ? snap.spendable.toString() : null,
      allowance: enrolled ? enrollment.permission.allowance.toString() : null,
      permissionEnd: enrolled ? enrollment.permission.end : null,
      oracles: snap.oracles.map((oracle) => ({
        symbol: oracle.symbol,
        oracle: oracle.oracle,
        verdict: verdictName(oracle.verdict),
        session: sessionLabel(oracle.session),
        divergenceBps: oracle.divergenceBps === null ? null : oracle.divergenceBps.toString(),
        divergenceBand: oracle.divergenceBand === null ? null : oracle.divergenceBand.toString(),
        explanation: oracle.explanation,
        priceError: oracle.priceError,
      })),
      unavailable: null,
    };
  }
}

/**
 * Builds the record for an account the keeper could not read at all.
 *
 * The status is `unavailable`, never a reason code. An RPC that will not answer is the absence of
 * information, and writing down a verdict derived from nothing would make the audit trail lie in
 * exactly the situation it is most needed.
 */
export function buildUnavailableRecord(args: {
  chainId: number;
  account: Address;
  blockNumber: bigint | null;
  error: string;
  dryRun: boolean;
}): DecisionRecord {
  return {
    schema: "aftermarket.keeper.decision/1",
    timestamp: new Date().toISOString(),
    chainId: args.chainId,
    blockNumber: args.blockNumber === null ? null : args.blockNumber.toString(),
    blockTimestamp: null,
    account: args.account,
    status: "unavailable",
    reason: null,
    reasonName: "UNAVAILABLE",
    explanation:
      "The chain could not be read for this account, so the keeper has no state to judge. It recorded the outage and did nothing; it did not assume a state.",
    inputs: {
      enrolled: false,
      policyEnabled: null,
      triggerHealthBps: null,
      maxPerExecution: null,
      minInterval: null,
      lastExecutedAt: null,
      session: null,
      priced: null,
      flagged: null,
      graceUntil: null,
      debtAssets: null,
      seizureThreshold: null,
      healthBps: null,
      amount: null,
      allowanceRemaining: null,
      allowance: null,
      permissionEnd: null,
      oracles: [],
      unavailable: args.error,
    },
    contract: null,
    action: { kind: "none", sent: false, txHash: null, repaid: null, note: "no action taken: state unknown" },
    dryRun: args.dryRun,
  };
}

const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
