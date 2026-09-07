import { getUsMarketStatus } from "@aftermarket/observer";

import { Session } from "@/lib/session";
import { NYSE_HOLIDAY_NAMES } from "@/lib/site";

/**
 * US equity session arithmetic, derived from the chain clock.
 *
 * The holiday calendar and the DST rule both live in `@aftermarket/observer`,
 * which is the same table the onchain `TradingCalendar` was seeded from. This
 * module adds only what a page needs on top of "is it open right now": when the
 * last defensible print was, when the next one is due, and which of the six
 * sessions the contracts recognise we are currently in.
 *
 * Nothing here reads the host machine's clock or its timezone database. Every
 * instant is a Base block timestamp.
 */

export { Session, SESSION_LABEL } from "@/lib/session";

const PRE_OPEN_MINUTES = 4 * 60;
const REGULAR_OPEN_MINUTES = 9 * 60 + 30;
const REGULAR_CLOSE_MINUTES = 16 * 60;
const POST_CLOSE_MINUTES = 20 * 60;

const SEARCH_DAYS = 14;

/** ET UTC offset in hours at an instant, taken from the observer's DST decision. */
export function etOffsetHours(unixSeconds: number): number {
  return getUsMarketStatus(unixSeconds).isDst ? -4 : -5;
}

interface EtCalendarDay {
  year: number;
  monthIndex: number;
  day: number;
  minutesSinceMidnight: number;
}

function etCalendarDay(unixSeconds: number): EtCalendarDay {
  const shifted = new Date((unixSeconds + etOffsetHours(unixSeconds) * 3600) * 1000);
  return {
    year: shifted.getUTCFullYear(),
    monthIndex: shifted.getUTCMonth(),
    day: shifted.getUTCDate(),
    minutesSinceMidnight: shifted.getUTCHours() * 60 + shifted.getUTCMinutes(),
  };
}

/**
 * The instant of `hours:minutes` ET on the ET calendar day `dayOffset` days
 * away from the day containing `unixSeconds`.
 *
 * The offset is resolved from 12:00 UTC on the target day, which is 07:00 or
 * 08:00 ET and therefore always inside the intended calendar day, so a DST
 * boundary between the two dates cannot shift the result onto the wrong day.
 */
function etInstant(unixSeconds: number, dayOffset: number, hours: number, minutes: number): number {
  const base = etCalendarDay(unixSeconds);
  const middayUtc = Date.UTC(base.year, base.monthIndex, base.day + dayOffset, 12, 0, 0) / 1000;
  const offset = etOffsetHours(middayUtc);
  return Date.UTC(base.year, base.monthIndex, base.day + dayOffset, hours - offset, minutes, 0) / 1000;
}

/** True when the ET calendar day containing `unixSeconds` runs a regular session. */
function isTradingDay(unixSeconds: number): boolean {
  return getUsMarketStatus(etInstant(unixSeconds, 0, 12, 0)).isOpen;
}

/** The next regular open at or after `unixSeconds`, or `null` if none falls inside the search window. */
export function nextRegularOpen(unixSeconds: number): number | null {
  for (let dayOffset = 0; dayOffset <= SEARCH_DAYS; dayOffset += 1) {
    const candidate = etInstant(unixSeconds, dayOffset, 9, 30);
    if (candidate >= unixSeconds && getUsMarketStatus(candidate).isOpen) return candidate;
  }
  return null;
}

/** The most recent regular close at or before `unixSeconds`, or `null` if none falls inside the search window. */
export function previousRegularClose(unixSeconds: number): number | null {
  for (let dayOffset = 0; dayOffset >= -SEARCH_DAYS; dayOffset -= 1) {
    const candidate = etInstant(unixSeconds, dayOffset, 16, 0);
    if (candidate <= unixSeconds && isTradingDay(candidate)) return candidate;
  }
  return null;
}

