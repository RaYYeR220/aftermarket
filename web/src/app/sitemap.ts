import type { MetadataRoute } from "next";

import { siteUrl } from "@/lib/env";

/** The public pages: the landing page, and the seven application screens. */
const SCREENS = [
  "/app/markets",
  "/app/line",
  "/app/borrow",
  "/app/earn",
  "/app/oracle",
  "/app/auto-repay",
  "/app/activity",
] as const;

export default function sitemap(): MetadataRoute.Sitemap {
  const origin = siteUrl();
  return [
    { url: origin, changeFrequency: "hourly", priority: 1 },
    ...SCREENS.map((path) => ({
      url: `${origin}${path}`,
      changeFrequency: "hourly" as const,
      priority: 0.8,
    })),
  ];
}
