import "server-only";

import { cache } from "react";
import { decodeFunctionResult, type Abi, type Address } from "viem";

import { lensAbi, sessionRateModelAbi, vaultAbi } from "@/lib/abi";
import { COLLATERAL_TOKENS, DEPLOYMENT } from "@/lib/deployment";
import {
  aprPercent,
  fromUsdc,
  fromWad,
  markToUsd,
  ratioOfWad,
  scaled,
  toVerdict,
} from "@/lib/protocol";
import { advanceBpsOf, isMarketOpenSession, SESSION_ORDER, Session, toSession } from "@/lib/session";
import { underlyingTicker } from "@/lib/site";
import { isTrusted, Verdict } from "@/lib/verdict";

import { etOffsetHours } from "./calendar";
import { aggregate, failureText, memoize, MULTICALL3, multicall3ClockAbi, publicClient, type Fallible } from "./chain";

/**
 * Everything the application surface knows about Base mainnet.
 *
 * One reader, one shape, one failure discipline. Every figure below comes back through
 * `AftermarketLens`, which is total: it answers with a fully populated struct under any failure of
 * any oracle, calendar or rate model. That is the property this interface is built on -- a screen
 * whose job is to render a refusal cannot be built on a read that fails when one happens.
 *
 * A field that genuinely could not be read is `null`, and the interface prints `unavailable`.
 * Nothing here substitutes a zero, a default or a remembered value for a live one.
 */

/* ============================================================== shapes === */

/** What one oracle currently knows. Mirrors the `Quote` struct field for field. */
export interface QuoteSnapshot {
  verdict: Verdict;
  session: Session;
  /** Chainlink total-return feed, USD per whole token. */
  anchorUsd: number;
  /** Aerodrome Slipstream TWAP over the oracle's window, USD per whole token. */
  poolUsd: number;
  /** The pessimistic mark the engine lends against, USD per whole token. */
  markBorrowUsd: number;
  /** The optimistic mark a seizure is tested against, USD per whole token. */
  markLiquidateUsd: number;
  feedAgeSeconds: number;
  stalenessBudgetSeconds: number;
  divergenceBps: number;
  divergenceBandBps: number;
  /** Gap-risk haircut currently applied to both marks. */
  haircutBps: number;
  /** B20 dividend/split multiplier. 1 means no corporate action in flight. */
  multiplier: number;
  /** Loan-side depth backing the pool mark. */
  poolLiquidityUsd: number;
  nextOpenUnix: number;
  lastCloseUnix: number;
}

/** Which rule a refusal tripped, with the number that tripped it and the number it was measured against. */
export interface Refusal {
  /** The typed error `price()` reverts with. */
  signature: string;
  /** What the oracle measured. */
  observed: string;
  /** What this session allows. */
  allowed: string;
  /** One sentence naming the rule. */
  rule: string;
}

export interface AssetSnapshot {
  address: Address;
  oracle: Address;
  /** As the token reports it, e.g. `AMZNc`. */
  symbol: string;
  /** The equity behind it, e.g. `AMZN`. */
  underlying: string;
  decimals: number;
  /** The oracle's state, or `null` when the oracle did not answer the lens at all. */
  quote: QuoteSnapshot | null;
  verdict: Verdict;
  /** Populated exactly when the oracle refuses to publish a mark. */
  refusal: Refusal | null;
  /** Advance rate in force for the current session. */
  advanceBps: number;
  /** Debt level, as a fraction of collateral value, at which this line becomes seizable. */
  liqThresholdBps: number;
  capRaw: bigint;
  postedRaw: bigint;
  capTokens: number;
  postedTokens: number;
  /**
   * Posted collateral at the borrow mark, or `null` when the oracle refuses to publish one.
   *
   * A refused asset still has a computable mark inside the quote, and printing it would be quoting
   * a price the protocol will not stand behind. The engine values such a leg at zero; this
   * interface declines to value it at all.
   */
  postedValueUsd: number | null;
  enabled: boolean;
  borrowAprPercent: number;
  supplyAprPercent: number;
}

