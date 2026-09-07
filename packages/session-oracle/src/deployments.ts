import type { Address } from "viem";
import { DEPLOYMENTS_BY_CHAIN } from "./deployments.generated.js";

/** One deployed `AftermarketOracle` and the Morpho market it prices. */
export interface DeployedMarket {
  /** Human label, e.g. `"AMZNc-USDC"`. Not used onchain; for display and lookup only. */
  name: string;
  oracle: Address;
  collateralToken: Address;
  loanToken: Address;
  calendar: Address;
  feed: Address;
  pool: Address;
}

/** Deployed markets, keyed by chain id. Empty for any chain with no known deployments. */
export type DeploymentRegistry = Readonly<Record<number, readonly DeployedMarket[]>>;

/**
 * Deployed `AftermarketOracle` markets, generated at build time from
 * `contracts/deployments/<chainId>.json` — one file per chain, each shaped like:
 *
 * ```json
 * {
 *   "chainId": 8453,
 *   "markets": [
 *     {
 *       "name": "AMZNc-USDC",
 *       "oracle": "0x...",
 *       "collateralToken": "0x...",
 *       "loanToken": "0x...",
 *       "calendar": "0x...",
 *       "feed": "0x...",
 *       "pool": "0x..."
 *     }
 *   ]
 * }
 * ```
 *
 * `scripts/generate-deployments.mjs` reads that directory before every `build`, `typecheck` and
 * `test`. When the directory (or a given chain's file) doesn't exist yet — true for this checkout —
 * this is simply an empty map for that chain: `getDeploymentsForChain` returns `[]` and
 * `getDeployment` returns `undefined`, never a thrown error. Nothing here reads the filesystem at
 * runtime, so this is safe to import in a browser bundle.
 */
export const DEPLOYMENTS: DeploymentRegistry = DEPLOYMENTS_BY_CHAIN;

/** All markets deployed on `chainId`, or `[]` if none are known. */
export function getDeploymentsForChain(chainId: number): readonly DeployedMarket[] {
  return DEPLOYMENTS[chainId] ?? [];
}

/**
 * A single deployed market on `chainId`. With no `name`, returns the first known market for that
 * chain (convenient when there's exactly one). Returns `undefined` when no market matches, rather
 * than throwing — check the result before using it.
 */
export function getDeployment(chainId: number, name?: string): DeployedMarket | undefined {
  const markets = getDeploymentsForChain(chainId);
  if (name === undefined) return markets[0];
  return markets.find((market) => market.name === name);
}

/** Chain ids with at least one known deployment. */
export function getSupportedChainIds(): number[] {
  return Object.keys(DEPLOYMENTS).map(Number);
}
