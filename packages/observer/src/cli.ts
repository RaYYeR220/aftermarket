#!/usr/bin/env node
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { createObserverClient, resolveRpcUrl } from "./chain.js";
import { buildReport, type AssetReport, type Fallible, type ObserverReport } from "./report.js";

interface CliOptions {
  json: boolean;
  snapshotPath: string | null;
  tickers: string[] | null;
  help: boolean;
}

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = { json: false, snapshotPath: null, tickers: null, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--json":
        options.json = true;
        break;
      case "--snapshot": {
        const value = argv[i + 1];
        if (!value) {
          throw new Error("--snapshot requires a file or directory path");
        }
        options.snapshotPath = value;
        i += 1;
        break;
      }
      case "--asset": {
        const value = argv[i + 1];
        if (!value) {
          throw new Error("--asset requires a ticker, e.g. --asset NVDAc");
        }
        options.tickers = (options.tickers ?? []).concat(value);
        i += 1;
        break;
      }
      case "--help":
      case "-h":
        options.help = true;
        break;
      default:
        throw new Error(`unrecognized argument: ${arg}`);
    }
  }
  return options;
}

const HELP_TEXT = `aftermarket-observer — live Base mainnet evidence for Coinbase tokenized stocks

Usage:
  observer [--asset TICKER] [--json] [--snapshot PATH]

Options:
  --asset TICKER    Report on a single asset (e.g. --asset NVDAc). Repeatable.
  --json            Print machine-readable JSON instead of the terminal table.
  --snapshot PATH   Also write a timestamped JSON evidence file. PATH may be a
                     directory (a filename is generated) or an exact .json file.
  -h, --help        Show this message.

Environment:
  BASE_RPC_URL      Base mainnet RPC endpoint (default: https://mainnet.base.org)
`;

function jsonSafe(value: unknown): unknown {
  if (typeof value === "bigint") {
    return value.toString();
  }
  if (Array.isArray(value)) {
    return value.map(jsonSafe);
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, jsonSafe(v)]));
  }
  return value;
}

function padRight(text: string, width: number): string {
  return text.length >= width ? text : text + " ".repeat(width - text.length);
}

function renderTable(headers: string[], rows: string[][]): string {
  const widths = headers.map((header, col) => Math.max(header.length, ...rows.map((row) => (row[col] ?? "").length)));
  const renderRow = (cells: string[]): string => cells.map((cell, col) => padRight(cell, widths[col] ?? 0)).join("  ");
  const separator = widths.map((w) => "-".repeat(w)).join("  ");
  return [renderRow(headers), separator, ...rows.map(renderRow)].join("\n");
}

const usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 2 });
const usdCompact = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });

function fmt<T>(value: Fallible<T>, render: (v: T) => string): string {
  return value.ok ? render(value.value) : "unavailable";
}

function formatWad(value: bigint): string {
  return (Number(value) / 1e18).toFixed(6);
}

function formatSupply(value: bigint, decimals: number): string {
  return (Number(value) / 10 ** decimals).toLocaleString("en-US", { maximumFractionDigits: 0 });
}

function shortFlag(report: AssetReport): string {
  if (!report.divergenceBps.ok) {
    return report.pool.ok ? "N/A" : "NO-POOL";
  }
  const bps = report.divergenceBps.value;
  if (bps < 25) return "OK";
  if (bps < 100) return "WATCH";
  return "STALE";
}

