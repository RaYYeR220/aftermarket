import { formatUnits } from "viem";
import { isMarketOpenSession, Verdict, type Quote } from "./types.js";

/**
 * Short, imperative guidance for what a consumer should do on each {@link Verdict}. Used to build
 * the verdict table in the package README — keep the two in sync if you change this.
 */
export const VERDICT_GUIDANCE: Record<Verdict, string> = {
  [Verdict.TRUSTED]: "Use the mark normally. Market is open and every source agrees.",
  [Verdict.TRUSTED_CLOSED]:
    "Use the mark normally. Market is closed as expected; a gap-risk haircut is already baked in.",
  [Verdict.UNTRUSTED_STALE]:
    "Do not use the mark. `price()`/`markBorrow()`/`markLiquidate()` revert — wait for the feed to refresh.",
  [Verdict.UNTRUSTED_DIVERGENT]:
    "Do not use the mark. `price()`/`markBorrow()`/`markLiquidate()` revert — wait for sources to reconverge.",
  [Verdict.UNTRUSTED_THIN]:
    "Do not use the mark. `price()`/`markBorrow()`/`markLiquidate()` revert — wait for pool depth to recover or the market to reopen.",
  [Verdict.UNTRUSTED_HALTED]:
    "Do not use the mark. `price()`/`markBorrow()`/`markLiquidate()` revert — wait for the halt to lift.",
};

/**
 * Renders a {@link Quote} as a plain-English sentence a UI can display as-is — the copy a support
 * ticket or a risk dashboard would otherwise have to hand-write for every one of the six verdicts.
 *
 * Every branch reads only the fields on `quote`, so it works equally well on the `bigint`-only
 * {@link Quote} returned by a raw `peek()` decode and on the enriched `DecodedQuote`.
 */
export function explainVerdict(quote: Quote): string {
  const open = isMarketOpenSession(quote.session);

  switch (quote.verdict) {
    case Verdict.TRUSTED:
      return (
        `Market is open and the reference feed and pool agree within ` +
        `${formatBand(quote.divergenceBand)} — the mark is fully trusted.`
      );

    case Verdict.TRUSTED_CLOSED:
      return (
        `Market is closed and reopens ${formatNextOpen(quote.nextOpen)}. Reference feed and pool still ` +
        `agree, so a ${formatBand(quote.haircutBps)} gap-risk haircut is applied to both marks — safe to ` +
        `use for new borrowing and liquidation.`
      );

    case Verdict.UNTRUSTED_STALE:
      return open
        ? `Reference feed hasn't updated in ${formatHours(quote.feedAge)} — older than the ` +
            `${formatHours(quote.stalenessBudget)} tolerated while the market is open. No mark can be ` +
            `trusted until it refreshes.`
        : `Reference feed has been frozen for ${formatHours(quote.feedAge)}, beyond the ` +
            `${formatHours(quote.stalenessBudget)} tolerated for a closed market. No mark can be trusted ` +
            `until the market reopens ${formatNextOpen(quote.nextOpen)}.`;

    case Verdict.UNTRUSTED_DIVERGENT:
      return (
        `Reference feed and pool disagree by ${formatPercent(quote.divergenceBps)} with only ` +
        `${formatUsdCompact(quote.poolLiquidityUsd)} of depth — no mark can be defended ` +
        `${open ? "right now" : `until the market reopens ${formatNextOpen(quote.nextOpen)}`}.`
      );

    case Verdict.UNTRUSTED_THIN:
      return (
        `The pool backing this feed has only ${formatUsdCompact(quote.poolLiquidityUsd)} of depth — too ` +
        `thin to corroborate the ${open ? "feed right now" : "frozen feed while the market is closed"}. ` +
        `No mark can be trusted until ${open ? "depth improves" : `the market reopens ${formatNextOpen(quote.nextOpen)}`}.`
      );

    case Verdict.UNTRUSTED_HALTED:
      return (
        `Trading is halted — a corporate-action multiplier (${formatMultiplier(quote.multiplier)}) or an ` +
        `issuer pause is in effect. No mark can be trusted until the halt lifts` +
        `${open ? "" : `, even though the market technically reopens ${formatNextOpen(quote.nextOpen)}`}.`
      );
  }
}

/** `9.29%` from a bps `bigint`. */
function formatPercent(bps: bigint): string {
  return `${(Number(bps) / 100).toFixed(2)}%`;
}

/** `25 bps` from a bps `bigint` — used where "bps" reads more naturally than a percent sign. */
function formatBand(bps: bigint): string {
  return `${bps.toString()} bps`;
}

/** `$62.5k`, `$1.2M`, or `$430.00` from a WAD (1e18) USD `bigint`, matched to the scale of the number. */
function formatUsdCompact(wad: bigint): string {
  const usd = Number(formatUnits(wad, 18));
  if (!Number.isFinite(usd)) return "an unknown amount";
  const abs = Math.abs(usd);
  if (abs >= 1_000_000) return `$${(usd / 1_000_000).toFixed(1)}M`;
  if (abs >= 1_000) return `$${(usd / 1_000).toFixed(1)}k`;
  return `$${usd.toFixed(2)}`;
}

/** `52 hours` or `18 minutes` from a seconds `bigint`. */
function formatHours(seconds: bigint): string {
  const totalSeconds = Number(seconds);
  if (!Number.isFinite(totalSeconds)) return "an unknown amount of time";
  const totalHours = totalSeconds / 3600;
  if (totalHours < 1) return `${Math.max(0, Math.round(totalSeconds / 60))} minutes`;
  return `${totalHours.toFixed(totalHours < 10 ? 1 : 0)} hours`;
}

/** `1.0000x` from a WAD `bigint` multiplier. */
function formatMultiplier(wad: bigint): string {
  return `${Number(formatUnits(wad, 18)).toFixed(4)}x`;
}

/**
 * `Monday 09:30 ET` from a unix-seconds `bigint`, in US Eastern time (DST-aware via the IANA
 * `America/New_York` zone).
 */
function formatNextOpen(nextOpen: bigint): string {
  const date = new Date(Number(nextOpen) * 1000);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    weekday: "long",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);

  const weekday = parts.find((part) => part.type === "weekday")?.value ?? "";
  const hour = parts.find((part) => part.type === "hour")?.value ?? "";
  const minute = parts.find((part) => part.type === "minute")?.value ?? "";
  return `${weekday} ${hour}:${minute} ET`;
}
