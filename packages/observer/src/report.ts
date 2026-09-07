import type { Address, PublicClient } from "viem";
import {
  ASSETS,
  SLIPSTREAM_FACTORY_ADDRESS,
  USDC_ADDRESS,
  USDC_DECIMALS,
  type AssetDefinition,
} from "./assets.js";
import {
  B20_ASSET_ABI,
  CHAINLINK_AGGREGATOR_ABI,
  ERC20_ABI,
  SLIPSTREAM_POOL_ABI,
  isSameAddress,
  withRateLimitRetry,
} from "./chain.js";

/** A value that was either read successfully or could not be, with a human-readable reason. Never a guess. */
export type Fallible<T> = { ok: true; value: T } | { ok: false; error: string };

function ok<T>(value: T): Fallible<T> {
  return { ok: true, value };
}

function fail<T>(error: string): Fallible<T> {
  return { ok: false, error };
}

export interface B20Snapshot {
  address: Address;
  symbol: string;
  decimals: number;
  totalSupply: bigint;
  multiplierWad: bigint;
}

export interface FeedSnapshot {
  address: Address;
  description: string;
  decimals: number;
  price: number;
  updatedAt: bigint;
  stalenessSeconds: number;
}

export interface PoolSnapshot {
  address: Address;
  tickSpacing: number;
  token0: Address;
  token1: Address;
  spotPriceUsd: number;
  twapPriceUsd: number;
  usdcDepth: number;
}

export interface AssetReport {
  ticker: string;
  b20Address: Address;
  chainlinkFeedAddress: Address;
  b20: Fallible<B20Snapshot>;
  feed: Fallible<FeedSnapshot>;
  pool: Fallible<PoolSnapshot>;
  divergenceBps: Fallible<number>;
  verdict: string;
}

export interface MarketStatus {
  isOpen: boolean;
  /** Wall-clock time in America/New_York, computed from the chain timestamp, formatted as `YYYY-MM-DD HH:MM:SS ET`. */
  etTime: string;
  isDst: boolean;
  reason: string;
}

export interface ObserverReport {
  rpcUrl: string;
  slipstreamFactoryAddress: Address;
  block: { number: bigint; timestampUnix: bigint; timestampIso: string };
  market: MarketStatus;
  assets: AssetReport[];
}

const TWAP_WINDOW_SECONDS = 1800;

// ---------------------------------------------------------------------------
// US equity market hours
// ---------------------------------------------------------------------------

/**
 * Full-day NYSE closures for 2026 and 2027, as ET calendar dates
 * (`YYYY-MM-DD`). Source: NYSE Group's published 2025/2026/2027 holiday
 * calendar. Weekends and the 09:30-16:00 ET session window are computed
 * below, not hardcoded.
 */
const NYSE_FULL_HOLIDAYS: ReadonlySet<string> = new Set([
  "2026-01-01", // New Year's Day
  "2026-01-19", // Martin Luther King Jr. Day
  "2026-02-16", // Washington's Birthday
  "2026-04-03", // Good Friday
  "2026-05-25", // Memorial Day
  "2026-06-19", // Juneteenth
  "2026-07-03", // Independence Day (observed)
  "2026-09-07", // Labor Day
  "2026-11-26", // Thanksgiving Day
  "2026-12-25", // Christmas Day
  "2027-01-01", // New Year's Day
  "2027-01-18", // Martin Luther King Jr. Day
  "2027-02-15", // Washington's Birthday
  "2027-03-26", // Good Friday
  "2027-05-31", // Memorial Day
  "2027-06-18", // Juneteenth (observed)
  "2027-07-05", // Independence Day (observed)
  "2027-09-06", // Labor Day
  "2027-11-25", // Thanksgiving Day
  "2027-12-24", // Christmas Day (observed)
]);

/** Day `n` (1-indexed) of the given UTC weekday in a month, e.g. the 2nd Sunday. */
function nthWeekdayOfMonthUtc(year: number, monthIndex0: number, weekday: number, n: number): number {
  const firstOfMonth = new Date(Date.UTC(year, monthIndex0, 1));
  const firstWeekday = firstOfMonth.getUTCDay();
  return 1 + ((7 + weekday - firstWeekday) % 7) + (n - 1) * 7;
}

/** US Eastern observes DST from 07:00 UTC on the 2nd Sunday of March to 06:00 UTC on the 1st Sunday of November. */
function isUsEasternDaylightTime(unixSeconds: number): boolean {
  const year = new Date(unixSeconds * 1000).getUTCFullYear();
  const marchSunday = nthWeekdayOfMonthUtc(year, 2, 0, 2);
  const novemberSunday = nthWeekdayOfMonthUtc(year, 10, 0, 1);
  const dstStartMs = Date.UTC(year, 2, marchSunday, 7, 0, 0);
  const dstEndMs = Date.UTC(year, 10, novemberSunday, 6, 0, 0);
  const ms = unixSeconds * 1000;
  return ms >= dstStartMs && ms < dstEndMs;
}

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

