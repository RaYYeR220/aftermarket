import { SignIn } from "@/components/auth/SignIn";
import { BrandGlyph } from "@/components/landing/Chrome";
import { Readout } from "@/components/primitives";
import { bpsAsWholePercent, durationHm, etDayTime } from "@/lib/format";
import { isRegularSession, SESSION_LABEL } from "@/lib/session";
import { SITE } from "@/lib/site";
import type { ProtocolSnapshot } from "@/server/protocol";

import styles from "./app.module.css";
import { Countdown } from "./Countdown";
import { Nav } from "./Nav";

/**
 * The frame every application screen renders inside.
 *
 * Two rows: the wordmark and the account control, then the screen index. The page measure is the
 * landing page's, so the left rule of this masthead and the left rule of every bay below it are the
 * same line.
 */
export function AppMasthead() {
  return (
    <header className={styles.mast}>
      <div className={`wrap ${styles.mastTop}`}>
        <a className={styles.brand} href="/">
          <BrandGlyph />
          <span className={styles.brandName}>{SITE.name}</span>
        </a>
        <div className={styles.mastAside}>
          <SignIn label="Sign in with Base" variant="compact" />
        </div>
      </div>
      <div className="wrap">
        <Nav />
      </div>
    </header>
  );
}

/**
 * Where the market is, on every screen, at all times.
 *
 * This band is the enforcement context, so it is never something a reader has to go and look up:
 * the session, the last defensible print, the next one, the countdown between them, and what the
 * session currently costs in advance rate. The ground darkens and the state mark fills with the
 * site's one pattern when the market is shut, which is a single state change rather than a set of
 * status colours.
 */
export function SessionStrip({ protocol }: { protocol: ProtocolSnapshot | null }) {
  if (protocol === null) {
    return (
      <div className={`${styles.strip} ${styles.stripClosed}`}>
        <div className={`wrap ${styles.stripInner}`}>
          <div className={styles.stripState}>
            <span className={styles.stripMark} aria-hidden />
            <span>
              <span className={styles.stripName}>Market state unavailable</span>
              <span className={styles.stripNote}>Base mainnet did not answer this read.</span>
            </span>
          </div>
        </div>
      </div>
    );
  }

  const {
    session,
    isMarketOpen,
    nextOpenUnix,
    lastCloseUnix,
    etOffsetHours,
    blockTimestampUnix,
    advanceBps,
    advanceOpenBps,
    quotingCount,
    assets,
  } = protocol;

  const untilOpen = Math.max(0, nextOpenUnix - blockTimestampUnix);
  // The credit engine's sense of open, which is the one that sets the advance rate.
  const regular = isRegularSession(session);

  return (
    <div className={`${styles.strip} ${regular ? "" : styles.stripClosed}`}>
      <div className={`wrap ${styles.stripInner}`}>
        <div className={styles.stripState}>
          <span
            className={`${styles.stripMark} ${regular ? styles.stripMarkOpen : styles.stripMarkShut}`}
            aria-hidden
          />
          <span>
            <span className={styles.stripName}>{SESSION_LABEL[session]}</span>
            <span className={styles.stripNote}>
              {regular
                ? "Prices are discoverable and a borrower can trade out of trouble."
                : `${isMarketOpen ? "There is a tape, but not the depth to unwind into." : "Nobody can hedge this gap until the bell."} ${durationHm(protocol.closedGapSeconds)} between the last print and the next.`}
            </span>
          </span>
        </div>

        <Readout size="sm" label="last print" value={etDayTime(lastCloseUnix, etOffsetHours)} />
        <Readout size="sm" label="next open" value={etDayTime(nextOpenUnix, etOffsetHours)} />
        <Readout
          size="sm"
          label={isMarketOpen ? "session closes in" : "reopens in"}
          value={<Countdown targetUnix={nextOpenUnix} initial={durationHm(untilOpen)} passed="the bell" />}
        />
        <Readout
          size="sm"
          label={`advance rate · ${bpsAsWholePercent(advanceOpenBps)} open`}
          value={`${bpsAsWholePercent(advanceBps)} · ${quotingCount}/${assets.length} quoting`}
        />
      </div>
    </div>
  );
}

/**
 * The read-only banner.
 *
 * Nothing on this application is gated behind a wallet: every screen reads Base mainnet and renders
 * for a visitor who has never connected anything. What a visitor cannot do is send a transaction,
 * and this says so, next to the address whose line they are currently looking at.
 */
export function DemoStrip({ referenceLine }: { referenceLine: string }) {
  return (
    <div className={styles.demo}>
      <p className={styles.demoText}>
        Read-only. Every figure on every screen is a live Base mainnet read. Account-specific screens are
        showing <b>the reference line</b> at {referenceLine.slice(0, 6)}…{referenceLine.slice(-4)}, opened by
        the deploying account, until you sign in with your own.
      </p>
      <SignIn label="Sign in with Base" variant="compact" />
    </div>
  );
}
