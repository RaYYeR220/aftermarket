import "server-only";

import { cache } from "react";
import { parseEventLogs, type Address, type Hex, type Log } from "viem";

import { autoRepayerAbi, creditAbi, vaultAbi } from "@/lib/abi";
import { DEPLOYMENT } from "@/lib/deployment";
import { AUTO_REPAY_CODE, fromUsdc, scaled, toAutoRepayReason } from "@/lib/protocol";
import { SESSION_LABEL, toSession } from "@/lib/session";

import { failureText, publicClient, type Fallible } from "./chain";

/**
 * The protocol's own log, including the entries where it declined to act.
 *
 * An activity feed that only shows what happened is a marketing surface. The interesting rows here
 * are `AutoRepayRefused` and `LineFlagged`: an agent that stood down with its reason recorded
 * onchain, and a line that was marked for seizure but given a grace window it cannot be taken
 * inside. Both are written by the contracts, not by this application, so they are evidence rather
 * than narration.
 */

/** Where a row came from. Used to group the feed and to colour nothing at all. */
export type ActivitySource = "credit" | "vault" | "agent";

export interface ActivityEntry {
  id: string;
  blockNumber: bigint;
  transactionHash: Hex;
  logIndex: number;
  source: ActivitySource;
  /** The Solidity event name, printed as emitted. */
  event: string;
  /** What happened, in the interface's own words. */
  headline: string;
  /** The supporting numbers, already formatted. */
  detail: string | null;
  /** The account it happened to, when the event names one. */
  actor: Address | null;
  /** True for a row that records the protocol declining to act. */
  isRefusal: boolean;
}

export interface ActivityFeed {
  entries: ActivityEntry[];
  /** The earliest block this feed covers. */
  fromBlock: bigint;
  toBlock: bigint;
  /** True when the window stops short of the deployment block. */
  windowTruncated: boolean;
  refusalCount: number;
}

export type ActivityRead = Fallible<ActivityFeed>;

/** The public Base endpoint caps `eth_getLogs` at ten thousand blocks. */
const CHUNK = 10_000n;

/** Roughly two days of Base blocks. Past that the feed is a history project, not a live log. */
const MAX_CHUNKS = 9n;

function usd(value: bigint): string {
  return `${fromUsdc(value).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USDC`;
}

function bps(value: bigint): string {
  return `${(Number(value) / 100).toFixed(2)}%`;
}

function shortSymbol(asset: Address, symbols: ReadonlyMap<string, string>): string {
  return symbols.get(asset.toLowerCase()) ?? `${asset.slice(0, 6)}…${asset.slice(-4)}`;
}

type Located = { blockNumber: bigint; transactionHash: Hex; logIndex: number };

function locate(log: Log): Located | null {
  if (log.blockNumber === null || log.transactionHash === null || log.logIndex === null) return null;
  return { blockNumber: log.blockNumber, transactionHash: log.transactionHash, logIndex: log.logIndex };
}

/* ============================================================= describe === */

interface Described {
  headline: string;
  detail: string | null;
  actor: Address | null;
  isRefusal: boolean;
}

