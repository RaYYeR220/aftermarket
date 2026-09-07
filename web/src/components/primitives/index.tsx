import type {
  AnchorHTMLAttributes,
  ButtonHTMLAttributes,
  InputHTMLAttributes,
  ReactNode,
} from "react";

import { UNAVAILABLE } from "@/lib/format";
import { Verdict, VERDICT_WORD } from "@/lib/verdict";

import styles from "./primitives.module.css";

function cx(...parts: Array<string | false | null | undefined>): string {
  return parts.filter(Boolean).join(" ");
}

/* ============================================================ Panel ======= */

export interface PanelProps {
  children: ReactNode;
  /** Sits on the panel's top-left. Omit for an untitled surface. */
  title?: ReactNode | undefined;
  /** A measured aside on the top-right: a record id, a block, an age. */
  note?: ReactNode | undefined;
  /**
   * `housing` is the bordered box the controls live in. `flush` is the bay
   * treatment: no box, a 2px classification rule across the top instead.
   */
  variant?: "housing" | "plain" | "flush" | undefined;
  className?: string | undefined;
}

export function Panel({ children, title, note, variant = "housing", className }: PanelProps) {
  return (
    <section
      className={cx(
        styles.panel,
        variant === "plain" && styles.panelPlain,
        variant === "flush" && styles.panelFlush,
        className,
      )}
    >
      {(title !== undefined || note !== undefined) && (
        <header className={styles.panelHead}>
          {title !== undefined && <h3 className={styles.panelTitle}>{title}</h3>}
          {note !== undefined && <p className={styles.panelNote}>{note}</p>}
        </header>
      )}
      {children}
    </section>
  );
}

/* ============================================================= Rail ======= */

export interface RailProps {
  /** Left cell: what is being operated on. */
  lead: ReactNode;
  /** Centre cell: the control itself. */
  children: ReactNode;
  /** Right cell: what the control currently reads. */
  trailing?: ReactNode | undefined;
  /** Full-width line under the three cells, saying what dragging does. */
  hint?: ReactNode | undefined;
  className?: string | undefined;
}

export function Rail({ lead, children, trailing, hint, className }: RailProps) {
  return (
    <div className={cx(styles.rail, className)}>
      <div className={styles.railLead}>{lead}</div>
      <div className={styles.railBody}>{children}</div>
      {trailing !== undefined && <div className={styles.railTrail}>{trailing}</div>}
      {hint !== undefined && <p className={styles.railHint}>{hint}</p>}
    </div>
  );
}

/* =========================================================== Figure ======= */

export interface FigureProps {
  children: ReactNode;
  /**
   * The reading under the drawing. On wide screens the leader callouts carry
   * this information and the caption stays hidden; below 900px the callouts go
   * and the caption takes over.
   */
  caption?: ReactNode | undefined;
  /** Show the caption at every width, not only where the callouts drop out. */
  captionAlways?: boolean | undefined;
  className?: string | undefined;
}

export function Figure({ children, caption, captionAlways = false, className }: FigureProps) {
  return (
    <figure className={cx(styles.figure, className)}>
      {children}
      {caption !== undefined && (
        <figcaption className={cx(styles.figureCaption, !captionAlways && styles.figureCaptionNarrowOnly)}>
          {caption}
        </figcaption>
      )}
    </figure>
  );
}

/* ========================================================== Readout ======= */

export interface ReadoutProps {
  /** The measured value. Pass `null` when the read failed. */
  value: ReactNode | null;
  /** What was measured. */
  label: ReactNode;
  size?: "sm" | "md" | "lg" | undefined;
  align?: "left" | "right" | undefined;
  className?: string | undefined;
}

export function Readout({ value, label, size = "md", align = "left", className }: ReadoutProps) {
  const unavailable = value === null;
  return (
    <div className={cx(styles.readout, align === "right" && styles.readoutRight, className)}>
      <span
        className={cx(
          styles.readoutValue,
          size === "sm" && styles.readoutValueSm,
          size === "lg" && styles.readoutValueLg,
          unavailable && styles.readoutUnavailable,
        )}
      >
        {unavailable ? UNAVAILABLE : value}
      </span>
      <span className={styles.readoutKey}>{label}</span>
    </div>
  );
}

/* ========================================================== Verdict ======= */

const VERDICT_TONE: Record<Verdict, string> = {
  [Verdict.TRUSTED]: styles.verdictTrusted ?? "",
  [Verdict.TRUSTED_CLOSED]: styles.verdictTrustedClosed ?? "",
  [Verdict.UNTRUSTED_STALE]: styles.verdictStale ?? "",
  [Verdict.UNTRUSTED_DIVERGENT]: styles.verdictDivergent ?? "",
  [Verdict.UNTRUSTED_THIN]: styles.verdictThin ?? "",
  [Verdict.UNTRUSTED_HALTED]: styles.verdictHalted ?? "",
};

/**
 * The mark is a drawing of what the state does to the shelf, at zero radius:
 * a filled bay, a bay under a lowered plate, a frozen bay, two marks that no
 * longer line up, a bay with nothing behind it, an empty bay. Colour is never
 * the only thing separating them.
 */
