import { beforeEach, describe, expect, it, vi } from "vitest";

// Stands in for scripts/generate-deployments.mjs's output. Mocked at the module level (rather than
// by constructing a registry object and re-testing lookup logic by hand) so this exercises the real
// getDeployment / getDeploymentsForChain / getSupportedChainIds from src/deployments.ts against
// real generated-module data, not a re-implementation of them.
vi.mock("../src/deployments.generated.js", () => ({
  DEPLOYMENTS_BY_CHAIN: {
    8453: [
      {
        name: "AMZNc-USDC",
        oracle: "0x1111111111111111111111111111111111111111",
        collateralToken: "0x2222222222222222222222222222222222222222",
        loanToken: "0x3333333333333333333333333333333333333333",
        calendar: "0x4444444444444444444444444444444444444444",
        feed: "0x5555555555555555555555555555555555555555",
        pool: "0x6666666666666666666666666666666666666666",
      },
      {
        name: "NVDAc-USDC",
        oracle: "0x7777777777777777777777777777777777777777",
        collateralToken: "0x2222222222222222222222222222222222222222",
        loanToken: "0x3333333333333333333333333333333333333333",
        calendar: "0x4444444444444444444444444444444444444444",
        feed: "0x8888888888888888888888888888888888888888",
        pool: "0x9999999999999999999999999999999999999999",
      },
    ],
  },
}));

describe("deployment lookups against a populated registry", () => {
  let deployments: typeof import("../src/deployments.js");

  beforeEach(async () => {
    vi.resetModules();
    deployments = await import("../src/deployments.js");
  });

  it("getDeploymentsForChain returns every market for a known chain", () => {
    expect(deployments.getDeploymentsForChain(8453)).toHaveLength(2);
  });

  it("getDeploymentsForChain returns [] for an unknown chain", () => {
    expect(deployments.getDeploymentsForChain(1)).toEqual([]);
  });

  it("getDeployment finds a market by chain and name", () => {
    const market = deployments.getDeployment(8453, "NVDAc-USDC");
    expect(market?.oracle).toBe("0x7777777777777777777777777777777777777777");
  });

  it("getDeployment falls back to the first market when no name is given", () => {
    const market = deployments.getDeployment(8453);
    expect(market?.name).toBe("AMZNc-USDC");
  });

  it("getDeployment returns undefined for an unknown name", () => {
    expect(deployments.getDeployment(8453, "TSLAc-USDC")).toBeUndefined();
  });

  it("getDeployment returns undefined for an unknown chain", () => {
    expect(deployments.getDeployment(1)).toBeUndefined();
  });

  it("getSupportedChainIds lists exactly the mocked chain", () => {
    expect(deployments.getSupportedChainIds()).toEqual([8453]);
  });

  it("DEPLOYMENTS exposes the mocked data directly", () => {
    expect(deployments.DEPLOYMENTS[8453]).toHaveLength(2);
  });
});
