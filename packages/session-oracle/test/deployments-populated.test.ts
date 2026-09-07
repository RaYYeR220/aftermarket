import { beforeEach, describe, expect, it, vi } from "vitest";

// Stands in for scripts/generate-deployments.mjs's output. Mocked at the module level (rather than
// by constructing a registry object and re-testing lookup logic by hand) so this exercises the real
// getDeployment / getOracleAddress / getMorphoMarketId / getSupportedChainIds from
// src/deployments.ts against real generated-module data, not a re-implementation of them.
vi.mock("../src/deployments.generated.js", () => ({
  DEPLOYMENTS_BY_CHAIN: {
    8453: {
      chainId: 8453,
      network: "base",
      usdc: "0x1111111111111111111111111111111111111111",
      tradingCalendar: "0x2222222222222222222222222222222222222222",
      attesterRegistry: "0x3333333333333333333333333333333333333333",
      regSGate: "0x4444444444444444444444444444444444444444",
      sessionRateModel: "0x5555555555555555555555555555555555555555",
      oracleFactory: "0x6666666666666666666666666666666666666666",
      swapAdapter: "0x7777777777777777777777777777777777777777",
      credit: "0x8888888888888888888888888888888888888888",
      vault: "0x9999999999999999999999999999999999999999",
      autoRepayer: "0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa",
      lens: "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
      negativeControl: "0xcCccccccCCCCcCCCcCcCcCccCcCCCcCcccccccC",
      oracles: {
        "AMZNc": "0xdDdDdDDddddDddddddDddddddddddDDddDDDDDd",
        "NVDAc": "0xeeeEeEeeeeEEeeeeeEEEeeeeeEEEEeeeEeeeEeee",
      },
      morphoMarkets: {
        "NVDAc": "0xfef5641f70e19a87e369304daa9ba823754f3db1e6481d757fcae0442cffe479",
      },
    },
  },
}));

describe("deployment lookups against a populated registry", () => {
  let deployments: typeof import("../src/deployments.js");

  beforeEach(async () => {
    vi.resetModules();
    deployments = await import("../src/deployments.js");
  });

  it("getDeployment returns the full record for a known chain", () => {
    const record = deployments.getDeployment(8453);
    expect(record?.network).toBe("base");
    expect(Object.keys(record?.oracles ?? {})).toHaveLength(2);
  });

  it("getDeployment returns undefined for an unknown chain", () => {
    expect(deployments.getDeployment(1)).toBeUndefined();
  });

  it("getOracleAddress finds an oracle by chain and symbol", () => {
    expect(deployments.getOracleAddress(8453, "NVDAc")).toBe("0xeeeEeEeeeeEEeeeeeEEEeeeeeEEEEeeeEeeeEeee");
  });

  it("getOracleAddress returns undefined for an unknown symbol", () => {
    expect(deployments.getOracleAddress(8453, "TSLAc")).toBeUndefined();
  });

  it("getOracleAddress returns undefined for an unknown chain", () => {
    expect(deployments.getOracleAddress(1, "NVDAc")).toBeUndefined();
  });

  it("getMorphoMarketId finds a market id by chain and symbol", () => {
    expect(deployments.getMorphoMarketId(8453, "NVDAc")).toBe(
      "0xfef5641f70e19a87e369304daa9ba823754f3db1e6481d757fcae0442cffe479",
    );
  });

  it("getMorphoMarketId returns undefined when that market doesn't exist yet", () => {
    expect(deployments.getMorphoMarketId(8453, "AMZNc")).toBeUndefined();
  });

  it("getSupportedChainIds lists exactly the mocked chain", () => {
    expect(deployments.getSupportedChainIds()).toEqual([8453]);
  });

  it("DEPLOYMENTS exposes the mocked record directly", () => {
    expect(deployments.DEPLOYMENTS[8453]?.oracles.AMZNc).toBe("0xdDdDdDDddddDddddddDddddddddddDDddDDDDDd");
  });
});