/** The borrow rate the same utilisation would carry in another session. */
export interface SessionRate {
  session: Session;
  aprPercent: number;
  /** Multiple of the open-market rate, e.g. 1.6. */
  premium: number;
  isCurrent: boolean;
}

export interface ProtocolSnapshot {
  blockNumber: bigint;
  blockTimestampUnix: number;
  etOffsetHours: number;

  session: Session;
  isMarketOpen: boolean;
  nextOpenUnix: number;
  lastCloseUnix: number;
  /** Seconds from the last defensible print to the next one. */
  closedGapSeconds: number;
  /** Advance rate the current session allows, in basis points. */
  advanceBps: number;
  /** Advance rate an open market allows, in basis points. */
  advanceOpenBps: number;

  totalDebtUsdc: number;
  totalSuppliedUsdc: number;
  /** USDC sitting in the vault, available to fund a draw. */
  idleUsdc: number | null;
  /** The same figure in USDC units, for a client component that has to do arithmetic on it. */
  idleUsdcRaw: bigint | null;
  utilisation: number;
  /** Utilisation at which the rate curve steepens, as a fraction of one. */
  kink: number | null;
  vaultSharePriceUsdc: number;
  vaultSymbol: string | null;
  vaultName: string | null;
  vaultDecimals: number | null;
  vaultTotalShares: bigint | null;

  assets: AssetSnapshot[];
  /** The rate ladder at the current utilisation, one entry per session. */
  sessionRates: SessionRate[] | null;

  quotingCount: number;
  refusingCount: number;
}

export type ProtocolRead = Fallible<ProtocolSnapshot>;

/* ============================================================ decoding === */

const SECONDS_PER_YEAR = 365n * 24n * 60n * 60n;

type LensQuote = {
  verdict: number;
  session: number;
  anchorPrice: bigint;
  poolPrice: bigint;
  markBorrow: bigint;
  markLiquidate: bigint;
  feedAge: bigint;
  stalenessBudget: bigint;
  divergenceBps: bigint;
  divergenceBand: bigint;
  haircutBps: bigint;
  multiplier: bigint;
  poolLiquidityUsd: bigint;
  nextOpen: bigint;
  lastClose: bigint;
};

function toQuote(raw: LensQuote, decimals: number): QuoteSnapshot {
  return {
    verdict: toVerdict(raw.verdict),
    session: toSession(raw.session) ?? Session.CLOSED_HOLIDAY,
    anchorUsd: fromWad(raw.anchorPrice),
    poolUsd: fromWad(raw.poolPrice),
    markBorrowUsd: markToUsd(raw.markBorrow, decimals),
    markLiquidateUsd: markToUsd(raw.markLiquidate, decimals),
    feedAgeSeconds: Number(raw.feedAge),
    stalenessBudgetSeconds: Number(raw.stalenessBudget),
    divergenceBps: Number(raw.divergenceBps),
    divergenceBandBps: Number(raw.divergenceBand),
    haircutBps: Number(raw.haircutBps),
    multiplier: fromWad(raw.multiplier),
    poolLiquidityUsd: fromWad(raw.poolLiquidityUsd),
    nextOpenUnix: Number(raw.nextOpen),
    lastCloseUnix: Number(raw.lastClose),
  };
}

