import { Verdict as VerdictOrdinal } from "@aftermarket/session-oracle";

import { Verdict } from "./verdict";

/**
 * The protocol's vocabulary, in the app's own types.
 *
 * Three enumerations cross the ABI boundary as bare `uint8`s -- the oracle's verdict, the lens's
 * preview reason and the agent's refusal reason -- and each one is the difference between an
 * interface that explains itself and one that shows a spinner. They are narrowed here, once, and
 * every screen reads the narrowed value.
 */

/* ============================================================== verdict === */

const VERDICT_BY_ORDINAL: Readonly<Record<number, Verdict>> = {
  [VerdictOrdinal.TRUSTED]: Verdict.TRUSTED,
  [VerdictOrdinal.TRUSTED_CLOSED]: Verdict.TRUSTED_CLOSED,
  [VerdictOrdinal.UNTRUSTED_STALE]: Verdict.UNTRUSTED_STALE,
  [VerdictOrdinal.UNTRUSTED_DIVERGENT]: Verdict.UNTRUSTED_DIVERGENT,
  [VerdictOrdinal.UNTRUSTED_THIN]: Verdict.UNTRUSTED_THIN,
  [VerdictOrdinal.UNTRUSTED_HALTED]: Verdict.UNTRUSTED_HALTED,
};

/**
 * Narrows the `uint8` an oracle returns into a {@link Verdict}.
 *
 * An ordinal outside the enum means the ABI this app compiles against no longer matches the
 * deployed bytecode, which is a state the interface must not paper over: it maps to `HALTED`, the
 * verdict that publishes no mark and seizes nothing.
 */
export function toVerdict(ordinal: number): Verdict {
  return VERDICT_BY_ORDINAL[ordinal] ?? Verdict.UNTRUSTED_HALTED;
}

/* ======================================================= preview reason === */

/** Why a previewed `draw` or `withdrawCollateral` would fail. Mirrors `IAftermarketLens`. */
export const PreviewReason = {
  OK: 0,
  ZERO_AMOUNT: 1,
  NOT_ELIGIBLE: 2,
  LINE_NOT_OPEN: 3,
  LINE_FLAGGED: 4,
  UNPRICED: 5,
  UNDERCOLLATERALIZED: 6,
  INSUFFICIENT_COLLATERAL: 7,
  INSUFFICIENT_LIQUIDITY: 8,
} as const;

export type PreviewReason = (typeof PreviewReason)[keyof typeof PreviewReason];

/** What the refusal means, and what to do about it. */
export const PREVIEW_MEANING: Record<PreviewReason, string> = {
  [PreviewReason.OK]: "The engine accepts this.",
  [PreviewReason.ZERO_AMOUNT]: "Enter an amount above zero.",
  [PreviewReason.NOT_ELIGIBLE]:
    "The Reg-S gate does not admit this account. It reads Coinbase's onchain verification attestations and reverts with the most specific reason that applies: a restricted jurisdiction, a missing attestation, or neither source recognising the account.",
  [PreviewReason.LINE_NOT_OPEN]: "Open a line before drawing against it. Opening is a single transaction and costs nothing.",
  [PreviewReason.LINE_FLAGGED]:
    "The line is flagged. Repay enough to bring it back under its own advance rate, and the flag clears in the same transaction.",
  [PreviewReason.UNPRICED]:
    "An oracle behind this basket will not publish a mark, so the lens declines to preview a total it cannot stand behind. The engine still acts on the legs it can price, and values the refused leg at zero — the simulation above is what the transaction would actually do.",
  [PreviewReason.UNDERCOLLATERALIZED]:
    "This would leave the debt above what the basket supports at the advance rate in force for the current session. A leg whose oracle refuses to mark counts as zero.",
  [PreviewReason.INSUFFICIENT_COLLATERAL]: "The line has posted less of this asset than this would take out.",
  [PreviewReason.INSUFFICIENT_LIQUIDITY]:
    "The vault does not hold enough idle USDC to fund this draw. Lenders can top it up, or borrowers can repay.",
};

/** Narrows the `uint8` a preview returns. An unknown value is treated as a refusal, never as `OK`. */
export function toPreviewReason(value: number): PreviewReason {
  return value in PREVIEW_MEANING ? (value as PreviewReason) : PreviewReason.UNPRICED;
}

/* ==================================================== auto-repay reason === */

/** Why the agent is standing down, or `NONE` when it will act. Mirrors `IAutoRepayer`. */
export const AutoRepayReason = {
  NONE: 0,
  NOT_ENROLLED: 1,
  POLICY_DISABLED: 2,
  INTERVAL_NOT_ELAPSED: 3,
  ORACLE_UNTRUSTED: 4,
  LINE_HEALTHY: 5,
  NOTHING_TO_REPAY: 6,
  ABOVE_MAX_PER_EXECUTION: 7,
  PERMISSION_UNAVAILABLE: 8,
} as const;

