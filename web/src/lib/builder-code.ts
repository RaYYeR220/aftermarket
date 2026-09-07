import { Attribution } from "ox/erc8021";
import type { Hex } from "viem";

import { builderCode } from "./env";

/**
 * ERC-8021 transaction attribution.
 *
 * base.dev issues a Builder Code per app; encoding it as a calldata suffix is
 * what lets Base attribute onchain activity back to the app that caused it.
 * The suffix is set once on the wagmi config, so every `useSendTransaction`
 * and `useSendCalls` in the app surface carries it without the call site
 * having to remember.
 *
 * The code is configuration, not a constant: an unset `NEXT_PUBLIC_BUILDER_CODE`
 * produces no suffix and transactions go out unattributed, which is the correct
 * behaviour for a fork or a local run rather than an error.
 */
export function builderDataSuffix(): Hex | undefined {
  const code = builderCode();
  if (!code) return undefined;
  return Attribution.toDataSuffix({ codes: [code] }) as Hex;
}
