/**
 * ABI fragments the eval harness needs on top of the keeper's own.
 *
 * Everything here belongs to the fixture rather than to the service: Coinbase's smart-wallet
 * factory, the test doubles the eval drives (a Chainlink aggregator, a Slipstream pool, a trading
 * calendar), and the vault. The keeper itself never sees any of them.
 */

export const smartWalletFactoryAbi = [
  {
    type: "function",
    name: "createAccount",
    stateMutability: "payable",
    inputs: [
      { name: "owners", type: "bytes[]" },
      { name: "nonce", type: "uint256" },
    ],
    outputs: [{ name: "account", type: "address" }],
  },
  {
    type: "function",
    name: "getAddress",
    stateMutability: "view",
    inputs: [
      { name: "owners", type: "bytes[]" },
      { name: "nonce", type: "uint256" },
    ],
    outputs: [{ type: "address" }],
  },
] as const;

export const smartWalletAbi = [
  {
    type: "function",
    name: "execute",
    stateMutability: "payable",
    inputs: [
      { name: "target", type: "address" },
      { name: "value", type: "uint256" },
      { name: "data", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "executeBatch",
    stateMutability: "payable",
    inputs: [
      {
        name: "calls",
        type: "tuple[]",
        components: [
          { name: "target", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "addOwnerAddress",
    stateMutability: "nonpayable",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [],
  },
  {
    type: "function",
    name: "isOwnerAddress",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "bool" }],
  },
] as const;

/** `MockERC20`: an ERC-20 with settable decimals and a B20-style corporate-action multiplier. */
export const mockErc20Abi = [
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "setMultiplier",
    stateMutability: "nonpayable",
    inputs: [{ name: "newMultiplier", type: "uint256" }],
    outputs: [],
  },
  { type: "function", name: "multiplier", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
] as const;

export const mockAggregatorAbi = [
  {
    type: "function",
    name: "set",
    stateMutability: "nonpayable",
    inputs: [
      { name: "answer", type: "int256" },
      { name: "updatedAt", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setReverting",
    stateMutability: "nonpayable",
    inputs: [{ name: "reverting", type: "bool" }],
    outputs: [],
  },
  { type: "function", name: "answer", stateMutability: "view", inputs: [], outputs: [{ type: "int256" }] },
] as const;

export const mockPoolAbi = [
  {
    type: "function",
    name: "setMeanTick",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tick", type: "int24" },
      { name: "window", type: "uint32" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setLiquidity",
    stateMutability: "nonpayable",
    inputs: [{ name: "liquidity", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "setObserveReverting",
    stateMutability: "nonpayable",
    inputs: [{ name: "reverting", type: "bool" }],
    outputs: [],
  },
] as const;

export const mockCalendarAbi = [
  {
    type: "function",
    name: "set",
    stateMutability: "nonpayable",
    inputs: [
      { name: "session", type: "uint8" },
      { name: "closedFor", type: "uint256" },
      { name: "nextOpen", type: "uint64" },
      { name: "lastClose", type: "uint64" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setReverting",
    stateMutability: "nonpayable",
    inputs: [{ name: "reverting", type: "bool" }],
    outputs: [],
  },
] as const;

/** The `Quote` half of `AftermarketOracle` the harness reads to steer a verdict. */
export const aftermarketOracleAbi = [
  {
    type: "function",
    name: "peek",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {
        name: "q",
        type: "tuple",
        components: [
          { name: "verdict", type: "uint8" },
          { name: "session", type: "uint8" },
          { name: "anchorPrice", type: "uint256" },
          { name: "poolPrice", type: "uint256" },
          { name: "markBorrow", type: "uint256" },
          { name: "markLiquidate", type: "uint256" },
          { name: "feedAge", type: "uint256" },
          { name: "stalenessBudget", type: "uint256" },
          { name: "divergenceBps", type: "uint256" },
          { name: "divergenceBand", type: "uint256" },
          { name: "haircutBps", type: "uint256" },
          { name: "multiplier", type: "uint256" },
          { name: "poolLiquidityUsd", type: "uint256" },
          { name: "nextOpen", type: "uint64" },
          { name: "lastClose", type: "uint64" },
        ],
      },
    ],
  },
  { type: "function", name: "price", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "markLiquidate", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "collateralToken", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
] as const;

export const vaultAbi = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
] as const;

/** `SpendPermissionManager.approve` returns a bool the harness ignores; the shape still has to match. */
export const spendPermissionApproveAbi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "spendPermission",
        type: "tuple",
        components: [
          { name: "account", type: "address" },
          { name: "spender", type: "address" },
          { name: "token", type: "address" },
          { name: "allowance", type: "uint160" },
          { name: "period", type: "uint48" },
          { name: "start", type: "uint48" },
          { name: "end", type: "uint48" },
          { name: "salt", type: "uint256" },
          { name: "extraData", type: "bytes" },
        ],
      },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;