function describeCredit(
  event: ReturnType<typeof parseEventLogs<typeof creditAbi>>[number],
  symbols: ReadonlyMap<string, string>,
  decimals: ReadonlyMap<string, number>,
): Described | null {
  const tokens = (asset: Address, amount: bigint): string =>
    `${scaled(amount, decimals.get(asset.toLowerCase()) ?? 18).toLocaleString("en-US", {
      maximumFractionDigits: 8,
    })} ${shortSymbol(asset, symbols)}`;

  switch (event.eventName) {
    case "LineOpened":
      return { headline: "Line opened", detail: null, actor: event.args.user, isRefusal: false };
    case "CollateralDeposited":
      return {
        headline: `Collateral posted · ${shortSymbol(event.args.asset, symbols)}`,
        detail: tokens(event.args.asset, event.args.amount),
        actor: event.args.user,
        isRefusal: false,
      };
    case "CollateralWithdrawn":
      return {
        headline: `Collateral withdrawn · ${shortSymbol(event.args.asset, symbols)}`,
        detail: tokens(event.args.asset, event.args.amount),
        actor: event.args.user,
        isRefusal: false,
      };
    case "Drawn":
      return { headline: "Drawn", detail: usd(event.args.assets), actor: event.args.user, isRefusal: false };
    case "Repaid":
      return { headline: "Repaid", detail: usd(event.args.assets), actor: event.args.user, isRefusal: false };
    case "LineFlagged": {
      const session = toSession(event.args.session);
      return {
        headline: "Line flagged, seizure deferred",
        detail: `Debt ${usd(event.args.debtAssets)} against a ${usd(event.args.seizureThreshold)} threshold. Cannot be seized before ${new Date(Number(event.args.graceUntil) * 1000).toISOString().replace("T", " ").slice(0, 16)} UTC${session === null ? "" : `, flagged during ${SESSION_LABEL[session].toLowerCase()}`}.`,
        actor: event.args.user,
        isRefusal: true,
      };
    }
    case "LineCured":
      return {
        headline: "Flag cleared",
        detail: `Debt ${usd(event.args.debtAssets)} back under a ${usd(event.args.seizureThreshold)} threshold.`,
        actor: event.args.user,
        isRefusal: false,
      };
    case "Liquidated":
      return {
        headline: `Collateral seized · ${shortSymbol(event.args.collateralAsset, symbols)}`,
        detail: `${usd(event.args.repaidAssets)} repaid for ${tokens(event.args.collateralAsset, event.args.seized)}.`,
        actor: event.args.user,
        isRefusal: false,
      };
    case "BadDebtRealized":
      return {
        headline: "Bad debt written down to lenders",
        detail: usd(event.args.assets),
        actor: event.args.user,
        isRefusal: false,
      };
    case "AutoRepaySet":
      return {
        headline: event.args.enabled ? "Auto-repay allowed on this line" : "Auto-repay disallowed on this line",
        detail: null,
        actor: event.args.user,
        isRefusal: false,
      };
    case "YieldSwept":
      return {
        headline: `Dividend swept to debt · ${shortSymbol(event.args.asset, symbols)}`,
        detail: `${usd(event.args.proceeds)} raised, ${usd(event.args.repaid)} applied to the line.`,
        actor: event.args.user,
        isRefusal: false,
      };
    default:
      return null;
  }
}

function describeVault(event: ReturnType<typeof parseEventLogs<typeof vaultAbi>>[number]): Described | null {
  switch (event.eventName) {
    case "Deposit":
      return { headline: "Lender deposit", detail: usd(event.args.assets), actor: event.args.owner, isRefusal: false };
    case "Withdraw":
      return {
        headline: "Lender withdrawal",
        detail: usd(event.args.assets),
        actor: event.args.owner,
        isRefusal: false,
      };
    case "Lent":
      return { headline: "Vault funded a draw", detail: usd(event.args.assets), actor: event.args.to, isRefusal: false };
    case "Settled":
      return {
        headline: "Repayment returned to the vault",
        detail: usd(event.args.assets),
        actor: event.args.from,
        isRefusal: false,
      };
    default:
      return null;
  }
}

function describeAgent(event: ReturnType<typeof parseEventLogs<typeof autoRepayerAbi>>[number]): Described | null {
  switch (event.eventName) {
    case "AutoRepaid": {
      const session = toSession(event.args.session);
      return {
        headline: "Agent repaid",
        detail: `${usd(event.args.amount)}, health ${bps(event.args.healthBefore)} to ${bps(event.args.healthAfter)}${session === null ? "" : `, ${SESSION_LABEL[session].toLowerCase()}`}.`,
        actor: event.args.user,
        isRefusal: false,
      };
    }
    case "AutoRepayRefused": {
      const reason = toAutoRepayReason(event.args.reason);
      return {
        headline: "Agent refused to act",
        detail: AUTO_REPAY_CODE[reason],
        actor: event.args.user,
        isRefusal: true,
      };
    }
    case "Enrolled":
      return {
        headline: "Spend cap granted to the agent",
        detail: `At most ${usd(BigInt(event.args.policy.maxPerExecution))} per action, acting below ${bps(BigInt(event.args.policy.triggerHealthBps))} health.`,
        actor: event.args.user,
        isRefusal: false,
      };
    case "PolicyUpdated":
      return {
        headline: "Mandate changed",
        detail: `At most ${usd(BigInt(event.args.policy.maxPerExecution))} per action, acting below ${bps(BigInt(event.args.policy.triggerHealthBps))} health.`,
        actor: event.args.user,
        isRefusal: false,
      };
    case "Withdrawn":
      return { headline: "Mandate withdrawn", detail: null, actor: event.args.user, isRefusal: false };
    case "Cancelled":
      return {
        headline: "Mandate withdrawn and permission handed back",
        detail: event.args.revoked ? "The manager accepted the revocation." : "Revoke at the manager to finish.",
        actor: event.args.user,
        isRefusal: false,
      };
    case "Refunded":
      return { headline: "Dust returned to the borrower", detail: usd(event.args.amount), actor: event.args.user, isRefusal: false };
    default:
      return null;
  }
}