export type AutoRepayReason = (typeof AutoRepayReason)[keyof typeof AutoRepayReason];

/** The short name the contract emits and the explorer shows. */
export const AUTO_REPAY_CODE: Record<AutoRepayReason, string> = {
  [AutoRepayReason.NONE]: "NONE",
  [AutoRepayReason.NOT_ENROLLED]: "NOT_ENROLLED",
  [AutoRepayReason.POLICY_DISABLED]: "POLICY_DISABLED",
  [AutoRepayReason.INTERVAL_NOT_ELAPSED]: "INTERVAL_NOT_ELAPSED",
  [AutoRepayReason.ORACLE_UNTRUSTED]: "ORACLE_UNTRUSTED",
  [AutoRepayReason.LINE_HEALTHY]: "LINE_HEALTHY",
  [AutoRepayReason.NOTHING_TO_REPAY]: "NOTHING_TO_REPAY",
  [AutoRepayReason.ABOVE_MAX_PER_EXECUTION]: "ABOVE_MAX_PER_EXECUTION",
  [AutoRepayReason.PERMISSION_UNAVAILABLE]: "PERMISSION_UNAVAILABLE",
};

/** One line, in the interface's own voice, saying what the agent decided and why. */
export const AUTO_REPAY_MEANING: Record<AutoRepayReason, string> = {
  [AutoRepayReason.NONE]: "Every precondition holds. The agent would repay now.",
  [AutoRepayReason.NOT_ENROLLED]: "No mandate. The agent has no authority over this account and will not act.",
  [AutoRepayReason.POLICY_DISABLED]: "The mandate exists but is switched off. Turn it on to let the agent act.",
  [AutoRepayReason.INTERVAL_NOT_ELAPSED]:
    "It acted too recently. The minimum interval you set has not elapsed, so it stands down.",
  [AutoRepayReason.ORACLE_UNTRUSTED]:
    "The protocol will not price this basket, so the agent cannot tell a healthy line from a doomed one. It refuses to spend your USDC on a number nobody will defend.",
  [AutoRepayReason.LINE_HEALTHY]: "The line is above its trigger and is not flagged. There is nothing to fix.",
  [AutoRepayReason.NOTHING_TO_REPAY]: "The repayment that would restore this line computes to zero.",
  [AutoRepayReason.ABOVE_MAX_PER_EXECUTION]:
    "The repayment the line needs is larger than your per-action cap. The agent refuses outright rather than spending the largest permitted amount, so a cap cannot be drained in small bites.",
  [AutoRepayReason.PERMISSION_UNAVAILABLE]:
    "The Spend Permission is revoked, outside its window, or has too little left in this period. Grant a fresh cap to let the agent act.",
};

/** Narrows the `uint8` `simulate` and `AutoRepayRefused` carry. */
export function toAutoRepayReason(value: number): AutoRepayReason {
  return value in AUTO_REPAY_MEANING ? (value as AutoRepayReason) : AutoRepayReason.NOT_ENROLLED;
}

/* =============================================================== scales === */

const WAD = 10n ** 18n;
const USDC_DECIMALS = 6;

/** Health sentinel the engine returns for a line the oracles will not price. */
export const HEALTH_UNKNOWN = 0n;

/** Health sentinel the engine returns for a line with no debt. */
export const HEALTH_NO_DEBT = 2n ** 256n - 1n;

/**
 * A fixed-point `bigint` as a display `number`.
 *
 * Deliberately routed through a decimal string rather than `Number(value) / 10 ** decimals`, so a
 * 1e36 Morpho mark does not lose its cents to a float division. The result is still an IEEE-754
 * number and is used for display only; every amount that touches a transaction stays a `bigint`.
 */
export function scaled(value: bigint, decimals: number): number {
  const negative = value < 0n;
  const digits = (negative ? -value : value).toString().padStart(decimals + 1, "0");
  const whole = digits.slice(0, digits.length - decimals);
  const fraction = decimals === 0 ? "" : `.${digits.slice(digits.length - decimals)}`;
  return Number(`${negative ? "-" : ""}${whole}${fraction}`);
}

/** 1e18 fixed point as a plain number. */
export function fromWad(value: bigint): number {
  return scaled(value, 18);
}

/** USDC's six decimals as a plain number. */
export function fromUsdc(value: bigint): number {
  return scaled(value, USDC_DECIMALS);
}

