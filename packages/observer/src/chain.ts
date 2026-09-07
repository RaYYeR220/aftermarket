import { createPublicClient, http, type Address, type Chain, type PublicClient } from "viem";
import { base } from "viem/chains";

/** Fixed-point scale Coinbase's B20 standard uses for `multiplier()`. */
export const WAD = 10n ** 18n;

export const DEFAULT_RPC_URL = "https://mainnet.base.org";

/** Resolves the RPC endpoint from an explicit override, then `BASE_RPC_URL`, then the Base default. */
export function resolveRpcUrl(override?: string): string {
  return override ?? process.env["BASE_RPC_URL"] ?? DEFAULT_RPC_URL;
}

/**
 * Builds the client used for every read in this package.
 *
 * Multicall aggregation is turned on at the client level so a burst of
 * `readContract` calls collapses into a handful of real `eth_call` requests.
 * Transport-level JSON-RPC batching stays off on purpose: against Base's
 * public endpoint, folding several independent requests into one HTTP batch
 * occasionally came back with stale or zeroed results for the tail of the
 * batch instead of an error, which is worse than a slower, honest request.
 */
export function createObserverClient(rpcUrl: string): PublicClient {
  return createPublicClient({
    chain: base as Chain,
    transport: http(rpcUrl, { timeout: 20_000, retryCount: 2, retryDelay: 400 }),
    batch: { multicall: true },
  });
}

/** Retries an RPC call a few times when the endpoint reports it is rate limiting us. */
export async function withRateLimitRetry<T>(fn: () => Promise<T>, attempts = 4): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      const message = error instanceof Error ? error.message : String(error);
      const isRateLimited = /rate limit|429|too many requests/i.test(message);
      if (!isRateLimited || attempt === attempts - 1) {
        throw error;
      }
      const backoffMs = 500 * 2 ** attempt;
      await new Promise((resolve) => setTimeout(resolve, backoffMs));
    }
  }
  throw lastError;
}

export const ERC20_ABI = [
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

/** ERC-20 plus the redemption-ratio accessor Coinbase's B20 precompiles add. */
export const B20_ASSET_ABI = [
  ...ERC20_ABI,
  { type: "function", name: "multiplier", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export const CHAINLINK_AGGREGATOR_ABI = [
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "description", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

/** The slice of Slipstream's (Uniswap-v3-shaped) pool ABI this tool reads. */
export const SLIPSTREAM_POOL_ABI = [
  { type: "function", name: "token0", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "token1", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "function",
    name: "slot0",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "observationIndex", type: "uint16" },
      { name: "observationCardinality", type: "uint16" },
      { name: "observationCardinalityNext", type: "uint16" },
      { name: "unlocked", type: "bool" },
    ],
  },
  {
    type: "function",
    name: "observe",
    stateMutability: "view",
    inputs: [{ name: "secondsAgos", type: "uint32[]" }],
    outputs: [
      { name: "tickCumulatives", type: "int56[]" },
      { name: "secondsPerLiquidityCumulativeX128s", type: "uint160[]" },
    ],
  },
] as const;

export function isSameAddress(a: Address, b: Address): boolean {
  return a.toLowerCase() === b.toLowerCase();
}
