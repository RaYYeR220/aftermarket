export { aftermarketOracleAbi, tradingCalendarAbi } from "./abi.js";

export {
  decodeOracleError,
  extractRevertData,
  isMarketOpenSession,
  isTrustedVerdict,
  morphoPriceToUsd,
  Session,
  SESSION_NAMES,
  toDecodedQuote,
  usdToMorphoPrice,
  Verdict,
  VERDICT_NAMES,
} from "./types.js";
export type { DecodedQuote, OracleError, Quote, RawQuote } from "./types.js";

export { createOracleClient } from "./client.js";
export type { OracleClient, OracleClientConfig, PriceResult, WatchOptions } from "./client.js";

export { explainVerdict, VERDICT_GUIDANCE } from "./verdict.js";

export {
  DEPLOYMENTS,
  getDeployment,
  getDeploymentsForChain,
  getSupportedChainIds,
} from "./deployments.js";
export type { DeployedMarket, DeploymentRegistry } from "./deployments.js";
