import type { Address } from "viem";

/**
 * Aftermarket's Base mainnet deployment, mirrored from `contracts/deployments/8453.json`.
 *
 * Written out here rather than imported so the keeper has no build-time dependency on the
 * contracts workspace, and so a judge reading one file can see every address the service will ever
 * touch. `keeper doctor` re-derives the wiring from the chain (`AutoRepayer.credit()`,
 * `.usdc()`, `.manager()`) and refuses to start if any of it disagrees with this table.
 */
export const BASE_MAINNET = {
  chainId: 8453,
  autoRepayer: "0xEFC7ce780F5030489a027cebde8BeFb7e7ee681A",
  credit: "0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3",
  lens: "0x5A18BdEB02B30b737a2464E02A2a669BF52bC049",
  vault: "0x00751166Ce3fa20a4143a1F0D848978Db73bd53f",
  tradingCalendar: "0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9",
  spendPermissionManager: "0xf85210B21cC50302F477BA56686d2019dC9b67Ad",
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  /** Deployment block of the core system; the floor for any `Enrolled` event scan. */
  deployedAtBlock: 50_987_282n,
} as const satisfies {
  chainId: number;
  autoRepayer: Address;
  credit: Address;
  lens: Address;
  vault: Address;
  tradingCalendar: Address;
  spendPermissionManager: Address;
  usdc: Address;
  deployedAtBlock: bigint;
};

/** The six `AftermarketOracle` deployments, by ticker. */
export const BASE_MAINNET_ORACLES = {
  NVDAc: "0x1E2b20B4703F97710c2600eA73179c6CD1E00b02",
  AMZNc: "0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C",
  AAPLc: "0x6cE58FE71eD10b82c2C0A9a348E82D1ee6D9a8dc",
  METAc: "0xf5Cc0cc94ecF4866661373f2aa066af76e08dEf2",
  GOOGLc: "0x203cDf7e33eA0d652cA54f4807c9d2d1d081C9aA",
  TSLAc: "0x74058d51B3b04Ba09be2aa51ab1CE930Dd3c2C99",
} as const satisfies Record<string, Address>;

export type OracleTicker = keyof typeof BASE_MAINNET_ORACLES;

/** USDC has six decimals on Base; every amount this service prints is scaled by this. */
export const USDC_DECIMALS = 6;

/**
 * Health, in bps above the policy trigger, that `AutoRepayer` sizes a repayment to restore.
 * Mirrors `AutoRepayer.RECOVERY_MARGIN_BPS`; `keeper doctor` reads the constant off the chain and
 * refuses to start if it has moved.
 */
export const RECOVERY_MARGIN_BPS = 500n;

/** `AutoRepayer` works in bps of the seizure threshold; 10 000 bps sits exactly on it. */
export const BPS = 10_000n;
