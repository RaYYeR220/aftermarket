import { parseUnits } from "viem";
import { describe, expect, it } from "vitest";
import { Session, Verdict, type Quote } from "../src/types.js";
import { explainVerdict, VERDICT_GUIDANCE } from "../src/verdict.js";

// Monday, September 14 2026, 09:30 America/New_York (EDT, UTC-4) == 13:30 UTC.
const MONDAY_0930_ET = BigInt(Date.UTC(2026, 8, 14, 13, 30, 0) / 1000);

const BASE_QUOTE: Quote = {
  verdict: Verdict.TRUSTED,
  session: Session.REGULAR,
  anchorPrice: parseUnits("257.69", 18),
  poolPrice: parseUnits("281.64", 18),
  markBorrow: 0n,
  markLiquidate: 0n,
  feedAge: 52n * 3600n,
  stalenessBudget: 26n * 3600n,
  divergenceBps: 929n,
  divergenceBand: 100n,
  haircutBps: 50n,
  multiplier: parseUnits("1", 18),
  poolLiquidityUsd: parseUnits("62500", 18),
  nextOpen: MONDAY_0930_ET,
  lastClose: MONDAY_0930_ET - 172_800n,
};

function quoteFor(verdict: Verdict, session: Session, overrides: Partial<Quote> = {}): Quote {
  return { ...BASE_QUOTE, verdict, session, ...overrides };
}

describe("explainVerdict", () => {
  it("reproduces the motivating example exactly: divergent + closed", () => {
    const quote = quoteFor(Verdict.UNTRUSTED_DIVERGENT, Session.CLOSED_WEEKEND);
    expect(explainVerdict(quote)).toBe(
      "Reference feed and pool disagree by 9.29% with only $62.5k of depth — " +
        "no mark can be defended until the market reopens Monday 09:30 ET.",
    );
  });

  it("all six verdicts x open/closed produce distinct, non-empty sentences", () => {
    const verdicts = [
      Verdict.TRUSTED,
      Verdict.TRUSTED_CLOSED,
      Verdict.UNTRUSTED_STALE,
      Verdict.UNTRUSTED_DIVERGENT,
      Verdict.UNTRUSTED_THIN,
      Verdict.UNTRUSTED_HALTED,
    ] as const;
    const sessions = [
      { session: Session.REGULAR, open: true },
      { session: Session.CLOSED_WEEKEND, open: false },
    ] as const;

    const sentences = new Set<string>();
    for (const verdict of verdicts) {
      for (const { session } of sessions) {
        const sentence = explainVerdict(quoteFor(verdict, session));
        expect(sentence.length).toBeGreaterThan(0);
        expect(sentence.endsWith(".")).toBe(true);
        sentences.add(sentence);
      }
    }
    // 6 verdicts x 2 sessions = 12 calls. TRUSTED and TRUSTED_CLOSED each collapse their open/closed
    // pair into one identical sentence (their name already says which session they mean), so the
    // floor is 2 (from those) + 8 (the four untrusted verdicts, each genuinely different open vs
    // closed) = 10 distinct sentences. Anything less means an open/closed branch stopped varying.
    expect(sentences.size).toBeGreaterThanOrEqual(10);
  });

  it("TRUSTED mentions the market is open and cites the divergence band", () => {
    const sentence = explainVerdict(quoteFor(Verdict.TRUSTED, Session.REGULAR));
    expect(sentence).toContain("open");
    expect(sentence).toContain("100 bps");
  });

  it("TRUSTED_CLOSED cites the reopen time and the haircut", () => {
    const sentence = explainVerdict(quoteFor(Verdict.TRUSTED_CLOSED, Session.CLOSED_WEEKEND));
    expect(sentence).toContain("Monday 09:30 ET");
    expect(sentence).toContain("50 bps");
  });

  it("UNTRUSTED_STALE while open talks about refreshing, not reopening", () => {
    const sentence = explainVerdict(quoteFor(Verdict.UNTRUSTED_STALE, Session.REGULAR));
    expect(sentence).toContain("52 hours");
    expect(sentence).not.toContain("reopens");
  });

  it("UNTRUSTED_STALE while closed mentions the reopen time", () => {
    const sentence = explainVerdict(quoteFor(Verdict.UNTRUSTED_STALE, Session.CLOSED_WEEKEND));
    expect(sentence).toContain("Monday 09:30 ET");
  });

  it("UNTRUSTED_THIN while open says depth needs to improve", () => {
    const sentence = explainVerdict(quoteFor(Verdict.UNTRUSTED_THIN, Session.REGULAR));
    expect(sentence).toContain("depth improves");
  });

  it("UNTRUSTED_THIN while closed mentions the reopen time", () => {
    const sentence = explainVerdict(quoteFor(Verdict.UNTRUSTED_THIN, Session.CLOSED_WEEKEND));
    expect(sentence).toContain("Monday 09:30 ET");
  });

  it("UNTRUSTED_HALTED mentions the multiplier", () => {
    const sentence = explainVerdict(
      quoteFor(Verdict.UNTRUSTED_HALTED, Session.REGULAR, { multiplier: parseUnits("1.05", 18) }),
    );
    expect(sentence).toContain("1.0500x");
  });

  it("formats large depth in millions", () => {
    const sentence = explainVerdict(
      quoteFor(Verdict.UNTRUSTED_DIVERGENT, Session.REGULAR, { poolLiquidityUsd: parseUnits("2500000", 18) }),
    );
    expect(sentence).toContain("$2.5M");
  });

  it("formats small depth in plain dollars", () => {
    const sentence = explainVerdict(
      quoteFor(Verdict.UNTRUSTED_DIVERGENT, Session.REGULAR, { poolLiquidityUsd: parseUnits("430", 18) }),
    );
    expect(sentence).toContain("$430.00");
  });
});

describe("VERDICT_GUIDANCE", () => {
  it("has guidance for all six verdicts", () => {
    expect(Object.keys(VERDICT_GUIDANCE)).toHaveLength(6);
    for (const verdict of [0, 1, 2, 3, 4, 5] as const) {
      expect(VERDICT_GUIDANCE[verdict]).toBeTruthy();
    }
  });

  it("only TRUSTED and TRUSTED_CLOSED say to use the mark normally", () => {
    expect(VERDICT_GUIDANCE[Verdict.TRUSTED]).toContain("Use the mark normally");
    expect(VERDICT_GUIDANCE[Verdict.TRUSTED_CLOSED]).toContain("Use the mark normally");
    for (const verdict of [
      Verdict.UNTRUSTED_STALE,
      Verdict.UNTRUSTED_DIVERGENT,
      Verdict.UNTRUSTED_THIN,
      Verdict.UNTRUSTED_HALTED,
    ] as const) {
      expect(VERDICT_GUIDANCE[verdict]).toContain("Do not use the mark");
    }
  });
});
