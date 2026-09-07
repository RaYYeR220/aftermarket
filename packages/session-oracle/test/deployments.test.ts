import { describe, expect, it } from "vitest";
import { DEPLOYMENTS, getDeployment, getDeploymentsForChain, getSupportedChainIds, type DeploymentRegistry } from "../src/deployments.js";

// This checkout has no contracts/deployments/ directory (see scripts/generate-deployments.mjs),
// so the generated registry is expected to be empty. These tests lock in that fallback behavior:
// every accessor must degrade gracefully rather than throw when nothing has been deployed yet.
describe("deployments registry fallback", () => {
  it("DEPLOYMENTS is an empty, well-typed map", () => {
    expect(DEPLOYMENTS).toEqual({});
    // Type-level check: DEPLOYMENTS must be assignable to DeploymentRegistry even when empty.
    const registry: DeploymentRegistry = DEPLOYMENTS;
    expect(registry).toBeDefined();
  });

  it("getDeploymentsForChain returns an empty array for any chain id", () => {
    expect(getDeploymentsForChain(8453)).toEqual([]);
    expect(getDeploymentsForChain(1)).toEqual([]);
    expect(getDeploymentsForChain(0)).toEqual([]);
  });

  it("getDeployment returns undefined rather than throwing", () => {
    expect(getDeployment(8453)).toBeUndefined();
    expect(getDeployment(8453, "AMZNc-USDC")).toBeUndefined();
  });

  it("getSupportedChainIds returns an empty array", () => {
    expect(getSupportedChainIds()).toEqual([]);
  });
});
