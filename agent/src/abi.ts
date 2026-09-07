/**
 * The slices of Aftermarket's deployed ABIs this keeper reads and writes.
 *
 * Hand-written rather than imported from `contracts/out`, for the same reason
 * `@aftermarket/observer` hand-writes its fragments: the keeper is a standalone service that must
 * compile and run from a clean checkout with no Solidity toolchain present, and a fragment that is
 * typed here as a `const` gives viem full end-to-end inference for every read and write.
 *
 * Every custom error the contracts can raise is included alongside the functions, because a revert
 * this keeper cannot decode is a refusal it cannot explain, and an unexplained refusal is exactly
 * the failure mode this whole service exists to avoid.
 */

/** `SpendPermission` from Coinbase's `SpendPermissionManager`, field-for-field. */
const SPEND_PERMISSION_COMPONENTS = [
  { name: "account", type: "address" },
  { name: "spender", type: "address" },
  { name: "token", type: "address" },
  { name: "allowance", type: "uint160" },
  { name: "period", type: "uint48" },
  { name: "start", type: "uint48" },
  { name: "end", type: "uint48" },
  { name: "salt", type: "uint256" },
  { name: "extraData", type: "bytes" },
] as const;

/** `IAutoRepayer.Policy`: the four fields that bound everything done on a borrower's behalf. */
const POLICY_COMPONENTS = [
  { name: "maxPerExecution", type: "uint128" },
  { name: "minInterval", type: "uint32" },
  { name: "triggerHealthBps", type: "uint16" },
  { name: "enabled", type: "bool" },
] as const;

/** `IAftermarketCredit.Position`: one line, in a single non-reverting read. */
const POSITION_COMPONENTS = [
  { name: "debtAssets", type: "uint256" },
  { name: "debtShares", type: "uint256" },
  { name: "borrowPower", type: "uint256" },
  { name: "seizureThreshold", type: "uint256" },
  { name: "healthFactor", type: "uint256" },
  { name: "priced", type: "bool" },
  { name: "flagged", type: "bool" },
  { name: "openedAt", type: "uint64" },
  { name: "flaggedAt", type: "uint64" },
  { name: "graceUntil", type: "uint64" },
  { name: "autoRepayEnabled", type: "bool" },
  { name: "session", type: "uint8" },
] as const;

export const autoRepayerAbi = [
  {
    type: "function",
    name: "simulate",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [
      { name: "willAct", type: "bool" },
      { name: "reason", type: "uint8" },
      { name: "amount", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "execute",
    stateMutability: "nonpayable",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "amount", type: "uint256" }],
  },
  {
    type: "function",
    name: "poke",
    stateMutability: "nonpayable",
    inputs: [{ name: "user", type: "address" }],
    outputs: [
      { name: "acted", type: "bool" },
      { name: "reason", type: "uint8" },
    ],
  },
  {
    type: "function",
    name: "enroll",
    stateMutability: "nonpayable",
    inputs: [
      { name: "permission", type: "tuple", components: SPEND_PERMISSION_COMPONENTS },
      { name: "policy", type: "tuple", components: POLICY_COMPONENTS },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setPolicy",
    stateMutability: "nonpayable",
    inputs: [{ name: "policy", type: "tuple", components: POLICY_COMPONENTS }],
    outputs: [],
  },
  { type: "function", name: "withdraw", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { type: "function", name: "cancel", stateMutability: "nonpayable", inputs: [], outputs: [] },
  {
    type: "function",
    name: "enrollmentOf",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "permissionHash", type: "bytes32" },
          { name: "lastExecutedAt", type: "uint64" },
          { name: "policy", type: "tuple", components: POLICY_COMPONENTS },
          { name: "permission", type: "tuple", components: SPEND_PERMISSION_COMPONENTS },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "isEnrolled",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "spendableFor",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "healthBpsOf",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "credit", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "usdc", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "manager", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "function",
    name: "RECOVERY_MARGIN_BPS",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "SPEND_PERMISSION_MANAGER",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "event",
    name: "Enrolled",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "permissionHash", type: "bytes32", indexed: true },
      { name: "policy", type: "tuple", components: POLICY_COMPONENTS, indexed: false },
    ],
  },
  {
    type: "event",
    name: "PolicyUpdated",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "policy", type: "tuple", components: POLICY_COMPONENTS, indexed: false },
    ],
  },
  {
    type: "event",
    name: "Withdrawn",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "permissionHash", type: "bytes32", indexed: true },
    ],
  },
  {
    type: "event",
    name: "Cancelled",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "permissionHash", type: "bytes32", indexed: true },
      { name: "revoked", type: "bool", indexed: false },
    ],
  },
  {
    type: "event",
    name: "AutoRepaid",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "healthBefore", type: "uint256", indexed: false },
      { name: "healthAfter", type: "uint256", indexed: false },
      { name: "session", type: "uint8", indexed: false },
    ],
  },
  {
    type: "event",
    name: "AutoRepayRefused",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "reason", type: "uint8", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Refunded",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  { type: "error", name: "ZeroAddress", inputs: [] },
  { type: "error", name: "NotEnrolled", inputs: [{ name: "user", type: "address" }] },
  { type: "error", name: "PolicyDisabled", inputs: [{ name: "user", type: "address" }] },
  {
    type: "error",
    name: "IntervalNotElapsed",
    inputs: [
      { name: "user", type: "address" },
      { name: "lastExecutedAt", type: "uint64" },
      { name: "minInterval", type: "uint32" },
    ],
  },
  { type: "error", name: "OracleUntrusted", inputs: [{ name: "user", type: "address" }] },
  {
    type: "error",
    name: "LineHealthy",
    inputs: [
      { name: "user", type: "address" },
      { name: "healthBps", type: "uint256" },
      { name: "triggerHealthBps", type: "uint16" },
    ],
  },
  { type: "error", name: "NothingToRepay", inputs: [{ name: "user", type: "address" }] },
  {
    type: "error",
    name: "AboveMaxPerExecution",
    inputs: [
      { name: "user", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "maxPerExecution", type: "uint128" },
    ],
  },
  {
    type: "error",
    name: "PermissionUnavailable",
    inputs: [
      { name: "user", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "available", type: "uint256" },
    ],
  },
  {
    type: "error",
    name: "PermissionAccountMismatch",
    inputs: [
      { name: "account", type: "address" },
      { name: "caller", type: "address" },
    ],
  },
  {
    type: "error",
    name: "PermissionSpenderMismatch",
    inputs: [
      { name: "spender", type: "address" },
      { name: "expected", type: "address" },
    ],
  },
  {
    type: "error",
    name: "PermissionTokenMismatch",
    inputs: [
      { name: "token", type: "address" },
      { name: "expected", type: "address" },
    ],
  },
  { type: "error", name: "PermissionAllowanceZero", inputs: [] },
  { type: "error", name: "PermissionExpired", inputs: [{ name: "end", type: "uint48" }] },
  {
    type: "error",
    name: "InvalidPolicy",
    inputs: [{ name: "policy", type: "tuple", components: POLICY_COMPONENTS }],
  },
] as const;

