import { http, createConfig, cookieStorage, createStorage } from "wagmi";
import { base } from "wagmi/chains";
import { baseAccount } from "wagmi/connectors";

import { builderDataSuffix } from "./builder-code";
import { publicBaseRpcUrl } from "./env";
import { SITE } from "./site";

/**
 * One chain, one connector.
 *
 * Aftermarket only exists on Base mainnet, and the account it wants is a Base
 * Account -- that is what "Sign in with Base" signs with, and what the credit
 * surface will later send calls through. Adding injected or WalletConnect
 * fallbacks here would offer people a wallet the product cannot serve.
 *
 * `dataSuffix` is set at the config level so ERC-8021 attribution rides on
 * every transaction the app ever sends, rather than on the ones a developer
 * remembered to tag.
 *
 * Reads are aggregated twice over: `batch.multicall` folds every concurrent
 * `readContract` into one Multicall3 call, and the transport folds whatever is
 * left into one JSON-RPC batch. They then leave through this app's own
 * `/api/rpc` unless a public endpoint is configured, because a public Base RPC
 * rate-limits per client and the live previews on these screens poll several
 * account-specific reads at once -- a visitor doing nothing but looking at the
 * page would otherwise watch every figure turn to `unavailable`.
 */
export function createWagmiConfig() {
  const dataSuffix = builderDataSuffix();
  return createConfig({
    chains: [base],
    connectors: [
      baseAccount({
        appName: SITE.name,
      }),
    ],
    batch: { multicall: true },
    transports: {
      [base.id]: http(publicBaseRpcUrl(), { batch: true }),
    },
    ssr: true,
    storage: createStorage({ storage: cookieStorage }),
    ...(dataSuffix ? { dataSuffix } : {}),
  });
}

export type WagmiConfig = ReturnType<typeof createWagmiConfig>;
