import { isAddress } from "viem";
import { describe, expect, it } from "vitest";
import {
  DEPLOYMENTS,
  getDeployment,
  getMorphoMarketId,
  getOracleAddress,
  getSupportedChainIds,
  type DeploymentRegistry,
} from "../src/deployments.js";

// This checkout's contracts/deployments/8453.json is real — a live deployment on Base mainnet — so
// the generated registry for chain 8453 is expected to be populated. These tests lock that in.
describe("deployments registry, chain 8453 (live)", () => {
  it("is non-empty for 8453", () => {
    const record = getDeployment(8453);
    expect(record).toBeDefined();
    expect(getSupportedChainIds()).toContain(8453);
  });

  it("carries all ten core contract addresses", () => {
    const record = getDeployment(8453);
    const coreFields = [
      "tradingCalendar",
      "attesterRegistry",
      "regSGate",
      "sessionRateModel",
      "oracleFactory",
      "swapAdapter",
      "credit",
      "vault",
      "autoRepayer",
      "lens",
    ] as const;
    for (const field of coreFields) {
      expect(record?.[field], `missing ${field}`).toBeDefined();
    }
    expect(coreFields).toHaveLength(10);
  });

  it("carries all six production oracles keyed by symbol", () => {
    const record = getDeployment(8453);
    expect(Object.keys(record?.oracles ?? {}).sort()).toEqual(["AAPLc", "AMZNc", "GOOGLc", "METAc", "NVDAc", "TSLAc"]);
  });

  it("carries the negative control", () => {
    expect(getDeployment(8453)?.negativeControl).toBeDefined();
  });

  it("carries the NVDAc Morpho Blue market id", () => {
    expect(getMorphoMarketId(8453, "NVDAc")).toMatch(/^0x[0-9a-fA-F]{64}$/);
  });

  it("every address the registry exposes is a valid checksummed address", () => {
    const record = getDeployment(8453);
    expect(record).toBeDefined();
    if (!record) return;

    const { oracles, morphoMarkets, chainId, network, ...addressFields } = record;
    const addresses = [...Object.values(addressFields), ...Object.values(oracles)];
    expect(addresses.length).toBeGreaterThan(0);
    for (const address of addresses) {
      expect(isAddress(address, { strict: true }), `${address} is not a valid checksummed address`).toBe(true);
    }

    // Morpho market ids are bytes32, not addresses — checked separately by shape above.
    expect(Object.keys(morphoMarkets).length).toBeGreaterThan(0);
  });

  it("getOracleAddress resolves a known symbol", () => {
    expect(getOracleAddress(8453, "AMZNc")).toBeDefined();
    expect(isAddress(getOracleAddress(8453, "AMZNc")!, { strict: true })).toBe(true);
  });

  it("getOracleAddress returns undefined for an unknown symbol", () => {
    expect(getOracleAddress(8453, "DOESNOTEXIST")).toBeUndefined();
  });
});

describe("deployments registry fallback for unknown chains", () => {
  it("getDeployment returns undefined for an unknown chain", () => {
    expect(getDeployment(1)).toBeUndefined();
    expect(getDeployment(0)).toBeUndefined();
  });

  it("getOracleAddress and getMorphoMarketId return undefined rather than throwing", () => {
    expect(getOracleAddress(1, "AMZNc")).toBeUndefined();
    expect(getMorphoMarketId(1, "NVDAc")).toBeUndefined();
  });

  it("DEPLOYMENTS is a well-typed map with no entry for an unknown chain", () => {
    const registry: DeploymentRegistry = DEPLOYMENTS;
    expect(registry[1]).toBeUndefined();
  });
});
