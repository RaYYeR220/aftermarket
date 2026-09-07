import { NextResponse } from "next/server";
import { createPublicClient, http, type Hex } from "viem";
import { base } from "viem/chains";
import { parseSiweMessage } from "viem/siwe";

import { baseRpcUrl, siteDomain } from "@/lib/env";
import { displayName } from "@/server/identity";
import { startSession, takeNonce } from "@/server/session";

export const dynamic = "force-dynamic";

interface VerifyBody {
  message?: unknown;
  signature?: unknown;
}

/**
 * Verifies a Sign in with Base signature and starts a session.
 *
 * The nonce comes out of the httpOnly cookie set by `/api/auth/nonce`, so a
 * message signed for someone else's challenge does not get in, and the domain
 * is checked against this deployment's own origin rather than against whatever
 * the message claims.
 */
export async function POST(request: Request) {
  let body: VerifyBody;
  try {
    body = (await request.json()) as VerifyBody;
  } catch {
    return NextResponse.json({ error: "Send a JSON body with a message and a signature." }, { status: 400 });
  }

  const { message, signature } = body;
  if (typeof message !== "string" || typeof signature !== "string") {
    return NextResponse.json({ error: "Send a JSON body with a message and a signature." }, { status: 400 });
  }

  const nonce = await takeNonce();
  if (!nonce) {
    return NextResponse.json({ error: "That sign-in challenge has expired. Start again." }, { status: 400 });
  }

  const client = createPublicClient({ chain: base, transport: http(baseRpcUrl()) });

  let valid = false;
  try {
    valid = await client.verifySiweMessage({
      message,
      signature: signature as Hex,
      nonce,
      domain: siteDomain(),
    });
  } catch {
    return NextResponse.json({ error: "The signature could not be checked against Base." }, { status: 502 });
  }

  if (!valid) {
    return NextResponse.json({ error: "That signature does not match the challenge." }, { status: 401 });
  }

  const parsed = parseSiweMessage(message);
  if (!parsed.address) {
    return NextResponse.json({ error: "The signed message names no address." }, { status: 400 });
  }

  await startSession(parsed.address);
  return NextResponse.json({
    signedIn: true,
    address: parsed.address,
    name: await displayName(parsed.address),
  });
}
