#!/usr/bin/env node
import { getAddress, isAddress, type Address } from "viem";
import { AuditTrail, DEFAULT_AUDIT_PATH } from "./audit.js";
import { BASE_MAINNET, RECOVERY_MARGIN_BPS } from "./addresses.js";
import { autoRepayerAbi } from "./abi.js";
import { createKeeperClient, createKeeperWallet, describeError, resolveKeeperAccount, resolveRpcUrl } from "./chain.js";
import { decide } from "./engine.js";
import { formatUsdc, renderExplain, renderTable, renderTickTable, wrap } from "./format.js";
import { Keeper, type KeeperConfig } from "./keeper.js";
import { readAccount, readBlock, readOracles, simulate, type ProtocolAddresses } from "./reader.js";
import { EVALUATION_ORDER, REASON_EXPLANATIONS, REASON_NAMES, Reason, reasonName } from "./reasons.js";
import { AccountRegistry, parsePinnedAccounts } from "./registry.js";
import { createKeeperServer, listen, type KeeperStatus } from "./server.js";
import type { TickResult } from "./types.js";

interface CliOptions {
  command: string;
  target: Address | null;
  rpcUrl: string | undefined;
  live: boolean;
  poke: boolean;
  maxTransactions: number;
  intervalSeconds: number;
  serve: boolean;
  port: number;
  auditPath: string;
  accounts: Address[];
  json: boolean;
  help: boolean;
  /** Everything after `--`, handed to the eval runner untouched. */
  passthrough: string[];
}

const HELP_TEXT = `aftermarket-keeper — the off-chain driver for Aftermarket's AutoRepayer

Usage:
  aftermarket-keeper <command> [options]

Commands:
  watch                 Poll every enrolled account on an interval, forever.
  once                  Evaluate every enrolled account exactly once and exit.
  simulate <address>    Print the contract's own simulate() verdict for one account.
  explain <address>     A full human-readable report for one account.
  doctor                Verify this build is wired to the contracts it thinks it is.
  eval [-- <args>]      Run the graded evaluation on a base-anvil fork of Base mainnet.
  reasons               Print the refusal vocabulary in the order the contract evaluates it.

Options:
  --rpc <url>           Base RPC endpoint. Default: $BASE_RPC_URL, else https://mainnet.base.org
  --live                Actually send transactions. Everything is a dry run without this flag.
  --poke                Also write refusals on-chain with poke(), so restraint is public evidence.
  --max-tx <n>          Hard ceiling on transactions per run or per tick. Default: 3
  --interval <seconds>  Seconds between ticks in watch mode. Default: 60
  --port <n>            Port for the read-only HTTP endpoint in watch mode. Default: 8787
  --no-serve            Do not start the HTTP endpoint in watch mode.
  --audit <path>        JSONL audit trail. Default: ${DEFAULT_AUDIT_PATH}
  --account <address>   Watch this address whether or not it is enrolled. Repeatable.
  --json                Machine-readable output where a command supports it.
  -h, --help            Show this message.

Environment:
  BASE_RPC_URL          Base mainnet RPC endpoint.
  KEEPER_PRIVATE_KEY    The keeper's signing key. The ONLY way to give this service a signer;
                        there is no file, flag or keystore path that will do it.
  KEEPER_ACCOUNTS       Comma-separated addresses to watch in addition to the enrolment scan.

Safety:
  Dry run is the default and --live is required to send anything. The keeper never sends a
  transaction the contract's own simulate() says will be refused, stops at --max-tx per run, and
  records 'unavailable' rather than assuming a state when the RPC cannot be reached. The cap that
  actually binds is not any of these: it is SpendPermissionManager.spend(), which reverts when
  used + amount exceeds the allowance the borrower signed.
`;

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = {
    command: "",
    target: null,
    rpcUrl: undefined,
    live: false,
    poke: false,
    maxTransactions: 3,
    intervalSeconds: 60,
    serve: true,
    port: 8787,
    auditPath: process.env["KEEPER_AUDIT_PATH"] ?? DEFAULT_AUDIT_PATH,
    accounts: parsePinnedAccounts(process.env["KEEPER_ACCOUNTS"]),
    json: false,
    help: false,
    passthrough: [],
  };

  const separator = argv.indexOf("--");
  const args = separator === -1 ? argv : argv.slice(0, separator);
  if (separator !== -1) options.passthrough = argv.slice(separator + 1);

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i] ?? "";
    switch (arg) {
      case "--rpc":
        options.rpcUrl = requireValue(args, i, "--rpc requires a URL");
        i += 1;
        break;
      case "--live":
        options.live = true;
        break;
      case "--poke":
        options.poke = true;
        break;
      case "--max-tx":
        options.maxTransactions = requireInteger(requireValue(args, i, "--max-tx requires a number"), "--max-tx");
        i += 1;
        break;
      case "--interval":
        options.intervalSeconds = requireInteger(requireValue(args, i, "--interval requires seconds"), "--interval");
        i += 1;
        break;
      case "--port":
        options.port = requireInteger(requireValue(args, i, "--port requires a port number"), "--port");
        i += 1;
        break;
      case "--no-serve":
        options.serve = false;
        break;
      case "--audit":
        options.auditPath = requireValue(args, i, "--audit requires a path");
        i += 1;
        break;
      case "--account": {
        const value = requireValue(args, i, "--account requires an address");
        if (!isAddress(value)) throw new Error(`--account is not an address: ${value}`);
        options.accounts.push(getAddress(value));
        i += 1;
        break;
      }
      case "--json":
        options.json = true;
        break;
      case "--help":
      case "-h":
        options.help = true;
        break;
      default: {
        if (arg.startsWith("-")) throw new Error(`unrecognized option: ${arg}`);
        if (options.command === "") options.command = arg;
        else if (options.target === null && isAddress(arg)) options.target = getAddress(arg);
        else throw new Error(`unexpected argument: ${arg}`);
      }
    }
  }
  return options;
}

