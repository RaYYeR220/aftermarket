import { beforeEach, describe, expect, it, vi } from "vitest";

// Stands in for scripts/generate-deployments.mjs's fallback output: no deployments directory, no
// <chainId>.json files, or every record malformed all collapse to this — an empty, well-typed map.
// Mocked at the module level so this exercises the real accessors in src/deployments.ts against
// that exact shape, independent of whether this checkout happens to have a real deployment.
vi.mock("../src/deployments.generated.js", () => ({
  DEPLOYMENTS_BY_CHAIN: {},
}));

describe("deployments registry fallback (no known deployments)", () => {
  let deployments: typeof import("../src/deployments.js");

  beforeEach(async () => {
    vi.resetModules();
    deployments = await import("../src/deployments.js");
  });

  it("DEPLOYMENTS is an empty, well-typed map", () => {
    expect(deployments.DEPLOYMENTS).toEqual({});
  });

  it("getDeployment returns undefined rather than throwing", () => {
    expect(deployments.getDeployment(8453)).toBeUndefined();
  });

  it("getOracleAddress and getMorphoMarketId return undefined rather than throwing", () => {
    expect(deployments.getOracleAddress(8453, "AMZNc")).toBeUndefined();
    expect(deployments.getMorphoMarketId(8453, "NVDAc")).toBeUndefined();
  });

  it("getSupportedChainIds returns an empty array", () => {
    expect(deployments.getSupportedChainIds()).toEqual([]);
  });
});
