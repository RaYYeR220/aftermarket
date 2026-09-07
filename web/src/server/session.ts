import "server-only";

import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

import { cookies } from "next/headers";
import type { Address } from "viem";

/**
 * Sign in with Base, server side.
 *
 * The browser never gets to say who it is. A nonce is issued here, spent here,
 * and the address only enters a session cookie after the signature over that
 * exact nonce has verified against Base mainnet -- which also covers smart
 * accounts, because the verification goes through ERC-6492 and ERC-1271 rather
 * than assuming an EOA.
 */

const NONCE_COOKIE = "aftermarket_nonce";
const SESSION_COOKIE = "aftermarket_session";
const NONCE_TTL_SECONDS = 10 * 60;
const SESSION_TTL_SECONDS = 7 * 24 * 60 * 60;

/**
 * Sessions are signed with `SESSION_SECRET`. Without it the process mints a
 * random secret at boot, which is fine for a single local instance and is
 * documented as such: sessions then end when the process does, and do not
 * travel between instances.
 */
const secret = process.env.SESSION_SECRET ?? randomBytes(32).toString("hex");

function sign(payload: string): string {
  return createHmac("sha256", secret).update(payload).digest("base64url");
}

function verify(payload: string, signature: string): boolean {
  const expected = Buffer.from(sign(payload));
  const given = Buffer.from(signature);
  if (expected.length !== given.length) return false;
  return timingSafeEqual(expected, given);
}

export interface Session {
  address: Address;
  issuedAtUnix: number;
}

/** Mints a nonce, remembers it in an httpOnly cookie and hands the caller the value to sign. */
export async function issueNonce(nonce: string): Promise<void> {
  const jar = await cookies();
  jar.set(NONCE_COOKIE, nonce, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: NONCE_TTL_SECONDS,
  });
}

export async function takeNonce(): Promise<string | null> {
  const jar = await cookies();
  const value = jar.get(NONCE_COOKIE)?.value ?? null;
  if (value !== null) jar.delete(NONCE_COOKIE);
  return value;
}

export async function startSession(address: Address): Promise<void> {
  const payload = JSON.stringify({ address, issuedAtUnix: Math.floor(Date.now() / 1000) });
  const encoded = Buffer.from(payload).toString("base64url");
  const jar = await cookies();
  jar.set(SESSION_COOKIE, `${encoded}.${sign(encoded)}`, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: SESSION_TTL_SECONDS,
  });
}

export async function readSession(): Promise<Session | null> {
  const jar = await cookies();
  const raw = jar.get(SESSION_COOKIE)?.value;
  if (!raw) return null;
  const [encoded, signature] = raw.split(".");
  if (!encoded || !signature || !verify(encoded, signature)) return null;
  try {
    const parsed = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as Session;
    if (typeof parsed.address !== "string" || typeof parsed.issuedAtUnix !== "number") return null;
    if (Date.now() / 1000 - parsed.issuedAtUnix > SESSION_TTL_SECONDS) return null;
    return parsed;
  } catch {
    return null;
  }
}

export async function endSession(): Promise<void> {
  const jar = await cookies();
  jar.delete(SESSION_COOKIE);
}
