import type { Address, PublicClient } from "viem";
import {
  aftermarketOracleAbi,
  decodeOracleError,
  explainVerdict,
  isTrustedVerdict,
  SESSION_NAMES,
  VERDICT_NAMES,
  type OracleError,
  type Quote,
  type Session,
  type Verdict,
} from "@aftermarket/session-oracle";
import { aftermarketCreditAbi, aftermarketLensAbi, autoRepayerAbi } from "./abi.js";
import { describeError, extractRevertData, withRateLimitRetry } from "./chain.js";
import type { AccountSnapshot, ContractSimulation, Enrollment, OracleSnapshot, Position } from "./types.js";

/** The addresses one keeper instance is wired to. */
export interface ProtocolAddresses {
  readonly autoRepayer: Address;
  readonly credit: Address;
  readonly lens: Address;
}

/** The block a tick was taken at, so every read in that tick refers to the same state. */
export interface BlockRef {
  readonly number: bigint;
  readonly timestamp: bigint;
}

/**
 * The oracle state of every configured collateral asset, read once per tick and shared across
 * accounts. Keyed by lowercase asset address.
 */
export type OracleTable = ReadonlyMap<string, OracleSnapshot>;

/** Reads the block every subsequent read in this tick will be pinned to. */
export async function readBlock(client: PublicClient): Promise<BlockRef> {
  const block = await withRateLimitRetry(() => client.getBlock({ blockTag: "latest" }));
  return { number: block.number, timestamp: block.timestamp };
}

/**
 * Reads every configured asset's oracle state through the lens, and — for any asset whose mark is
 * untrusted — the typed revert `price()` produces, decoded by `@aftermarket/session-oracle`.
 *
 * The second read is what turns "unpriced" into a sentence. `SourcesDiverged(session=5
 * CLOSED_HOLIDAY, divergence=910bps, band=300bps)` is the difference between an audit trail that
 * says the agent stood down and one that says why anybody should agree with it.
 */
export async function readOracles(
  client: PublicClient,
  addresses: ProtocolAddresses,
  block: BlockRef,
): Promise<OracleTable> {
  const views = await withRateLimitRetry(() =>
    client.readContract({
      address: addresses.lens,
      abi: aftermarketLensAbi,
      functionName: "assetViews",
      blockNumber: block.number,
    }),
  );

  const table = new Map<string, OracleSnapshot>();
  for (const view of views) {
    const quote = view.quote as Quote;
    const trusted = view.quoteOk && isTrustedVerdict(quote.verdict as Verdict);
    const priceError = view.quoteOk && !trusted ? await readPriceError(client, view.oracle) : null;

    table.set(view.asset.toLowerCase(), {
      asset: view.asset,
      symbol: view.symbol || shortAddress(view.asset),
      oracle: view.oracle,
      quoteOk: view.quoteOk,
      verdict: view.quoteOk ? (quote.verdict as Verdict) : null,
      session: view.quoteOk ? (quote.session as Session) : null,
      divergenceBps: view.quoteOk ? quote.divergenceBps : null,
      divergenceBand: view.quoteOk ? quote.divergenceBand : null,
      feedAge: view.quoteOk ? quote.feedAge : null,
      stalenessBudget: view.quoteOk ? quote.stalenessBudget : null,
      poolLiquidityUsd: view.quoteOk ? quote.poolLiquidityUsd : null,
      multiplier: view.quoteOk ? quote.multiplier : null,
      explanation: view.quoteOk ? explainVerdict(quote) : null,
      priceError,
    });
  }
  return table;
}

/**
 * Asks an oracle for its Morpho-scale mark and, when it refuses, renders the refusal.
 *
 * Returns `null` when the mark is produced, and a description when it is not. A failure that is
 * *not* one of the oracle's five typed errors — a dead RPC, a wrong address — is reported as such
 * rather than being misattributed to the oracle, because "the feed diverged" and "we could not ask"
 * are different facts and only one of them is the protocol's.
 */
export async function readPriceError(client: PublicClient, oracle: Address): Promise<string | null> {
  try {
    await client.readContract({ address: oracle, abi: aftermarketOracleAbi, functionName: "price" });
    return null;
  } catch (error) {
    const revertData = extractRevertData(error);
    const decoded = revertData ? decodeOracleError(revertData) : undefined;
    if (decoded) return formatOracleError(decoded);
    return `oracle unreadable: ${describeError(error)}`;
  }
}

/** `SourcesDiverged(session=CLOSED_HOLIDAY, divergence=910bps, band=300bps)` and friends. */
export function formatOracleError(error: OracleError): string {
  switch (error.name) {
    case "StaleFeed":
      return `StaleFeed(session=${sessionName(error.session)}, age=${error.age}s, budget=${error.budget}s)`;
    case "SourcesDiverged":
      return `SourcesDiverged(session=${sessionName(error.session)}, divergence=${error.divergenceBps}bps, band=${error.band}bps)`;
    case "PoolTooThin":
      return `PoolTooThin(liquidityUsd=${error.liquidityUsd}, min=${error.minLiquidityUsd})`;
    case "MarketHalted":
      return `MarketHalted(multiplier=${error.multiplier})`;
    case "InvalidFeedAnswer":
      return `InvalidFeedAnswer(answer=${error.answer})`;
  }
}

