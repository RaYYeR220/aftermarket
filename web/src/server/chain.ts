import "server-only";

import {
  createPublicClient,
  custom,
  encodeFunctionData,
  multicall3Abi,
  RpcRequestError,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { base } from "viem/chains";

import { baseRpcUrl } from "@/lib/env";

import { isReusable, sendRpc } from "./rpc";

/**
 * One Base mainnet client, and one rule about how it is used.
 *
 * Public RPC endpoints rate-limit per second, not per page, so a screen that fires thirty separate
 * `eth_call`s will get a 429 in front of a judge. Every read in this application therefore goes
 * through Multicall3: an entire screen is one `eth_call`, atomic at one block, which is also the
 * only way the oracle screen can honestly claim that the production oracle and the negative control
 * were read at the same block with the same inputs.
 */

/** Multicall3, at the same address on every chain it is deployed to. */
export const MULTICALL3: Address = "0xcA11bde05977b3631167028862bE2a173976CA11";

/**
 * The two Multicall3 helpers that report the block a batch executed at.
 *
 * viem ships only `aggregate3` and `getEthBalance`, and the block a read happened at is not
 * decoration here: every screen states it, and the oracle screen's whole argument is that the
 * production oracle and the negative control were read at the same one.
 */
export const multicall3ClockAbi = [
  {
    type: "function",
    name: "getBlockNumber",
    inputs: [],
    outputs: [{ name: "blockNumber", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getCurrentBlockTimestamp",
    inputs: [],
    outputs: [{ name: "timestamp", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

let nextRequestId = 0;

/**
 * A viem transport over the shared, paced sender in `./rpc`.
 *
 * viem's own HTTP transport would be simpler, but it cannot see the failure that matters here:
 * `mainnet.base.org` answers a rate limit with HTTP 200 and an error inside the JSON-RPC envelope,
 * which viem treats as a permanent failure and does not retry. Going through `sendRpc` puts both
 * the server's reads and the browser's reads behind one queue with one retry policy.
 *
 * The error is rethrown as viem's own `RpcRequestError` so that everything downstream still works:
 * `simulateContract` walks that error to reach the revert data, which is how a typed contract error
 * reaches the screen instead of a generic failure.
 */
const transport = custom({
  async request({ method, params }) {
    const url = baseRpcUrl();
    const body = { jsonrpc: "2.0", id: (nextRequestId += 1), method, params } as const;
    const reply = await sendRpc(JSON.stringify(body), { reusable: isReusable([method]) });
    const parsed = JSON.parse(reply.body) as { result?: unknown; error?: { code: number; message: string } };
    if (parsed.error !== undefined) {
      throw new RpcRequestError({ body, error: parsed.error, url });
    }
    return parsed.result;
  },
});

export const publicClient = createPublicClient({ chain: base, transport });

/** A value that was read, or the reason it could not be. Never a guess, never a zero standing in. */
export type Fallible<T> = { ok: true; value: T } | { ok: false; error: string };

/**
 * Holds one whole-protocol read for a few seconds so that clicking through the screens does not
 * open a new conversation with the RPC endpoint on every navigation.
 *
 * This is not a fallback cache: it never serves a value in place of a read that failed, and every
 * screen prints the block its figures came from, so a reader can see exactly how old the answer is.
 * A failed read is cached for a much shorter interval than a good one, so an endpoint that comes
 * back is picked up immediately rather than after the full window.
 */
export function memoize<T>(load: () => Promise<Fallible<T>>, ttlMs: number): () => Promise<Fallible<T>> {
  let pending: Promise<Fallible<T>> | null = null;
  let value: Fallible<T> | null = null;
  let expiresAt = 0;

  return async () => {
    const now = Date.now();
    if (value !== null && now < expiresAt) return value;
    if (pending !== null) return pending;

    pending = load()
      .then((result) => {
        value = result;
        expiresAt = Date.now() + (result.ok ? ttlMs : Math.min(ttlMs, 2_000));
        return result;
      })
      .finally(() => {
        pending = null;
      });

    return pending;
  };
}

/** The first line of whatever went wrong, which is the only part worth showing a reader. */
export function failureText(error: unknown): string {
  if (error instanceof Error) {
    const first = error.message.split("\n")[0]?.trim();
    if (first !== undefined && first.length > 0) return first;
  }
  return "the Base RPC endpoint did not answer";
}

export interface RawCall {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[] | undefined;
}

/** The raw outcome of one call inside the batch: it returned bytes, or it reverted with bytes. */
export interface RawResult {
  success: boolean;
  returnData: Hex;
}

/**
 * Runs every call in one `aggregate3`, returning raw bytes for successes and failures alike.
 *
 * This is the path a reverting call has to take. viem's own `multicall` decodes a revert into an
 * `Error`, which loses the ABI-encoded arguments -- and those arguments are the product: the
 * session, the divergence and the band that `SourcesDiverged` carries are what the oracle screen
 * exists to print. Handing back the bytes lets the caller decode them with the typed decoder in
 * `@aftermarket/session-oracle` instead of parsing a message string.
 */
export async function aggregate(calls: readonly RawCall[]): Promise<readonly RawResult[]> {
  const results = await publicClient.readContract({
    address: MULTICALL3,
    abi: multicall3Abi,
    functionName: "aggregate3",
    args: [
      calls.map((call) => ({
        target: call.address,
        allowFailure: true,
        callData: encodeFunctionData({
          abi: call.abi,
          functionName: call.functionName,
          ...(call.args === undefined ? {} : { args: call.args }),
        }),
      })),
    ],
  });
  return results.map((result) => ({ success: result.success, returnData: result.returnData }));
}
