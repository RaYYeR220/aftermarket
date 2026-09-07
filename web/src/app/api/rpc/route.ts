import { NextResponse } from "next/server";

import { isReusable, sendRpc } from "@/server/rpc";

/**
 * The browser's read path to Base mainnet.
 *
 * The live previews on the borrow, earn and auto-repay screens have to run in the browser -- they
 * follow what a person is typing -- and a browser pointed straight at a public endpoint gets rate
 * limited within a few keystrokes, which would turn every honest figure on the screen into
 * `unavailable` for the wrong reason. Routing those reads through this endpoint means the app has
 * one Base connection rather than one per visitor, and it means a deployment can put a private RPC
 * key in `BASE_RPC_URL` without ever shipping it to a client.
 *
 * It is a read proxy and nothing else:
 *
 *   - only the JSON-RPC methods below are forwarded, so it cannot be used as an open relay;
 *   - `eth_sendRawTransaction` is deliberately absent, because every transaction this app sends
 *     goes out through the wallet's own provider and never through here;
 *   - batches are capped, and so is the body, so one caller cannot turn a single request into an
 *     unbounded amount of upstream work.
 */

/** Everything a viem public client needs for reads, simulations and receipt polling. */
const ALLOWED_METHODS = new Set([
  "eth_blockNumber",
  "eth_call",
  "eth_chainId",
  "eth_estimateGas",
  "eth_feeHistory",
  "eth_gasPrice",
  "eth_getBalance",
  "eth_getBlockByHash",
  "eth_getBlockByNumber",
  "eth_getCode",
  "eth_getLogs",
  "eth_getStorageAt",
  "eth_getTransactionByHash",
  "eth_getTransactionCount",
  "eth_getTransactionReceipt",
  "eth_maxPriorityFeePerGas",
  "net_version",
  "web3_clientVersion",
]);

const MAX_BATCH = 40;
const MAX_BODY_BYTES = 256 * 1024;

interface RpcRequest {
  jsonrpc?: string;
  id?: number | string | null;
  method?: unknown;
  params?: unknown;
}

function rejected(id: RpcRequest["id"], message: string) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code: -32601, message } };
}

export async function POST(request: Request): Promise<NextResponse> {
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) {
    return NextResponse.json(rejected(null, "Request body too large."), { status: 413 });
  }

  let payload: RpcRequest | RpcRequest[];
  try {
    payload = JSON.parse(raw) as RpcRequest | RpcRequest[];
  } catch {
    return NextResponse.json(rejected(null, "Request body is not JSON."), { status: 400 });
  }

  const calls = Array.isArray(payload) ? payload : [payload];
  if (calls.length === 0 || calls.length > MAX_BATCH) {
    return NextResponse.json(rejected(null, `A batch must hold between 1 and ${MAX_BATCH} calls.`), {
      status: 400,
    });
  }

  const blocked = calls.find((call) => typeof call.method !== "string" || !ALLOWED_METHODS.has(call.method));
  if (blocked !== undefined) {
    return NextResponse.json(rejected(blocked.id, `This endpoint does not forward ${String(blocked.method)}.`), {
      status: 400,
    });
  }

  const methods = calls.map((call) => String(call.method));

  try {
    const { status, body } = await sendRpc(raw, { reusable: isReusable(methods) });
    return new NextResponse(body, {
      status,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
    });
  } catch {
    return NextResponse.json(
      { jsonrpc: "2.0", id: null, error: { code: -32603, message: "The Base RPC endpoint did not answer." } },
      { status: 502 },
    );
  }
}
