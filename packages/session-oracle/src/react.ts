/**
 * Optional React bindings, exported from the `@aftermarket/session-oracle/react` subpath so the
 * core package (`@aftermarket/session-oracle`) never pulls in React or wagmi for a Node script, a
 * keeper, or a backend service that only needs `createOracleClient`.
 *
 * `react` and `wagmi` are peer dependencies of this package, both marked optional in
 * `package.json` — install them yourself, and wrap your app in wagmi's `WagmiProvider` (and
 * TanStack Query's `QueryClientProvider`, which wagmi itself requires) before using these hooks.
 */
import { useMemo } from "react";
import { useReadContract, type Config } from "wagmi";
import type { Address } from "viem";
import { aftermarketOracleAbi } from "./abi.js";
import { decodeOracleError, extractRevertData, toDecodedQuote, type DecodedQuote, type OracleError } from "./types.js";

interface QueryOptions {
  /** Milliseconds between refetches. Defaults to 12,000. Pass `false` to disable polling. */
  refetchInterval?: number | false;
  /** Set to `false` to skip the read entirely, e.g. while `address` isn't known yet. */
  enabled?: boolean;
}

export interface UseQuoteOptions {
  address: Address;
  /** Defaults to the connected wallet's chain. */
  chainId?: number;
  query?: QueryOptions;
  /** Pass a specific wagmi `Config` (e.g. in a multi-config app); defaults to the nearest provider. */
  config?: Config;
}

export interface UseQuoteResult {
  /** `undefined` until the first successful read. */
  quote: DecodedQuote | undefined;
  isLoading: boolean;
  error: Error | null;
  refetch: () => void;
}

/**
 * Subscribes to `AftermarketOracle.peek()`. `peek()` never reverts onchain, so `error` here reflects
 * only transport-level failures (bad RPC, wrong address, etc.), never an oracle verdict — check
 * `quote.verdict` / `quote.isTrusted` for that.
 */
export function useQuote({ address, chainId, query, config }: UseQuoteOptions): UseQuoteResult {
  const result = useReadContract({
    address,
    abi: aftermarketOracleAbi,
    functionName: "peek",
    chainId,
    config,
    query: {
      refetchInterval: query?.refetchInterval ?? 12_000,
      enabled: query?.enabled,
    },
  });

  const quote = useMemo(() => (result.data ? toDecodedQuote(result.data) : undefined), [result.data]);

  return {
    quote,
    isLoading: result.isLoading,
    error: result.error,
    refetch: () => void result.refetch(),
  };
}

export type PriceFunctionName = "price" | "markBorrow" | "markLiquidate";

export interface UsePriceOptions extends UseQuoteOptions {
  /** Which of the oracle's three price-shaped reads to call. Defaults to `"price"`. */
  functionName?: PriceFunctionName;
}

export interface UsePriceResult {
  /** `undefined` while loading or when the read reverted. */
  price: bigint | undefined;
  /** The decoded oracle revert, if the read reverted with one of the five typed errors. */
  error: OracleError | undefined;
  /** True when the read reverted with something other than a decodable oracle error. */
  isUnknownError: boolean;
  isLoading: boolean;
  refetch: () => void;
}

/**
 * Subscribes to `price()`, `markBorrow()`, or `markLiquidate()`. Unlike {@link useQuote}, this call
 * reverts wherever the oracle is untrusted — `error` surfaces that revert already decoded into an
 * {@link OracleError}, the same shape `createOracleClient(...).price()` returns, so a component can
 * render `explainVerdict`-style guidance without touching wagmi's raw error object.
 *
 * Retries are disabled: a reverting read will not resolve on retry until the underlying quote
 * changes, so retrying only adds latency to showing the (accurate) error state.
 */
export function usePrice({ address, chainId, functionName = "price", query, config }: UsePriceOptions): UsePriceResult {
  const result = useReadContract({
    address,
    abi: aftermarketOracleAbi,
    functionName,
    chainId,
    config,
    query: {
      refetchInterval: query?.refetchInterval ?? 12_000,
      enabled: query?.enabled,
      retry: false,
    },
  });

  const { error, isUnknownError } = useMemo(() => {
    if (!result.error) return { error: undefined, isUnknownError: false };
    const revertData = extractRevertData(result.error);
    const decoded = revertData ? decodeOracleError(revertData) : undefined;
    return { error: decoded, isUnknownError: decoded === undefined };
  }, [result.error]);

  return {
    price: result.data,
    error,
    isUnknownError,
    isLoading: result.isLoading,
    refetch: () => void result.refetch(),
  };
}