/** Derives US equity regular-session status from a chain timestamp, with no dependency on the host's own timezone data. */
export function getUsMarketStatus(unixSeconds: number): MarketStatus {
  const isDst = isUsEasternDaylightTime(unixSeconds);
  const offsetHours = isDst ? -4 : -5;
  const etWallClock = new Date(unixSeconds * 1000 + offsetHours * 3_600_000);

  const year = etWallClock.getUTCFullYear();
  const month = etWallClock.getUTCMonth();
  const day = etWallClock.getUTCDate();
  const weekday = etWallClock.getUTCDay();
  const hours = etWallClock.getUTCHours();
  const minutes = etWallClock.getUTCMinutes();
  const seconds = etWallClock.getUTCSeconds();

  const dateKey = `${year}-${pad2(month + 1)}-${pad2(day)}`;
  const etTime = `${dateKey} ${pad2(hours)}:${pad2(minutes)}:${pad2(seconds)} ET`;

  if (weekday === 0 || weekday === 6) {
    return { isOpen: false, etTime, isDst, reason: `closed — weekend (${weekday === 0 ? "Sunday" : "Saturday"})` };
  }
  if (NYSE_FULL_HOLIDAYS.has(dateKey)) {
    return { isOpen: false, etTime, isDst, reason: `closed — NYSE holiday (${dateKey})` };
  }

  const minutesSinceMidnight = hours * 60 + minutes;
  const openMinutes = 9 * 60 + 30;
  const closeMinutes = 16 * 60;
  if (minutesSinceMidnight < openMinutes || minutesSinceMidnight >= closeMinutes) {
    return { isOpen: false, etTime, isDst, reason: "closed — outside 09:30–16:00 ET regular session" };
  }
  return { isOpen: true, etTime, isDst, reason: "open — regular session" };
}

// ---------------------------------------------------------------------------
// Report assembly
// ---------------------------------------------------------------------------

type MulticallResult = { status: "success"; result: unknown } | { status: "failure"; error: Error };

interface AssetJob {
  asset: AssetDefinition;
  b20Range: [number, number];
  feedRange: [number, number];
  poolRange: [number, number] | null;
}

function describeError(error: unknown): string {
  if (error instanceof Error) {
    return error.message.split("\n")[0] ?? error.message;
  }
  return String(error);
}

function slice(results: MulticallResult[], range: [number, number]): MulticallResult[] {
  return results.slice(range[0], range[1]);
}

function decodeB20(results: MulticallResult[]): Fallible<{ symbol: string; decimals: number; totalSupply: bigint; multiplierWad: bigint }> {
  const [symbolR, decimalsR, totalSupplyR, multiplierR] = results;
  const failed = results.find((r) => r.status === "failure");
  if (failed && failed.status === "failure") {
    return fail(`could not read the B20 token (${describeError(failed.error)})`);
  }
  if (symbolR?.status !== "success" || decimalsR?.status !== "success" || totalSupplyR?.status !== "success" || multiplierR?.status !== "success") {
    return fail("could not read the B20 token (incomplete response)");
  }
  return ok({
    symbol: symbolR.result as string,
    decimals: decimalsR.result as number,
    totalSupply: totalSupplyR.result as bigint,
    multiplierWad: multiplierR.result as bigint,
  });
}

function decodeFeed(results: MulticallResult[], blockTimestamp: bigint): Fallible<{ description: string; decimals: number; price: number; updatedAt: bigint }> {
  const [decimalsR, descriptionR, roundR] = results;
  const failed = results.find((r) => r.status === "failure");
  if (failed && failed.status === "failure") {
    return fail(`could not read the Chainlink feed (${describeError(failed.error)})`);
  }
  if (decimalsR?.status !== "success" || descriptionR?.status !== "success" || roundR?.status !== "success") {
    return fail("could not read the Chainlink feed (incomplete response)");
  }
  const decimals = decimalsR.result as number;
  const round = roundR.result as readonly [bigint, bigint, bigint, bigint, bigint];
  const answer = round[1];
  const updatedAt = round[3];
  if (answer <= 0n) {
    return fail("feed returned a non-positive price");
  }
  if (updatedAt === 0n) {
    return fail("feed has never been updated");
  }
  const price = Number(answer) / 10 ** decimals;
  return ok({ description: descriptionR.result as string, decimals, price, updatedAt });
}

