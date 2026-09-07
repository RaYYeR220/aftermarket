/**
 * Every environment value the app reads, resolved in one place.
 *
 * Nothing here throws on a missing value. A landing page that cannot reach an
 * RPC endpoint should render "unavailable" and stay up, not 500, and an app
 * without a Builder Code should send unattributed transactions rather than
 * refuse to boot.
 */

const DEFAULT_SITE_URL = "http://localhost:3000";
const DEFAULT_RPC_URL = "https://mainnet.base.org";

/** This app's own read proxy. Relative on purpose: it is only ever fetched from the browser. */
const RPC_PROXY_PATH = "/api/rpc";

function trimTrailingSlash(url: string): string {
  return url.endsWith("/") ? url.slice(0, -1) : url;
}

/** Public origin, without a trailing slash. Drives OG tags, the manifest and the SIWE domain check. */
export function siteUrl(): string {
  const configured = process.env.NEXT_PUBLIC_SITE_URL;
  if (configured && configured.length > 0) return trimTrailingSlash(configured);
  const vercel = process.env.VERCEL_PROJECT_PRODUCTION_URL ?? process.env.VERCEL_URL;
  if (vercel && vercel.length > 0) return `https://${trimTrailingSlash(vercel)}`;
  return DEFAULT_SITE_URL;
}

/** Host and port of {@link siteUrl}, which is the value a SIWE message must carry as its domain. */
export function siteDomain(): string {
  return new URL(siteUrl()).host;
}

/** Base mainnet RPC endpoint for server-side reads. */
export function baseRpcUrl(): string {
  const configured = process.env.BASE_RPC_URL;
  return configured && configured.length > 0 ? configured : DEFAULT_RPC_URL;
}

/**
 * Where the browser sends its Base mainnet reads.
 *
 * Separate from {@link baseRpcUrl} because a server-side key must never be inlined into a client
 * bundle. Unset, reads go to this app's own `/api/rpc`, which forwards a fixed list of read methods
 * upstream: one Base connection for the whole application instead of one per visitor, and no key in
 * the client bundle. Set it to send the browser somewhere directly instead.
 */
export function publicBaseRpcUrl(): string {
  const configured = process.env.NEXT_PUBLIC_BASE_RPC_URL;
  return configured && configured.length > 0 ? configured : RPC_PROXY_PATH;
}

/**
 * Builder Code (ERC-8021) issued by base.dev. Read on both the server and the
 * client, so it has to be a `NEXT_PUBLIC_` name and is inlined at build time.
 */
export function builderCode(): string | null {
  const code = process.env.NEXT_PUBLIC_BUILDER_CODE;
  return code && code.length > 0 ? code : null;
}
