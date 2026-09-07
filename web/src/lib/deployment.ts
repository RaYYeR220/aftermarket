import type { Address, Hex } from "viem";

import type { ListedTicker } from "./site";

/**
 * The frozen Base mainnet deployment.
 *
 * Every address here is transcribed from `contracts/deployments/8453.json`, which the deploy
 * script writes and which carries the constructor arguments each address was built with. That file
 * is the record; this module is the app's typed view of it, and the two are checked against each
 * other by `scripts/verify-onchain.mjs`.
 *
 * Nothing in the application ever hardcodes an address anywhere else.
 */
export const DEPLOYMENT = {
  chainId: 8453,
  /** Block the deployment landed at. The activity feed never looks further back than this. */
  blockNumber: 51_009_740n,

  /** The read surface. Total by construction: it answers even with every oracle refusing. */
  lens: "0x27BFaddEc57fF76d498Ef1a7b09C5951DeA6735D",
  /** The credit engine. Collateral, draws, repayments, flags and cures. */
  credit: "0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93",
  /** The ERC-4626 lender vault that funds every draw. */
  vault: "0x00ee99240Ad9a4b25DD06eAcD1b852C83fbd2697",
  /** The autonomous repayment agent. Spends only under a Spend Permission the borrower signed. */
  autoRepayer: "0xBe1EA7CA0Fabc93F86C43fBcB25bbB3f2a0A2404",
  /** Reg-S eligibility. Reads Coinbase's onchain verification attestations. */
  regSGate: "0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C",
  /** The fallback attester set the gate consults when no Coinbase attestation exists. */
  attesterRegistry: "0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E",
  /** The onchain US equity calendar every session decision is derived from. */
  tradingCalendar: "0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9",
  /** Utilisation curve times the session multiplier. */
  sessionRateModel: "0x6d5152d81982DEb660736fC514761E18533a2343",
  /** Coinbase's SpendPermissionManager, identical on Base mainnet and Base Sepolia. */
  spendPermissionManager: "0xf85210B21cC50302F477BA56686d2019dC9b67Ad",
  /** The loan asset. Circle USDC on Base. */
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",

  /**
   * A second NVDAc oracle, deployed with one parameter changed: a 25 bps divergence band in place
   * of the production band. Same asset, same feed, same pool, same block. It exists so that the
   * refusal can be demonstrated rather than described.
   */
  negativeControl: "0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58",

  /** The Morpho Blue market this deployment's NVDAc oracle prices. */
  morphoMarketId: "0xfef5641f70e19a87e369304daa9ba823754f3db1e6481d757fcae0442cffe479",

  /**
   * The line the deploying account opened on mainnet. Read-only visitors are shown this line,
   * clearly named, so that every screen has real onchain state behind it without a wallet.
   */
  referenceLine: "0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f",
} as const satisfies {
  chainId: number;
  blockNumber: bigint;
  morphoMarketId: Hex;
  [key: string]: Address | number | bigint | Hex;
};

/** One deployed `AftermarketOracle` per listed asset. */
export const ORACLES: Readonly<Record<ListedTicker, Address>> = {
  NVDAc: "0x1E2b20B4703F97710c2600eA73179c6CD1E00b02",
  AAPLc: "0x6cE58FE71eD10b82c2C0A9a348E82D1ee6D9a8dc",
  METAc: "0xf5Cc0cc94ecF4866661373f2aa066af76e08dEf2",
  GOOGLc: "0x203cDf7e33eA0d652cA54f4807c9d2d1d081C9aA",
  TSLAc: "0x74058d51B3b04Ba09be2aa51ab1CE930Dd3c2C99",
  AMZNc: "0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C",
};

/** The B20 collateral tokens, in the order the lens was deployed to cover them. */
export const COLLATERAL_TOKENS: Readonly<Record<ListedTicker, Address>> = {
  NVDAc: "0xb20000000000000000000078ee7ce2fE4908108C",
  AAPLc: "0xb200000000000000000000C2e324d24d7eEcd1fb",
  METAc: "0xb2000000000000000000008bC8786B856E61707C",
  GOOGLc: "0xb2000000000000000000002D0BA3164cc74f58B7",
  TSLAc: "0xb2000000000000000000001e800a7f5189430cD0",
  AMZNc: "0xb200000000000000000000d9192b6B456483C2E8",
};

/** `https://basescan.org/address/0x…`. Every address the app prints is a link to this. */
export function explorerAddress(address: string): string {
  return `https://basescan.org/address/${address}`;
}

/** `https://basescan.org/tx/0x…`. */
export function explorerTx(hash: string): string {
  return `https://basescan.org/tx/${hash}`;
}

/** `https://basescan.org/block/12345`. */
export function explorerBlock(blockNumber: bigint | string): string {
  return `https://basescan.org/block/${blockNumber.toString()}`;
}
