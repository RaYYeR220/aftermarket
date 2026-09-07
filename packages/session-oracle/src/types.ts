import { BaseError, ContractFunctionRevertedError, decodeErrorResult, formatUnits, parseUnits } from "viem";
import type { Hex } from "viem";
import { aftermarketOracleAbi } from "./abi.js";

/**
 * Where the US equity market is in its daily cycle, as seen from the chain.
 *
 * Mirrors `contracts/src/libraries/Types.sol`'s `Session` enum exactly — same names, same ordinal
 * values. `AftermarketOracle` returns this as a `uint8`, which viem decodes as a plain `number`.
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

/** Human-readable names for {@link Session}, indexed by ordinal. */
export const SESSION_NAMES: Record<Session, string> = {
  [Session.REGULAR]: "REGULAR",
  [Session.PRE]: "PRE",
  [Session.POST]: "POST",
  [Session.CLOSED_OVERNIGHT]: "CLOSED_OVERNIGHT",
  [Session.CLOSED_WEEKEND]: "CLOSED_WEEKEND",
  [Session.CLOSED_HOLIDAY]: "CLOSED_HOLIDAY",
};

/** True for the three sessions with a live tape (`REGULAR`, `PRE`, `POST`). */
export function isMarketOpenSession(session: Session): boolean {
  return session === Session.REGULAR || session === Session.PRE || session === Session.POST;
}

/**
 * How much the oracle trusts its own mark right now.
 *
 * Mirrors `contracts/src/libraries/Types.sol`'s `Verdict` enum exactly. Anything past
 * `TRUSTED_CLOSED` makes `price()` / `markBorrow()` / `markLiquidate()` revert — see
 * {@link isTrustedVerdict} and the package README's verdict table.
 */
export const Verdict = {
  TRUSTED: 0,
  TRUSTED_CLOSED: 1,
  UNTRUSTED_STALE: 2,
  UNTRUSTED_DIVERGENT: 3,
  UNTRUSTED_THIN: 4,
  UNTRUSTED_HALTED: 5,
} as const;
export type Verdict = (typeof Verdict)[keyof typeof Verdict];

/** Human-readable names for {@link Verdict}, indexed by ordinal. */
export const VERDICT_NAMES: Record<Verdict, string> = {
  [Verdict.TRUSTED]: "TRUSTED",
  [Verdict.TRUSTED_CLOSED]: "TRUSTED_CLOSED",
  [Verdict.UNTRUSTED_STALE]: "UNTRUSTED_STALE",
  [Verdict.UNTRUSTED_DIVERGENT]: "UNTRUSTED_DIVERGENT",
  [Verdict.UNTRUSTED_THIN]: "UNTRUSTED_THIN",
  [Verdict.UNTRUSTED_HALTED]: "UNTRUSTED_HALTED",
};

/** True for the two verdicts under which `price()` / `markBorrow()` / `markLiquidate()` succeed. */
export function isTrustedVerdict(verdict: Verdict): boolean {
  return verdict === Verdict.TRUSTED || verdict === Verdict.TRUSTED_CLOSED;
}

/**
 * Everything `AftermarketOracle.peek()` returns, field-for-field identical to
 * `contracts/src/libraries/Types.sol`'s `Quote` struct. `verdict` and `session` decode as plain
 * numbers (viem decodes `uint8` as `number`, not `bigint`); every other field is a `uint256` or
 * `uint64` and decodes as `bigint`.
 */
export interface Quote {
  verdict: Verdict;
  session: Session;
  /** Chainlink total-return feed, 1e18 USD per whole token. */
  anchorPrice: bigint;
  /** Aerodrome Slipstream TWAP, 1e18 USD per whole token. */
  poolPrice: bigint;
  /** Pessimistic mark, Morpho `1e36 * 10**(loanDecimals - collateralDecimals)` scale. */
  markBorrow: bigint;
  /** Optimistic mark, same Morpho scale as {@link markBorrow}. */
  markLiquidate: bigint;
  /** Seconds since the Chainlink feed last moved. */
  feedAge: bigint;
  /** Feed age tolerated in `session`, in seconds. */
  stalenessBudget: bigint;
  /** `|anchorPrice - poolPrice| / anchorPrice`, in basis points. */
  divergenceBps: bigint;
  /** Divergence tolerated in `session`, in basis points. */
  divergenceBand: bigint;
  /** Gap-risk haircut currently applied to both marks, in basis points. */
  haircutBps: bigint;
  /** B20 `multiplier()` dividend/split adjustment, WAD (1e18 = no adjustment yet). */
  multiplier: bigint;
  /** Loan-side pool depth backing the TWAP, 1e18 USD. */
  poolLiquidityUsd: bigint;
  /** Unix timestamp of the next regular-session open. */
  nextOpen: bigint;
  /** Unix timestamp of the previous regular-session close. */
  lastClose: bigint;
}

