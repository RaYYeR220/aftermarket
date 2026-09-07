import { renderTable } from "../format.js";
import type { AnswerKey } from "./answer-key.js";

/** What actually happened for one scenario. */
export interface ScenarioResult {
  readonly id: string;
  readonly title: string;
  readonly category: string;
  readonly trap: boolean;
  readonly negativeControl: boolean;
  readonly account: string;
  readonly expected: { readonly willAct: boolean; readonly reason: number; readonly reasonName: string };
  /** The keeper's own rule engine, before it asked the chain anything. */
  readonly engine: { readonly willAct: boolean; readonly reason: number; readonly reasonName: string; readonly amount: string };
  /** The contract's own `simulate()`. */
  readonly contract: { readonly willAct: boolean; readonly reason: number; readonly reasonName: string; readonly amount: string };
  /** What the keeper did when allowed to act for real. */
  readonly acted: boolean;
  readonly repaid: string | null;
  readonly txHash: string | null;
  /** Money and debt moved, measured on chain before and after. */
  readonly borrowerUsdcDelta: string;
  readonly debtDelta: string;
  /** Oracle state the keeper saw, for the record. */
  readonly oracle: {
    readonly verdict: string | null;
    readonly session: string | null;
    readonly divergenceBps: string | null;
    readonly priceError: string | null;
  } | null;
  /** Invariants that must hold whatever the verdict was. Empty when everything held. */
  readonly violations: readonly string[];
  readonly correct: boolean;
  readonly falseAction: boolean;
  readonly note: string | null;
}

export interface Scorecard {
  readonly total: number;
  readonly correct: number;
  readonly incorrect: number;
  readonly falseActions: number;
  readonly traps: number;
  readonly trapsRefused: number;
  readonly negativeControls: number;
  readonly negativeControlsActed: number;
  readonly invariantViolations: number;
  readonly passed: boolean;
  readonly headline: string;
}

/**
 * Scores a run against the pre-registered key.
 *
 * Three things are counted separately because they fail for different reasons and a single number
 * would hide the important one.
 *
 * **Correct** is the plain hit rate: did the keeper reach the pre-registered verdict.
 *
 * **False actions** are counted on their own and are a hard failure, never a warning. Every other
 * mistake this keeper can make costs a borrower some delay; a false action costs them money out of
 * a permission they granted for something else. One is enough to fail the run.
 *
 * **Traps refused** and **negative controls acted** are the two halves of the same guard. A keeper
 * that refuses everything scores perfectly on traps and is worthless; a keeper that acts on
 * everything scores perfectly on controls and is dangerous. Reporting both makes either failure
 * mode visible at a glance.
 */
export function score(results: readonly ScenarioResult[], key: AnswerKey): Scorecard {
  const total = results.length;
  const correct = results.filter((result) => result.correct).length;
  const falseActions = results.filter((result) => result.falseAction).length;
  const traps = results.filter((result) => result.trap);
  const trapsRefused = traps.filter((result) => result.correct && !result.acted).length;
  const controls = results.filter((result) => result.negativeControl);
  const controlsActed = controls.filter((result) => result.acted).length;
  const invariantViolations = results.reduce((sum, result) => sum + result.violations.length, 0);

  const passed =
    total === key.scenarioCount &&
    correct === total &&
    falseActions === 0 &&
    trapsRefused === traps.length &&
    controlsActed === controls.length &&
    invariantViolations === 0;

  const headline =
    `${correct}/${total} correct · ${falseActions} false action${falseActions === 1 ? "" : "s"} · ` +
    `${trapsRefused}/${traps.length} traps refused · ${controlsActed}/${controls.length} negative controls acted`;

  return {
    total,
    correct,
    incorrect: total - correct,
    falseActions,
    traps: traps.length,
    trapsRefused,
    negativeControls: controls.length,
    negativeControlsActed: controlsActed,
    invariantViolations,
    passed,
    headline,
  };
}

/** The per-scenario table printed to the terminal and pasted into a report. */
export function renderScenarioTable(results: readonly ScenarioResult[]): string {
  const rows = results.map((result) => [
    result.id,
    result.correct ? "pass" : "FAIL",
    result.trap ? "trap" : result.negativeControl ? "control" : "",
    result.expected.reasonName,
    result.engine.reasonName,
    result.contract.reasonName,
    result.acted ? "acted" : "refused",
    result.repaid ?? "-",
    result.violations.length === 0 ? "" : `${result.violations.length} violation(s)`,
  ]);
  return renderTable(
    ["Id", "Result", "Kind", "Expected", "Keeper engine", "Contract", "Action", "Repaid", "Invariants"],
    rows,
  );
}

/** The scorecard block, with the failures spelled out underneath. */
export function renderScorecard(results: readonly ScenarioResult[], card: Scorecard): string {
  const lines: string[] = [];
  lines.push(card.headline);
  lines.push("");
  lines.push(
    renderTable(
      ["Measure", "Value"],
      [
        ["scenarios", String(card.total)],
        ["correct", `${card.correct}/${card.total}`],
        ["false actions (hard failure)", String(card.falseActions)],
        ["traps refused", `${card.trapsRefused}/${card.traps}`],
        ["negative controls acted", `${card.negativeControlsActed}/${card.negativeControls}`],
        ["invariant violations", String(card.invariantViolations)],
        ["verdict", card.passed ? "PASS" : "FAIL"],
      ],
    ),
  );

  const failures = results.filter((result) => !result.correct || result.violations.length > 0);
  if (failures.length > 0) {
    lines.push("");
    lines.push("Failures");
    for (const failure of failures) {
      lines.push(`  ${failure.id} ${failure.title}`);
      if (!failure.correct) {
        lines.push(
          `    expected ${failure.expected.reasonName}, keeper engine said ${failure.engine.reasonName}, contract said ${failure.contract.reasonName}`,
        );
      }
      for (const violation of failure.violations) lines.push(`    invariant: ${violation}`);
      if (failure.note) lines.push(`    note: ${failure.note}`);
    }
  }

  return lines.join("\n");
}
