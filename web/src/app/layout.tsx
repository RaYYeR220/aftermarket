import type { Metadata, Viewport } from "next";
import { Azeret_Mono, Bricolage_Grotesque } from "next/font/google";

import { Providers } from "@/components/Providers";
import { siteUrl } from "@/lib/env";
import { SITE } from "@/lib/site";
import "@/styles/globals.css";

/**
 * Bricolage argues, Azeret measures.
 *
 * Both are self-hosted and preloaded by `next/font`, so the first paint has the
 * real faces and the hero never reflows into them. Both axes on Bricolage are
 * actually driven -- hierarchy on this site comes from width, which is how Base
 * itself gets emphasis, rather than from a weight jump or an all-caps eyebrow.
 */
const bricolage = Bricolage_Grotesque({
  subsets: ["latin"],
  axes: ["opsz", "wdth"],
  display: "swap",
  variable: "--font-bricolage",
  fallback: ["Trebuchet MS", "system-ui", "sans-serif"],
});

const azeret = Azeret_Mono({
  subsets: ["latin"],
  weight: ["300", "400", "500", "600"],
  display: "swap",
  variable: "--font-azeret",
  fallback: ["ui-monospace", "Cascadia Mono", "Consolas", "monospace"],
});

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl()),
  title: {
    default: `${SITE.name} — ${SITE.tagline}`,
    template: `%s — ${SITE.name}`,
  },
  description: SITE.summary,
  applicationName: SITE.name,
  category: "finance",
  keywords: [
    "tokenized equities",
    "Base",
    "portfolio line of credit",
    "price oracle",
    "market hours",
    "Chainlink",
    "Aerodrome",
    "Morpho",
  ],
  authors: [{ name: SITE.name }],
  openGraph: {
    type: "website",
    siteName: SITE.name,
    title: `${SITE.name} — ${SITE.tagline}`,
    description: SITE.summary,
    url: siteUrl(),
    images: [{ url: "/og.png", width: 1200, height: 630, alt: `${SITE.name}: ${SITE.tagline}` }],
  },
  twitter: {
    card: "summary_large_image",
    title: `${SITE.name} — ${SITE.tagline}`,
    description: SITE.summary,
    images: ["/og.png"],
  },
  alternates: { canonical: siteUrl() },
  robots: { index: true, follow: true },
  // base.dev proves you own the domain you registered by looking for this tag in the served HTML,
  // so it has to be in the document head of every route rather than on one page. `other` is the
  // App Router's escape hatch for a `<meta name=... content=...>` Next has no typed field for;
  // hand-writing the tag in the body would put it outside <head> and the check would not see it.
  // This is the base.dev app registration for aftermarket-fawn.vercel.app. It is not an ERC-8021
  // Builder Code: that is a separate, still-unclaimed thing, and NEXT_PUBLIC_BUILDER_CODE stays
  // empty until one is actually registered. See README → Attribution.
  other: { "base:app_id": "6aa012ce227c28e4adffe46b" },
};

export const viewport: Viewport = {
  themeColor: "#ffffff",
  colorScheme: "light",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${bricolage.variable} ${azeret.variable}`}>
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
