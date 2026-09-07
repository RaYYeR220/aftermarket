import type { MetadataRoute } from "next";

import { SITE } from "@/lib/site";

/**
 * The app manifest, served at `/manifest.webmanifest`.
 *
 * Base.dev registers standard web apps from their metadata -- name, icon,
 * tagline, description, screenshot, category and primary URL -- and this is
 * where those live in a machine-readable form, alongside the OpenGraph tags in
 * the root layout. Aftermarket is a web app rather than a mini app, so there is
 * no Farcaster manifest here: since April 2026 the Base App treats every app as
 * a standard web app and reads its metadata from the base.dev project instead.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: SITE.name,
    short_name: SITE.name,
    description: SITE.summary,
    start_url: "/",
    scope: "/",
    display: "standalone",
    orientation: "portrait",
    background_color: "#FFFFFF",
    theme_color: "#FFFFFF",
    categories: ["finance"],
    icons: [
      { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
      { src: "/icon-1024.png", sizes: "1024x1024", type: "image/png", purpose: "any" },
      { src: "/icon.svg", sizes: "any", type: "image/svg+xml" },
    ],
    screenshots: [
      {
        src: "/og.png",
        sizes: "1200x630",
        type: "image/png",
        form_factor: "wide",
      },
    ],
  };
}