export const aftermarketCreditAbi = [
  {
    type: "function",
    name: "positionOf",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "p", type: "tuple", components: POSITION_COMPONENTS }],
  },
  {
    type: "function",
    name: "debtOf",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "isFlagged",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "graceUntil",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint64" }],
  },
  {
    type: "function",
    name: "assetsOf",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "address[]" }],
  },
  {
    type: "function",
    name: "collateral",
    stateMutability: "view",
    inputs: [
      { name: "user", type: "address" },
      { name: "asset", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "healthFactor",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [
      { name: "hf", type: "uint256" },
      { name: "priced", type: "bool" },
    ],
  },
  { type: "function", name: "totalDebtAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "usdc", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "calendar", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "vault", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "accrue", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { type: "function", name: "openLine", stateMutability: "nonpayable", inputs: [], outputs: [] },
  {
    type: "function",
    name: "setAutoRepay",
    stateMutability: "nonpayable",
    inputs: [{ name: "enabled", type: "bool" }],
    outputs: [],
  },
  {
    type: "function",
    name: "depositCollateral",
    stateMutability: "nonpayable",
    inputs: [
      { name: "asset", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "draw",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "to", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "repay",
    stateMutability: "nonpayable",
    inputs: [{ name: "assets", type: "uint256" }],
    outputs: [
      { name: "repaidAssets", type: "uint256" },
      { name: "repaidShares", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "repayOnBehalf",
    stateMutability: "nonpayable",
    inputs: [
      { name: "user", type: "address" },
      { name: "assets", type: "uint256" },
    ],
    outputs: [
      { name: "repaidAssets", type: "uint256" },
      { name: "repaidShares", type: "uint256" },
    ],
  },
  { type: "function", name: "flag", stateMutability: "nonpayable", inputs: [{ name: "user", type: "address" }], outputs: [] },
  { type: "function", name: "cure", stateMutability: "nonpayable", inputs: [{ name: "user", type: "address" }], outputs: [] },
  {
    type: "function",
    name: "setAsset",
    stateMutability: "nonpayable",
    inputs: [
      { name: "asset", type: "address" },
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "oracle", type: "address" },
          { name: "advanceOpenBps", type: "uint16" },
          { name: "advanceClosedBps", type: "uint16" },
          { name: "liqThresholdOpenBps", type: "uint16" },
          { name: "liqThresholdClosedBps", type: "uint16" },
          { name: "liqBonusBps", type: "uint16" },
          { name: "cap", type: "uint128" },
          { name: "enabled", type: "bool" },
        ],
      },
    ],
    outputs: [],
  },
  { type: "error", name: "UnpricedCollateral", inputs: [{ name: "assets", type: "uint256" }] },
  { type: "error", name: "LineNotOpen", inputs: [{ name: "user", type: "address" }] },
  {
    type: "error",
    name: "LineHealthy",
    inputs: [
      { name: "debtAssets", type: "uint256" },
      { name: "seizureThreshold", type: "uint256" },
    ],
  },
  { type: "error", name: "NoDebt", inputs: [{ name: "user", type: "address" }] },
  {
    type: "error",
    name: "AlreadyFlagged",
    inputs: [
      { name: "user", type: "address" },
      { name: "graceUntil", type: "uint64" },
    ],
  },
  { type: "error", name: "CalendarHorizon", inputs: [] },
] as const;

/** `Quote` from `contracts/src/libraries/Types.sol`, as `AftermarketLens` re-exports it. */
const QUOTE_COMPONENTS = [
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
] as const;

const ASSET_VIEW_COMPONENTS = [
  { name: "asset", type: "address" },
  { name: "symbol", type: "string" },
  { name: "decimals", type: "uint8" },
  { name: "oracle", type: "address" },
  { name: "quote", type: "tuple", components: QUOTE_COMPONENTS },
  { name: "quoteOk", type: "bool" },
  { name: "advanceBps", type: "uint16" },
  { name: "liqThresholdBps", type: "uint16" },
  { name: "cap", type: "uint128" },
  { name: "posted", type: "uint128" },
  { name: "enabled", type: "bool" },
  { name: "borrowApr", type: "uint256" },
  { name: "supplyApr", type: "uint256" },
] as const;

export const aftermarketLensAbi = [
  {
    type: "function",
    name: "assetViews",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "tuple[]", components: ASSET_VIEW_COMPONENTS }],
  },
  {
    type: "function",
    name: "assetView",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ name: "", type: "tuple", components: ASSET_VIEW_COMPONENTS }],
  },
  {
    type: "function",
    name: "userView",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "user", type: "address" },
          { name: "collateral", type: "address[]" },
          { name: "amounts", type: "uint256[]" },
          { name: "debt", type: "uint256" },
          { name: "borrowPower", type: "uint256" },
          { name: "seizureThreshold", type: "uint256" },
          { name: "healthBps", type: "uint256" },
          { name: "priced", type: "bool" },
          { name: "graceUntil", type: "uint64" },
          { name: "flaggedAt", type: "uint64" },
          { name: "eligible", type: "bool" },
          { name: "country", type: "bytes2" },
          { name: "autoRepayEnrolled", type: "bool" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "protocolView",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "session", type: "uint8" },
          { name: "nextOpen", type: "uint64" },
          { name: "lastClose", type: "uint64" },
          { name: "totalDebt", type: "uint256" },
          { name: "totalSupplied", type: "uint256" },
          { name: "utilisation", type: "uint256" },
          { name: "vaultSharePrice", type: "uint256" },
          { name: "assets", type: "address[]" },
        ],
      },
    ],
  },
] as const;