function requireValue(args: string[], index: number, message: string): string {
  const value = args[index + 1];
  if (value === undefined || value.startsWith("--")) throw new Error(message);
  return value;
}

function requireInteger(raw: string, flag: string): number {
  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value) || value < 0) throw new Error(`${flag} requires a non-negative integer, got ${raw}`);
  return value;
}

const ADDRESSES: ProtocolAddresses = {
  autoRepayer: BASE_MAINNET.autoRepayer,
  credit: BASE_MAINNET.credit,
  lens: BASE_MAINNET.lens,
};

function buildKeeper(options: CliOptions): { keeper: Keeper; registry: AccountRegistry; rpcUrl: string; audit: AuditTrail } {
  const rpcUrl = resolveRpcUrl(options.rpcUrl);
  const publicClient = createKeeperClient(rpcUrl);
  const wallet = options.live ? createKeeperWallet(rpcUrl) : undefined;
  const audit = new AuditTrail(options.auditPath);
  const registry = new AccountRegistry({
    autoRepayer: ADDRESSES.autoRepayer,
    fromBlock: BASE_MAINNET.deployedAtBlock,
    pinned: options.accounts,
  });

  const config: KeeperConfig = {
    chainId: BASE_MAINNET.chainId,
    addresses: ADDRESSES,
    dryRun: !options.live,
    maxTransactionsPerRun: options.maxTransactions,
    pokeOnRefusal: options.poke,
    audit,
  };

  return { keeper: new Keeper(publicClient, wallet, registry, config), registry, rpcUrl, audit };
}

async function commandOnce(options: CliOptions): Promise<void> {
  const { keeper } = buildKeeper(options);
  const tick = await keeper.tick();
  printTick(tick, options);
}