/**
 * A {@link Quote} plus the display conveniences a UI reaches for immediately: USD numbers instead
 * of WAD `bigint`s, a plain `number` age, and the two booleans that answer "can I trust this?" and
 * "is the market open?" without the caller re-deriving them from `verdict`/`session`.
 *
 * The USD fields are `Number`-precision display helpers, not settlement values — use the raw
 * `bigint` fields (or {@link morphoPriceToUsd}) for anything that touches money.
 */
export interface DecodedQuote extends Quote {
  /** `anchorPrice` as a plain USD number (`anchorPrice / 1e18`). */
  readonly priceUsd: number;
  /** `poolPrice` as a plain USD number (`poolPrice / 1e18`). */
  readonly poolPriceUsd: number;
  /** `feedAge` as a plain number of seconds. */
  readonly feedAgeSeconds: number;
  /** `true` when `verdict` is `TRUSTED` or `TRUSTED_CLOSED` — see {@link isTrustedVerdict}. */
  readonly isTrusted: boolean;
  /** `true` when `session` is `REGULAR`, `PRE` or `POST` — see {@link isMarketOpenSession}. */
  readonly isMarketOpen: boolean;
}

/**
 * The shape viem's `readContract` (or wagmi's `useReadContract`) actually returns for `peek()`:
 * identical to {@link Quote} field-for-field, except `verdict` and `session` come back as plain
 * `number` rather than the narrower {@link Verdict} / {@link Session} literal unions, because viem
 * decodes every ABI type by bit width, not by its Solidity `enum` name. {@link toDecodedQuote} is the
 * one place that narrows them back.
 */
export interface RawQuote extends Omit<Quote, "verdict" | "session"> {
  verdict: number;
  session: number;
}

/** Converts a WAD (1e18) fixed-point `bigint` to a display `number`. Precision-lossy by design. */
function wadToDisplayNumber(value: bigint): number {
  return Number(formatUnits(value, 18));
}

/**
 * Adds the {@link DecodedQuote} convenience fields to a raw `peek()` result, narrowing `verdict` and
 * `session` from `number` to {@link Verdict} / {@link Session} in the process.
 *
 * The narrowing is a plain cast, not a runtime check: `AftermarketOracle`'s Solidity `enum`s only
 * ever encode 0-5, so any other value would mean `abi.ts` no longer matches the deployed contract,
 * which is a build-time problem this function does not attempt to detect. `test/quote.test.ts`
 * covers every field for both directions.
 */
export function toDecodedQuote(raw: RawQuote): DecodedQuote {
  const quote: Quote = { ...raw, verdict: raw.verdict as Verdict, session: raw.session as Session };
  return {
    ...quote,
    priceUsd: wadToDisplayNumber(quote.anchorPrice),
    poolPriceUsd: wadToDisplayNumber(quote.poolPrice),
    feedAgeSeconds: Number(quote.feedAge),
    isTrusted: isTrustedVerdict(quote.verdict),
    isMarketOpen: isMarketOpenSession(quote.session),
  };
}

/**
 * The five typed reverts `AftermarketOracle` can raise, decoded from raw revert bytes into plain
 * objects — never a raw revert blob. This is the shape {@link decodeOracleError} returns and
 * `createOracleClient`'s `price()` / `markBorrow()` / `markLiquidate()` surface on failure.
 */
export type OracleError =
  | { name: "StaleFeed"; session: Session; age: bigint; budget: bigint }
  | { name: "SourcesDiverged"; session: Session; divergenceBps: bigint; band: bigint }
  | { name: "PoolTooThin"; liquidityUsd: bigint; minLiquidityUsd: bigint }
  | { name: "MarketHalted"; multiplier: bigint }
  | { name: "InvalidFeedAnswer"; answer: bigint };

/**
 * Decodes raw revert bytes from `AftermarketOracle` into a typed {@link OracleError}.
 *
 * Returns `undefined` for anything that isn't one of the five oracle errors — including a plain
 * `Error(string)` / `Panic(uint256)` revert, malformed bytes, or a selector this ABI doesn't know —
 * so callers can fall back to rethrowing the original error instead of fabricating a wrong one.
 */
export function decodeOracleError(data: Hex): OracleError | undefined {
  try {
    const decoded = decodeErrorResult({ abi: aftermarketOracleAbi, data });
    switch (decoded.errorName) {
      case "StaleFeed": {
        const [session, age, budget] = decoded.args;
        return { name: "StaleFeed", session: session as Session, age, budget };
      }
      case "SourcesDiverged": {
        const [session, divergenceBps, band] = decoded.args;
        return { name: "SourcesDiverged", session: session as Session, divergenceBps, band };
      }
      case "PoolTooThin": {
        const [liquidityUsd, minLiquidityUsd] = decoded.args;
        return { name: "PoolTooThin", liquidityUsd, minLiquidityUsd };
      }
      case "MarketHalted": {
        const [multiplier] = decoded.args;
        return { name: "MarketHalted", multiplier };
      }
      case "InvalidFeedAnswer": {
        const [answer] = decoded.args;
        return { name: "InvalidFeedAnswer", answer };
      }
      default:
        return undefined;
    }
  } catch {
    return undefined;
  }
}

