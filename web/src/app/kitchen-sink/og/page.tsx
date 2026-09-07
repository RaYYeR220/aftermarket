import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { BrandGlyph } from "@/components/landing/Chrome";
import type { ShelfModel } from "@/components/shelf/model";
import { SCENE_VIEWBOX, buildShelfScene } from "@/components/shelf/scene";
import sceneStyles from "@/components/shelf/scene.module.css";
import { SITE } from "@/lib/site";

import styles from "../kitchen-sink.module.css";

/**
 * The artboards the site's two raster assets are cut from.
 *
 * `public/og.png` and `public/icon-1024.png` are baked from these at the sizes
 * below, which is how the social card gets the real Bricolage and Azeret cuts
 * instead of whatever a runtime image renderer happens to have. Development
 * only: rebake by screenshotting `#og-card` and `#icon-card`.
 */
export const metadata: Metadata = {
  title: "Artboards",
  robots: { index: false, follow: false },
};

/**
 * A drawing for a card, not a reading: even bays, a plate at the closed advance
 * rate and a line drawn under it. No figure from it is ever printed, and the
 * annotations that would print one are not rendered.
 */
const CARD_MODEL: ShelfModel = {
  bays: ["NVDA", "AAPL", "META", "GOOGL", "TSLA", "AMZN"].map((underlying) => ({
    ticker: `${underlying}c`,
    underlying,
    valueUsd: 1,
    quoting: true,
    markedAt: "feed" as const,
  })),
  basketUsd: 6,
  lendableUsd: 6,
  drawnUsd: 2.04,
  advanceOpen: 0.65,
  advanceClosed: 0.5,
  limitFractionClosed: 0.5,
  limitFractionOpen: 0.65,
  drawnFraction: 0.34,
  title: { key: "", value: "" },
};

export default function Artboards() {
  if (process.env.NODE_ENV === "production") notFound();

  const scene = buildShelfScene({ model: CARD_MODEL, limitFraction: CARD_MODEL.limitFractionClosed });

  return (
    <div className={`wrap ${styles.page} ${styles.artboards}`}>
      <div className={styles.ogCard} id="og-card">
        <div className={styles.ogText}>
          <div className={styles.ogBrand}>
            <BrandGlyph />
            <span>{SITE.name}</span>
          </div>
          <p className={styles.ogClaim}>
            When the market shuts, the ceiling comes down. Nothing else moves.
          </p>
          <p className={styles.ogMeta}>
            A portfolio line of credit against Coinbase tokenized stocks on <b>Base</b>.
            <br />
            The oracle refuses to publish a mark it cannot defend.
          </p>
        </div>
        <div className={styles.ogArt}>
          <svg className={sceneStyles.svg} viewBox={SCENE_VIEWBOX} aria-hidden>
            <defs>
              <radialGradient id="shelf-light" cx="34%" cy="24%" r="78%">
                <stop offset="0" className={sceneStyles.lightStopIn} />
                <stop offset="1" className={sceneStyles.lightStopOut} />
              </radialGradient>
              <radialGradient id="shelf-shadow-contact" cx="50%" cy="50%" r="50%">
                <stop offset="0" className={sceneStyles.contactStop0} />
                <stop offset="0.55" className={sceneStyles.contactStop1} />
                <stop offset="1" className={sceneStyles.contactStop2} />
              </radialGradient>
              <radialGradient id="shelf-shadow-cast" cx="50%" cy="50%" r="50%">
                <stop offset="0" className={sceneStyles.castStop0} />
                <stop offset="0.6" className={sceneStyles.castStop1} />
                <stop offset="1" className={sceneStyles.castStop2} />
              </radialGradient>
            </defs>
            <g>
              {scene.body.map((node) =>
                node.kind === "path" ? (
                  <path key={node.id} d={node.d} className={sceneStyles[node.cls]} opacity={node.opacity} />
                ) : node.kind === "ellipse" ? (
                  <circle
                    key={node.id}
                    cx={0}
                    cy={0}
                    r={node.r}
                    className={sceneStyles[node.cls]}
                    transform={node.transform}
                    opacity={node.opacity}
                  />
                ) : null,
              )}
            </g>
          </svg>
        </div>
      </div>

      <div className={styles.iconCard} id="icon-card">
        <svg width="720" height="720" viewBox="0 0 18 18" aria-hidden>
          <rect x="1" y="1" width="2" height="16" fill="var(--wordmark-upright)" />
          <rect x="15" y="1" width="2" height="16" fill="var(--wordmark-upright)" />
          <rect x="3" y="3.5" width="12" height="2" fill="var(--wordmark-shelf-top)" />
          <rect x="3" y="8" width="12" height="2" fill="var(--wordmark-shelf-mid)" />
          <rect x="3" y="12.5" width="12" height="2" fill="var(--wordmark-shelf-low)" />
        </svg>
      </div>
    </div>
  );
}
