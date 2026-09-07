import "server-only";

import { getName } from "@coinbase/onchainkit/identity";
import { base } from "viem/chains";
import type { Address } from "viem";

import { shortAddress } from "@/lib/format";

/**
 * Turns a verified address into the name its owner actually uses.
 *
 * OnchainKit resolves Base names against the registrar Coinbase runs and falls
 * back to ENS, which is a lookup nobody should reimplement. Only the
 * `identity` entry point is used: OnchainKit's root and its React surfaces
 * still import `wagmi/experimental`, a path wagmi 3 removed, so pulling them in
 * would break the build. `identity` carries no wagmi dependency at all.
 *
 * The resolver is a courtesy, not a source of truth: a failure degrades to the
 * shortened address rather than blocking a sign-in.
 */
export async function displayName(address: Address): Promise<string> {
  try {
    const name = await getName({ address, chain: base });
    return name ?? shortAddress(address);
  } catch {
    return shortAddress(address);
  }
}