/** Price of `token1` in `token0` terms, decimal-adjusted, from a raw Uniswap-v3-style tick. */
function priceFromTick(tick: number, decimals0: number, decimals1: number): number {
  const rawPriceToken1PerToken0 = Math.pow(1.0001, tick);
  return rawPriceToken1PerToken0 * 10 ** (decimals0 - decimals1);
}

function decodePool(
  results: MulticallResult[],
  pool: { address: Address; tickSpacing: number },
  b20Decimals: number,
): Fallible<PoolSnapshot> {
  const [token0R, token1R, slot0R, observeR, usdcBalanceR] = results;
  const failed = results.find((r) => r.status === "failure");
  if (failed && failed.status === "failure") {
    return fail(`could not read the Slipstream pool (${describeError(failed.error)})`);
  }
  if (
    token0R?.status !== "success" ||
    token1R?.status !== "success" ||
    slot0R?.status !== "success" ||
    observeR?.status !== "success" ||
    usdcBalanceR?.status !== "success"
  ) {
    return fail("could not read the Slipstream pool (incomplete response)");
  }

  const token0 = token0R.result as Address;
  const token1 = token1R.result as Address;
  const usdcIsToken0 = isSameAddress(token0, USDC_ADDRESS);
  if (!usdcIsToken0 && !isSameAddress(token1, USDC_ADDRESS)) {
    return fail("pool does not actually pair this token with USDC");
  }
  const decimals0 = usdcIsToken0 ? USDC_DECIMALS : b20Decimals;
  const decimals1 = usdcIsToken0 ? b20Decimals : USDC_DECIMALS;

  const slot0 = slot0R.result as readonly [bigint, number, number, number, number, boolean];
  const spotTick = slot0[1];
  const humanSpotToken1PerToken0 = priceFromTick(spotTick, decimals0, decimals1);
  const spotPriceUsd = usdcIsToken0 ? 1 / humanSpotToken1PerToken0 : humanSpotToken1PerToken0;

  const observation = observeR.result as readonly [readonly bigint[], readonly bigint[]];
  const tickCumulatives = observation[0];
  const olderCumulative = tickCumulatives[0];
  const newerCumulative = tickCumulatives[1];
  if (olderCumulative === undefined || newerCumulative === undefined) {
    return fail("pool returned an incomplete TWAP observation");
  }
  const avgTick = Number(newerCumulative - olderCumulative) / TWAP_WINDOW_SECONDS;
  const humanTwapToken1PerToken0 = priceFromTick(avgTick, decimals0, decimals1);
  const twapPriceUsd = usdcIsToken0 ? 1 / humanTwapToken1PerToken0 : humanTwapToken1PerToken0;

  const usdcDepth = Number(usdcBalanceR.result as bigint) / 10 ** USDC_DECIMALS;

  return ok({
    address: pool.address,
    tickSpacing: pool.tickSpacing,
    token0,
    token1,
    spotPriceUsd,
    twapPriceUsd,
    usdcDepth,
  });
}

function buildVerdict(feed: Fallible<FeedSnapshot>, pool: Fallible<PoolSnapshot>, divergenceBps: Fallible<number>): string {
  if (!pool.ok) {
    return "No Aerodrome Slipstream pool exists for this token, so there is no independent on-chain price to check the feed against.";
  }
  if (!feed.ok) {
    return `Chainlink feed unreadable (${feed.error}); cannot compare it to the pool.`;
  }
  if (!divergenceBps.ok) {
    return `Divergence could not be computed (${divergenceBps.error}).`;
  }
  const bps = divergenceBps.value;
  const hours = feed.value.stalenessSeconds / 3600;
  const staleness = hours >= 1 ? `feed is ${hours.toFixed(1)}h old` : `feed is ${Math.round(feed.value.stalenessSeconds)}s old`;
  if (bps < 25) {
    return `Feed and pool agree within ${bps.toFixed(1)} bps (${staleness}); a Chainlink-only reader is marking close to the live pool price.`;
  }
  if (bps < 100) {
    return `Feed diverges ${bps.toFixed(1)} bps from the pool (${staleness}); a Chainlink-only reader is marking moderately away from the live pool price.`;
  }
  return `Feed diverges ${bps.toFixed(1)} bps from the pool (${staleness}); a Chainlink-only reader would be marking against a stale price.`;
}

export interface BuildReportOptions {
  rpcUrl: string;
  /** Case-insensitive ticker filter, e.g. `["NVDAc"]`. Omit for every known asset. */
  tickers?: string[] | undefined;
}

