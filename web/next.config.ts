import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@aftermarket/observer", "@aftermarket/session-oracle"],
  typedRoutes: true,
  poweredByHeader: false,
  /**
   * The Base Account SDK reaches the bundler through the wagmi connector, and
   * its Node entry lazily imports the x402 payment schemes. Aftermarket does
   * not use x402, so those packages are not installed; keeping the SDK external
   * to the server bundle leaves those imports where they belong -- inside a
   * dynamic import that is never taken -- instead of asking the bundler to
   * resolve them at build time.
   */
  serverExternalPackages: ["@base-org/account", "@coinbase/cdp-sdk"],
  // This repository keeps its own contributor documentation; the framework does
  // not need to write more into the workspace root.
  agentRules: false,
};

export default nextConfig;