/**
 * Pulls the raw revert bytes out of a thrown viem read/simulate error, if there are any to pull.
 *
 * viem wraps a contract revert in nested `BaseError`s (`ContractFunctionExecutionError` ->
 * `CallExecutionError` -> `ContractFunctionRevertedError` -> ...); this walks that chain so callers
 * don't have to know its shape. Returns `undefined` for anything that isn't a decodable on-chain
 * revert — a network error, a timeout, an unrelated throw — so callers know to rethrow it untouched.
 */
export function extractRevertData(error: unknown): Hex | undefined {
  if (!(error instanceof BaseError)) return undefined;
  const revertError = error.walk((candidate) => candidate instanceof ContractFunctionRevertedError);
  if (!(revertError instanceof ContractFunctionRevertedError)) return undefined;
  if (!revertError.raw || revertError.raw === "0x") return undefined;
  return revertError.raw;
}

/**
 * Converts a Morpho Blue oracle `price()` value into a human USD number.
 *
 * Morpho's `IOracle.price()` returns "the price of 1 asset of collateral token quoted in 1 asset of
 * loan token, scaled by 1e36" — which for a market whose loan token is a USD stablecoin reduces to:
 *
 * ```text
 * usd = price / 10 ** (36 + loanDecimals - collateralDecimals)
 * ```
 *
 * That exponent is exactly what `AftermarketOracle` bakes into `markBorrow()` / `markLiquidate()`
 * (see `_morphoScale` in `AftermarketOracle.sol`), so this is the inverse of the contract's own
 * scaling — not a separate convention.
 *
 * Known-good vector: an 8-decimal Chainlink feed answering `22995730000` for an 8-decimal collateral
 * token against a 6-decimal loan token produces `price === 2299573n * 10n ** 30n`, and
 * `morphoPriceToUsd(2299573n * 10n ** 30n, 8, 6) === 229.9573`.
 *
 * This assumes the loan token is worth ~$1 (true for every USD-stablecoin Morpho market this oracle
 * targets). It is a display helper: it round-trips through a decimal string (via viem's
 * `formatUnits`) to avoid `bigint`-to-`number` precision loss for ordinary prices, but the result is
 * still an IEEE-754 `number` — never use it for settlement math.
 *
 * @param price Morpho-scale price, e.g. the return value of `price()`, `markBorrow()`, or
 *   `markLiquidate()`.
 * @param collateralDecimals `decimals()` of the Morpho market's collateral token.
 * @param loanDecimals `decimals()` of the Morpho market's loan token.
 * @see usdToMorphoPrice for the inverse.
 */
export function morphoPriceToUsd(price: bigint, collateralDecimals: number, loanDecimals: number): number {
  const exponent = morphoScaleExponent(collateralDecimals, loanDecimals);
  return Number(formatUnits(price, exponent));
}

/**
 * Converts a human USD price into the Morpho Blue oracle `price()` scale — the inverse of
 * {@link morphoPriceToUsd}. See that function's doc for the underlying formula and the known-good
 * vector both directions are tested against.
 *
 * Accepts `usd` as a `string` when you need exact decimal precision (recommended for anything with
 * more than a handful of significant digits); a `number` is converted via `String(usd)` first, which
 * is exact for any literal you'd actually type but can carry ordinary floating-point noise for a
 * value computed elsewhere.
 *
 * @param usd Human USD price of one whole collateral token, e.g. `229.9573`.
 * @param collateralDecimals `decimals()` of the Morpho market's collateral token.
 * @param loanDecimals `decimals()` of the Morpho market's loan token.
 * @see morphoPriceToUsd for the inverse and the full explanation of the scale.
 */
export function usdToMorphoPrice(usd: number | string, collateralDecimals: number, loanDecimals: number): bigint {
  const exponent = morphoScaleExponent(collateralDecimals, loanDecimals);
  return parseUnits(typeof usd === "number" ? String(usd) : usd, exponent);
}

/** Shared by {@link morphoPriceToUsd} and {@link usdToMorphoPrice}: `36 + loanDecimals - collateralDecimals`. */
function morphoScaleExponent(collateralDecimals: number, loanDecimals: number): number {
  const exponent = 36 + loanDecimals - collateralDecimals;
  if (!Number.isInteger(exponent) || exponent < 0) {
    throw new RangeError(
      `Invalid Morpho scale for collateralDecimals=${collateralDecimals}, loanDecimals=${loanDecimals}: ` +
        `36 + loanDecimals - collateralDecimals must be a non-negative integer, got ${exponent}.`,
    );
  }
  return exponent;
}
