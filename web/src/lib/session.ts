import { DEPLOYED_PARAMS } from "./site";

/**
 * The six market sessions, as the contracts number them.
 *
 * Mirrors the `Session` enum in `contracts/src/libraries/Types.sol` ordinal for ordinal. Kept in
 * `lib` rather than in the server calendar so that a client component can name a session without
 * pulling the holiday table and the DST rule into the browser bundle.
 */
export const Session = {
  REGULAR: 0,
  PRE: 1,
  POST: 2,
  CLOSED_OVERNIGHT: 3,
  CLOSED_WEEKEND: 4,
  CLOSED_HOLIDAY: 5,
} as const;

export type Session = (typeof Session)[keyof typeof Session];

export const SESSION_ORDER: readonly Session[] = [
  Session.REGULAR,
  Session.PRE,
  Session.POST,
  Session.CLOSED_OVERNIGHT,
  Session.CLOSED_WEEKEND,
  Session.CLOSED_HOLIDAY,
];

/** The sentence a session prints as. */
export const SESSION_LABEL: Record<Session, string> = {
  [Session.REGULAR]: "Regular session",
  [Session.PRE]: "Pre-market",
  [Session.POST]: "Post-market",
  [Session.CLOSED_OVERNIGHT]: "Closed overnight",
  [Session.CLOSED_WEEKEND]: "Closed for the weekend",
  [Session.CLOSED_HOLIDAY]: "Closed for a market holiday",
};

/** The same thing where a column is narrow. */
export const SESSION_SHORT: Record<Session, string> = {
  [Session.REGULAR]: "Regular",
  [Session.PRE]: "Pre-market",
  [Session.POST]: "Post-market",
  [Session.CLOSED_OVERNIGHT]: "Overnight",
  [Session.CLOSED_WEEKEND]: "Weekend",
  [Session.CLOSED_HOLIDAY]: "Holiday",
};

/**
 * True for the three sessions with a live tape.
 *
 * This is the oracle's sense of "open" -- the one that decides a staleness budget and a divergence
 * band. It is deliberately *not* the credit engine's sense: see {@link isRegularSession}.
 */
export function isMarketOpenSession(session: Session): boolean {
  return session === Session.REGULAR || session === Session.PRE || session === Session.POST;
}

/**
 * True only during the regular session, which is the credit engine's definition of an open market.
 *
 * `AftermarketCredit._isOpen` returns `s == Session.REGULAR` and nothing else, so the higher advance
 * rate and the earlier seizure threshold apply between the bells and at no other time. Pre- and
 * post-market have a tape but not the depth to unwind a position into, and the engine prices that
 * distinction even though the oracle does not.
 */
export function isRegularSession(session: Session): boolean {
  return session === Session.REGULAR;
}

/** Narrows a `uint8` the chain returned into a {@link Session}, or `null` if it is not one. */
export function toSession(value: number): Session | null {
  return SESSION_ORDER.includes(value as Session) ? (value as Session) : null;
}

/**
 * Advance rate in force for this session, in basis points of collateral value.
 *
 * Mirrors `AftermarketCredit`: the open rate applies during the regular session only, so pre- and
 * post-market carry the closed rate.
 */
export function advanceBpsOf(session: Session): number {
  return isRegularSession(session) ? DEPLOYED_PARAMS.advanceOpenBps : DEPLOYED_PARAMS.advanceClosedBps;
}

/**
 * The session as a phrase that reads inside a sentence, e.g. "on a market holiday".
 *
 * `SESSION_LABEL` is a heading; lowercasing it produces "closed for a market holiday", which cannot
 * be dropped into prose without mangling it.
 */
export const SESSION_PHRASE: Record<Session, string> = {
  [Session.REGULAR]: "during the regular session",
  [Session.PRE]: "before the opening bell",
  [Session.POST]: "after the closing bell",
  [Session.CLOSED_OVERNIGHT]: "overnight",
  [Session.CLOSED_WEEKEND]: "over the weekend",
  [Session.CLOSED_HOLIDAY]: "on a market holiday",
};