function VerdictMark({ state }: { state: Verdict }) {
  const common = { width: 12, height: 12, viewBox: "0 0 12 12", className: styles.verdictMark, "aria-hidden": true };
  const tone = "currentColor";
  switch (state) {
    case Verdict.TRUSTED:
      return (
        <svg {...common}>
          <rect x="1" y="1" width="10" height="10" fill={tone} />
        </svg>
      );
    case Verdict.TRUSTED_CLOSED:
      return (
        <svg {...common}>
          <rect x="1" y="1" width="10" height="2" fill={tone} />
          <rect x="1" y="5" width="10" height="6" fill={tone} opacity="0.55" />
        </svg>
      );
    case Verdict.UNTRUSTED_STALE:
      return (
        <svg {...common}>
          <rect x="1.5" y="1.5" width="9" height="9" fill="none" stroke={tone} strokeWidth="1.4" />
          <rect x="1.5" y="5.3" width="9" height="1.4" fill={tone} />
        </svg>
      );
    case Verdict.UNTRUSTED_DIVERGENT:
      return (
        <svg {...common}>
          <rect x="0.5" y="2" width="8" height="1.8" fill={tone} />
          <rect x="3.5" y="8.2" width="8" height="1.8" fill={tone} />
        </svg>
      );
    case Verdict.UNTRUSTED_THIN:
      return (
        <svg {...common}>
          <rect
            x="1.5"
            y="1.5"
            width="9"
            height="9"
            fill="none"
            stroke={tone}
            strokeWidth="1.4"
            strokeDasharray="2 2"
          />
        </svg>
      );
    case Verdict.UNTRUSTED_HALTED:
      return (
        <svg {...common}>
          <rect x="1.5" y="1.5" width="9" height="9" fill="none" stroke={tone} strokeWidth="1.4" />
          <path d="M1.5 10.5L10.5 1.5" stroke={tone} strokeWidth="1.4" />
        </svg>
      );
  }
}

export interface VerdictProps {
  state: Verdict;
  /** The record this verdict belongs to, e.g. `AMZN 0907-02`. Vitsoe numbering: an id, not a rank. */
  record?: string | undefined;
  className?: string | undefined;
}

export function VerdictChip({ state, record, className }: VerdictProps) {
  return (
    <span className={cx(styles.verdict, VERDICT_TONE[state], className)}>
      <VerdictMark state={state} />
      {record !== undefined && <span className={styles.verdictRecord}>{record}</span>}
      <span className={styles.verdictWord}>{VERDICT_WORD[state]}</span>
    </span>
  );
}

/* ============================================================ Hatch ======= */

export interface HatchProps {
  /** Sits on top of the pattern, on a solid ground, so the words stay readable. */
  children?: ReactNode | undefined;
  /** Render as a bordered block rather than as a bare fill. */
  block?: boolean | undefined;
  className?: string | undefined;
}

export function Hatch({ children, block = false, className }: HatchProps) {
  return (
    <div className={cx(styles.hatch, block && styles.hatchBlock, className)}>
      {children !== undefined && <span className={styles.hatchLabel}>{children}</span>}
    </div>
  );
}

/* =========================================================== Button ======= */

type ButtonVariant = "primary" | "quiet";

export type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & { variant?: ButtonVariant };

export function Button({ variant = "primary", className, type = "button", ...rest }: ButtonProps) {
  return (
    <button
      type={type}
      className={cx(styles.button, variant === "quiet" && styles.buttonQuiet, className)}
      {...rest}
    />
  );
}

export type ButtonLinkProps = AnchorHTMLAttributes<HTMLAnchorElement> & { variant?: ButtonVariant };

export function ButtonLink({ variant = "primary", className, ...rest }: ButtonLinkProps) {
  return (
    <a className={cx(styles.button, variant === "quiet" && styles.buttonQuiet, className)} {...rest} />
  );
}

/* ============================================================ Field ======= */

export type FieldProps = Omit<InputHTMLAttributes<HTMLInputElement>, "id"> & {
  id: string;
  label: ReactNode;
  /** A unit or a venue, sitting inside the shell to the right of the value. */
  suffix?: ReactNode | undefined;
  hint?: ReactNode | undefined;
  invalid?: boolean | undefined;
};

export function Field({ id, label, suffix, hint, invalid = false, className, ...rest }: FieldProps) {
  const hintId = hint !== undefined ? `${id}-hint` : undefined;
  return (
    <div className={cx(styles.field, className)}>
      <label className={styles.fieldLabel} htmlFor={id}>
        {label}
      </label>
      <div className={cx(styles.fieldShell, invalid && styles.fieldShellInvalid)}>
        <input
          id={id}
          className={styles.fieldInput}
          aria-invalid={invalid || undefined}
          aria-describedby={hintId}
          {...rest}
        />
        {suffix !== undefined && <span className={styles.fieldSuffix}>{suffix}</span>}
      </div>
      {hint !== undefined && (
        <p className={styles.fieldHint} id={hintId}>
          {hint}
        </p>
      )}
    </div>
  );
}
