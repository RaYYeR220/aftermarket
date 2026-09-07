import { ContractFunctionRevertedError, encodeErrorResult } from "viem";
import { describe, expect, it } from "vitest";
import { aftermarketOracleAbi } from "../src/abi.js";
import { decodeOracleError, extractRevertData, Session } from "../src/types.js";

describe("decodeOracleError", () => {
  it("decodes StaleFeed", () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "StaleFeed",
      args: [Session.REGULAR, 187_200n, 3_600n],
    });
    expect(decodeOracleError(data)).toEqual({
      name: "StaleFeed",
      session: Session.REGULAR,
      age: 187_200n,
      budget: 3_600n,
    });
  });

  it("decodes SourcesDiverged", () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "SourcesDiverged",
      args: [Session.CLOSED_WEEKEND, 929n, 100n],
    });
    expect(decodeOracleError(data)).toEqual({
      name: "SourcesDiverged",
      session: Session.CLOSED_WEEKEND,
      divergenceBps: 929n,
      band: 100n,
    });
  });

  it("decodes PoolTooThin", () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "PoolTooThin",
      args: [1_000_000_000_000_000_000_000n, 5_000_000_000_000_000_000_000n],
    });
    expect(decodeOracleError(data)).toEqual({
      name: "PoolTooThin",
      liquidityUsd: 1_000_000_000_000_000_000_000n,
      minLiquidityUsd: 5_000_000_000_000_000_000_000n,
    });
  });

  it("decodes MarketHalted", () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "MarketHalted",
      args: [1_050_000_000_000_000_000n],
    });
    expect(decodeOracleError(data)).toEqual({
      name: "MarketHalted",
      multiplier: 1_050_000_000_000_000_000n,
    });
  });

  it("decodes InvalidFeedAnswer, including a negative answer", () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "InvalidFeedAnswer",
      args: [-5n],
    });
    expect(decodeOracleError(data)).toEqual({
      name: "InvalidFeedAnswer",
      answer: -5n,
    });
  });

  it("returns undefined for a plain Error(string) revert (not one of the five)", () => {
    const data = encodeErrorResult({
      abi: [{ type: "error", name: "Error", inputs: [{ name: "message", type: "string" }] }],
      errorName: "Error",
      args: ["insufficient balance"],
    });
    expect(decodeOracleError(data)).toBeUndefined();
  });

  it("returns undefined for empty revert data", () => {
    expect(decodeOracleError("0x")).toBeUndefined();
  });

  it("returns undefined for garbage/unrecognized selector bytes", () => {
    expect(decodeOracleError("0xdeadbeef")).toBeUndefined();
  });
});

describe("extractRevertData", () => {
  it("pulls raw revert bytes out of a ContractFunctionRevertedError", () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "MarketHalted",
      args: [0n],
    });
    const error = new ContractFunctionRevertedError({
      abi: aftermarketOracleAbi,
      data,
      functionName: "price",
    });
    expect(extractRevertData(error)).toBe(data);
  });

  it("full round trip: ContractFunctionRevertedError -> extractRevertData -> decodeOracleError", () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "StaleFeed",
      args: [Session.CLOSED_HOLIDAY, 999_999n, 3_600n],
    });
    const error = new ContractFunctionRevertedError({
      abi: aftermarketOracleAbi,
      data,
      functionName: "markBorrow",
    });
    const raw = extractRevertData(error);
    expect(raw).toBeDefined();
    expect(decodeOracleError(raw!)).toEqual({
      name: "StaleFeed",
      session: Session.CLOSED_HOLIDAY,
      age: 999_999n,
      budget: 3_600n,
    });
  });

  it("returns undefined for a non-viem error", () => {
    expect(extractRevertData(new Error("network timeout"))).toBeUndefined();
  });

  it("returns undefined for a ContractFunctionRevertedError with no data (message-only revert)", () => {
    const error = new ContractFunctionRevertedError({
      abi: aftermarketOracleAbi,
      functionName: "price",
      message: "execution reverted",
    });
    expect(extractRevertData(error)).toBeUndefined();
  });
});
