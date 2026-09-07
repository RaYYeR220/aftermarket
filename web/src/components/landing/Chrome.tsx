import { SITE } from "@/lib/site";

import styles from "./landing.module.css";

/**
 * The wordmark glyph is a drawing of the mechanism -- two uprights and three
 * shelves at three tints -- rather than a symbol standing in for one. It is the
 * hero object reduced to 18 pixels, and it is the only logo on the site.
 */
export function BrandGlyph() {
  return (
    <svg className={styles.brandGlyph} width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
      <rect x="1" y="1" width="2" height="16" fill="var(--wordmark-upright)" />
      <rect x="15" y="1" width="2" height="16" fill="var(--wordmark-upright)" />
      <rect x="3" y="3.5" width="12" height="2" fill="var(--wordmark-shelf-top)" />
      <rect x="3" y="8" width="12" height="2" fill="var(--wordmark-shelf-mid)" />
      <rect x="3" y="12.5" width="12" height="2" fill="var(--wordmark-shelf-low)" />
    </svg>
  );
}

export function Masthead() {
  return (
    <header className={styles.mast}>
      <div className={`wrap ${styles.mastInner}`}>
        <a className={styles.brand} href="/">
          <BrandGlyph />
          <span className={styles.brandName}>{SITE.name}</span>
        </a>
        <nav className={styles.nav} aria-label="Sections">
          <a href="#mechanism">How it works</a>
          <a href="#evidence">Live marks</a>
          <a href="#integrate">Integrate</a>
        </nav>
      </div>
    </header>
  );
}

export interface FooterProps {
  /** The block every figure on the page was read at, or `null` when the read failed. */
  blockNumber: string | null;
}

export function Footer({ blockNumber }: FooterProps) {
  return (
    <footer className={styles.footer}>
      <div className={`wrap ${styles.footerInner}`}>
        <div className={styles.footerLeft}>
          <a className={styles.brand} href="/">
            <BrandGlyph />
            <span className={styles.brandName}>{SITE.name}</span>
          </a>
          <div className={styles.footerLinks}>
            <a href="#mechanism">How it works</a>
            <a href="#limits">What it will not do</a>
            <a href="#integrate">{SITE.sdkPackage}</a>
            <a href={SITE.repository}>Source</a>
          </div>
        </div>
        <p className={styles.footerMeta}>
          {SITE.name} runs on {SITE.chainName} mainnet, chain {SITE.chainId}.
          <br />
          {blockNumber === null
            ? "Every figure on this page is read live; this read did not complete."
            : `Every figure on this page was read at block ${blockNumber}.`}
        </p>
      </div>
    </footer>
  );
}
