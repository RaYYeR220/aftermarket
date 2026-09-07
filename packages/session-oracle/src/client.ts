import type { Address, PublicClient } from "viem";
import { aftermarketOracleAbi } from "./abi.js";
import { decodeOracleError, extractRevertData, toDecodedQuote, type DecodedQuote, type OracleError } from "./types.js";

export interface OracleClientConfig {
  /** Any viem `PublicClient` connected to the chain the oracle is deployed on. */
  publicClient: PublicClient;
  /** Deployed `AftermarketOracle` address. */
  address: Address;
}

/**
 * The result shape for `price()`, `markBorrow()` and `markLiquidate()`: a resolved Morpho-scale
 * value on success, or the {@link OracleError} decoded from the revert on failure — never a raw
 * revert blob, and never a thrown exception for the five reverts the contract can raise on purpose.
 *
 * All three methods share this exact shape (same two keys, same discriminant) so a caller can
 * handle them identically regardless of which one they called.
 */
export type PriceResult = { ok: true; price: bigint } | { ok: false; error: OracleError };

export interface WatchOptions {
  /** Milliseconds between polls. Defaults to 12,000 (roughly Base's block time times a few). */
  pollingInterval?: number;
  /** Called when a poll fails for a reason other than a decodable oracle revert. */
  onError?: (error: unknown) => void;
}

export interface OracleClient {
  readonly address: Address;
  /** Full oracle state. Never rejects on a contract revert — `peek()` itself never reverts onchain. */
  peek(): Promise<DecodedQuote>;
  /** Morpho Blue `IOracle.price()`: the pessimistic mark, or the decoded revert reason. */
  price(): Promise<PriceResult>;
  /** Same value as `price()` today; kept distinct because Aftermarket's own credit contract reads
   *  `markBorrow()` and `markLiquidate()` independently of Morpho's single `price()` hook. */
  markBorrow(): Promise<PriceResult>;
  /** The optimistic mark used to test whether a position may be seized, or the decoded revert reason. */
  markLiquidate(): Promise<PriceResult>;
  /**
   * Polls `peek()` on an interval and calls `onQuote` with each result. Returns an `unsubscribe`
   * function; call it to stop polling (e.g. on component unmount).
   */
  watch(onQuote: (quote: DecodedQuote) => void, options?: WatchOptions): () => void;
}

const READ_FUNCTIONS = ["price", "markBorrow", "markLiquidate"] as const;
type ReadFunctionName = (typeof READ_FUNCTIONS)[number];

/**
 * Builds a typed client around a deployed `AftermarketOracle`.
 *
 * The headline ergonomic win is `price()` / `markBorrow()` / `markLiquidate()`: instead of a raw
 * revert, a failure comes back as `{ ok: false, error }` where `error` is one of the five typed
 * `AftermarketOracle` errors with its arguments already decoded (`StaleFeed`, `SourcesDiverged`,
 * `PoolTooThin`, `MarketHalted`, `InvalidFeedAnswer`). Any other failure — a bad RPC, a network
 * timeout, a call to an address that isn't this oracle — is rethrown rather than misreported as one
 * of those five.
 */
export function createOracleClient({ publicClient, address }: OracleClientConfig): OracleClient {
  const readMark = async (functionName: ReadFunctionName): Promise<PriceResult> => {
    try {
      const price = await publicClient.readContract({ address, abi: aftermarketOracleAbi, functionName });
      return { ok: true, price };
    } catch (error) {
      const revertData = extractRevertData(error);
      const oracleError = revertData ? decodeOracleError(revertData) : undefined;
      if (oracleError) return { ok: false, error: oracleError };
      throw error;
    }
  };

  const peek = async (): Promise<DecodedQuote> => {
    const raw = await publicClient.readContract({ address, abi: aftermarketOracleAbi, functionName: "peek" });
    return toDecodedQuote(raw);
  };

  return {
    address,
    peek,
    price: () => readMark("price"),
    markBorrow: () => readMark("markBorrow"),
    markLiquidate: () => readMark("markLiquidate"),
    watch(onQuote, options = {}) {
      const pollingInterval = options.pollingInterval ?? 12_000;
      let cancelled = false;

      const tick = async () => {
        try {
          const quote = await peek();
          if (!cancelled) onQuote(quote);
        } catch (error) {
          if (!cancelled) options.onError?.(error);
        }
      };

      void tick();
      const timer = setInterval(() => void tick(), pollingInterval);

      return () => {
        cancelled = true;
        clearInterval(timer);
      };
    },
  };
}
