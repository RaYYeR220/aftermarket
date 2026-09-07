import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { reasonName } from "../reasons.js";
import { SCENARIOS, type Scenario } from "./scenarios.js";

/** One pre-registered expectation. */
export interface AnswerKeyEntry {
  readonly id: string;
  readonly title: string;
  readonly category: string;
  readonly trap: boolean;
  readonly negativeControl: boolean;
  readonly expected: { readonly willAct: boolean; readonly reason: number; readonly reasonName: string };
  readonly rationale: string;
}

export interface AnswerKey {
  readonly schema: "aftermarket.keeper.answer-key/1";
  readonly note: string;
  readonly scenarioCount: number;
  readonly trapCount: number;
  readonly negativeControlCount: number;
  readonly hash: string;
  readonly entries: readonly AnswerKeyEntry[];
}

/** Where the committed key lives, relative to the repository root. */
export const ANSWER_KEY_PATH = "agent/eval/answer-key.json";

const NOTE =
  "Pre-registered expectations for the Aftermarket keeper evaluation. Every entry was written before " +
  "the harness was ever run. `hash` is the SHA-256 of the canonical JSON of `entries`; the runner " +
  "recomputes it from the scenario definitions and refuses to score if the two differ, so an " +
  "expectation cannot be quietly edited to match a result.";

/** Builds the key from the scenario definitions in this build. */
export function buildAnswerKey(scenarios: readonly Scenario[] = SCENARIOS): AnswerKey {
  const entries: AnswerKeyEntry[] = scenarios.map((scenario) => ({
    id: scenario.id,
    title: scenario.title,
    category: scenario.category,
    trap: scenario.trap,
    negativeControl: scenario.negativeControl,
    expected: {
      willAct: scenario.expected.willAct,
      reason: scenario.expected.reason,
      reasonName: reasonName(scenario.expected.reason),
    },
    rationale: scenario.rationale,
  }));

  return {
    schema: "aftermarket.keeper.answer-key/1",
    note: NOTE,
    scenarioCount: entries.length,
    trapCount: entries.filter((entry) => entry.trap).length,
    negativeControlCount: entries.filter((entry) => entry.negativeControl).length,
    hash: hashEntries(entries),
    entries,
  };
}

/**
 * The hash the pre-registration rests on.
 *
 * Only the fields that constitute a claim are hashed — the id, whether the scenario is a trap or a
 * control, and the expected verdict. Prose is excluded on purpose: rewording a rationale should not
 * invalidate a pre-registration, and changing an expected verdict must.
 */
export function hashEntries(entries: readonly AnswerKeyEntry[]): string {
  const canonical = entries
    .map((entry) => [entry.id, entry.category, entry.trap, entry.negativeControl, entry.expected.willAct, entry.expected.reason])
    .sort((a, b) => String(a[0]).localeCompare(String(b[0])));
  return createHash("sha256").update(JSON.stringify(canonical)).digest("hex");
}

/** Reads the committed key, or `null` when it has never been written. */
export async function readAnswerKey(path: string): Promise<AnswerKey | null> {
  try {
    return JSON.parse(await readFile(path, "utf8")) as AnswerKey;
  } catch {
    return null;
  }
}

/** Writes the key, which is a deliberate act: it re-registers every expectation. */
export async function writeAnswerKey(path: string, key: AnswerKey): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(key, null, 2)}\n`, "utf8");
}

export type AnswerKeyStatus =
  | { readonly ok: true; readonly key: AnswerKey }
  | { readonly ok: false; readonly reason: string; readonly committedHash: string | null; readonly currentHash: string };

/**
 * Compares the key committed to the repository against the scenarios this build is about to run.
 *
 * This is the mechanism that makes the evaluation pre-registered rather than merely documented. A
 * mismatch means somebody changed an expected verdict without re-registering it, and the run is
 * refused: a scorecard produced against expectations edited after the fact is worth nothing.
 */
export async function verifyAnswerKey(path: string, scenarios: readonly Scenario[] = SCENARIOS): Promise<AnswerKeyStatus> {
  const current = buildAnswerKey(scenarios);
  const committed = await readAnswerKey(path);

  if (!committed) {
    return {
      ok: false,
      reason: `no answer key at ${path}. Register the current expectations with \`keeper eval -- --write-key\` and commit the file before scoring against it.`,
      committedHash: null,
      currentHash: current.hash,
    };
  }
  if (committed.hash !== current.hash) {
    return {
      ok: false,
      reason:
        `the committed answer key (${committed.hash.slice(0, 16)}…) does not match the scenarios in this build ` +
        `(${current.hash.slice(0, 16)}…). An expected verdict changed without being re-registered.`,
      committedHash: committed.hash,
      currentHash: current.hash,
    };
  }
  return { ok: true, key: committed };
}
