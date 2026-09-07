import { usdAuto } from "@/lib/format";
import { advanceBpsOf, Session } from "@/lib/session";
import type { LineSnapshot } from "@/server/line";
import type { ProtocolSnapshot } from "@/server/protocol";

import type { ShelfBay, ShelfModel } from "./model";

/**
 * The same drawing the landing page uses, driven by a real position instead of a worked example.
 *
 * Two things differ from the landing's book. The bays are the account's actual posted collateral
 * rather than an even holding, and the ceiling plate is the borrowing power the engine reports for
 * this line rather than a fraction derived from the advance rate.
 *
 * When any oracle in the basket refuses, `frozen` is true and the drawing loses its ceiling
 * entirely. That is not a stylistic choice: the engine reports no borrowing power at all for a
 * basket it cannot fully price -- not a smaller one -- so a plate at any height would assert a
 * limit nobody is standing behind.
 */
export interface LineShelf {
  model: ShelfModel;
  /** True when an oracle in the basket will not publish a mark. */
  frozen: boolean;
}

export function buildLineShelf(line: LineSnapshot, protocol: ProtocolSnapshot): LineShelf | null {
  const marks = new Map(protocol.assets.map((asset) => [asset.address.toLowerCase(), asset]));

  const bays: ShelfBay[] = [];
  for (const holding of line.holdings) {
    if (holding.postedRaw === 0n) continue;
    const asset = marks.get(holding.address.toLowerCase());
    const quote = asset?.quote ?? null;

    /*
     * A refused bay still has to occupy the height its collateral takes up, or the drawing would
     * imply the position is smaller than it is. It is sized from the anchor feed and drawn as an
     * empty cage with no figure attached, so the geometry says "there is collateral here" without
     * quoting a price the protocol will not defend.
     */
    const sizingPrice = holding.markUsd ?? quote?.anchorUsd ?? null;
    if (sizingPrice === null || sizingPrice <= 0) continue;

    bays.push({
      ticker: holding.symbol,
      underlying: holding.underlying,
      valueUsd: holding.postedTokens * sizingPrice,
      quoting: holding.quoting,
      markedAt: holding.quoting ? "feed" : "pool",
    });
  }

  if (bays.length === 0) return null;

  const ordered = [
    ...bays.filter((bay) => bay.quoting).sort((a, b) => b.valueUsd - a.valueUsd),
    ...bays.filter((bay) => !bay.quoting).sort((a, b) => b.valueUsd - a.valueUsd),
  ];

  const basketUsd = ordered.reduce((sum, bay) => sum + bay.valueUsd, 0);
  const lendableUsd = ordered.filter((bay) => bay.quoting).reduce((sum, bay) => sum + bay.valueUsd, 0);

  /*
   * The ceiling is the limit the engine will act on, which is the priced legs alone -- read from
   * `Undercollateralized`, not derived. A basket with nothing priceable in it has no ceiling at any
   * height, and only then does the plate come off the drawing.
   */
  const actionable = line.limits.borrowPowerUsdc;
  const frozen = actionable === null;

  const advanceOpen = advanceBpsOf(Session.REGULAR) / 10_000;
  const advanceClosed = advanceBpsOf(Session.CLOSED_OVERNIGHT) / 10_000;

  const limitClosed = actionable === null ? 0 : actionable / basketUsd;
  const limitOpen = (lendableUsd * advanceOpen) / basketUsd;

  const posted = ordered.length;
  return {
    frozen,
    model: {
      bays: ordered,
      basketUsd,
      lendableUsd,
      drawnUsd: line.debtUsdc,
      advanceOpen,
      advanceClosed,
      limitFractionClosed: clamp(limitClosed),
      limitFractionOpen: clamp(limitOpen),
      drawnFraction: clamp(line.debtUsdc / basketUsd),
      title: {
        key: `Live position · ${posted} ${posted === 1 ? "asset" : "assets"} posted`,
        value: frozen
          ? `${usdAuto(line.debtUsdc)} drawn · nothing in the basket can be priced`
          : `${usdAuto(line.debtUsdc)} drawn against ${usdAuto(actionable)} the engine will act on`,
      },
    },
  };
}

function clamp(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(1, Math.max(0, value));
}
