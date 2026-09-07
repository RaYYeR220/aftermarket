import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createWalletClient, http, type Chain } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { erc20Abi } from "../abi.js";
import { AuditTrail } from "../audit.js";
import { BASE_MAINNET } from "../addresses.js";
import { createKeeperClient, describeError, resolveRpcUrl } from "../chain.js";
import { Keeper } from "../keeper.js";
import { readBlock, type ProtocolAddresses } from "../reader.js";
import { reasonName } from "../reasons.js";
import { AccountRegistry } from "../registry.js";
import type { DecisionRecord } from "../types.js";
import { startAnvil } from "./anvil.js";
import { ANSWER_KEY_PATH, buildAnswerKey, verifyAnswerKey, writeAnswerKey } from "./answer-key.js";
import { findRepoRoot, repoPath } from "./artifacts.js";
import { EvalHarness, type EvalLine, type LiveOracleEvidence } from "./harness.js";
import { renderScenarioTable, renderScorecard, score, type ScenarioResult, type Scorecard } from "./score.js";
import { assertUniqueScenarioIds, SCENARIOS, type Scenario } from "./scenarios.js";

/** The keeper's own audit trail for the run, written next to the scorecard as supporting evidence. */
const EVAL_AUDIT_FILE = "eval-audit.jsonl";

/** Anvil's first deterministic account. The keeper signs with it; it is a public test key. */
const KEEPER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;

interface EvalOptions {
  rpcUrl: string;
  forkBlockNumber: bigint | undefined;
  port: number;
  writeKey: boolean;
  json: boolean;
  only: string[];
  outDir: string | null;
}

const HELP = `keeper eval — the graded evaluation, on a base-anvil fork of Base mainnet

Usage:
  aftermarket-keeper eval [-- <options>]

Options:
  --rpc <url>        Base mainnet endpoint to fork. Default: $BASE_RPC_URL
  --fork-block <n>   Pin the fork to a block. Default: the chain head when the run starts.
  --port <n>         Port for the local fork. Default: 8555
  --only <id>        Run one scenario (e.g. --only S16). Repeatable. Skips scoring.
  --write-key        Re-register the answer key from the current scenarios, then exit.
  --out <dir>        Where to write the results artifact. Default: agent/eval/results
  --json             Print the results document instead of the tables.
  -h, --help         Show this message.
`;

function parseEvalArgs(argv: string[]): EvalOptions & { help: boolean } {
  const options: EvalOptions & { help: boolean } = {
    rpcUrl: resolveRpcUrl(),
    forkBlockNumber: undefined,
    port: 8555,
    writeKey: false,
    json: false,
    only: [],
    outDir: null,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i] ?? "";
    const next = (message: string): string => {
      const value = argv[i + 1];
      if (value === undefined) throw new Error(message);
      i += 1;
      return value;
    };
    switch (arg) {
      case "--rpc":
        options.rpcUrl = next("--rpc requires a URL");
        break;
      case "--fork-block":
        options.forkBlockNumber = BigInt(next("--fork-block requires a block number"));
        break;
      case "--port":
        options.port = Number.parseInt(next("--port requires a port"), 10);
        break;
      case "--only":
        options.only.push(next("--only requires a scenario id"));
        break;
      case "--out":
        options.outDir = next("--out requires a directory");
        break;
      case "--write-key":
        options.writeKey = true;
        break;
      case "--json":
        options.json = true;
        break;
      case "-h":
      case "--help":
        options.help = true;
        break;
      default:
        throw new Error(`unrecognized eval option: ${arg}`);
    }
  }
  return options;
}

