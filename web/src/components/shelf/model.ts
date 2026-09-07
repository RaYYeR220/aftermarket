import { usd } from "@/lib/format";
import { DEPLOYED_PARAMS, WORKED_EXAMPLE } from "@/lib/site";
import { isTrusted } from "@/lib/verdict";
import type { AssetRead, MarketRead } from "@/server/market-data";

/**
 * The book the hero drawing is built from.
 *
 * The *shape* of the position is a worked example, and the page says so: a flat
 * holding across every listed asset, with the line drawn to a stated fraction
 * of the limit the closed session allows. Every price underneath it is a live
 * Base mainnet read, and so is the decision about which bays count toward the
 * limit at all.
 *
 * Bays are stacked with the collateral the oracle will quote at the bottom and
 * the collateral it refuses at the top, because that is literally where they
 * sit: refused collateral ends up above the ceiling plate, in the wireframe,
 * which is the drawing's way of saying the session will not lend against it.
 */

export interface ShelfBay {
  ticker: string;
  underlying: string;
  valueUsd: number;
  /** True when the oracle would quote this asset right now. */
  quoting: boolean;
  /** Which source the value above was marked at. */
  markedAt: "feed" | "pool";
}

export interface ShelfModel {
  bays: ShelfBay[];
  /** Every listed bay, at its current mark. */
  basketUsd: number;
  /** The part of the basket the oracle will quote, and therefore lend against. */
  lendableUsd: number;
  drawnUsd: number;
  advanceOpen: number;
  advanceClosed: number;
  /** Fraction of the full column the ceiling plate sits at, with the market shut. */
  limitFractionClosed: number;
  /** The same, with the market open. */
  limitFractionOpen: number;
  drawnFraction: number;
  /** The title block under the drawing: what this book is, and what it currently totals. */
  title: { key: string; value: string };
}

function markOf(asset: AssetRead): { price: number; source: "feed" | "pool" } | null {
  if (isTrusted(asset.verdict) && asset.feedPriceUsd !== null) {
    return { price: asset.feedPriceUsd, source: "feed" };
  }
  if (asset.poolTwapUsd !== null) return { price: asset.poolTwapUsd, source: "pool" };
  if (asset.feedPriceUsd !== null) return { price: asset.feedPriceUsd, source: "feed" };
  return null;
}

export function buildShelfModel(market: MarketRead): ShelfModel | null {
  const shares = WORKED_EXAMPLE.sharesPerAsset;

  const priced = market.listed.flatMap<ShelfBay>((asset) => {
    const mark = markOf(asset);
    if (mark === null) return [];
    return [
      {
        ticker: asset.ticker,
        underlying: asset.underlying,
        valueUsd: mark.price * shares,
        quoting: isTrusted(asset.verdict),
        markedAt: mark.source,
      },
    ];
  });

  if (priced.length === 0) return null;

  const bays = [
    ...priced.filter((bay) => bay.quoting).sort((a, b) => b.valueUsd - a.valueUsd),
    ...priced.filter((bay) => !bay.quoting).sort((a, b) => b.valueUsd - a.valueUsd),
  ];

  const basketUsd = bays.reduce((sum, bay) => sum + bay.valueUsd, 0);
  const lendableUsd = bays.filter((bay) => bay.quoting).reduce((sum, bay) => sum + bay.valueUsd, 0);

  const advanceOpen = DEPLOYED_PARAMS.advanceOpenBps / 10_000;
  const advanceClosed = DEPLOYED_PARAMS.advanceClosedBps / 10_000;

  const limitClosedUsd = lendableUsd * advanceClosed;
  const drawnUsd = limitClosedUsd * WORKED_EXAMPLE.drawnFractionOfLimit;

  return {
    bays,
    basketUsd,
    lendableUsd,
    drawnUsd,
    advanceOpen,
    advanceClosed,
    limitFractionClosed: (lendableUsd * advanceClosed) / basketUsd,
    limitFractionOpen: (lendableUsd * advanceOpen) / basketUsd,
    drawnFraction: drawnUsd / basketUsd,
    title: {
      key: `Worked example · ${shares} shares of each listed stock`,
      value: `${usd(basketUsd)} across ${bays.length} bays, marked live`,
    },
  };
}
