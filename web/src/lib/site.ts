/** Canonical, environment-independent facts about the product this site describes. */

export const SITE = {
  name: "Aftermarket",
  /** One line, used as the meta description and the OG description. */
  summary:
    "A portfolio line of credit against Coinbase tokenized stocks on Base. While the US market is closed the oracle will not publish a mark it cannot defend.",
  tagline: "The ceiling comes down when the market shuts.",
  chainId: 8453,
  chainName: "Base",
  sdkPackage: "@aftermarket/session-oracle",
  /**
   * The hosted app. `NEXT_PUBLIC_SITE_URL` is set to this in production, which is
   * what actually drives the OG tags, the manifest and the SIWE domain check --
   * this constant is the canonical record of where the deployment lives.
   */
  url: "https://aftermarket-fawn.vercel.app",
  repository: "https://github.com/RaYYeR220/aftermarket",
  explorer: "https://basescan.org",
} as const;

/**
 * Risk and oracle parameters as deployed to Base mainnet. Mirrors
 * `contracts/script/config/base.json` -- the file the deploy script reads --
 * so the landing page quotes the numbers the contracts were actually
 * constructed with rather than a rounded illustration of them.
 */
export const DEPLOYED_PARAMS = {
  advanceOpenBps: 6_500,
  advanceClosedBps: 5_000,
  liqThresholdOpenBps: 8_000,
  liqThresholdClosedBps: 8_500,
  liqBonusBps: 700,
  twapWindowSeconds: 1_800,
  minPoolLiquidityUsd: 25_000,
  maxHaircutBps: 500,
  haircutSlopeBpsPerHour: 15,
  baseHaircutBps: 25,
  morphoLltvBps: 7_700,
  /**
   * Per-session tolerances, indexed by the `Session` ordinal
   * (REGULAR, PRE, POST, CLOSED_OVERNIGHT, CLOSED_WEEKEND, CLOSED_HOLIDAY).
   * A feed older than its budget, or two sources further apart than the band,
   * makes the mark undefendable for that session.
   */
  stalenessBudgetSeconds: [3_600, 21_600, 21_600, 90_000, 273_600, 360_000],
  divergenceBandBps: [500, 500, 500, 200, 250, 300],
  /**
   * Borrow-rate multiplier per session, same ordinals. A closed market costs
   * more to borrow into because the lender is carrying a gap nobody can hedge
   * until the bell.
   */
  sessionMultiplierBps: [10_000, 10_000, 10_000, 12_500, 15_000, 16_000],
} as const;

/** The six B20 collateral assets listed by the mainnet deployment, in listing order. */
export const LISTED_COLLATERAL = ["NVDAc", "AAPLc", "METAc", "GOOGLc", "TSLAc", "AMZNc"] as const;

export type ListedTicker = (typeof LISTED_COLLATERAL)[number];

/**
 * The worked example the hero drawing is built from. It is an example, and the
 * page says so: a flat holding across every listed asset, marked at whatever
 * price the oracle would defend right now, with the line drawn to a stated
 * fraction of basket value. Only the shape of the position is invented -- every
 * price behind it is read from Base mainnet.
 */
export const WORKED_EXAMPLE = {
  sharesPerAsset: 25,
  drawnFractionOfLimit: 0.68,
} as const;

/**
 * NYSE full-day closures, by ET calendar date. The dates themselves are the
 * observer package's calendar and the onchain `TradingCalendar`; only the names
 * live here, so a closed session can say which holiday shut it rather than
 * "a market holiday".
 */
export const NYSE_HOLIDAY_NAMES: Readonly<Record<string, string>> = {
  "2026-01-01": "New Year's Day",
  "2026-01-19": "Martin Luther King, Jr. Day",
  "2026-02-16": "Washington's Birthday",
  "2026-04-03": "Good Friday",
  "2026-05-25": "Memorial Day",
  "2026-06-19": "Juneteenth",
  "2026-07-03": "Independence Day, observed",
  "2026-09-07": "Labor Day",
  "2026-11-26": "Thanksgiving Day",
  "2026-12-25": "Christmas Day",
  "2027-01-01": "New Year's Day",
  "2027-01-18": "Martin Luther King, Jr. Day",
  "2027-02-15": "Washington's Birthday",
  "2027-03-26": "Good Friday",
  "2027-05-31": "Memorial Day",
  "2027-06-18": "Juneteenth, observed",
  "2027-07-05": "Independence Day, observed",
  "2027-09-06": "Labor Day",
  "2027-11-25": "Thanksgiving Day",
  "2027-12-24": "Christmas Day, observed",
};

/** Strips the trailing `c` Coinbase appends to a tokenized ticker. */
export function underlyingTicker(ticker: string): string {
  return ticker.endsWith("c") ? ticker.slice(0, -1) : ticker;
}
