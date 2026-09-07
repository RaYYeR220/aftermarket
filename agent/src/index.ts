export { aftermarketCreditAbi, aftermarketLensAbi, autoRepayerAbi, erc20Abi, spendPermissionManagerAbi } from "./abi.js";
export { BASE_MAINNET, BASE_MAINNET_ORACLES, BPS, RECOVERY_MARGIN_BPS, USDC_DECIMALS } from "./addresses.js";
export type { OracleTicker } from "./addresses.js";

export { AuditTrail, DEFAULT_AUDIT_PATH, buildRecord, buildUnavailableRecord } from "./audit.js";

export {
  createKeeperClient,
  createKeeperWallet,
  DEFAULT_RPC_URL,
  describeError,
  extractRevertData,
  isContractRevert,
  resolveKeeperAccount,
  resolveRpcUrl,
  withRateLimitRetry,
} from "./chain.js";

export { agreesWithContract, decide, formatHealthBps, MAX_UINT256 } from "./engine.js";
export { formatHealthPercent, formatUsdc, renderExplain, renderTable, renderTickTable, wrap } from "./format.js";
export { Keeper } from "./keeper.js";
export type { KeeperConfig } from "./keeper.js";

export {
  formatOracleError,
  readAccount,
  readBlock,
  readOracles,
  readPriceError,
  sessionLabel,
  simulate,
  verdictName,
} from "./reader.js";
export type { BlockRef, OracleTable, ProtocolAddresses } from "./reader.js";

export {
  EVALUATION_ORDER,
  REASON_EXPLANATIONS,
  REASON_NAMES,
  Reason,
  reasonExplanation,
  reasonName,
  toReason,
} from "./reasons.js";

export { AccountRegistry, parsePinnedAccounts } from "./registry.js";
export type { RegistryOptions } from "./registry.js";

export { createKeeperServer, listen } from "./server.js";
export type { KeeperServerOptions, KeeperStatus } from "./server.js";

export type {
  AccountSnapshot,
  ActionKind,
  ActionOutcome,
  ContractSimulation,
  Decision,
  DecisionInputs,
  DecisionRecord,
  DecisionStatus,
  Enrollment,
  OracleSnapshot,
  Policy,
  Position,
  SpendPermission,
  TickResult,
} from "./types.js";