export async function buildReport(client: PublicClient, options: BuildReportOptions): Promise<ObserverReport> {
  const assets = options.tickers
    ? ASSETS.filter((asset) => options.tickers?.some((t) => t.toLowerCase() === asset.ticker.toLowerCase()))
    : ASSETS;

  const block = await withRateLimitRetry(() => client.getBlock());

  const contracts: { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] }[] = [];
  const jobs: AssetJob[] = [];

  for (const asset of assets) {
    const b20Start = contracts.length;
    contracts.push(
      { address: asset.b20Address, abi: B20_ASSET_ABI, functionName: "symbol" },
      { address: asset.b20Address, abi: B20_ASSET_ABI, functionName: "decimals" },
      { address: asset.b20Address, abi: B20_ASSET_ABI, functionName: "totalSupply" },
      { address: asset.b20Address, abi: B20_ASSET_ABI, functionName: "multiplier" },
    );
    const b20Range: [number, number] = [b20Start, contracts.length];

    const feedStart = contracts.length;
    contracts.push(
      { address: asset.chainlinkFeedAddress, abi: CHAINLINK_AGGREGATOR_ABI, functionName: "decimals" },
      { address: asset.chainlinkFeedAddress, abi: CHAINLINK_AGGREGATOR_ABI, functionName: "description" },
      { address: asset.chainlinkFeedAddress, abi: CHAINLINK_AGGREGATOR_ABI, functionName: "latestRoundData" },
    );
    const feedRange: [number, number] = [feedStart, contracts.length];

    let poolRange: [number, number] | null = null;
    if (asset.pool) {
      const poolStart = contracts.length;
      contracts.push(
        { address: asset.pool.address, abi: SLIPSTREAM_POOL_ABI, functionName: "token0" },
        { address: asset.pool.address, abi: SLIPSTREAM_POOL_ABI, functionName: "token1" },
        { address: asset.pool.address, abi: SLIPSTREAM_POOL_ABI, functionName: "slot0" },
        { address: asset.pool.address, abi: SLIPSTREAM_POOL_ABI, functionName: "observe", args: [[TWAP_WINDOW_SECONDS, 0]] },
        { address: USDC_ADDRESS, abi: ERC20_ABI, functionName: "balanceOf", args: [asset.pool.address] },
      );
      poolRange = [poolStart, contracts.length];
    }

    jobs.push({ asset, b20Range, feedRange, poolRange });
  }

  const results = (await withRateLimitRetry(() =>
    client.multicall({ contracts: contracts as never, allowFailure: true }),
  )) as unknown as MulticallResult[];

  const assetReports: AssetReport[] = jobs.map((job) => {
    const b20 = decodeB20(slice(results, job.b20Range));
    const feed = decodeFeed(slice(results, job.feedRange), block.timestamp);

    const feedWithStaleness: Fallible<FeedSnapshot> = feed.ok
      ? ok({
          address: job.asset.chainlinkFeedAddress,
          description: feed.value.description,
          decimals: feed.value.decimals,
          price: feed.value.price,
          updatedAt: feed.value.updatedAt,
          stalenessSeconds: Number(block.timestamp - feed.value.updatedAt),
        })
      : feed;

    let pool: Fallible<PoolSnapshot>;
    if (!job.asset.pool || !job.poolRange) {
      pool = fail("no Slipstream pool has been found for this asset");
    } else if (!b20.ok) {
      pool = fail("pool price needs the B20 token's decimals, which could not be read");
    } else {
      pool = decodePool(slice(results, job.poolRange), job.asset.pool, b20.value.decimals);
    }

    let divergenceBps: Fallible<number> = fail("feed and/or pool price unavailable");
    if (feedWithStaleness.ok && pool.ok && feedWithStaleness.value.price > 0) {
      const diff = Math.abs(feedWithStaleness.value.price - pool.value.twapPriceUsd);
      divergenceBps = ok((diff / feedWithStaleness.value.price) * 10_000);
    }

    const b20Snapshot: Fallible<B20Snapshot> = b20.ok
      ? ok({ address: job.asset.b20Address, symbol: b20.value.symbol, decimals: b20.value.decimals, totalSupply: b20.value.totalSupply, multiplierWad: b20.value.multiplierWad })
      : b20;

    return {
      ticker: job.asset.ticker,
      b20Address: job.asset.b20Address,
      chainlinkFeedAddress: job.asset.chainlinkFeedAddress,
      b20: b20Snapshot,
      feed: feedWithStaleness,
      pool,
      divergenceBps,
      verdict: buildVerdict(feedWithStaleness, pool, divergenceBps),
    };
  });

  return {
    rpcUrl: options.rpcUrl,
    slipstreamFactoryAddress: SLIPSTREAM_FACTORY_ADDRESS,
    block: {
      number: block.number,
      timestampUnix: block.timestamp,
      timestampIso: new Date(Number(block.timestamp) * 1000).toISOString(),
    },
    market: getUsMarketStatus(Number(block.timestamp)),
    assets: assetReports,
  };
}
