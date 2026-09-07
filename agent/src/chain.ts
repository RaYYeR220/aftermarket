import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  http,
  type Account,
  type Chain,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

export const DEFAULT_RPC_URL = "https://mainnet.base.org";

/** Resolves the RPC endpoint from an explicit override, then `BASE_RPC_URL`, then Base's default. */
export function resolveRpcUrl(override?: string | undefined): string {
  return override ?? process.env["BASE_RPC_URL"] ?? DEFAULT_RPC_URL;
}

/**
 * The read client for every tick.
 *
 * Multicall aggregation is on so one tick's worth of reads collapses into a handful of `eth_call`s;
 * transport-level JSON-RPC batching stays off for the same reason `@aftermarket/observer` leaves it
 * off — against public Base endpoints a folded batch has been observed returning stale or zeroed
 * results for its tail rather than an error, and a silently wrong read is far worse for a keeper
 * than a slow one.
 */
export function createKeeperClient(rpcUrl: string): PublicClient {
  return createPublicClient({
    chain: base as Chain,
    transport: http(rpcUrl, { timeout: 20_000, retryCount: 2, retryDelay: 400 }),
    batch: { multicall: true },
  });
}

/**
 * The signing client, built only from `KEEPER_PRIVATE_KEY`.
 *
 * There is deliberately no file path, no keystore and no flag that can point this at a key on disk:
 * the only way to give this service a signer is an environment variable, so a key can never be
 * committed by accident. Returns `undefined` when the variable is absent, which is the normal state
 * for a dry run.
 */
export function createKeeperWallet(rpcUrl: string): WalletClient | undefined {
  const account = resolveKeeperAccount();
  if (!account) return undefined;
  return createWalletClient({ account, chain: base as Chain, transport: http(rpcUrl, { timeout: 20_000 }) });
}

/** The keeper's signing account, or `undefined` when `KEEPER_PRIVATE_KEY` is not set. */
export function resolveKeeperAccount(): Account | undefined {
  const raw = process.env["KEEPER_PRIVATE_KEY"]?.trim();
  if (!raw) return undefined;
  const key = (raw.startsWith("0x") ? raw : `0x${raw}`) as Hex;
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) {
    throw new Error("KEEPER_PRIVATE_KEY must be a 32-byte hex private key, with or without a 0x prefix.");
  }
  return privateKeyToAccount(key);
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
      if (!isRateLimited || attempt === attempts - 1) throw error;
      await new Promise((resolve) => setTimeout(resolve, 500 * 2 ** attempt));
    }
  }
  throw lastError;
}

/**
 * Whether a thrown error is the chain answering "no" or the network failing to answer at all.
 *
 * The distinction is the whole of this keeper's failure policy. A contract revert is information:
 * it tells us what the protocol thinks, and we record it. An unreachable RPC is the absence of
 * information, and the only honest thing to write down is `unavailable` — never a health of zero,
 * never a stale verdict carried forward from the previous tick.
 */
export function isContractRevert(error: unknown): boolean {
  if (!(error instanceof BaseError)) return false;
  return error.walk((candidate) => candidate instanceof ContractFunctionRevertedError) !== null;
}

/**
 * Pulls the raw revert bytes out of a thrown viem error, using *this* package's viem.
 *
 * `@aftermarket/session-oracle` exports the same helper, and it cannot be used from here. Both
 * packages depend on viem 2.56.0, but pnpm resolves them to two separate instances (their peer sets
 * differ), so `error instanceof ContractFunctionRevertedError` is false when the error was raised
 * by one instance and tested by the other, and the helper silently returns `undefined` for every
 * revert it is given. Unwrapping locally and handing the resulting hex to the SDK's
 * `decodeOracleError` keeps the decoding where it belongs — that function is pure over bytes and
 * crosses the boundary without trouble.
 */
export function extractRevertData(error: unknown): Hex | undefined {
  if (!(error instanceof BaseError)) return undefined;
  const revertError = error.walk((candidate) => candidate instanceof ContractFunctionRevertedError);
  if (!(revertError instanceof ContractFunctionRevertedError)) return undefined;
  if (!revertError.raw || revertError.raw === "0x") return undefined;
  return revertError.raw;
}

/** A short, printable description of any thrown value, for the audit trail. */
export function describeError(error: unknown): string {
  if (error instanceof BaseError) return error.shortMessage || error.message;
  if (error instanceof Error) return error.message;
  return String(error);
}