/** Which of the six contract sessions `unixSeconds` falls in. */
export function classifySession(unixSeconds: number): Session {
  const status = getUsMarketStatus(unixSeconds);
  if (status.reason.includes("weekend")) return Session.CLOSED_WEEKEND;
  if (status.reason.includes("holiday")) return Session.CLOSED_HOLIDAY;

  const { minutesSinceMidnight } = etCalendarDay(unixSeconds);
  if (minutesSinceMidnight < PRE_OPEN_MINUTES || minutesSinceMidnight >= POST_CLOSE_MINUTES) {
    return Session.CLOSED_OVERNIGHT;
  }
  if (minutesSinceMidnight < REGULAR_OPEN_MINUTES) return Session.PRE;
  if (minutesSinceMidnight < REGULAR_CLOSE_MINUTES) return Session.REGULAR;
  return Session.POST;
}

/** `Labor Day` when the ET day containing `unixSeconds` is a full NYSE closure, otherwise `null`. */
export function holidayName(unixSeconds: number): string | null {
  const day = etCalendarDay(unixSeconds);
  const key = `${day.year}-${String(day.monthIndex + 1).padStart(2, "0")}-${String(day.day).padStart(2, "0")}`;
  return NYSE_HOLIDAY_NAMES[key] ?? null;
}

/** One stretch of the rail timeline in which the market state does not change. */
export interface RailSegment {
  fromUnix: number;
  toUnix: number;
  isOpen: boolean;
  /** What that stretch is, in the interface's own words. */
  note: string;
}

export interface RailTick {
  atUnix: number;
  label: string;
}

/**
 * The session the hero rail scrubs through: from four hours before the last
 * regular close to two and a half hours after the next regular open, so both
 * ends of the closed stretch are on screen.
 *
 * Resolved on the server and handed to the browser as plain numbers. The
 * calendar, the DST rule and the holiday table stay out of the client bundle.
 */
export interface RailTimeline {
  startUnix: number;
  endUnix: number;
  nowUnix: number;
  etOffsetHours: number;
  segments: RailSegment[];
  ticks: RailTick[];
}

const STEP_SECONDS = 15 * 60;
const WEEKDAY_LABELS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

function describe(unixSeconds: number): { isOpen: boolean; note: string } {
  const session = classifySession(unixSeconds);
  switch (session) {
    case Session.REGULAR:
      return { isOpen: true, note: "Market open · regular session" };
    case Session.PRE:
      return { isOpen: false, note: "Market closed · pre-open" };
    case Session.POST:
      return { isOpen: false, note: "Market closed · after the bell" };
    case Session.CLOSED_OVERNIGHT:
      return { isOpen: false, note: "Market closed · overnight" };
    case Session.CLOSED_WEEKEND:
      return { isOpen: false, note: "Market closed · weekend" };
    case Session.CLOSED_HOLIDAY: {
      const name = holidayName(unixSeconds);
      return { isOpen: false, note: name ? `Market closed · ${name}` : "Market closed · market holiday" };
    }
  }
}

export function buildRailTimeline(nowUnix: number): RailTimeline | null {
  const previousClose = previousRegularClose(nowUnix);
  const nextOpen = nextRegularOpen(nowUnix);
  if (previousClose === null || nextOpen === null) return null;

  const startUnix = previousClose - 4 * 3600;
  const endUnix = nextOpen + Math.round(2.5 * 3600);

  const segments: RailSegment[] = [];
  for (let t = startUnix; t < endUnix; t += STEP_SECONDS) {
    const { isOpen, note } = describe(t);
    const last = segments[segments.length - 1];
    if (last && last.isOpen === isOpen && last.note === note) {
      last.toUnix = Math.min(t + STEP_SECONDS, endUnix);
    } else {
      segments.push({ fromUnix: t, toUnix: Math.min(t + STEP_SECONDS, endUnix), isOpen, note });
    }
  }

  const ticks: RailTick[] = [];
  for (let dayOffset = 0; dayOffset <= 8; dayOffset += 1) {
    const midnight = etInstant(startUnix, dayOffset, 0, 0);
    if (midnight < startUnix || midnight > endUnix) continue;
    const shifted = new Date((midnight + etOffsetHours(midnight) * 3600) * 1000);
    ticks.push({ atUnix: midnight, label: WEEKDAY_LABELS[shifted.getUTCDay()] ?? "" });
  }

  return { startUnix, endUnix, nowUnix, etOffsetHours: etOffsetHours(nowUnix), segments, ticks };
}
