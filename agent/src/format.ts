import { formatUnits } from "viem";
import { USDC_DECIMALS } from "./addresses.js";
import { formatHealthBps, MAX_UINT256 } from "./engine.js";
import { reasonName } from "./reasons.js";
import { sessionLabel, verdictName } from "./reader.js";
import type { AccountSnapshot, ContractSimulation, Decision, DecisionRecord } from "./types.js";

function padRight(text: string, width: number): string {
  return text.length >= width ? text : text + " ".repeat(width - text.length);
}

/** The same fixed-width table the observer package prints, so the two tools read alike. */
export function renderTable(headers: string[], rows: string[][]): string {
  const widths = headers.map((header, col) => Math.max(header.length, ...rows.map((row) => (row[col] ?? "").length)));
  const renderRow = (cells: string[]): string =>
    cells
      .map((cell, col) => padRight(cell, widths[col] ?? 0))
      .join("  ")
      .trimEnd();
  const separator = widths.map((width) => "-".repeat(width)).join("  ");
  return [renderRow(headers), separator, ...rows.map(renderRow)].join("\n");
}

/** `1,250.00 USDC` from raw six-decimal units. */
export function formatUsdc(value: bigint | null): string {
  if (value === null) return "unavailable";
  const whole = Number(formatUnits(value, USDC_DECIMALS));
  return `${whole.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USDC`;
}

/** `112.34%` of the seizure threshold, from a bps health reading. */
export function formatHealthPercent(healthBps: bigint | null): string {
  if (healthBps === null) return "unavailable";
  if (healthBps === MAX_UINT256) return "no debt";
  return `${(Number(healthBps) / 100).toFixed(2)}%`;
}

function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/** One row per account: what the keeper decided and what it did about it. */
export function renderTickTable(records: readonly DecisionRecord[]): string {
  const rows = records.map((record) => [
    shortAddress(record.account),
    record.status,
    record.reasonName,
    record.inputs.healthBps === null ? "-" : formatHealthPercent(BigInt(record.inputs.healthBps)),
    record.inputs.amount === null ? "-" : formatUsdc(BigInt(record.inputs.amount)),
    record.inputs.allowanceRemaining === null ? "-" : formatUsdc(BigInt(record.inputs.allowanceRemaining)),
    record.inputs.session ?? "-",
    record.action.txHash ? shortAddress(record.action.txHash) : record.action.note,
  ]);
  return renderTable(["Account", "Status", "Reason", "Health", "Amount", "Allowance left", "Session", "Action"], rows);
}

/**
 * The `explain` report: one account, written out for a person.
 *
 * It walks the same eight checks in the same order the contract does, marking each one passed,
 * failed or not reached. A refusal that only says `ORACLE_UNTRUSTED` is a code; a refusal that
 * shows the four checks that passed before it, the feed that caused it and the exact revert that
 * feed produced is an argument.
 */
export function renderExplain(
  snapshot: AccountSnapshot,
  decision: Decision,
  contract: ContractSimulation | null,
): string {
  const lines: string[] = [];
  const { enrollment, position } = snapshot;
  const enrolled = enrollment.permissionHash !== ZERO_HASH;

  lines.push(`Account ${snapshot.account}`);
  lines.push(`Block #${snapshot.blockNumber}  chain time ${new Date(Number(snapshot.blockTimestamp) * 1000).toISOString()}`);
  lines.push("");

  lines.push("Mandate");
  if (!enrolled) {
    lines.push("  not enrolled — this account has never granted the agent a mandate, or it has withdrawn.");
  } else {
    lines.push(`  permission hash    ${enrollment.permissionHash}`);
    lines.push(`  enabled            ${enrollment.policy.enabled}`);
    lines.push(`  trigger health     ${enrollment.policy.triggerHealthBps} bps (${formatHealthPercent(BigInt(enrollment.policy.triggerHealthBps))} of the seizure threshold)`);
    lines.push(`  max per execution  ${formatUsdc(enrollment.policy.maxPerExecution)}`);
    lines.push(`  min interval       ${enrollment.policy.minInterval}s`);
    lines.push(
      `  last executed      ${enrollment.lastExecutedAt === 0n ? "never" : new Date(Number(enrollment.lastExecutedAt) * 1000).toISOString()}`,
    );
    lines.push(`  permission window  ${isoOrNever(enrollment.permission.start)} → ${isoOrNever(enrollment.permission.end)}`);
    lines.push(`  allowance          ${formatUsdc(enrollment.permission.allowance)} per ${enrollment.permission.period}s period`);
    lines.push(`  spendable now      ${formatUsdc(snapshot.spendable)}`);
  }
  lines.push("");

  lines.push("Line");
  if (position === null) {
    lines.push("  unavailable — AftermarketCredit.positionOf reverted, so the protocol will not report a position at all.");
  } else {
    lines.push(`  session            ${sessionLabel(position.session)}`);
    lines.push(`  priced             ${position.priced}`);
    lines.push(`  flagged            ${position.flagged}${position.flagged ? ` (grace until ${isoOrNever(Number(position.graceUntil))})` : ""}`);
    lines.push(`  debt               ${formatUsdc(position.debtAssets)}`);
    lines.push(`  seizure threshold  ${formatUsdc(position.seizureThreshold)}`);
    lines.push(`  borrow power       ${formatUsdc(position.borrowPower)}`);
    lines.push(`  health             ${formatHealthBps(decision.healthBps)} (${formatHealthPercent(decision.healthBps)})`);
  }
  lines.push("");

  lines.push("Collateral oracles");
  if (snapshot.oracles.length === 0) {
    lines.push("  none posted, or the lens could not be read.");
  } else {
    for (const oracle of snapshot.oracles) {
      lines.push(`  ${oracle.symbol} @ ${oracle.oracle}`);
      lines.push(`    verdict          ${verdictName(oracle.verdict) ?? "unavailable"}`);
      if (oracle.explanation) lines.push(`    ${oracle.explanation}`);
      if (oracle.priceError) lines.push(`    price() reverts  ${oracle.priceError}`);
    }
  }
  lines.push("");

  lines.push("Decision");
  lines.push(`  keeper engine      ${reasonName(decision.reason)}${decision.willAct ? ` — would repay ${formatUsdc(decision.amount)}` : ""}`);
  if (contract) {
    lines.push(
      `  contract simulate  ${reasonName(contract.reason)}${contract.willAct ? ` — willAct, amount ${formatUsdc(contract.amount)}` : ""}`,
    );
    const agree = contract.reason === decision.reason && contract.willAct === decision.willAct;
    lines.push(`  agreement          ${agree ? "the two agree" : "DISAGREEMENT — the keeper stands down"}`);
  }
  lines.push("");
  lines.push(wrap(decision.explanation, 96, "  "));

  return lines.join("\n");
}

function isoOrNever(unixSeconds: number): string {
  if (unixSeconds === 0) return "never";
  return new Date(unixSeconds * 1000).toISOString();
}

/** Wraps prose to a column so a terminal report stays readable at any width. */
export function wrap(text: string, width: number, indent = ""): string {
  const words = text.split(/\s+/);
  const lines: string[] = [];
  let current = indent;
  for (const word of words) {
    if (current.length + word.length + 1 > width && current.trim() !== "") {
      lines.push(current.trimEnd());
      current = indent;
    }
    current += `${word} `;
  }
  if (current.trim() !== "") lines.push(current.trimEnd());
  return lines.join("\n");
}

const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
