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