export const spendPermissionManagerAbi = [
  {
    type: "function",
    name: "isValid",
    stateMutability: "view",
    inputs: [{ name: "spendPermission", type: "tuple", components: SPEND_PERMISSION_COMPONENTS }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "isRevoked",
    stateMutability: "view",
    inputs: [{ name: "spendPermission", type: "tuple", components: SPEND_PERMISSION_COMPONENTS }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "getHash",
    stateMutability: "view",
    inputs: [{ name: "spendPermission", type: "tuple", components: SPEND_PERMISSION_COMPONENTS }],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "getCurrentPeriod",
    stateMutability: "view",
    inputs: [{ name: "spendPermission", type: "tuple", components: SPEND_PERMISSION_COMPONENTS }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "start", type: "uint48" },
          { name: "end", type: "uint48" },
          { name: "spend", type: "uint160" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [{ name: "spendPermission", type: "tuple", components: SPEND_PERMISSION_COMPONENTS }],
    outputs: [],
  },
  {
    type: "function",
    name: "revoke",
    stateMutability: "nonpayable",
    inputs: [{ name: "spendPermission", type: "tuple", components: SPEND_PERMISSION_COMPONENTS }],
    outputs: [],
  },
  {
    type: "function",
    name: "spend",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spendPermission", type: "tuple", components: SPEND_PERMISSION_COMPONENTS },
      { name: "value", type: "uint160" },
    ],
    outputs: [],
  },
  {
    type: "error",
    name: "ExceededSpendPermission",
    inputs: [
      { name: "value", type: "uint256" },
      { name: "allowance", type: "uint256" },
    ],
  },
  { type: "error", name: "UnauthorizedSpendPermission", inputs: [] },
  {
    type: "error",
    name: "BeforeSpendPermissionStart",
    inputs: [
      { name: "currentTimestamp", type: "uint48" },
      { name: "start", type: "uint48" },
    ],
  },
  {
    type: "error",
    name: "AfterSpendPermissionEnd",
    inputs: [
      { name: "currentTimestamp", type: "uint48" },
      { name: "end", type: "uint48" },
    ],
  },
] as const;

/** The ERC-20 surface the keeper reads for display and for its own balance assertions. */
export const erc20Abi = [
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
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
    name: "transfer",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

export { POLICY_COMPONENTS, POSITION_COMPONENTS, SPEND_PERMISSION_COMPONENTS };