/** A human USDC amount as the `uint256` the contracts take. Returns `null` for anything unparseable. */
export function toUsdc(input: string): bigint | null {
  return parseDecimal(input, USDC_DECIMALS);
}

/** A human token amount as the `uint256` the contracts take, at that token's own decimals. */
export function parseDecimal(input: string, decimals: number): bigint | null {
  const trimmed = input.trim();
  if (!/^\d*(\.\d*)?$/.test(trimmed) || trimmed === "" || trimmed === ".") return null;
  const [whole = "", fraction = ""] = trimmed.split(".");
  if (fraction.length > decimals) return null;
  return BigInt(`${whole || "0"}${fraction.padEnd(decimals, "0")}`);
}

/**
 * A Morpho Blue oracle mark as USD per whole collateral token.
 *
 * Morpho scales `price()` by `1e36 * 10 ** (loanDecimals - collateralDecimals)`, which is exactly
 * what `AftermarketOracle` bakes in; this is the inverse of the contract's own scaling rather than
 * a separate convention.
 */
export function markToUsd(mark: bigint, collateralDecimals: number): number {
  return scaled(mark, 36 + USDC_DECIMALS - collateralDecimals);
}

/** A WAD annual rate as a percentage, e.g. `0.062e18` becomes `6.2`. */
export function aprPercent(wad: bigint): number {
  return fromWad(wad) * 100;
}

/** A WAD ratio as a fraction of one, clamped to the unit interval. */
export function ratioOfWad(wad: bigint): number {
  return Math.min(1, Math.max(0, Number((wad * 10_000n) / WAD) / 10_000));
}

/** Decodes the `bytes2` ISO 3166-1 alpha-2 country the Reg-S gate proved, or `null` when unproven. */
export function decodeCountry(bytes2: string): string | null {
  const hex = bytes2.startsWith("0x") ? bytes2.slice(2) : bytes2;
  if (hex.length < 4 || hex === "0000") return null;
  const first = Number.parseInt(hex.slice(0, 2), 16);
  const second = Number.parseInt(hex.slice(2, 4), 16);
  if (!first || !second) return null;
  return String.fromCharCode(first, second);
}

/* ======================================================== credit errors === */

/**
 * What each typed revert from the credit engine means, in the interface's own voice.
 *
 * These are the errors a borrower can actually provoke. Anything not listed here is rendered as the
 * bare error name and its decoded arguments, which is still more use than a selector, and is a
 * deliberate choice over inventing a friendly sentence for a state this interface does not model.
 */
export const CREDIT_ERROR_MEANING: Readonly<Record<string, string>> = {
  ZeroAmount: "The engine rejects a zero amount.",
  ZeroAddress: "The engine rejects the zero address as a recipient.",
  LineNotOpen: "This account has never opened a line. Opening one is a single transaction.",
  LineAlreadyOpen: "This account already has a line.",
  LineIsFlagged:
    "The line is flagged. Repay enough to bring it back under its own advance rate; the flag clears in the same transaction.",
  Undercollateralized:
    "This would leave the debt above what the basket supports. Collateral whose oracle refuses to publish a mark counts as zero here — the engine will not lend against a price it would also refuse to seize on.",
  InsufficientCollateral: "The line has posted less of this asset than this would take out.",
  AssetNotEnabled: "The engine no longer accepts this asset as collateral.",
  AssetCapExceeded: "This asset is at its protocol-wide ceiling. Nothing more of it can be posted.",
  TooManyAssets: "A basket cannot hold more distinct assets than this.",
  UnpricedCollateral:
    "Every leg of this basket is unpriceable, so the engine has nothing to measure the line against. It refuses to act in either direction rather than treat a total oracle outage as insolvency.",
  InsufficientLiquidity:
    "The vault does not hold enough idle USDC to fund this draw. Lenders can top it up, or borrowers can repay.",
  CalendarHorizon:
    "The onchain calendar cannot name the next opening bell this far ahead, so there is no session in which this line could ever be flagged, cured or seized. New debt is refused rather than becoming a one-way ratchet.",
  NotEligible: "The Reg-S gate does not admit this account.",
  RestrictedJurisdiction: "The account proved a jurisdiction this deployment does not admit.",
  AttestationMissing: "The account carries no verification attestation the gate recognises.",
  LineHealthy: "The line is above its seizure threshold, so it cannot be flagged.",
  AlreadyFlagged: "The line is already flagged and its grace clock is already running.",
  NoDebt: "The line carries no debt.",
  Overflow: "The amount is larger than the engine's accounting can represent.",
};

/** The sentence for a decoded revert, or `null` when this interface has no better words than the name. */
export function creditErrorMeaning(name: string): string | null {
  return CREDIT_ERROR_MEANING[name] ?? null;
}