/* ============================================================== reading === */

export interface ActivityOptions {
  /** Only rows naming this account. */
  account?: Address | undefined;
  /** How many rows to keep, newest first. */
  limit?: number | undefined;
  /** Symbols and decimals for the collateral tokens, so a row can name the asset it moved. */
  symbols?: ReadonlyMap<string, string> | undefined;
  decimals?: ReadonlyMap<string, number> | undefined;
}

async function read(options: ActivityOptions = {}): Promise<ActivityRead> {
  const symbols = options.symbols ?? new Map<string, string>();
  const decimals = options.decimals ?? new Map<string, number>();
  const limit = options.limit ?? 60;

  try {
    const latest = await publicClient.getBlockNumber();
    const floor = DEPLOYMENT.blockNumber;
    const windowStart = latest > CHUNK * MAX_CHUNKS ? latest - CHUNK * MAX_CHUNKS : 0n;
    const fromBlock = windowStart > floor ? windowStart : floor;

    const ranges: { from: bigint; to: bigint }[] = [];
    for (let start = fromBlock; start <= latest; start += CHUNK) {
      const end = start + CHUNK - 1n;
      ranges.push({ from: start, to: end > latest ? latest : end });
    }

    const chunks = await Promise.all(
      ranges.map((range) =>
        publicClient.getLogs({
          address: [DEPLOYMENT.credit, DEPLOYMENT.vault, DEPLOYMENT.autoRepayer],
          fromBlock: range.from,
          toBlock: range.to,
        }),
      ),
    );
    const logs = chunks.flat();

    const entries: ActivityEntry[] = [];
    const push = (log: Log, source: ActivitySource, event: string, described: Described | null) => {
      if (described === null) return;
      const at = locate(log);
      if (at === null) return;
      entries.push({
        id: `${at.transactionHash}-${at.logIndex}`,
        blockNumber: at.blockNumber,
        transactionHash: at.transactionHash,
        logIndex: at.logIndex,
        source,
        event,
        ...described,
      });
    };

    const creditLogs = logs.filter((log) => log.address.toLowerCase() === DEPLOYMENT.credit.toLowerCase());
    for (const event of parseEventLogs({ abi: creditAbi, logs: creditLogs })) {
      push(event, "credit", event.eventName, describeCredit(event, symbols, decimals));
    }

    const vaultLogs = logs.filter((log) => log.address.toLowerCase() === DEPLOYMENT.vault.toLowerCase());
    for (const event of parseEventLogs({ abi: vaultAbi, logs: vaultLogs })) {
      push(event, "vault", event.eventName, describeVault(event));
    }

    const agentLogs = logs.filter((log) => log.address.toLowerCase() === DEPLOYMENT.autoRepayer.toLowerCase());
    for (const event of parseEventLogs({ abi: autoRepayerAbi, logs: agentLogs })) {
      push(event, "agent", event.eventName, describeAgent(event));
    }

    const account = options.account?.toLowerCase();
    const filtered =
      account === undefined ? entries : entries.filter((entry) => entry.actor?.toLowerCase() === account);

    filtered.sort((a, b) =>
      a.blockNumber === b.blockNumber ? b.logIndex - a.logIndex : Number(b.blockNumber - a.blockNumber),
    );

    return {
      ok: true,
      value: {
        entries: filtered.slice(0, limit),
        fromBlock,
        toBlock: latest,
        windowTruncated: fromBlock > floor,
        refusalCount: filtered.filter((entry) => entry.isRefusal).length,
      },
    };
  } catch (error) {
    return { ok: false, error: failureText(error) };
  }
}

/** Deduplicated per request. */
export const readActivity = cache(read);