/** Entry point for `aftermarket-keeper eval`. */
export async function runEvalCli(argv: string[]): Promise<void> {
  const options = parseEvalArgs(argv);
  if (options.help) {
    process.stdout.write(HELP);
    return;
  }

  assertUniqueScenarioIds();
  const repoRoot = await findRepoRoot();
  const keyPath = repoPath(repoRoot, ANSWER_KEY_PATH);

  if (options.writeKey) {
    const key = buildAnswerKey();
    await writeAnswerKey(keyPath, key);
    process.stdout.write(`registered ${key.scenarioCount} expectations (${key.trapCount} traps, ${key.negativeControlCount} negative controls)\n`);
    process.stdout.write(`hash ${key.hash}\n`);
    process.stdout.write(`written to ${keyPath} — commit this file before scoring against it\n`);
    return;
  }

  const scenarios = options.only.length > 0 ? SCENARIOS.filter((s) => options.only.includes(s.id)) : SCENARIOS;
  if (scenarios.length === 0) throw new Error(`no scenarios matched ${options.only.join(", ")}`);

  const keyStatus = await verifyAnswerKey(keyPath);
  if (!keyStatus.ok) {
    process.stderr.write(`answer key check failed: ${keyStatus.reason}\n`);
    process.exitCode = 1;
    return;
  }
  process.stdout.write(`answer key verified — ${keyStatus.key.scenarioCount} pre-registered expectations, hash ${keyStatus.key.hash.slice(0, 16)}…\n`);

  const outDir = options.outDir ?? repoPath(repoRoot, "agent", "eval", "results");
  // The eval's own decision trail is an artifact of one run, so it starts empty rather than
  // accumulating across runs and making it ambiguous which scorecard it belongs to.
  await mkdir(outDir, { recursive: true });
  await rm(join(outDir, EVAL_AUDIT_FILE), { force: true });

  const report = await runEval({ ...options, repoRoot, scenarios, outDir });

  const partial = options.only.length > 0;
  const card = partial ? null : score(report.results, keyStatus.key);
  await writeArtifacts(outDir, report, card, keyStatus.key.hash, partial);

  if (options.json) {
    process.stdout.write(`${JSON.stringify(toJson(report, card, keyStatus.key.hash), null, 2)}\n`);
  } else {
    process.stdout.write(`\n${renderScenarioTable(report.results)}\n\n`);
    if (card) process.stdout.write(`${renderScorecard(report.results, card)}\n\n`);
    process.stdout.write(`results written to ${outDir}\n`);
  }

  if (card && !card.passed) process.exitCode = 1;
}

interface EvalReport {
  readonly startedAt: string;
  readonly finishedAt: string;
  readonly forkBlockNumber: string;
  readonly forkChainId: number;
  readonly deployment: Record<string, unknown>;
  readonly liveOracles: readonly LiveOracleEvidence[];
  readonly results: readonly ScenarioResult[];
}

/**
 * Runs every scenario against one fork.
 *
 * The keeper under test is the real {@link Keeper}, in `--live` mode, with a per-scenario
 * transaction cap of one and `poke` enabled — so a refusal leaves an `AutoRepayRefused` event on
 * the fork and an action leaves an `AutoRepaid`. Nothing about the keeper is stubbed for the eval;
 * the only thing the harness supplies is the world.
 */
async function runEval(
  options: EvalOptions & { repoRoot: string; scenarios: readonly Scenario[]; outDir: string },
): Promise<EvalReport> {
  const startedAt = new Date().toISOString();
  process.stdout.write(`starting a base-anvil fork of ${new URL(options.rpcUrl).host}…\n`);

  const anvil = await startAnvil({
    forkUrl: options.rpcUrl,
    port: options.port,
    ...(options.forkBlockNumber === undefined ? {} : { forkBlockNumber: options.forkBlockNumber }),
  });

  try {
    const harness = await EvalHarness.deploy({
      rpcUrl: anvil.rpcUrl,
      repoRoot: options.repoRoot,
      lineCount: options.scenarios.length,
    });
    process.stdout.write(`fixture deployed — AutoRepayer ${harness.deployment.autoRepayer}\n`);

    const liveOracles = await harness.readLiveOracles();
    for (const oracle of liveOracles) {
      const state = oracle.priceReverts ? `price() REVERTS — ${oracle.priceError ?? "unknown"}` : "price() answers";
      process.stdout.write(`  live ${oracle.ticker.padEnd(7)} ${state}\n`);
    }

    const addresses: ProtocolAddresses = {
      autoRepayer: harness.deployment.autoRepayer,
      credit: harness.deployment.credit,
      lens: harness.deployment.lens,
    };
    const publicClient = createKeeperClient(anvil.rpcUrl);
    const chainId = await publicClient.getChainId();
    const results: ScenarioResult[] = [];

    for (const [index, scenario] of options.scenarios.entries()) {
      process.stdout.write(`  ${scenario.id} ${scenario.title}\n`);
      await harness.resetWorld();
      const line = await harness.lineFor(index);
      let result: ScenarioResult;
      try {
        await scenario.setup(line);
        await line.applyOracleState();
        result = await evaluateScenario({ scenario, line, harness, addresses, rpcUrl: anvil.rpcUrl, chainId, outDir: options.outDir });
      } catch (error) {
        result = failedScenario(scenario, line, describeError(error));
      }
      results.push(result);
    }

    const block = await readBlock(publicClient);
    return {
      startedAt,
      finishedAt: new Date().toISOString(),
      forkBlockNumber: block.number.toString(),
      forkChainId: chainId,
      deployment: { ...harness.deployment },
      liveOracles,
      results,
    };
  } finally {
    anvil.stop();
  }
}

