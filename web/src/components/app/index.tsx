import type { ReactNode } from "react";

import { explorerAddress, explorerBlock, explorerTx } from "@/lib/deployment";
import { shortAddress, UNAVAILABLE } from "@/lib/format";
import { SESSION_SHORT, type Session } from "@/lib/session";

import styles from "./app.module.css";

function cx(...parts: Array<string | false | null | undefined>): string {
  return parts.filter(Boolean).join(" ");
}

/* ================================================================ bay ===== */

export interface BayProps {
  title?: ReactNode | undefined;
  /** A measured aside on the top right: a block, an address, an age. */
  note?: ReactNode | undefined;
  /** One paragraph under the title saying what this bay is for. */
  lede?: ReactNode | undefined;
  /** Darkens the classification rule. Used where the bay records a refusal. */
  refused?: boolean | undefined;
  /**
   * Names the section for assistive technology where the bay carries no visible title -- an asset
   * row, for instance, whose identity is the ticker rather than a heading.
   */
  label?: string | undefined;
  children: ReactNode;
  className?: string | undefined;
}

/**
 * A bay: the flush panel treatment from the design system, which is a 2px
 * classification rule and no box. Every section of every screen is one.
 */
export function Bay({ title, note, lede, refused = false, label, children, className }: BayProps) {
  return (
    <section aria-label={label} className={cx(styles.bay, refused && styles.bayRefused, className)}>
      {(title !== undefined || note !== undefined) && (
        <header className={styles.bayHead}>
          {title !== undefined && <h2 className={styles.bayTitle}>{title}</h2>}
          {note !== undefined && <p className={styles.bayNote}>{note}</p>}
        </header>
      )}
      {lede !== undefined && <p className={styles.bayLede}>{lede}</p>}
      {children}
    </section>
  );
}

/* ============================================================== meter ===== */

export interface MeterProps {
  /** What was measured. */
  value: number | null;
  /** What this session allows. The limit is drawn as a marked position, not a colour change. */
  limit: number;
  /** Label under the observed value. */
  valueLabel: string;
  /** Label under the limit. */
  limitLabel: string;
  /**
   * Which side of the limit is the safe side. Divergence and feed age are safe below their limit;
   * health is safe above it.
   */
  direction?: "below-is-safe" | "above-is-safe" | undefined;
  className?: string | undefined;
}

/**
 * One measured value judged against one limit.
 *
 * The same instrument reads divergence against its band, feed age against its budget, utilisation
 * against the kink and health against the seizure threshold, so a reader learns it once. The limit
 * is a rule across the track and the shaded zone is the permitted side of it: the reading survives
 * without colour, in print, and under any form of colour blindness.
 */
export function Meter({
  value,
  limit,
  valueLabel,
  limitLabel,
  direction = "below-is-safe",
  className,
}: MeterProps) {
  const safe =
    value === null ? true : direction === "below-is-safe" ? value <= limit : value >= limit;
  const scale = Math.max(limit * 1.6, (value ?? 0) * 1.12, Number.EPSILON);
  const fill = value === null ? 0 : Math.min(1, value / scale);
  const gate = Math.min(1, limit / scale);

  return (
    <div className={cx(styles.meter, className)}>
      <div className={styles.meterTrack}>
        <span
          className={styles.meterZone}
          style={direction === "below-is-safe" ? { width: `${gate * 100}%` } : { left: `${gate * 100}%`, right: 0, width: "auto" }}
          aria-hidden
        />
        <span
          className={cx(styles.meterFill, !safe && styles.meterFillOver)}
          style={{ width: `${fill * 100}%` }}
          aria-hidden
        />
        <span className={styles.meterAllowed} style={{ left: `${gate * 100}%` }} aria-hidden />
        {value !== null && value > scale && <span className={styles.meterOverflow} aria-hidden />}
      </div>
      <p className={styles.meterScale}>
        <span>
          <b>{value === null ? UNAVAILABLE : valueLabel}</b> measured
        </span>
        <span>
          allowed <b>{limitLabel}</b>
        </span>
      </p>
    </div>
  );
}

/* ======================================================== source pair ===== */

export interface SourceRowProps {
  kind: "feed" | "pool";
  name: string;
  value: ReactNode | null;
  aside?: ReactNode | undefined;
}

export function SourceRow({ kind, name, value, aside }: SourceRowProps) {
  return (
    <span className={styles.source}>
      <span
        className={cx(styles.sourceMark, kind === "feed" ? styles.sourceMarkFeed : styles.sourceMarkPool)}
        aria-hidden
      />
      <span className={styles.sourceName}>{name}</span>
      <span className={styles.sourceValue}>{value === null ? UNAVAILABLE : value}</span>
      {aside !== undefined && <span className={styles.sourceAside}>{aside}</span>}
    </span>
  );
}

export function Sources({ children, className }: { children: ReactNode; className?: string | undefined }) {
  return <div className={cx(styles.sources, className)}>{children}</div>;
}

/* ============================================================ refusal ===== */

export interface RefusalBlockProps {
  /** The word for the state, e.g. `divergent`. */
  word: string;
  /** The typed error `price()` reverts with. */
  signature: string;
  /** One sentence naming the rule that was broken. */
  rule: string;
  /** Measured versus allowed, and anything else worth stating. */
  figures?: ReactNode | undefined;
  /** The decoded arguments the revert actually carried. */
  args?: { key: string; value: string }[] | undefined;
  className?: string | undefined;
}

