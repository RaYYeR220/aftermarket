import type { Address, Hex } from "viem";
import { DEPLOYMENTS_BY_CHAIN } from "./deployments.generated.js";

/**
 * The full Aftermarket protocol deployment on one chain: the ten core contracts, every production
 * `AftermarketOracle` keyed by its B20 asset symbol, every Morpho Blue market id keyed by the
 * collateral symbol it was created for, and the negative-control oracle used to prove the honest
 * revert path onchain.
 */
export interface ChainDeployment {
  chainId: number;
  network: string;
  usdc: Address;
  tradingCalendar: Address;
  attesterRegistry: Address;
  regSGate: Address;
  sessionRateModel: Address;
  oracleFactory: Address;
  swapAdapter: Address;
  credit: Address;
  vault: Address;
  autoRepayer: Address;
  lens: Address;
  /** Deliberately misconfigured `AftermarketOracle` kept live to prove the revert path onchain. */
  negativeControl: Address;
  /** `AftermarketOracle` addresses keyed by B20 asset symbol, e.g. `"AMZNc"`. */
  oracles: Readonly<Record<string, Address>>;
  /** Morpho Blue market ids (bytes32), keyed by the collateral symbol the market was created for. */
  morphoMarkets: Readonly<Record<string, Hex>>;
}

/** Known deployments, keyed by chain id. No entry for a chain means no known deployment there. */
export type DeploymentRegistry = Readonly<Record<number, ChainDeployment>>;

/**
 * Aftermarket protocol deployments, generated at build time from
 * `contracts/deployments/<chainId>.json` — one file per chain, shaped like:
 *
 * ```json
 * {
 *   "chainId": 8453,
 *   "network": "base",
 *   "usdc": "0x...",
 *   "tradingCalendar": "0x...",
 *   "attesterRegistry": "0x...",
 *   "regSGate": "0x...",
 *   "sessionRateModel": "0x...",
 *   "oracleFactory": "0x...",
 *   "swapAdapter": "0x...",
 *   "credit": "0x...",
 *   "vault": "0x...",
 *   "autoRepayer": "0x...",
 *   "lens": "0x...",
 *   "negativeControl": "0x...",
 *   "oracles": { "AMZNc": "0x...", "NVDAc": "0x...", ... },
 *   "morphoMarkets": { "NVDAc": "0x<market id>" }
 * }
 * ```
 *
 * `scripts/generate-deployments.mjs` reads that directory before every `build`, `typecheck` and
 * `test`. When the directory (or a given chain's file) doesn't exist yet, or a record is missing a
 * required field, that chain is simply absent from this map: `getDeployment` returns `undefined`
 * and `getSupportedChainIds` omits it — never a thrown error. Nothing here reads the filesystem at
 * runtime, so this is safe to import in a browser bundle.
 */
export const DEPLOYMENTS: DeploymentRegistry = DEPLOYMENTS_BY_CHAIN;

/** The full deployment record for `chainId`, or `undefined` if nothing is known there yet. */
export function getDeployment(chainId: number): ChainDeployment | undefined {
  return DEPLOYMENTS[chainId];
}

/** The `AftermarketOracle` address for `symbol` on `chainId`, or `undefined` if unknown. */
export function getOracleAddress(chainId: number, symbol: string): Address | undefined {
  return DEPLOYMENTS[chainId]?.oracles[symbol];
}

/** The Morpho Blue market id for `symbol` on `chainId`, or `undefined` if that market doesn't exist yet. */
export function getMorphoMarketId(chainId: number, symbol: string): Hex | undefined {
  return DEPLOYMENTS[chainId]?.morphoMarkets[symbol];
}

/** Chain ids with a known deployment. */
export function getSupportedChainIds(): number[] {
  return Object.keys(DEPLOYMENTS).map(Number);
}