/** Sets up one scenario, runs one keeper tick against it, and grades the outcome. */
async function evaluateScenario(context: {
  scenario: Scenario;
  line: EvalLine;
  harness: EvalHarness;
  addresses: ProtocolAddresses;
  rpcUrl: string;
  chainId: number;
  outDir: string;
}): Promise<ScenarioResult> {
  const { scenario, line, harness, addresses, rpcUrl, chainId } = context;

  const usdcBefore = await line.usdcBalance();
  // A scenario that takes the calendar offline makes the engine's own debt view revert. That is the
  // state under test, so the measurement has to tolerate it rather than fail the scenario.
  const debtBefore = await readOrNull(() => line.debt());

  const publicClient = createKeeperClient(rpcUrl);
  const wallet = createWalletClient({
    account: privateKeyToAccount(KEEPER_KEY),
    chain: base as Chain,
    transport: http(rpcUrl, { timeout: 60_000 }),
  });
  const block = await readBlock(publicClient);
  const registry = new AccountRegistry({ autoRepayer: addresses.autoRepayer, fromBlock: block.number, pinned: [line.account] });
  const audit = new AuditTrail(join(context.outDir, EVAL_AUDIT_FILE));

  const keeper = new Keeper(publicClient, wallet, registry, {
    chainId,
    addresses,
    dryRun: false,
    // One transaction per scenario: the keeper either repays or writes its refusal, never both and
    // never twice. Anything more would let a scenario pass by accident on a second attempt.
    maxTransactionsPerRun: 1,
    pokeOnRefusal: true,
    audit,
  });

  const tick = await keeper.tick();
  const record = tick.records.find((entry) => entry.account.toLowerCase() === line.account.toLowerCase());
  if (!record) return failedScenario(scenario, line, "the keeper produced no decision for this account");

  const usdcAfter = await line.usdcBalance();
  const debtAfter = await readOrNull(() => line.debt());
  const repayerBalance = await publicClient.readContract({
    address: BASE_MAINNET.usdc,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [addresses.autoRepayer],
  });

  const acted = record.status === "acted";
  const usdcDelta = usdcAfter - usdcBefore;
  const debtDelta = debtBefore === null || debtAfter === null ? null : debtAfter - debtBefore;
  const engineReason = record.reason ?? -1;
  const contractReason = record.contract?.reason ?? -1;

  const correct =
    engineReason === scenario.expected.reason &&
    contractReason === scenario.expected.reason &&
    (record.contract?.willAct ?? false) === scenario.expected.willAct &&
    acted === scenario.expected.willAct;

  const falseAction = !scenario.expected.willAct && (acted || usdcDelta < 0n);

  const violations: string[] = [];
  if (repayerBalance !== 0n) {
    violations.push(`AutoRepayer holds ${repayerBalance} USDC after the tick; it must end every call holding nothing`);
  }
  if (!scenario.expected.willAct) {
    if (usdcDelta !== 0n) violations.push(`borrower USDC moved by ${usdcDelta} on a scenario the agent must refuse`);
    if (debtDelta !== null && debtDelta !== 0n) {
      violations.push(`debt moved by ${debtDelta} on a scenario the agent must refuse`);
    }
  } else if (acted) {
    const repaid = BigInt(record.action.repaid ?? "0");
    if (usdcDelta !== -repaid) violations.push(`borrower USDC moved by ${usdcDelta}, expected -${repaid}`);
    if (debtDelta !== null && debtDelta !== -repaid) violations.push(`debt moved by ${debtDelta}, expected -${repaid}`);
    if (repaid === 0n) violations.push("the agent acted but repaid nothing");
  }
  if (record.status === "engine-mismatch") {
    violations.push("the keeper's rule engine and the contract's simulate() disagreed");
  }

  const oracle = record.inputs.oracles[0] ?? null;

  return {
    id: scenario.id,
    title: scenario.title,
    category: scenario.category,
    trap: scenario.trap,
    negativeControl: scenario.negativeControl,
    account: line.account,
    expected: {
      willAct: scenario.expected.willAct,
      reason: scenario.expected.reason,
      reasonName: reasonName(scenario.expected.reason),
    },
    engine: {
      willAct: record.status === "acted" || record.status === "would-act",
      reason: engineReason,
      reasonName: record.reasonName,
      amount: record.inputs.amount ?? "0",
    },
    contract: {
      willAct: record.contract?.willAct ?? false,
      reason: contractReason,
      reasonName: record.contract?.reasonName ?? "UNAVAILABLE",
      amount: record.contract?.amount ?? "0",
    },
    acted,
    repaid: record.action.repaid,
    txHash: record.action.txHash,
    borrowerUsdcDelta: usdcDelta.toString(),
    debtDelta: debtDelta === null ? "unavailable" : debtDelta.toString(),
    oracle: oracle
      ? {
          verdict: oracle.verdict,
          session: oracle.session,
          divergenceBps: oracle.divergenceBps,
          priceError: oracle.priceError,
        }
      : null,
    violations,
    correct: correct && violations.length === 0,
    falseAction,
    note: describeRecord(record),
  };
}

