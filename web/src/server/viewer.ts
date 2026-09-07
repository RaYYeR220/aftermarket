import "server-only";

import { cache } from "react";
import type { Address } from "viem";

import { DEPLOYMENT } from "@/lib/deployment";

import { readSession } from "./session";

/**
 * Whose line the account-specific screens are showing.
 *
 * Nothing in this application is gated behind a wallet. A visitor who has never connected anything
 * still gets every screen, reading Base mainnet, because the account-specific reads fall back to
 * the line the deploying account opened on mainnet -- a real position with real collateral and real
 * debt, named as such wherever it is shown. Signing in with Base swaps that address for the
 * visitor's own; it is the write actions, and only the write actions, that need a wallet.
 */
export interface Viewer {
  address: Address;
  /** True when this is the reference line rather than the visitor's own. */
  isReference: boolean;
}

async function read(): Promise<Viewer> {
  const session = await readSession();
  if (session === null) return { address: DEPLOYMENT.referenceLine, isReference: true };
  return { address: session.address, isReference: false };
}

export const readViewer = cache(read);