/**
 * A refusal, rendered as a state the product designed rather than an error it suffered.
 *
 * The hatch under the card is the site's one pattern and it has one meaning: no defensible mark
 * here. The card on top carries the rule in words and the numbers that tripped it, because a
 * refusal a reader cannot check is just a different kind of black box.
 */
export function RefusalBlock({ word, signature, rule, figures, args, className }: RefusalBlockProps) {
  return (
    <div className={cx(styles.refusal, className)}>
      <div className={styles.refusalCard}>
        <div className={styles.refusalHead}>
          <span className={styles.refusalWord}>{word}</span>
          <span className={styles.refusalSignature}>{signature}</span>
        </div>
        <p className={styles.refusalRule}>{rule}</p>
        {args !== undefined && args.length > 0 && (
          <p className={styles.args}>
            {args.map((arg) => (
              <span className={styles.arg} key={arg.key}>
                <span className={styles.argKey}>{arg.key}</span>
                <span className={styles.argValue}>{arg.value}</span>
              </span>
            ))}
          </p>
        )}
        {figures !== undefined && <div className={styles.refusalFigures}>{figures}</div>}
      </div>
    </div>
  );
}

/* =============================================================== cell ===== */

/**
 * One cell of a row-based table, carrying the column name for the widths where the header is gone.
 *
 * These tables are grids rather than `<table>` elements because a bay is a grid and the rows have to
 * reflow rather than scroll sideways on a phone. That reflow is what makes a header row useless
 * below 900px, so the name travels with the value instead.
 */
export function Cell({
  label,
  children,
  className,
}: {
  label: string;
  children: ReactNode;
  className?: string | undefined;
}) {
  return (
    <span className={cx(styles.cell, className)}>
      <span className={styles.cellKey}>{label}</span>
      {children}
    </span>
  );
}

/* ============================================================== links ===== */

export function AddressLink({ address, label }: { address: string; label?: string | undefined }) {
  return (
    <a className={styles.address} href={explorerAddress(address)} rel="noreferrer" target="_blank">
      {label ?? shortAddress(address)}
    </a>
  );
}

export function TxLink({ hash, label }: { hash: string; label?: string | undefined }) {
  return (
    <a className={styles.address} href={explorerTx(hash)} rel="noreferrer" target="_blank">
      {label ?? shortAddress(hash)}
    </a>
  );
}

export function BlockLink({ blockNumber }: { blockNumber: bigint }) {
  return (
    <a className={styles.address} href={explorerBlock(blockNumber)} rel="noreferrer" target="_blank">
      {blockNumber.toString()}
    </a>
  );
}

/* ============================================================ notices ===== */

export interface NoticeProps {
  title: ReactNode;
  children?: ReactNode | undefined;
  /** Draws the harder border. Use where the protocol is declining to do something. */
  strong?: boolean | undefined;
  actions?: ReactNode | undefined;
  className?: string | undefined;
}

export function Notice({ title, children, strong = false, actions, className }: NoticeProps) {
  return (
    <div className={cx(styles.notice, strong && styles.noticeStrong, className)}>
      <p className={styles.noticeTitle}>{title}</p>
      {children !== undefined && <div className={styles.noticeBody}>{children}</div>}
      {actions !== undefined && <div className={styles.noticeActions}>{actions}</div>}
    </div>
  );
}

/** What a screen renders when the chain did not answer. States the failure; invents nothing. */
export function ReadFailure({ what, error }: { what: string; error: string }) {
  return (
    <Notice strong title={`${what} is unavailable`}>
      <p>
        This screen reads Base mainnet live and holds no cache, so there is nothing to show in place of the
        read that failed. The endpoint reported: <code>{error}</code>
      </p>
    </Notice>
  );
}

/* ============================================================= ladder ===== */

export interface LadderEntry {
  session: Session;
  /** The bar length, as a fraction of the widest row. */
  fraction: number;
  /** The number printed at the end of the row. */
  value: string;
  isCurrent: boolean;
}

/**
 * The same policy priced in all six sessions.
 *
 * One series, so no legend: every bar carries its own value and the session in force is marked
 * structurally by a rule down its left edge rather than by a different colour.
 */
export function SessionLadder({ entries, caption }: { entries: LadderEntry[]; caption?: ReactNode | undefined }) {
  return (
    <div>
      <div className={styles.ladder}>
        {entries.map((entry) => (
          <div
            className={cx(styles.ladderRow, entry.isCurrent && styles.ladderRowCurrent)}
            key={entry.session}
          >
            <span className={styles.ladderName}>
              {SESSION_SHORT[entry.session]}
              {entry.isCurrent ? " · now" : ""}
            </span>
            <span className={styles.ladderBarTrack}>
              <span
                className={styles.ladderBar}
                style={{ width: `${Math.max(0, Math.min(1, entry.fraction)) * 100}%` }}
              />
            </span>
            <span className={styles.ladderValue}>{entry.value}</span>
          </div>
        ))}
      </div>
      {caption !== undefined && <p className={styles.ladderCaption}>{caption}</p>}
    </div>
  );
}

export { styles as appStyles };