async function commandWatch(options: CliOptions): Promise<void> {
  const { keeper, registry, rpcUrl, audit } = buildKeeper(options);
  let lastTick: TickResult | null = null;

  if (options.serve) {
    const status = (): KeeperStatus => ({
      chainId: BASE_MAINNET.chainId,
      rpcUrl,
      autoRepayer: ADDRESSES.autoRepayer,
      credit: ADDRESSES.credit,
      lens: ADDRESSES.lens,
      signer: keeper.signer,
      dryRun: !options.live,
      pokeOnRefusal: options.poke,
      maxTransactionsPerRun: options.maxTransactions,
      transactionsSent: keeper.sent,
      watching: registry.list(),
      lastTick,
    });
    const server = createKeeperServer({ audit, port: options.port, status });
    await listen(server, options.port);
    process.stderr.write(`decision endpoint listening on http://127.0.0.1:${options.port} (/health /decisions /accounts /reasons)\n`);
  }

  process.stderr.write(
    `watching every ${options.intervalSeconds}s — ${options.live ? "LIVE, transactions will be sent" : "dry run, no transactions"}\n`,
  );

  for (;;) {
    lastTick = await keeper.tick();
    printTick(lastTick, options);
    await new Promise((resolve) => setTimeout(resolve, options.intervalSeconds * 1_000));
  }
}

function printTick(tick: TickResult, options: CliOptions): void {
  if (options.json) {
    process.stdout.write(`${JSON.stringify({ ...tick, blockNumber: tick.blockNumber?.toString() ?? null })}\n`);
    return;
  }
  const header = `tick @ ${tick.finishedAt}  block ${tick.blockNumber ?? "unavailable"}  ${tick.records.length} decision(s), ${tick.transactionsSent} transaction(s)`;
  process.stdout.write(`${header}\n`);
  if (tick.records.length > 0) process.stdout.write(`${renderTickTable(tick.records)}\n`);
  process.stdout.write("\n");
}

async function commandSimulate(options: CliOptions): Promise<void> {
  const account = requireTarget(options, "simulate");
  const client = createKeeperClient(resolveRpcUrl(options.rpcUrl));
  const result = await simulate(client, ADDRESSES, account);

  if (options.json) {
    process.stdout.write(
      `${JSON.stringify({
        account,
        willAct: result.willAct,
        reason: result.reason,
        reasonName: reasonName(result.reason),
        amount: result.amount.toString(),
      })}\n`,
    );
    return;
  }
  process.stdout.write(`${account}\n`);
  process.stdout.write(`  willAct  ${result.willAct}\n`);
  process.stdout.write(`  reason   ${result.reason} ${reasonName(result.reason)}\n`);
  process.stdout.write(`  amount   ${formatUsdc(result.amount)}\n\n`);
  process.stdout.write(`${wrap(REASON_EXPLANATIONS[result.reason as Reason] ?? "unknown reason code", 96, "  ")}\n`);
}

async function commandExplain(options: CliOptions): Promise<void> {
  const account = requireTarget(options, "explain");
  const client = createKeeperClient(resolveRpcUrl(options.rpcUrl));
  const block = await readBlock(client);
  const oracles = await readOracles(client, ADDRESSES, block).catch(() => new Map());
  const snapshot = await readAccount(client, ADDRESSES, account, block, oracles);
  const decision = decide(snapshot);
  const contract = await simulate(client, ADDRESSES, account, block).catch(() => null);
  process.stdout.write(`${renderExplain(snapshot, decision, contract)}\n`);
}

/**
 * Confirms this build is pointed at the contracts it claims to be.
 *
 * Every value below is re-derived from the chain and compared against the table compiled into
 * `addresses.ts`. A keeper wired to the wrong `AutoRepayer` would produce a perfectly coherent,
 * perfectly wrong audit trail, and that is the one failure mode a reader of the trail could never
 * detect from the trail itself.
 */
