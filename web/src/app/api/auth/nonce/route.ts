import { NextResponse } from "next/server";
import { generateSiweNonce } from "viem/siwe";

import { issueNonce } from "@/server/session";

export const dynamic = "force-dynamic";

/** Issues a single-use nonce and remembers it server side, before the wallet popup opens. */
export async function GET() {
  const nonce = generateSiweNonce();
  await issueNonce(nonce);
  return NextResponse.json({ nonce });
}
