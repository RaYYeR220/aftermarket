import "server-only";

import { decodeOracleError, explainVerdict, toDecodedQuote, VERDICT_GUIDANCE } from "@aftermarket/session-oracle";
import { cache } from "react";
import { decodeFunctionResult, type Abi, type Address, type Hex } from "viem";

import { oracleAbi } from "@/lib/abi";
import { DEPLOYMENT, ORACLES } from "@/lib/deployment";
import { fromWad, markToUsd, toVerdict } from "@/lib/protocol";
import { Session, toSession } from "@/lib/session";
import { LISTED_COLLATERAL, type ListedTicker } from "@/lib/site";

import { aggregate, failureText, memoize, MULTICALL3, multicall3ClockAbi, type Fallible, type RawCall } from "./chain";
import { refusalOf, type QuoteSnapshot, type Refusal } from "./protocol";

/**
 * The transparency read: what each oracle knows, and what it actually does when asked for a price.
 *
 * `peek()` and `price()` are read for every oracle inside one `aggregate3`, so the pair is a single
 * atomic observation of a single block rather than two calls that happened to land nearby. That is
 * what makes the negative control an argument instead of an anecdote: same asset, same feed, same
 * pool, same block, one parameter different, and only one of them answers.
 *
 * The revert is never swallowed. `aggregate3` hands back raw revert bytes and
 * `@aftermarket/session-oracle` decodes them into the typed error with its arguments intact -- the
 * session, the divergence and the band the contract measured. Those arguments are the evidence.
 */

/** A decoded `AftermarketOracle` revert, ready to render. */
export interface OracleFailure {
  /** The Solidity error name, e.g. `SourcesDiverged`. */
  name: string;
  /** Its arguments, in declaration order, already formatted. */
  args: { key: string; value: string }[];
}

/** What `price()` did at this block. */
export type PriceOutcome =
  | { ok: true; markUsd: number; raw: bigint }
  | { ok: false; failure: OracleFailure | null };

export interface OracleReading {
  /** How this instrument is named on screen. */
  label: string;
  ticker: string;
  address: Address;
  /** True for the second NVDAc oracle, the one deployed with a tighter band. */
  isControl: boolean;
  decimals: number;
  quote: QuoteSnapshot | null;
  refusal: Refusal | null;
  /** The SDK's own plain-English account of this verdict. */
  sentence: string | null;
  /** What an integrator should do about it. */
  guidance: string | null;
  price: PriceOutcome | null;
  feed: Address | null;
  pool: Address | null;
  collateralToken: Address | null;
}

export interface OracleBench {
  blockNumber: bigint;
  blockTimestampUnix: number;
  readings: OracleReading[];
  /** The production NVDAc oracle. */
  production: OracleReading | null;
  /** The same asset, the same block, a 25 bps band. */
  control: OracleReading | null;
}

export type OracleRead = Fallible<OracleBench>;

/** Every listed asset's oracle, then the negative control, in that order. */
const INSTRUMENTS: readonly { ticker: string; label: string; address: Address; isControl: boolean }[] = [
  ...LISTED_COLLATERAL.map((ticker: ListedTicker) => ({
    ticker,
    label: ticker,
    address: ORACLES[ticker],
    isControl: false,
  })),
  {
    ticker: "NVDAc",
    label: "NVDAc control",
    address: DEPLOYMENT.negativeControl,
    isControl: true,
  },
];

/** Every B20 token in this deployment carries eight decimals; the Morpho scale follows from that. */
const COLLATERAL_DECIMALS = 8;

/** peek, price, feed, pool, collateralToken. */
const READS_PER_INSTRUMENT = 5;

function oracleCall(address: Address, functionName: string): RawCall {
  return { address, abi: oracleAbi as unknown as Abi, functionName };
}

function clockCall(functionName: string): RawCall {
  return { address: MULTICALL3, abi: multicall3ClockAbi as unknown as Abi, functionName };
}

function describeFailure(error: ReturnType<typeof decodeOracleError>): OracleFailure | null {
  if (error === undefined) return null;
  switch (error.name) {
    case "StaleFeed":
      return {
        name: error.name,
        args: [
          { key: "session", value: error.session.toString() },
          { key: "age", value: `${error.age.toString()} s` },
          { key: "budget", value: `${error.budget.toString()} s` },
        ],
      };
    case "SourcesDiverged":
      return {
        name: error.name,
        args: [
          { key: "session", value: error.session.toString() },
          { key: "divergenceBps", value: error.divergenceBps.toString() },
          { key: "band", value: error.band.toString() },
        ],
      };
    case "PoolTooThin":
      return {
        name: error.name,
        args: [
          { key: "liquidityUsd", value: error.liquidityUsd.toString() },
          { key: "minLiquidityUsd", value: error.minLiquidityUsd.toString() },
        ],
      };
    case "MarketHalted":
      return { name: error.name, args: [{ key: "multiplier", value: error.multiplier.toString() }] };
    case "InvalidFeedAnswer":
      return { name: error.name, args: [{ key: "answer", value: error.answer.toString() }] };
  }
}

