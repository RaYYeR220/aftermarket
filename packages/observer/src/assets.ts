import type { Address } from "viem";

export interface AssetPool {
  /** Slipstream CL pool address. Every pool below pairs the asset with USDC. */
  address: Address;
  /** Tick spacing the pool was created with; Slipstream keys pools by spacing rather than a fee tier. */
  tickSpacing: number;
}

export interface AssetDefinition {
  ticker: string;
  b20Address: Address;
  chainlinkFeedAddress: Address;
  /** `null` when no Slipstream pool could be found for this asset against USDC. */
  pool: AssetPool | null;
}

export const USDC_ADDRESS: Address = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
/** USDC uses 6 decimals; every B20 token here uses 8 — the report math accounts for that gap explicitly. */
export const USDC_DECIMALS = 6;

/**
 * Aerodrome Slipstream CL factory on Base. Not read at runtime — the pool
 * addresses below were found by calling this factory's `getPool(tokenA,
 * tokenB, tickSpacing)` for USDC against each B20 token across every tick
 * spacing the factory has enabled (1, 10, 50, 100, 200, 500, 2000 as of this
 * writing), then keeping whichever non-zero result held the deeper USDC
 * balance. It is surfaced in report output so the discovery can be repeated.
 */
export const SLIPSTREAM_FACTORY_ADDRESS: Address = "0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef";

/**
 * Coinbase tokenized stocks (B20) live on Base, paired with their Chainlink
 * total-return feed and, where one exists, an Aerodrome Slipstream/USDC pool.
 *
 * The four original listings (NVDAc, AAPLc, METAc, GOOGLc) and their feed
 * addresses were given directly. The remaining nine — and every Slipstream
 * pool below — were found from Base's own tokenized-stocks-on-base
 * documentation table and then confirmed live by calling `symbol()` and, for
 * pools, `getPool()` on the Slipstream factory above.
 */
export const ASSETS: readonly AssetDefinition[] = [
  {
    ticker: "NVDAc",
    b20Address: "0xb20000000000000000000078ee7ce2fE4908108C",
    chainlinkFeedAddress: "0x04689a41629776563E6822F76f2e57D148d28513",
    pool: { address: "0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9", tickSpacing: 10 },
  },
  {
    ticker: "AAPLc",
    b20Address: "0xb200000000000000000000C2e324d24d7eEcd1fb",
    chainlinkFeedAddress: "0x787f13dEa48Db0897CbCDD985de77809D837F988",
    pool: { address: "0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0", tickSpacing: 10 },
  },
  {
    ticker: "METAc",
    b20Address: "0xb2000000000000000000008bC8786B856E61707C",
    chainlinkFeedAddress: "0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D",
    pool: { address: "0xEAF57753BC382E0324a1D43F72E7027705a2273E", tickSpacing: 10 },
  },
  {
    ticker: "GOOGLc",
    b20Address: "0xb2000000000000000000002D0BA3164cc74f58B7",
    chainlinkFeedAddress: "0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2",
    pool: { address: "0xB1987CAD1682841b4b641d50E520777eC5Ab5542", tickSpacing: 10 },
  },
  // Went live on Base 2026-09-04. Addresses confirmed via docs.base.org and symbol().
  {
    ticker: "TSLAc",
    b20Address: "0xb2000000000000000000001e800a7f5189430cD0",
    chainlinkFeedAddress: "0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4",
    pool: { address: "0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB", tickSpacing: 10 },
  },
  {
    ticker: "AMZNc",
    b20Address: "0xb200000000000000000000d9192b6B456483C2E8",
    chainlinkFeedAddress: "0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295",
    pool: { address: "0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b", tickSpacing: 10 },
  },
  {
    ticker: "MSFTc",
    b20Address: "0xB200000000000000000000Ab99cFa739E253872B",
    chainlinkFeedAddress: "0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c",
    pool: { address: "0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54", tickSpacing: 10 },
  },
  {
    ticker: "MSTRc",
    b20Address: "0xb2000000000000000000004884b426556b92883d",
    chainlinkFeedAddress: "0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a",
    pool: { address: "0x8b27f626ab668197000BC722A1012022CAeD10E2", tickSpacing: 10 },
  },
  {
    ticker: "SNDKc",
    b20Address: "0xb200000000000000000000397293Cb8cda9a10c5",
    chainlinkFeedAddress: "0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA",
    pool: { address: "0x5A8236f575471e7BfCA2C8462a200c28f737246E", tickSpacing: 10 },
  },
  {
    ticker: "SPCXc",
    b20Address: "0xb2000000000000000000007b9fcbd005511aCBd5",
    chainlinkFeedAddress: "0x6A634B235903C4ad6376892180d6fF8612e3Fa68",
    pool: { address: "0x0bf58fe0FAc935Ac69595c19B12Ba0d75E3F8c0E", tickSpacing: 10 },
  },
  // Live and readable (symbol/decimals/multiplier all respond), but each has
  // zero totalSupply on-chain and no Slipstream pool exists at any tick
  // spacing the factory has enabled. Reported as unavailable rather than
  // guessed at a pool address.
  {
    ticker: "COINc",
    b20Address: "0xb200000000000000000000c85a31389D71F3ecfb",
    chainlinkFeedAddress: "0x408e44f504A7371a345F03a73dDC96A4b48e8aa7",
    pool: null,
  },
  {
    ticker: "CRCLc",
    b20Address: "0xB20000000000000000000019f6E7C675b73C2e4D",
    chainlinkFeedAddress: "0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33",
    pool: null,
  },
  {
    ticker: "INTCc",
    b20Address: "0xB2000000000000000000004AFF16039bA04bdFBc",
    chainlinkFeedAddress: "0xAB657C39bac0D5886250D70849e2E3E008F2EECB",
    pool: null,
  },
] as const;
