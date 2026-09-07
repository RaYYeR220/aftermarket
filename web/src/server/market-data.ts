import "server-only";

import { cache } from "react";

import { buildReport, createObserverClient } from "@aftermarket/observer";

import { baseRpcUrl } from "@/lib/env";
import { DEPLOYED_PARAMS, LISTED_COLLATERAL, underlyingTicker } from "@/lib/site";
import { isTrusted, Verdict } from "@/lib/verdict";

import { classifySession, etOffsetHours, nextRegularOpen, previousRegularClose, Session } from "./calendar";

/**
 * The data-layer boundary.
 *
 * Everything the browser is told about Base mainnet passes through this module,
 * and it has one rule: a read that failed is reported as a failure. There is no
 * default price, no cached last-known value standing in for a live one and no
 * zero where a number could not be fetched. The UI renders the word
 * `unavailable`, which is a true statement, instead of a figure that is not.
 *
 * The app surface, when it lands, reads its state from here too -- the same
 * `Fallible` shape, the same failure discipline.
 */

/** A value that was read, or an explanation of why it could not be. Never a guess. */
export type Fallible<T> = { ok: true; value: T } | { ok: false; error: string };

export interface AssetRead {
  /** B20 ticker as listed by Coinbase, e.g. `AMZNc`. */
  ticker: string;
  /** The equity behind it, e.g. `AMZN`. */
  underlying: string;
  /** True when the mainnet deployment lists this asset as collateral. */
  isListed: boolean;
  /** Last Chainlink total-return print, in USD. */
  feedPriceUsd: number | null;
  /** Age of that print at the block this was read at. */
  feedAgeSeconds: number | null;
  /** Aerodrome Slipstream 30-minute TWAP, in USD. */
  poolTwapUsd: number | null;
  /** USDC sitting in the Slipstream pool. */
  poolDepthUsd: number | null;
  /** Distance between the two sources, in basis points. */
  divergenceBps: number | null;
  verdict: Verdict;
  /** Why the verdict came out that way, in one sentence. */
  reason: string;
}

export interface SessionRead {
  session: Session;
  isOpen: boolean;
  /** UTC offset in hours that applies to every ET stamp derived from this read. */
  etOffsetHours: number;
  /** Most recent regular close, as a unix timestamp. */
  previousCloseUnix: number | null;
  /** Next regular open, as a unix timestamp. */
  nextOpenUnix: number | null;
  /** Seconds between those two prints, when both are known. */
  gapSeconds: number | null;
  /** How stale a feed may be before this session stops trusting it. */
  stalenessBudgetSeconds: number;
  /** How far the two sources may sit apart before this session stops trusting them. */
  divergenceBandBps: number;
  /** The observer's own sentence for why the market is in this state. */
  reason: string;
}

export interface MarketRead {
  blockNumber: string;
  blockTimestampUnix: number;
  session: SessionRead;
  assets: AssetRead[];
  /** Listed collateral only, in listing order. */
  listed: AssetRead[];
  /** The listed asset whose two sources disagree most, when at least one has both sources. */
  widestDivergence: AssetRead | null;
  /** Listed assets the oracle would quote right now. */
  quotingCount: number;
  /** Listed assets the oracle would refuse to quote right now. */
  refusingCount: number;
  /** Observed B20 tokens that have an Aerodrome pool to check the feed against. */
  pricedCount: number;
  /** Observed B20 tokens with no independent onchain price at all. */
  unpricedCount: number;
}

export type MarketData = Fallible<MarketRead>;

function sessionPolicy(session: Session): { staleness: number; band: number } {
  const staleness = DEPLOYED_PARAMS.stalenessBudgetSeconds[session] ?? 0;
  const band = DEPLOYED_PARAMS.divergenceBandBps[session] ?? 0;
  return { staleness, band };
}