async function commandDoctor(options: CliOptions): Promise<void> {
  const rpcUrl = resolveRpcUrl(options.rpcUrl);
  const client = createKeeperClient(rpcUrl);
  const rows: string[][] = [];
  let ok = true;

  const check = (label: string, actual: string, expected: string): void => {
    const pass = actual.toLowerCase() === expected.toLowerCase();
    if (!pass) ok = false;
    rows.push([label, actual, expected, pass ? "ok" : "MISMATCH"]);
  };

  const chainId = await client.getChainId();
  check("chainId", String(chainId), String(BASE_MAINNET.chainId));

  const read = <T,>(functionName: "credit" | "usdc" | "manager" | "RECOVERY_MARGIN_BPS"): Promise<T> =>
    client.readContract({ address: ADDRESSES.autoRepayer, abi: autoRepayerAbi, functionName }) as Promise<T>;

  check("AutoRepayer.credit()", await read<Address>("credit"), BASE_MAINNET.credit);
  check("AutoRepayer.usdc()", await read<Address>("usdc"), BASE_MAINNET.usdc);
  check("AutoRepayer.manager()", await read<Address>("manager"), BASE_MAINNET.spendPermissionManager);
  check("AutoRepayer.RECOVERY_MARGIN_BPS()", (await read<bigint>("RECOVERY_MARGIN_BPS")).toString(), RECOVERY_MARGIN_BPS.toString());

  const signer = resolveKeeperAccount();
  process.stdout.write(`rpc     ${new URL(rpcUrl).host}\n`);
  process.stdout.write(`signer  ${signer ? signer.address : "none (KEEPER_PRIVATE_KEY not set — dry run only)"}\n\n`);
  process.stdout.write(`${renderTable(["Check", "On chain", "Expected", "Result"], rows)}\n\n`);
  process.stdout.write(ok ? "wiring verified\n" : "WIRING MISMATCH — this keeper is not pointed at the deployment it thinks it is\n");
  if (!ok) process.exitCode = 1;
}

function commandReasons(options: CliOptions): void {
  const order = [Reason.NONE, ...EVALUATION_ORDER];
  if (options.json) {
    process.stdout.write(
      `${JSON.stringify(order.map((reason) => ({ code: reason, name: REASON_NAMES[reason], explanation: REASON_EXPLANATIONS[reason] })))}\n`,
    );
    return;
  }
  process.stdout.write("The order below is the order AutoRepayer._evaluate tests its preconditions.\n");
  process.stdout.write("ORACLE_UNTRUSTED is decided before LINE_HEALTHY: with no defensible mark, the agent\n");
  process.stdout.write("can neither judge whether a line is in trouble nor size a repayment.\n\n");
  for (const reason of order) {
    process.stdout.write(`${String(reason).padStart(2)}  ${REASON_NAMES[reason]}\n`);
    process.stdout.write(`${wrap(REASON_EXPLANATIONS[reason], 96, "    ")}\n\n`);
  }
}

function requireTarget(options: CliOptions, command: string): Address {
  if (options.target === null) throw new Error(`${command} requires an address, e.g. aftermarket-keeper ${command} 0x…`);
  return options.target;
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  if (options.help || options.command === "") {
    process.stdout.write(HELP_TEXT);
    return;
  }

  switch (options.command) {
    case "watch":
      await commandWatch(options);
      return;
    case "once":
      await commandOnce(options);
      return;
    case "simulate":
      await commandSimulate(options);
      return;
    case "explain":
      await commandExplain(options);
      return;
    case "doctor":
      await commandDoctor(options);
      return;
    case "reasons":
      commandReasons(options);
      return;
    case "eval": {
      const { runEvalCli } = await import("./eval/run.js");
      await runEvalCli(options.passthrough);
      return;
    }
    default:
      throw new Error(`unrecognized command: ${options.command}. Run with --help for usage.`);
  }
}

main().catch((error: unknown) => {
  process.stderr.write(`${describeError(error)}\n`);
  process.exitCode = 1;
});
