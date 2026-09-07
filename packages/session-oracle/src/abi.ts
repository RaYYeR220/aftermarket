/**
 * ABI constants for `AftermarketOracle` and `TradingCalendar`.
 *
 * These are transcribed from the compiled Foundry artifacts at
 * `contracts/out/IAftermarketOracle.sol/IAftermarketOracle.json` and
 * `contracts/out/ITradingCalendar.sol/ITradingCalendar.json` (build them with
 * `cd contracts && forge build` if they are missing), not hand-written and not
 * imported as JSON — they are checked in as `as const` arrays so viem can infer
 * exact argument and return types from them.
 *
 * `contracts/out/` is a build artifact of a sibling package under active
 * development; this file is a point-in-time snapshot of the frozen interface,
 * not a live read of that directory. If `IAftermarketOracle.sol` or
 * `ITradingCalendar.sol` change their public surface, regenerate this file by
 * hand from the new artifacts.
 */

/** `IAftermarketOracle` — the full interface `AftermarketOracle` implements. */
export const aftermarketOracleAbi = [
  {
    type: "function",
    name: "calendar",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "collateralToken",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "feed",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "loanToken",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "markBorrow",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "markLiquidate",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "peek",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {
        name: "",
        type: "tuple",
        internalType: "struct Quote",
        components: [
          { name: "verdict", type: "uint8", internalType: "enum Verdict" },
          { name: "session", type: "uint8", internalType: "enum Session" },
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
  {
    type: "function",
    name: "pool",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "price",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "error",
    name: "InvalidFeedAnswer",
    inputs: [{ name: "answer", type: "int256" }],
  },
  {
    type: "error",
    name: "MarketHalted",
    inputs: [{ name: "multiplier", type: "uint256" }],
  },
  {
    type: "error",
    name: "PoolTooThin",
    inputs: [
      { name: "liquidityUsd", type: "uint256" },
      { name: "minLiquidityUsd", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "SourcesDiverged",
    inputs: [
      { name: "session", type: "uint8", internalType: "enum Session" },
      { name: "divergenceBps", type: "uint256" },
      { name: "band", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "StaleFeed",
    inputs: [
      { name: "session", type: "uint8", internalType: "enum Session" },
      { name: "age", type: "uint256" },
      { name: "budget", type: "uint256" },
    ],
  },
] as const;

/**
 * `ITradingCalendar` — the onchain NYSE/Nasdaq session calendar `AftermarketOracle.calendar()`
 * points at. Not called by `createOracleClient` (the oracle already folds the calendar's verdict
 * into `Quote.session` / `Quote.nextOpen` / `Quote.lastClose`), but exported for integrators who
 * want to query the calendar directly — e.g. to schedule a keeper around the next open.
 */
export const tradingCalendarAbi = [
  {
    type: "function",
    name: "closedFor",
    stateMutability: "view",
    inputs: [{ name: "timestamp", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "isOpen",
    stateMutability: "view",
    inputs: [{ name: "timestamp", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "nextOpen",
    stateMutability: "view",
    inputs: [{ name: "timestamp", type: "uint256" }],
    outputs: [{ name: "", type: "uint64" }],
  },
  {
    type: "function",
    name: "session",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8", internalType: "enum Session" }],
  },
  {
    type: "function",
    name: "sessionAt",
    stateMutability: "view",
    inputs: [{ name: "timestamp", type: "uint256" }],
    outputs: [
      { name: "session", type: "uint8", internalType: "enum Session" },
      { name: "nextOpen", type: "uint64" },
      { name: "lastClose", type: "uint64" },
    ],
  },
] as const;
