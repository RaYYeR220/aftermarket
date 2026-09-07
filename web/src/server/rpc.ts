import "server-only";

import { baseRpcUrl } from "@/lib/env";

/**
 * The one place this process talks to Base.
 *
 * Public Base endpoints limit by requests per second, so a burst is the thing to avoid: a visitor
 * clicking through seven screens while three of them poll would otherwise collect a handful of
 * `over rate limit` answers, and the interface would print `unavailable` for a refusal the protocol
 * never made. Three things keep that from happening, in order of how much work they save:
 *
 *   1. identical reads inside a few seconds are answered from memory rather than sent twice;
 *   2. what is left is paced through one queue with a minimum gap between sends;
 *   3. a call that is limited anyway is retried here, backing off, rather than surfaced as a
 *      failure the reader would reasonably mistake for the protocol declining to answer.
 *
 * Both callers share it: server components read through a viem transport built on this, and the
 * browser reads through `/api/rpc`, an allowlist in front of the same function. A deployment with
 * its own endpoint sets `BASE_RPC_URL` and none of this is load-bearing any more.
 */

/** Long enough to turn a burst into a stream, short enough to be invisible on a page load. */
const MIN_GAP_MS = 220;

/** Three retries, backing off. Past that the endpoint is not rate limiting, it is down. */
const RETRY_DELAYS_MS = [400, 1_000, 2_200];

/**
 * How long an identical read is reused.
 *
 * Base produces a block roughly every two seconds and every screen prints the block its figures
 * came from, so this is a coalescing window rather than a cache of record: it collapses the poll
 * that three panels fire at the same instant, and the second visit to a screen a reader just left.
 * It never holds a failed call, and it never stands in for a read that did not happen.
 */
const REUSE_MS = 3_000;

/**
 * JSON-RPC error codes that mean "you asked too quickly", across the endpoints Base users point at.
 * `-32005` is the standard limit-exceeded code; `-32016` is what `mainnet.base.org` returns.
 */
const RATE_LIMIT_CODES = new Set([-32016, -32005, -32097]);

export interface RpcReply {
  status: number;
  body: string;
}

interface CacheEntry {
  reply: Promise<RpcReply>;
  expiresAt: number;
}

let queue: Promise<unknown> = Promise.resolve();
let lastSentAt = 0;
const inFlight = new Map<string, CacheEntry>();

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** True when the answer is a rate limit, whether it arrived as a status or inside the envelope. */
function isRateLimited(status: number, body: string): boolean {
  if (status === 429) return true;
  if (!body.includes('"error"')) return false;
  try {
    const parsed: unknown = JSON.parse(body);
    const entries = Array.isArray(parsed) ? parsed : [parsed];
    return entries.some((entry) => {
      if (typeof entry !== "object" || entry === null || !("error" in entry)) return false;
      const code = (entry as { error?: { code?: unknown } }).error?.code;
      return typeof code === "number" && RATE_LIMIT_CODES.has(code);
    });
  } catch {
    return false;
  }
}

function prune(now: number): void {
  for (const [key, entry] of inFlight) {
    if (entry.expiresAt <= now) inFlight.delete(key);
  }
}

async function post(raw: string): Promise<RpcReply> {
  const wait = MIN_GAP_MS - (Date.now() - lastSentAt);
  if (wait > 0) await sleep(wait);

  for (let attempt = 0; ; attempt += 1) {
    lastSentAt = Date.now();
    const upstream = await fetch(baseRpcUrl(), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: raw,
      cache: "no-store",
    });
    const body = await upstream.text();
    const delay = RETRY_DELAYS_MS[attempt];
    if (delay === undefined || !isRateLimited(upstream.status, body)) {
      return { status: upstream.status, body };
    }
    await sleep(delay);
  }
}

export interface SendOptions {
  /**
   * Whether an identical body may be answered from the reuse window. False for anything whose
   * answer changes the moment it changes -- a transaction receipt being the one that matters.
   */
  reusable?: boolean | undefined;
}

/** Sends one JSON-RPC body upstream, paced against every other call this process is making. */
export function sendRpc(raw: string, options: SendOptions = {}): Promise<RpcReply> {
  const now = Date.now();
  prune(now);

  if (options.reusable === true) {
    const cached = inFlight.get(raw);
    if (cached !== undefined) return cached.reply;
  }

  const run = queue.then(() => post(raw));
  queue = run.catch(() => undefined);

  if (options.reusable === true) {
    const entry: CacheEntry = { reply: run, expiresAt: now + REUSE_MS };
    inFlight.set(raw, entry);
    void run.catch(() => inFlight.delete(raw));
  }

  return run;
}

/** Methods whose answer is stable enough inside the reuse window to be shared between callers. */
const REUSABLE_METHODS = new Set([
  "eth_blockNumber",
  "eth_call",
  "eth_chainId",
  "eth_feeHistory",
  "eth_gasPrice",
  "eth_getBalance",
  "eth_getBlockByHash",
  "eth_getBlockByNumber",
  "eth_getCode",
  "eth_getLogs",
  "eth_getStorageAt",
  "eth_maxPriorityFeePerGas",
  "net_version",
  "web3_clientVersion",
]);

/** True when every call in a request is one of {@link REUSABLE_METHODS}. */
export function isReusable(methods: readonly string[]): boolean {
  return methods.length > 0 && methods.every((method) => REUSABLE_METHODS.has(method));
}