type RawQuote = ReturnType<typeof decodeQuote>;

function decodeQuote(data: Hex) {
  return decodeFunctionResult({ abi: oracleAbi, functionName: "peek", data });
}

function toSnapshot(raw: RawQuote): QuoteSnapshot {
  return {
    verdict: toVerdict(raw.verdict),
    session: toSession(raw.session) ?? Session.CLOSED_HOLIDAY,
    anchorUsd: fromWad(raw.anchorPrice),
    poolUsd: fromWad(raw.poolPrice),
    markBorrowUsd: markToUsd(raw.markBorrow, COLLATERAL_DECIMALS),
    markLiquidateUsd: markToUsd(raw.markLiquidate, COLLATERAL_DECIMALS),
    feedAgeSeconds: Number(raw.feedAge),
    stalenessBudgetSeconds: Number(raw.stalenessBudget),
    divergenceBps: Number(raw.divergenceBps),
    divergenceBandBps: Number(raw.divergenceBand),
    haircutBps: Number(raw.haircutBps),
    multiplier: fromWad(raw.multiplier),
    poolLiquidityUsd: fromWad(raw.poolLiquidityUsd),
    nextOpenUnix: Number(raw.nextOpen),
    lastCloseUnix: Number(raw.lastClose),
  };
}

async function read(): Promise<OracleRead> {
  try {
    const results = await aggregate([
      clockCall("getBlockNumber"),
      clockCall("getCurrentBlockTimestamp"),
      ...INSTRUMENTS.flatMap((instrument) => [
        oracleCall(instrument.address, "peek"),
        oracleCall(instrument.address, "price"),
        oracleCall(instrument.address, "feed"),
        oracleCall(instrument.address, "pool"),
        oracleCall(instrument.address, "collateralToken"),
      ]),
    ]);

    const bytesAt = (index: number): Hex | null => {
      const result = results[index];
      return result !== undefined && result.success ? result.returnData : null;
    };
    const addressAt = (index: number): Address | null => {
      const data = bytesAt(index);
      return data === null ? null : decodeFunctionResult({ abi: oracleAbi, functionName: "feed", data });
    };

    const readings: OracleReading[] = INSTRUMENTS.map((instrument, position) => {
      const base = 2 + position * READS_PER_INSTRUMENT;

      const peekData = bytesAt(base);
      const raw = peekData === null ? null : decodeQuote(peekData);
      const quote = raw === null ? null : toSnapshot(raw);

      const priceResult = results[base + 1];
      let price: PriceOutcome | null = null;
      if (priceResult !== undefined) {
        if (priceResult.success) {
          const mark = decodeFunctionResult({
            abi: oracleAbi,
            functionName: "price",
            data: priceResult.returnData,
          });
          price = { ok: true, raw: mark, markUsd: markToUsd(mark, COLLATERAL_DECIMALS) };
        } else {
          price = { ok: false, failure: describeFailure(decodeOracleError(priceResult.returnData)) };
        }
      }

      const decoded = raw === null ? null : toDecodedQuote(raw);
      return {
        label: instrument.label,
        ticker: instrument.ticker,
        address: instrument.address,
        isControl: instrument.isControl,
        decimals: COLLATERAL_DECIMALS,
        quote,
        refusal: refusalOf(quote),
        sentence: decoded === null ? null : explainVerdict(decoded),
        guidance: decoded === null ? null : (VERDICT_GUIDANCE[decoded.verdict] ?? null),
        price,
        feed: addressAt(base + 2),
        pool: addressAt(base + 3),
        collateralToken: addressAt(base + 4),
      };
    });

    const blockData = bytesAt(0);
    const timeData = bytesAt(1);

    return {
      ok: true,
      value: {
        blockNumber:
          blockData === null
            ? 0n
            : decodeFunctionResult({ abi: multicall3ClockAbi, functionName: "getBlockNumber", data: blockData }),
        blockTimestampUnix:
          timeData === null
            ? Math.floor(Date.now() / 1000)
            : Number(
                decodeFunctionResult({
                  abi: multicall3ClockAbi,
                  functionName: "getCurrentBlockTimestamp",
                  data: timeData,
                }),
              ),
        readings,
        production: readings.find((reading) => reading.ticker === "NVDAc" && !reading.isControl) ?? null,
        control: readings.find((reading) => reading.isControl) ?? null,
      },
    };
  } catch (error) {
    return { ok: false, error: failureText(error) };
  }
}

/** Deduplicated per request, and held briefly across requests. The block read is always printed. */
export const readOracleBench = cache(memoize(read, 20_000));
