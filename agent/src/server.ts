import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { getAddress, isAddress, type Address } from "viem";
import type { AuditTrail } from "./audit.js";
import { EVALUATION_ORDER, REASON_EXPLANATIONS, REASON_NAMES, Reason } from "./reasons.js";
import type { TickResult } from "./types.js";

export interface KeeperServerOptions {
  readonly audit: AuditTrail;
  readonly port: number;
  readonly host?: string;
  /** Everything the `/health` document needs that only the running process knows. */
  readonly status: () => KeeperStatus;
}

export interface KeeperStatus {
  readonly chainId: number;
  readonly rpcUrl: string;
  readonly autoRepayer: Address;
  readonly credit: Address;
  readonly lens: Address;
  readonly signer: Address | null;
  readonly dryRun: boolean;
  readonly pokeOnRefusal: boolean;
  readonly maxTransactionsPerRun: number;
  readonly transactionsSent: number;
  readonly watching: readonly Address[];
  readonly lastTick: TickResult | null;
}

/**
 * A read-only HTTP surface over the audit trail, so the web app can render what the agent decided
 * and — much more to the point — what it refused to do and why.
 *
 * Deliberately tiny and dependency-free: four `GET` routes, no write path, no authentication,
 * nothing that could turn a dashboard into a way to make the keeper act. The keeper's authority is
 * a spend permission the borrower signed; an HTTP server has no business anywhere near it.
 *
 * | Route | Returns |
 * |---|---|
 * | `GET /health` | Wiring, signer, dry-run state, watch list, and the last tick's summary. |
 * | `GET /decisions?limit=&account=` | The decision records, newest first. |
 * | `GET /accounts` | The addresses currently watched. |
 * | `GET /reasons` | The refusal vocabulary, in the order the contract evaluates it. |
 */
export function createKeeperServer(options: KeeperServerOptions): Server {
  const server = createServer((request, response) => {
    void handle(request, response, options).catch((error: unknown) => {
      sendJson(response, 500, { error: error instanceof Error ? error.message : String(error) });
    });
  });
  return server;
}

/** Starts the server and resolves once it is accepting connections. */
export function listen(server: Server, port: number, host = "127.0.0.1"): Promise<void> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => {
      server.removeListener("error", reject);
      resolve();
    });
  });
}

async function handle(request: IncomingMessage, response: ServerResponse, options: KeeperServerOptions): Promise<void> {
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);

  if (request.method === "OPTIONS") {
    response.writeHead(204, corsHeaders()).end();
    return;
  }
  if (request.method !== "GET") {
    sendJson(response, 405, { error: "this service is read-only; only GET is supported" });
    return;
  }

  switch (url.pathname) {
    case "/health": {
      const status = options.status();
      sendJson(response, 200, {
        ok: true,
        chainId: status.chainId,
        rpcUrl: redactRpc(status.rpcUrl),
        contracts: { autoRepayer: status.autoRepayer, credit: status.credit, lens: status.lens },
        signer: status.signer,
        dryRun: status.dryRun,
        pokeOnRefusal: status.pokeOnRefusal,
        maxTransactionsPerRun: status.maxTransactionsPerRun,
        transactionsSent: status.transactionsSent,
        watching: status.watching,
        auditTrail: await options.audit.info(),
        lastTick: status.lastTick
          ? {
              startedAt: status.lastTick.startedAt,
              finishedAt: status.lastTick.finishedAt,
              blockNumber: status.lastTick.blockNumber?.toString() ?? null,
              decisions: status.lastTick.records.length,
              transactionsSent: status.lastTick.transactionsSent,
            }
          : null,
      });
      return;
    }

    case "/decisions": {
      const limit = clampLimit(url.searchParams.get("limit"));
      const accountParam = url.searchParams.get("account");
      let account: Address | undefined;
      if (accountParam !== null) {
        if (!isAddress(accountParam)) {
          sendJson(response, 400, { error: `not an address: ${accountParam}` });
          return;
        }
        account = getAddress(accountParam);
      }
      const records = await options.audit.read({ limit, ...(account ? { account } : {}) });
      sendJson(response, 200, { count: records.length, records });
      return;
    }

    case "/accounts": {
      sendJson(response, 200, { accounts: options.status().watching });
      return;
    }

    case "/reasons": {
      sendJson(response, 200, {
        note: "The order below is the order AutoRepayer._evaluate tests its preconditions. ORACLE_UNTRUSTED is decided before LINE_HEALTHY because 'the line is healthy' is itself a claim about a price.",
        reasons: [Reason.NONE, ...EVALUATION_ORDER].map((reason) => ({
          code: reason,
          name: REASON_NAMES[reason],
          explanation: REASON_EXPLANATIONS[reason],
        })),
      });
      return;
    }

    default:
      sendJson(response, 404, { error: `no such route: ${url.pathname}`, routes: ["/health", "/decisions", "/accounts", "/reasons"] });
  }
}

function sendJson(response: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body, (_key, value: unknown) => (typeof value === "bigint" ? value.toString() : value));
  response.writeHead(status, { "content-type": "application/json; charset=utf-8", ...corsHeaders() });
  response.end(payload);
}

function corsHeaders(): Record<string, string> {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET, OPTIONS",
    "access-control-allow-headers": "content-type",
    "cache-control": "no-store",
  };
}

function clampLimit(raw: string | null): number {
  const parsed = raw === null ? 100 : Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return 100;
  return Math.min(parsed, 1_000);
}

/**
 * Strips credentials out of an RPC URL before it is served.
 *
 * Endpoints are routinely of the form `https://provider/v2/<api-key>`, and a health document is the
 * easiest thing in the world to paste into a screenshot.
 */
function redactRpc(rpcUrl: string): string {
  try {
    const url = new URL(rpcUrl);
    return `${url.protocol}//${url.host}`;
  } catch {
    return "unavailable";
  }
}
