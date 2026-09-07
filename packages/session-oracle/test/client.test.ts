import { ContractFunctionRevertedError, encodeErrorResult, type Address, type PublicClient } from "viem";
import { afterEach, describe, expect, it, vi } from "vitest";
import { aftermarketOracleAbi } from "../src/abi.js";
import { createOracleClient } from "../src/client.js";
import { Session, Verdict, type DecodedQuote, type RawQuote } from "../src/types.js";

const ORACLE_ADDRESS: Address = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

const SAMPLE_RAW_QUOTE: RawQuote = {
  verdict: Verdict.TRUSTED,
  session: Session.REGULAR,
  anchorPrice: 257_690_000_000_000_000_000n,
  poolPrice: 281_640_000_000_000_000_000n,
  markBorrow: 1n,
  markLiquidate: 2n,
  feedAge: 10n,
  stalenessBudget: 3_600n,
  divergenceBps: 929n,
  divergenceBand: 5_000n,
  haircutBps: 0n,
  multiplier: 1_000_000_000_000_000_000n,
  poolLiquidityUsd: 62_500_000_000_000_000_000_000n,
  nextOpen: 1_800_000_000n,
  lastClose: 1_799_800_000n,
};

type ReadContractCall = { functionName: string };

/** A minimal stand-in for viem's `PublicClient`, exposing just the one method the client calls. */
function mockPublicClient(handlers: {
  peek?: () => RawQuote;
  price?: () => bigint;
  markBorrow?: () => bigint;
  markLiquidate?: () => bigint;
}) {
  const readContract = vi.fn(async ({ functionName }: ReadContractCall) => {
    switch (functionName) {
      case "peek":
        if (!handlers.peek) throw new Error("unexpected call to peek");
        return handlers.peek();
      case "price":
        if (!handlers.price) throw new Error("unexpected call to price");
        return handlers.price();
      case "markBorrow":
        if (!handlers.markBorrow) throw new Error("unexpected call to markBorrow");
        return handlers.markBorrow();
      case "markLiquidate":
        if (!handlers.markLiquidate) throw new Error("unexpected call to markLiquidate");
        return handlers.markLiquidate();
      default:
        throw new Error(`unexpected functionName ${functionName}`);
    }
  });
  return { client: { readContract } as unknown as PublicClient, readContract };
}

function revertErrorFromData(data: ReturnType<typeof encodeErrorResult>, functionName: string) {
  return new ContractFunctionRevertedError({ abi: aftermarketOracleAbi, data, functionName });
}

describe("createOracleClient", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("peek() decodes the raw quote into a DecodedQuote", async () => {
    const { client } = mockPublicClient({ peek: () => SAMPLE_RAW_QUOTE });
    const oracle = createOracleClient({ publicClient: client, address: ORACLE_ADDRESS });
    const quote = await oracle.peek();
    expect(quote.verdict).toBe(Verdict.TRUSTED);
    expect(quote.isTrusted).toBe(true);
    expect(quote.priceUsd).toBeCloseTo(257.69, 8);
  });

  it("price() returns { ok: true, price } on success", async () => {
    const { client, readContract } = mockPublicClient({ price: () => 123_456n });
    const oracle = createOracleClient({ publicClient: client, address: ORACLE_ADDRESS });
    const result = await oracle.price();
    expect(result).toEqual({ ok: true, price: 123_456n });
    expect(readContract).toHaveBeenCalledWith(expect.objectContaining({ address: ORACLE_ADDRESS, functionName: "price" }));
  });

  it("price() decodes a StaleFeed revert into { ok: false, error }", async () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "StaleFeed",
      args: [Session.CLOSED_WEEKEND, 200_000n, 3_600n],
    });
    const { client } = mockPublicClient({
      price: () => {
        throw revertErrorFromData(data, "price");
      },
    });
    const oracle = createOracleClient({ publicClient: client, address: ORACLE_ADDRESS });
    const result = await oracle.price();
    expect(result).toEqual({
      ok: false,
      error: { name: "StaleFeed", session: Session.CLOSED_WEEKEND, age: 200_000n, budget: 3_600n },
    });
  });

  it("markBorrow() decodes a SourcesDiverged revert", async () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "SourcesDiverged",
      args: [Session.REGULAR, 929n, 100n],
    });
    const { client } = mockPublicClient({
      markBorrow: () => {
        throw revertErrorFromData(data, "markBorrow");
      },
    });
    const oracle = createOracleClient({ publicClient: client, address: ORACLE_ADDRESS });
    const result = await oracle.markBorrow();
    expect(result).toEqual({
      ok: false,
      error: { name: "SourcesDiverged", session: Session.REGULAR, divergenceBps: 929n, band: 100n },
    });
  });

  it("markLiquidate() decodes a MarketHalted revert", async () => {
    const data = encodeErrorResult({
      abi: aftermarketOracleAbi,
      errorName: "MarketHalted",
      args: [1_050_000_000_000_000_000n],
    });
    const { client } = mockPublicClient({
      markLiquidate: () => {
        throw revertErrorFromData(data, "markLiquidate");
      },
    });
    const oracle = createOracleClient({ publicClient: client, address: ORACLE_ADDRESS });
    const result = await oracle.markLiquidate();
    expect(result).toEqual({ ok: false, error: { name: "MarketHalted", multiplier: 1_050_000_000_000_000_000n } });
  });

  it("rethrows an error that isn't a decodable oracle revert", async () => {
    const { client } = mockPublicClient({
      price: () => {
        throw new Error("connection reset");
      },
    });
    const oracle = createOracleClient({ publicClient: client, address: ORACLE_ADDRESS });
    await expect(oracle.price()).rejects.toThrow("connection reset");
  });

  it("watch() polls peek() immediately and again on each interval, until unsubscribed", async () => {
    vi.useFakeTimers();
    let call = 0;
    const { client } = mockPublicClient({
      peek: () => {
        call += 1;
        return { ...SAMPLE_RAW_QUOTE, feedAge: BigInt(call) };
      },
    });
    const oracle = createOracleClient({ publicClient: client, address: ORACLE_ADDRESS });

    const onQuote = vi.fn<(quote: DecodedQuote) => void>();
    const unsubscribe = oracle.watch(onQuote, { pollingInterval: 1_000 });

    await vi.advanceTimersByTimeAsync(0);
    expect(onQuote).toHaveBeenCalledTimes(1);
    expect(onQuote.mock.calls[0]?.[0]?.feedAgeSeconds).toBe(1);

    await vi.advanceTimersByTimeAsync(1_000);
    expect(onQuote).toHaveBeenCalledTimes(2);

    unsubscribe();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(onQuote).toHaveBeenCalledTimes(2);
  });

  it("watch() reports poll failures via onError instead of throwing", async () => {
    vi.useFakeTimers();
    const { client } = mockPublicClient({
      peek: () => {
        throw new Error("rpc down");
      },
    });
    const oracle = createOracleClient({ publicClient: client, address: ORACLE_ADDRESS });

    const onQuote = vi.fn();
    const onError = vi.fn();
    const unsubscribe = oracle.watch(onQuote, { pollingInterval: 1_000, onError });

    await vi.advanceTimersByTimeAsync(0);
    expect(onError).toHaveBeenCalledTimes(1);
    expect(onQuote).not.toHaveBeenCalled();

    unsubscribe();
  });
});