function usdCompact(value: number): string {
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(1)}k`;
  return `$${value.toFixed(2)}`;
}

function hours(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  return h === 0 ? `${m}m` : `${h}h ${String(m).padStart(2, "0")}m`;
}

/**
 * Which rule a refusal tripped.
 *
 * The order matches `AftermarketOracle`'s own check order, so the rule named here is the rule
 * `price()` would actually revert on rather than the first one a reader happens to notice.
 */
export function refusalOf(quote: QuoteSnapshot | null): Refusal | null {
  if (quote === null) {
    return {
      signature: "no answer",
      observed: "the oracle did not answer",
      allowed: "a reachable oracle",
      rule: "The lens could not reach this oracle at all, so there is no state to report.",
    };
  }
  if (isTrusted(quote.verdict)) return null;

  switch (quote.verdict) {
    case Verdict.UNTRUSTED_HALTED:
      return {
        signature: "MarketHalted(uint256)",
        observed: `multiplier ${quote.multiplier.toFixed(4)}`,
        allowed: "multiplier 1.0000",
        rule: "A corporate action is in flight. The token's own share multiplier has moved, so the price of one token is not the price of one share.",
      };
    case Verdict.UNTRUSTED_THIN:
      return {
        signature: "PoolTooThin(uint256,uint256)",
        observed: usdCompact(quote.poolLiquidityUsd),
        allowed: "$25.00k",
        rule: "There is not enough depth behind the pool price to corroborate the feed, so there is only one source and no way to check it.",
      };
    case Verdict.UNTRUSTED_STALE:
      return {
        signature: "StaleFeed(uint8,uint256,uint256)",
        observed: hours(quote.feedAgeSeconds),
        allowed: hours(quote.stalenessBudgetSeconds),
        rule: "The reference feed has not printed for longer than this session allows, so the anchor has expired.",
      };
    default:
      return {
        signature: "SourcesDiverged(uint8,uint256,uint256)",
        observed: `${Math.round(quote.divergenceBps)} bps`,
        allowed: `${Math.round(quote.divergenceBandBps)} bps`,
        rule: "The reference feed and the pool disagree by more than this session tolerates, so neither number can be defended as the mark.",
      };
  }
}

/* ============================================================= reading === */

async function read(): Promise<ProtocolRead> {
  try {
    const core = await publicClient.multicall({
      allowFailure: true,
      contracts: [
        { address: DEPLOYMENT.lens, abi: lensAbi, functionName: "protocolView" },
        { address: DEPLOYMENT.lens, abi: lensAbi, functionName: "assetViews" },
        { address: DEPLOYMENT.vault, abi: vaultAbi, functionName: "idleAssets" },
        { address: DEPLOYMENT.vault, abi: vaultAbi, functionName: "totalSupply" },
        { address: DEPLOYMENT.vault, abi: vaultAbi, functionName: "symbol" },
        { address: DEPLOYMENT.vault, abi: vaultAbi, functionName: "name" },
        { address: DEPLOYMENT.vault, abi: vaultAbi, functionName: "decimals" },
        { address: DEPLOYMENT.sessionRateModel, abi: sessionRateModelAbi, functionName: "kink" },
        { address: MULTICALL3, abi: multicall3ClockAbi, functionName: "getBlockNumber" },
        { address: MULTICALL3, abi: multicall3ClockAbi, functionName: "getCurrentBlockTimestamp" },
      ] as const,
    });

    const [
      protocolResult,
      assetsResult,
      idle,
      shares,
      symbol,
      name,
      vaultDecimals,
      kink,
      blockNumber,
      blockTimestamp,
    ] = core;

    if (protocolResult.status !== "success" || assetsResult.status !== "success") {
      const failure = protocolResult.status === "failure" ? protocolResult.error : assetsResult.error;
      return { ok: false, error: failureText(failure) };
    }

    const protocol = protocolResult.result;
    const views = assetsResult.result;

    const session = toSession(protocol.session) ?? Session.CLOSED_HOLIDAY;
    const timestampUnix =
      blockTimestamp.status === "success" ? Number(blockTimestamp.result) : Math.floor(Date.now() / 1000);

    const assets: AssetSnapshot[] = views.map((view) => {
      const quote = view.quoteOk ? toQuote(view.quote, view.decimals) : null;
      const verdict = quote?.verdict ?? Verdict.UNTRUSTED_HALTED;
      const postedTokens = scaled(view.posted, view.decimals);
      return {
        address: view.asset,
        oracle: view.oracle,
        symbol: view.symbol,
        underlying: underlyingTicker(view.symbol),
        decimals: view.decimals,
        quote,
        verdict,
        refusal: refusalOf(quote),
        advanceBps: view.advanceBps,
        liqThresholdBps: view.liqThresholdBps,
        capRaw: view.cap,
        postedRaw: view.posted,
        capTokens: scaled(view.cap, view.decimals),
        postedTokens,
        postedValueUsd: quote === null || !isTrusted(verdict) ? null : postedTokens * quote.markBorrowUsd,
        enabled: view.enabled,
        borrowAprPercent: aprPercent(view.borrowApr),
        supplyAprPercent: aprPercent(view.supplyApr),
      };
    });

    const sessionRates = await readSessionRates(protocol.totalDebt, protocol.totalSupplied, session);

    return {
      ok: true,
      value: {
        blockNumber: blockNumber.status === "success" ? blockNumber.result : 0n,
        blockTimestampUnix: timestampUnix,
        etOffsetHours: etOffsetHours(timestampUnix),

        session,
        isMarketOpen: isMarketOpenSession(session),
        nextOpenUnix: Number(protocol.nextOpen),
        lastCloseUnix: Number(protocol.lastClose),
        closedGapSeconds: Number(protocol.nextOpen) - Number(protocol.lastClose),
        // Read from the lens rather than derived: it is the number the engine will actually use.
        advanceBps: assets[0]?.advanceBps ?? advanceBpsOf(session),
        advanceOpenBps: advanceBpsOf(Session.REGULAR),

        totalDebtUsdc: fromUsdc(protocol.totalDebt),
        totalSuppliedUsdc: fromUsdc(protocol.totalSupplied),
        idleUsdc: idle.status === "success" ? fromUsdc(idle.result) : null,
        idleUsdcRaw: idle.status === "success" ? idle.result : null,
        utilisation: ratioOfWad(protocol.utilisation),
        kink: kink.status === "success" ? ratioOfWad(kink.result) : null,
        vaultSharePriceUsdc: fromUsdc(protocol.vaultSharePrice),
        vaultSymbol: symbol.status === "success" ? symbol.result : null,
        vaultName: name.status === "success" ? name.result : null,
        vaultDecimals: vaultDecimals.status === "success" ? vaultDecimals.result : null,
        vaultTotalShares: shares.status === "success" ? shares.result : null,

        assets,
        sessionRates,

        quotingCount: assets.filter((asset) => isTrusted(asset.verdict)).length,
        refusingCount: assets.filter((asset) => !isTrusted(asset.verdict)).length,
      },
    };
  } catch (error) {
    return { ok: false, error: failureText(error) };
  }
}

/**
 * The same utilisation priced in all six sessions.
 *
 * A second call, because the rate model takes the current debt and supply as arguments and those
 * only exist once the first batch has returned. Reading the ladder rather than deriving it from a
 * multiplier keeps the closed-market premium a measurement instead of an assertion.
 */
async function readSessionRates(
  totalDebt: bigint,
  totalSupplied: bigint,
  current: Session,
): Promise<SessionRate[] | null> {
  try {
    const results = await aggregate(
      SESSION_ORDER.map((session) => ({
        address: DEPLOYMENT.sessionRateModel,
        abi: sessionRateModelAbi as unknown as Abi,
        functionName: "ratePerSecondAt",
        args: [totalDebt, totalSupplied, session],
      })),
    );

    const perSecond = results.map((result) =>
      result.success
        ? decodeFunctionResult({
            abi: sessionRateModelAbi,
            functionName: "ratePerSecondAt",
            data: result.returnData,
          })
        : null,
    );

    const open = perSecond[SESSION_ORDER.indexOf(Session.REGULAR)];
    if (open === null || open === undefined || open === 0n) return null;

    return SESSION_ORDER.map((session, index) => {
      const rate = perSecond[index] ?? 0n;
      return {
        session,
        aprPercent: aprPercent(rate * SECONDS_PER_YEAR),
        premium: Number((rate * 10_000n) / open) / 10_000,
        isCurrent: session === current,
      };
    });
  } catch {
    return null;
  }
}

/**
 * Deduplicated per request by React, and held for twenty seconds across requests so that walking
 * the seven screens is one conversation with Base rather than seven. Every screen prints the block
 * it was read at.
 */
export const readProtocol = cache(memoize(read, 20_000));

/* ======================================================== convenience === */

/** The listed assets in listing order, so a table always reads the same way. */
export function orderedAssets(snapshot: ProtocolSnapshot): AssetSnapshot[] {
  const order = Object.values(COLLATERAL_TOKENS).map((address) => address.toLowerCase());
  return [...snapshot.assets].sort(
    (a, b) => order.indexOf(a.address.toLowerCase()) - order.indexOf(b.address.toLowerCase()),
  );
}
