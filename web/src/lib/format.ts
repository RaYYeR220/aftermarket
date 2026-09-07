/**
 * Formatting for measured values.
 *
 * Two rules hold everywhere: a value that could not be read prints the word
 * `unavailable` rather than a zero or a dash, and no number is rounded to a
 * precision the underlying read does not support.
 */

export const UNAVAILABLE = "unavailable";

const usdWhole = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

const usdCents = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

/** `$62,559`. For depths, balances and limits, where cents are noise. */
export function usd(value: number): string {
  return usdWhole.format(value);
}

/** `$257.69`. For a price, where the cent is the point. */
export function price(value: number): string {
  return usdCents.format(value);
}

/**
 * `$0.56`, `$1.13`, `$62,559`. The default for any amount of money on the application surface.
 *
 * Cents are noise on a five-figure basket and they are the entire number on a fifty-cent line, so
 * the precision follows the magnitude rather than a house style. Rounding $0.56 to `$1` would not
 * be a formatting choice, it would be a false statement about somebody's debt.
 */
export function usdAuto(value: number): string {
  return Math.abs(value) < 1_000 ? usdCents.format(value) : usdWhole.format(value);
}

/** `$62.6k`, `$1.87M`. For depth badges where the column is narrow. */
export function usdCompact(value: number): string {
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(1)}k`;
  return usd(value);
}

/** `9.29%` from 929 basis points. */
export function bpsAsPercent(bps: number, digits = 2): string {
  return `${(bps / 100).toFixed(digits)}%`;
}

/**
 * `92 bps`, `0.4 bps`. Rounding a sub-basis-point gap to `0 bps` would claim
 * the two sources agree exactly, which is a stronger statement than the read
 * supports, so small values keep a decimal.
 */
export function bpsExact(bps: number): string {
  return bps < 10 ? `${bps.toFixed(1)} bps` : `${Math.round(bps)} bps`;
}

/** `65%` from 6500 basis points. Whole points only: these are policy numbers. */
export function bpsAsWholePercent(bps: number): string {
  return `${Math.round(bps / 100)}%`;
}

/** `58h 18m`, `12m`. The unit a stale feed is actually judged in. */
export function durationHm(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (hours === 0) return `${minutes}m`;
  return `${hours}h ${String(minutes).padStart(2, "0")}m`;
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
const MONTHS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
] as const;

/**
 * A wall-clock instant in US Eastern, rendered from the offset the caller
 * already resolved. Deliberately does not touch `Intl` time zones: every ET
 * instant in this app is derived from a chain timestamp plus the DST decision
 * the observer package made, so the host's own zone database never enters.
 */
export interface EasternParts {
  weekday: string;
  day: number;
  month: string;
  hours: number;
  minutes: number;
}

export function easternParts(unixSeconds: number, offsetHours: number): EasternParts {
  const shifted = new Date((unixSeconds + offsetHours * 3600) * 1000);
  return {
    weekday: WEEKDAYS[shifted.getUTCDay()] ?? "",
    day: shifted.getUTCDate(),
    month: MONTHS[shifted.getUTCMonth()] ?? "",
    hours: shifted.getUTCHours(),
    minutes: shifted.getUTCMinutes(),
  };
}

function pad2(value: number): string {
  return String(value).padStart(2, "0");
}

/** `Fri 16:00 ET`. */
export function etDayTime(unixSeconds: number, offsetHours: number): string {
  const p = easternParts(unixSeconds, offsetHours);
  return `${p.weekday} ${pad2(p.hours)}:${pad2(p.minutes)} ET`;
}

/** `Mon 07 Sep · 02:25 ET`. The session readout on the rail. */
export function etStamp(unixSeconds: number, offsetHours: number): string {
  const p = easternParts(unixSeconds, offsetHours);
  return `${p.weekday} ${pad2(p.day)} ${p.month} · ${pad2(p.hours)}:${pad2(p.minutes)} ET`;
}

/** `0x1804…1f38`. */
export function shortAddress(address: string): string {
  if (address.length < 12) return address;
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}