/**
 * Reads one account's full state at `block`.
 *
 * `positionOf` is the only read here that is allowed to fail without failing the tick: the credit
 * engine can revert outright when the calendar or the rate model is unreachable, and the agent
 * treats that identically to an oracle refusing to mark. Every other read failing means the chain
 * could not be reached, and that propagates so the caller can write `unavailable` instead of
 * guessing.
 */
export async function readAccount(
  client: PublicClient,
  addresses: ProtocolAddresses,
  account: Address,
  block: BlockRef,
  oracles: OracleTable,
): Promise<AccountSnapshot> {
  const [enrollmentRaw, spendable, assets] = await Promise.all([
    withRateLimitRetry(() =>
      client.readContract({
        address: addresses.autoRepayer,
        abi: autoRepayerAbi,
        functionName: "enrollmentOf",
        args: [account],
        blockNumber: block.number,
      }),
    ),
    withRateLimitRetry(() =>
      client.readContract({
        address: addresses.autoRepayer,
        abi: autoRepayerAbi,
        functionName: "spendableFor",
        args: [account],
        blockNumber: block.number,
      }),
    ),
    withRateLimitRetry(() =>
      client.readContract({
        address: addresses.credit,
        abi: aftermarketCreditAbi,
        functionName: "assetsOf",
        args: [account],
        blockNumber: block.number,
      }),
    ),
  ]);

  let position: Position | null = null;
  try {
    const raw = await client.readContract({
      address: addresses.credit,
      abi: aftermarketCreditAbi,
      functionName: "positionOf",
      args: [account],
      blockNumber: block.number,
    });
    position = {
      debtAssets: raw.debtAssets,
      debtShares: raw.debtShares,
      borrowPower: raw.borrowPower,
      seizureThreshold: raw.seizureThreshold,
      healthFactor: raw.healthFactor,
      priced: raw.priced,
      flagged: raw.flagged,
      openedAt: raw.openedAt,
      flaggedAt: raw.flaggedAt,
      graceUntil: raw.graceUntil,
      autoRepayEnabled: raw.autoRepayEnabled,
      session: raw.session as Session,
    };
  } catch {
    // `positionOf` is documented as total, so a revert here means a dependency of the engine is
    // down. That is the agent's `ORACLE_UNTRUSTED` case, not a tick failure.
    position = null;
  }

  const basket = assets
    .map((asset) => oracles.get(asset.toLowerCase()))
    .filter((snapshot): snapshot is OracleSnapshot => snapshot !== undefined);

  return {
    account,
    blockNumber: block.number,
    blockTimestamp: block.timestamp,
    enrollment: toEnrollment(enrollmentRaw),
    position,
    spendable,
    oracles: basket,
  };
}

/** The contract's own verdict, which the keeper never sends a transaction without. */
export async function simulate(
  client: PublicClient,
  addresses: ProtocolAddresses,
  account: Address,
  block?: BlockRef | undefined,
): Promise<ContractSimulation> {
  const [willAct, reason, amount] = await withRateLimitRetry(() =>
    client.readContract({
      address: addresses.autoRepayer,
      abi: autoRepayerAbi,
      functionName: "simulate",
      args: [account],
      ...(block ? { blockNumber: block.number } : {}),
    }),
  );
  return { willAct, reason, amount };
}

type RawEnrollment = {
  permissionHash: `0x${string}`;
  lastExecutedAt: bigint;
  policy: { maxPerExecution: bigint; minInterval: number; triggerHealthBps: number; enabled: boolean };
  permission: {
    account: Address;
    spender: Address;
    token: Address;
    allowance: bigint;
    period: number;
    start: number;
    end: number;
    salt: bigint;
    extraData: `0x${string}`;
  };
};

function toEnrollment(raw: RawEnrollment): Enrollment {
  return {
    permissionHash: raw.permissionHash,
    lastExecutedAt: raw.lastExecutedAt,
    policy: {
      maxPerExecution: raw.policy.maxPerExecution,
      minInterval: raw.policy.minInterval,
      triggerHealthBps: raw.policy.triggerHealthBps,
      enabled: raw.policy.enabled,
    },
    permission: { ...raw.permission },
  };
}

function sessionName(session: Session): string {
  return SESSION_NAMES[session] ?? `SESSION_${session}`;
}

/** The name of an oracle verdict, or a stable placeholder for a value this build does not know. */
export function verdictName(verdict: Verdict | null): string | null {
  if (verdict === null) return null;
  return VERDICT_NAMES[verdict] ?? `VERDICT_${verdict}`;
}

/** The name of a market session, or a stable placeholder. */
export function sessionLabel(session: Session | null): string | null {
  if (session === null) return null;
  return SESSION_NAMES[session] ?? `SESSION_${session}`;
}

function shortAddress(address: Address): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}