function renderHumanReport(report: ObserverReport): string {
  const lines: string[] = [];
  lines.push("Aftermarket Observer — live Base mainnet evidence");
  lines.push(`Block #${report.block.number}  Chain time: ${report.block.timestampIso} (unix ${report.block.timestampUnix})`);
  lines.push(
    `US equity market: ${report.market.isOpen ? "OPEN" : "CLOSED"} — ${report.market.reason} (${report.market.etTime}, DST: ${report.market.isDst ? "yes" : "no"})`,
  );
  lines.push(`RPC: ${report.rpcUrl}`);
  lines.push(`Slipstream factory: ${report.slipstreamFactoryAddress}`);
  lines.push("");

  const headers = ["Ticker", "Supply", "Mult.", "Feed $", "Feed Age", "TWAP $", "Spot $", "Depth (USDC)", "Div (bps)", "Flag"];
  const rows = report.assets.map((asset) => [
    asset.ticker,
    fmt(asset.b20, (b) => formatSupply(b.totalSupply, b.decimals)),
    fmt(asset.b20, (b) => formatWad(b.multiplierWad)),
    fmt(asset.feed, (f) => usd.format(f.price)),
    fmt(asset.feed, (f) => (f.stalenessSeconds >= 3600 ? `${(f.stalenessSeconds / 3600).toFixed(1)}h` : `${f.stalenessSeconds}s`)),
    fmt(asset.pool, (p) => usd.format(p.twapPriceUsd)),
    fmt(asset.pool, (p) => usd.format(p.spotPriceUsd)),
    fmt(asset.pool, (p) => usdCompact.format(p.usdcDepth)),
    fmt(asset.divergenceBps, (bps) => bps.toFixed(1)),
    shortFlag(asset),
  ]);
  lines.push(renderTable(headers, rows));
  lines.push("");

  lines.push("Verdicts");
  lines.push("--------");
  for (const asset of report.assets) {
    lines.push(`${asset.ticker}: ${asset.verdict}`);
  }
  lines.push("");

  const stale = report.assets.filter((a) => shortFlag(a) === "STALE").length;
  const watch = report.assets.filter((a) => shortFlag(a) === "WATCH").length;
  const noPool = report.assets.filter((a) => shortFlag(a) === "NO-POOL").length;
  const assetNoun = report.assets.length === 1 ? "asset" : "assets";
  lines.push(
    `Summary: ${report.assets.length} ${assetNoun} checked — ${stale} marking against a stale price, ${watch} drifting, ${noPool} with no on-chain pool to check against.`,
  );

  return lines.join("\n");
}

async function writeSnapshot(path: string, report: ObserverReport): Promise<string> {
  const isJsonFile = path.toLowerCase().endsWith(".json");
  const timestampTag = new Date(Number(report.block.timestampUnix) * 1000).toISOString().replace(/[:.]/g, "-");
  const targetPath = isJsonFile ? path : join(path, `observer-snapshot-${report.block.number}-${timestampTag}.json`);

  await mkdir(dirname(targetPath), { recursive: true });
  const payload = { generatedAtIso: new Date().toISOString(), ...report };
  await writeFile(targetPath, JSON.stringify(jsonSafe(payload), null, 2) + "\n", "utf8");
  return targetPath;
}

async function main(): Promise<void> {
  let options: CliOptions;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n\n${HELP_TEXT}`);
    process.exitCode = 0;
    return;
  }

  if (options.help) {
    process.stdout.write(HELP_TEXT);
    return;
  }

  const rpcUrl = resolveRpcUrl();
  const client = createObserverClient(rpcUrl);

  let report: ObserverReport;
  try {
    report = await buildReport(client, { rpcUrl, tickers: options.tickers ?? undefined });
  } catch (error) {
    process.stderr.write(`fatal: could not reach the Base RPC at ${rpcUrl}: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
    return;
  }

  if (options.tickers && report.assets.length === 0) {
    process.stderr.write(`no known asset matches: ${options.tickers.join(", ")}\n`);
  }

  if (options.json) {
    process.stdout.write(JSON.stringify(jsonSafe(report), null, 2) + "\n");
  } else {
    process.stdout.write(renderHumanReport(report) + "\n");
  }

  if (options.snapshotPath) {
    const writtenPath = await writeSnapshot(options.snapshotPath, report);
    process.stderr.write(`snapshot written: ${writtenPath}\n`);
  }
}

main().catch((error: unknown) => {
  process.stderr.write(`fatal: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});
