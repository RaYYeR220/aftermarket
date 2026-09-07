"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { WagmiProvider } from "wagmi";

import { createWagmiConfig } from "@/lib/wagmi";

/**
 * Wallet and query context.
 *
 * The config is built once per browser session rather than at module scope, so
 * a server render never shares connector state with a client, and the ERC-8021
 * data suffix is attached where it is created rather than at every call site.
 */
export function Providers({ children }: { children: ReactNode }) {
  const [config] = useState(createWagmiConfig);
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: { queries: { staleTime: 30_000, refetchOnWindowFocus: false } },
      }),
  );

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
