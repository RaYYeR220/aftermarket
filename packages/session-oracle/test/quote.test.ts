import { parseUnits } from "viem";
import { describe, expect, it } from "vitest";
import {
  isMarketOpenSession,
  isTrustedVerdict,
  Session,
  SESSION_NAMES,
  toDecodedQuote,
  Verdict,
  VERDICT_NAMES,
  type RawQuote,
} from "../src/types.js";

/**
 * Shaped exactly like what `publicClient.readContract({ functionName: "peek" })` returns: `verdict`
 * and `session` as plain `number` (viem decodes `uint8` that way), everything else `bigint`. This is
 * the motivating scenario from the README: a 52-hour-stale AMZN feed at $257.69 against a pool
 * printing $281.64, a 9.29% divergence over $62.5k of depth.
 */
const RAW_QUOTE: RawQuote = {
  verdict: Verdict.UNTRUSTED_DIVERGENT,
  session: Session.CLOSED_WEEKEND,
  anchorPrice: parseUnits("257.69", 18),
  poolPrice: parseUnits("281.64", 18),
  markBorrow: parseUnits("257.69", 18) * 10n ** 30n, // arbitrary Morpho-scale stand-in
  markLiquidate: parseUnits("281.64", 18) * 10n ** 30n,
  feedAge: 52n * 3600n,
  stalenessBudget: 26n * 3600n,
  divergenceBps: 929n,
  divergenceBand: 100n,
  haircutBps: 50n,
  multiplier: parseUnits("1", 18),
  poolLiquidityUsd: parseUnits("62500", 18),
  nextOpen: 1_800_000_000n,
  lastClose: 1_799_800_000n,
};

describe("toDecodedQuote", () => {
  it("round-trips every raw field unchanged", () => {
    const decoded = toDecodedQuote(RAW_QUOTE);
    for (const key of Object.keys(RAW_QUOTE) as (keyof RawQuote)[]) {
      expect(decoded[key]).toBe(RAW_QUOTE[key]);
    }
  });

  it("narrows verdict and session to the enum types", () => {
    const decoded = toDecodedQuote(RAW_QUOTE);
    expect(decoded.verdict).toBe(Verdict.UNTRUSTED_DIVERGENT);
    expect(decoded.session).toBe(Session.CLOSED_WEEKEND);
  });

  it("computes priceUsd and poolPriceUsd from the WAD anchor/pool prices", () => {
    const decoded = toDecodedQuote(RAW_QUOTE);
    expect(decoded.priceUsd).toBeCloseTo(257.69, 8);
    expect(decoded.poolPriceUsd).toBeCloseTo(281.64, 8);
  });

  it("computes feedAgeSeconds as a plain number", () => {
    const decoded = toDecodedQuote(RAW_QUOTE);
    expect(decoded.feedAgeSeconds).toBe(52 * 3600);
    expect(typeof decoded.feedAgeSeconds).toBe("number");
  });

  it("flags an untrusted, closed-market quote correctly", () => {
    const decoded = toDecodedQuote(RAW_QUOTE);
    expect(decoded.isTrusted).toBe(false);
    expect(decoded.isMarketOpen).toBe(false);
  });

  it.each([
    [Verdict.TRUSTED, true],
    [Verdict.TRUSTED_CLOSED, true],
    [Verdict.UNTRUSTED_STALE, false],
    [Verdict.UNTRUSTED_DIVERGENT, false],
    [Verdict.UNTRUSTED_THIN, false],
    [Verdict.UNTRUSTED_HALTED, false],
  ] as const)("isTrusted reflects verdict %i -> %s", (verdict, expected) => {
    const decoded = toDecodedQuote({ ...RAW_QUOTE, verdict });
    expect(decoded.isTrusted).toBe(expected);
    expect(isTrustedVerdict(verdict)).toBe(expected);
  });

  it.each([
    [Session.REGULAR, true],
    [Session.PRE, true],
    [Session.POST, true],
    [Session.CLOSED_OVERNIGHT, false],
    [Session.CLOSED_WEEKEND, false],
    [Session.CLOSED_HOLIDAY, false],
  ] as const)("isMarketOpen reflects session %i -> %s", (session, expected) => {
    const decoded = toDecodedQuote({ ...RAW_QUOTE, session });
    expect(decoded.isMarketOpen).toBe(expected);
    expect(isMarketOpenSession(session)).toBe(expected);
  });
});

describe("SESSION_NAMES / VERDICT_NAMES", () => {
  it("names every session ordinal", () => {
    expect(SESSION_NAMES).toEqual({
      0: "REGULAR",
      1: "PRE",
      2: "POST",
      3: "CLOSED_OVERNIGHT",
      4: "CLOSED_WEEKEND",
      5: "CLOSED_HOLIDAY",
    });
  });

  it("names every verdict ordinal", () => {
    expect(VERDICT_NAMES).toEqual({
      0: "TRUSTED",
      1: "TRUSTED_CLOSED",
      2: "UNTRUSTED_STALE",
      3: "UNTRUSTED_DIVERGENT",
      4: "UNTRUSTED_THIN",
      5: "UNTRUSTED_HALTED",
    });
  });
});