function classifyAsset(
  args: {
    feedPriceUsd: number | null;
    feedAgeSeconds: number | null;
    poolTwapUsd: number | null;
    poolDepthUsd: number | null;
    divergenceBps: number | null;
    poolError: string | null;
  },
  session: Session,
): { verdict: Verdict; reason: string } {
  const { staleness, band } = sessionPolicy(session);
  const marketOpen = session <= Session.POST;

  if (args.feedPriceUsd === null || args.feedAgeSeconds === null) {
    return {
      verdict: Verdict.UNTRUSTED_HALTED,
      reason: "The reference feed did not answer, so there is no anchor to check anything against.",
    };
  }
  if (args.poolTwapUsd === null || args.poolDepthUsd === null) {
    return {
      verdict: Verdict.UNTRUSTED_THIN,
      reason: args.poolError ?? "No Aerodrome pool exists for this token, so the feed cannot be checked.",
    };
  }
  if (args.poolDepthUsd < DEPLOYED_PARAMS.minPoolLiquidityUsd) {
    return {
      verdict: Verdict.UNTRUSTED_THIN,
      reason: `Only ${Math.round(args.poolDepthUsd).toLocaleString("en-US")} USDC of depth backs the pool price, below the ${DEPLOYED_PARAMS.minPoolLiquidityUsd.toLocaleString("en-US")} floor the oracle needs to believe it.`,
    };
  }
  if (args.feedAgeSeconds > staleness) {
    return {
      verdict: Verdict.UNTRUSTED_STALE,
      reason: `The feed has not printed for longer than this session allows, so the anchor has expired.`,
    };
  }
  if (args.divergenceBps !== null && args.divergenceBps > band) {
    return {
      verdict: Verdict.UNTRUSTED_DIVERGENT,
      reason: `Feed and pool are ${(args.divergenceBps / 100).toFixed(2)}% apart, past the ${(band / 100).toFixed(2)}% this session tolerates.`,
    };
  }
  return {
    verdict: marketOpen ? Verdict.TRUSTED : Verdict.TRUSTED_CLOSED,
    reason: marketOpen
      ? "Feed and pool agree and the market is open, so the mark is the live price."
      : "Feed and pool still agree, so the closed-session mark holds at the last print.",
  };
}

async function read(): Promise<MarketData> {
  const rpcUrl = baseRpcUrl();
  try {
    const client = createObserverClient(rpcUrl);
    const report = await buildReport(client, { rpcUrl });

    const timestamp = Number(report.block.timestampUnix);
    const session = classifySession(timestamp);
    const { staleness, band } = sessionPolicy(session);
    const previousCloseUnix = previousRegularClose(timestamp);
    const nextOpenUnix = nextRegularOpen(timestamp);

    const assets: AssetRead[] = report.assets.map((asset) => {
      const feedPriceUsd = asset.feed.ok ? asset.feed.value.price : null;
      const feedAgeSeconds = asset.feed.ok ? asset.feed.value.stalenessSeconds : null;
      const poolTwapUsd = asset.pool.ok ? asset.pool.value.twapPriceUsd : null;
      const poolDepthUsd = asset.pool.ok ? asset.pool.value.usdcDepth : null;
      const divergenceBps = asset.divergenceBps.ok ? asset.divergenceBps.value : null;
      const poolError = asset.pool.ok ? null : asset.pool.error;

      const { verdict, reason } = classifyAsset(
        { feedPriceUsd, feedAgeSeconds, poolTwapUsd, poolDepthUsd, divergenceBps, poolError },
        session,
      );

      return {
        ticker: asset.ticker,
        underlying: underlyingTicker(asset.ticker),
        isListed: (LISTED_COLLATERAL as readonly string[]).includes(asset.ticker),
        feedPriceUsd,
        feedAgeSeconds,
        poolTwapUsd,
        poolDepthUsd,
        divergenceBps,
        verdict,
        reason,
      };
    });

    const byTicker = new Map(assets.map((asset) => [asset.ticker, asset]));
    const listed = LISTED_COLLATERAL.map((ticker) => byTicker.get(ticker)).filter(
      (asset): asset is AssetRead => asset !== undefined,
    );

    const widestDivergence = listed.reduce<AssetRead | null>((widest, asset) => {
      if (asset.divergenceBps === null) return widest;
      if (widest?.divergenceBps === undefined || widest.divergenceBps === null) return asset;
      return asset.divergenceBps > widest.divergenceBps ? asset : widest;
    }, null);

    return {
      ok: true,
      value: {
        blockNumber: report.block.number.toString(),
        blockTimestampUnix: timestamp,
        session: {
          session,
          isOpen: report.market.isOpen,
          etOffsetHours: etOffsetHours(timestamp),
          previousCloseUnix,
          nextOpenUnix,
          gapSeconds:
            previousCloseUnix !== null && nextOpenUnix !== null ? nextOpenUnix - previousCloseUnix : null,
          stalenessBudgetSeconds: staleness,
          divergenceBandBps: band,
          reason: report.market.reason,
        },
        assets,
        listed,
        widestDivergence,
        quotingCount: listed.filter((asset) => isTrusted(asset.verdict)).length,
        refusingCount: listed.filter((asset) => !isTrusted(asset.verdict)).length,
        pricedCount: assets.filter((asset) => asset.poolTwapUsd !== null).length,
        unpricedCount: assets.filter((asset) => asset.poolTwapUsd === null).length,
      },
    };
  } catch (error) {
    const message = error instanceof Error ? error.message.split("\n")[0] : String(error);
    return { ok: false, error: message ?? "the Base RPC endpoint did not answer" };
  }
}

/**
 * Deduplicated per request. The revalidate window that decides how often this
 * actually hits Base lives on the route segment that renders it.
 */
export const readMarket = cache(read);