/** Reads a value that the contracts are allowed to refuse, without failing the scenario. */
async function readOrNull(read: () => Promise<bigint>): Promise<bigint | null> {
  try {
    return await read();
  } catch {
    return null;
  }
}

function describeRecord(record: DecisionRecord): string | null {
  if (record.status === "unavailable") return record.inputs.unavailable;
  if (record.action.note && record.action.note !== "refusal recorded off-chain only") return record.action.note;
  return null;
}

function failedScenario(scenario: Scenario, line: EvalLine, note: string): ScenarioResult {
  return {
    id: scenario.id,
    title: scenario.title,
    category: scenario.category,
    trap: scenario.trap,
    negativeControl: scenario.negativeControl,
    account: line.account,
    expected: {
      willAct: scenario.expected.willAct,
      reason: scenario.expected.reason,
      reasonName: reasonName(scenario.expected.reason),
    },
    engine: { willAct: false, reason: -1, reasonName: "SETUP_FAILED", amount: "0" },
    contract: { willAct: false, reason: -1, reasonName: "SETUP_FAILED", amount: "0" },
    acted: false,
    repaid: null,
    txHash: null,
    borrowerUsdcDelta: "0",
    debtDelta: "0",
    oracle: null,
    violations: [`scenario could not be set up or evaluated: ${note}`],
    correct: false,
    falseAction: false,
    note,
  };
}

/**
 * Writes the run's artifacts.
 *
 * A partial run — one launched with `--only` — goes to its own timestamped file and never touches
 * `latest.*`. Those two files are the committed evidence for a full, scored run, and a
 * one-scenario debugging pass silently overwriting them with an unscored document would quietly
 * destroy the thing the evaluation exists to produce.
 */
async function writeArtifacts(
  outDir: string,
  report: EvalReport,
  card: Scorecard | null,
  keyHash: string,
  partial: boolean,
): Promise<void> {
  await mkdir(outDir, { recursive: true });
  const body = `${JSON.stringify(toJson(report, card, keyHash), null, 2)}\n`;
  const stamp = report.finishedAt.replaceAll(":", "-").replace(/\..*/, "");

  if (partial) {
    await writeFile(join(outDir, `partial-${stamp}.json`), body, "utf8");
    return;
  }

  await writeFile(join(outDir, `scorecard-${stamp}.json`), body, "utf8");
  await writeFile(join(outDir, "latest.json"), body, "utf8");
  await writeFile(
    join(outDir, "latest.txt"),
    `${card ? `${card.headline}\n\n` : ""}${renderScenarioTable(report.results)}\n\n${card ? renderScorecard(report.results, card) : ""}\n`,
    "utf8",
  );
}

function toJson(report: EvalReport, card: Scorecard | null, keyHash: string): Record<string, unknown> {
  return {
    schema: "aftermarket.keeper.eval/1",
    startedAt: report.startedAt,
    finishedAt: report.finishedAt,
    answerKeyHash: keyHash,
    fork: {
      chainId: report.forkChainId,
      blockNumber: report.forkBlockNumber,
      note: "A base-anvil fork of Base mainnet. USDC, Coinbase's SpendPermissionManager and the CoinbaseSmartWalletFactory are the live mainnet contracts; Aftermarket itself is deployed fresh from the same sources as the mainnet system, with a controllable feed, pool and calendar per line.",
    },
    deployment: report.deployment,
    liveOracles: report.liveOracles,
    scorecard: card,
    results: report.results,
  };
}
