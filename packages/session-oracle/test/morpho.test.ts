import { describe, expect, it } from "vitest";
import { morphoPriceToUsd, usdToMorphoPrice } from "../src/types.js";

// The known-good vector from the task brief: an 8-decimal Chainlink feed answering
// `22995730000` for an 8-decimal collateral token against a 6-decimal loan token.
const FEED_ANSWER = 22_995_730_000n; // 8-decimal feed: $229.9573
const COLLATERAL_DECIMALS = 8;
const LOAN_DECIMALS = 6;
const EXPECTED_MORPHO_PRICE = 2_299_573n * 10n ** 30n;
const EXPECTED_USD = 229.9573;

describe("morphoPriceToUsd", () => {
  it("matches the known-good vector", () => {
    expect(morphoPriceToUsd(EXPECTED_MORPHO_PRICE, COLLATERAL_DECIMALS, LOAN_DECIMALS)).toBe(EXPECTED_USD);
  });

  it("derives the same Morpho price from the raw feed answer as the contract's own scaling", () => {
    // AftermarketOracle: anchorPrice (WAD) = rawAnswer * 10**(18 - feedDecimals);
    // markBorrow/markLiquidate (Morpho scale) = markWad * 10**(18 + loanDecimals - collateralDecimals).
    // Combined: morphoPrice = rawAnswer * 10**(36 + loanDecimals - collateralDecimals - feedDecimals).
    const feedDecimals = 8;
    const anchorWad = FEED_ANSWER * 10n ** BigInt(18 - feedDecimals);
    const morphoScale = 10n ** BigInt(18 + LOAN_DECIMALS - COLLATERAL_DECIMALS);
    const morphoPrice = anchorWad * morphoScale;
    expect(morphoPrice).toBe(EXPECTED_MORPHO_PRICE);
    expect(morphoPriceToUsd(morphoPrice, COLLATERAL_DECIMALS, LOAN_DECIMALS)).toBe(EXPECTED_USD);
  });

  it("handles equal collateral/loan decimals (18/18)", () => {
    // price = usd * 1e36 exactly when collateralDecimals === loanDecimals.
    const price = 150n * 10n ** 36n; // $150.00
    expect(morphoPriceToUsd(price, 18, 18)).toBe(150);
  });

  it("handles an 18-decimal collateral token against a 6-decimal loan token", () => {
    const price = usdToMorphoPrice("1800.5", 18, 6);
    expect(morphoPriceToUsd(price, 18, 6)).toBe(1800.5);
  });

  it("throws a RangeError when the exponent would be negative", () => {
    // 36 + loanDecimals - collateralDecimals < 0
    expect(() => morphoPriceToUsd(1n, 40, 0)).toThrow(RangeError);
  });
});

describe("usdToMorphoPrice", () => {
  it("matches the known-good vector (number input)", () => {
    expect(usdToMorphoPrice(EXPECTED_USD, COLLATERAL_DECIMALS, LOAN_DECIMALS)).toBe(EXPECTED_MORPHO_PRICE);
  });

  it("matches the known-good vector (string input)", () => {
    expect(usdToMorphoPrice("229.9573", COLLATERAL_DECIMALS, LOAN_DECIMALS)).toBe(EXPECTED_MORPHO_PRICE);
  });

  it("throws a RangeError when the exponent would be negative", () => {
    expect(() => usdToMorphoPrice("1", 40, 0)).toThrow(RangeError);
  });

  it("round-trips through morphoPriceToUsd for a range of decimal combinations", () => {
    const cases: Array<[string, number, number]> = [
      ["1.00", 18, 18],
      ["100.25", 8, 6],
      ["0.5", 6, 18],
      ["999999.99", 8, 8],
    ];
    for (const [usd, collateralDecimals, loanDecimals] of cases) {
      const price = usdToMorphoPrice(usd, collateralDecimals, loanDecimals);
      expect(morphoPriceToUsd(price, collateralDecimals, loanDecimals)).toBe(Number(usd));
    }
  });
});
