"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";

import { Figure, Rail, Readout } from "@/components/primitives";
import { etStamp, UNAVAILABLE, usdAuto } from "@/lib/format";
import type { RailSegment, RailTimeline } from "@/server/calendar";

import type { ShelfModel } from "./model";
import { buildShelfScene } from "./scene";
import { SceneSvg } from "./SceneSvg";
import styles from "./ShelfStage.module.css";

/**
 * The hero object and the control that drives it.
 *
 * One orchestrated moment happens on this page and this is it: on load the
 * handle sweeps once from the last open session to now, and the ceiling plate
 * comes down as the closing bell passes. It is the product thesis, not an
 * entrance animation, and nothing else on the page moves on its own.
 *
 * The spring is lightly under-damped so the plate settles rather than snapping:
 * it reads as a physical part coming to rest on its pins. Under
 * `prefers-reduced-motion` there is no sweep and no spring -- the closed state
 * renders directly, and dragging the handle still works.
 */

const SPRING_K = 168;
const SPRING_C = 20.5;
const REVEAL_MS = 1500;
const SCRUB_STEPS = 1000;

function easeInOutCubic(t: number): number {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

function segmentAt(segments: readonly RailSegment[], unix: number): RailSegment | undefined {
  return segments.find((segment) => unix >= segment.fromUnix && unix < segment.toUnix) ?? segments.at(-1);
}

export interface ShelfStageProps {
  model: ShelfModel;
  timeline: RailTimeline;
  /** Server-rendered copy, placed in the left column of the stage. */
  children: ReactNode;
  label: string;
  /**
   * Draw the column with no ceiling: an oracle in the basket refuses to publish a mark, so the
   * protocol reports no borrowing power at all and there is no height at which a plate would be
   * true.
   */
  frozen?: boolean | undefined;
}

export function ShelfStage({ model, timeline, children, label, frozen = false }: ShelfStageProps) {
  const span = timeline.endUnix - timeline.startUnix;
  const nowFraction = Math.min(1, Math.max(0, (timeline.nowUnix - timeline.startUnix) / span));

  const limitAt = useCallback(
    (fraction: number) => {
      const unix = timeline.startUnix + fraction * span;
      const segment = segmentAt(timeline.segments, unix);
      return segment?.isOpen ? model.limitFractionOpen : model.limitFractionClosed;
    },
    [model.limitFractionClosed, model.limitFractionOpen, span, timeline.segments, timeline.startUnix],
  );

  const [scrub, setScrub] = useState(nowFraction);
  const [limitFraction, setLimitFraction] = useState(() => limitAt(nowFraction));

  const target = useRef(limitFraction);
  const current = useRef(limitFraction);
  const velocity = useRef(0);
  const frame = useRef<number | null>(null);
  const lastTime = useRef(0);

  const step = useCallback((now: number) => {
    const dt = Math.min((now - lastTime.current) / 1000, 1 / 30);
    lastTime.current = now;
    velocity.current += (SPRING_K * (target.current - current.current) - SPRING_C * velocity.current) * dt;
    current.current += velocity.current * dt;

    if (Math.abs(target.current - current.current) < 0.0004 && Math.abs(velocity.current) < 0.0025) {
      current.current = target.current;
      velocity.current = 0;
      setLimitFraction(current.current);
      frame.current = null;
      return;
    }
    setLimitFraction(current.current);
    frame.current = requestAnimationFrame(step);
  }, []);

  const settle = useCallback(
    (next: number, animate: boolean) => {
      target.current = next;
      if (!animate) {
        current.current = next;
        velocity.current = 0;
        setLimitFraction(next);
        return;
      }
      if (frame.current === null) {
        lastTime.current = performance.now();
        frame.current = requestAnimationFrame(step);
      }
    },
    [step],
  );

  // The one orchestrated load moment. Skipped entirely under reduced motion.
  useEffect(() => {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced) return;

    let revealFrame = 0;
    let cancelled = false;

    const run = () => {
      if (cancelled) return;
      const startedAt = performance.now();
      current.current = model.limitFractionOpen;
      velocity.current = 0;
      const advance = (now: number) => {
        if (cancelled) return;
        const progress = Math.min((now - startedAt) / REVEAL_MS, 1);
        const fraction = easeInOutCubic(progress) * nowFraction;
        setScrub(fraction);
        settle(limitAt(fraction), true);
        if (progress < 1) revealFrame = requestAnimationFrame(advance);
      };
      revealFrame = requestAnimationFrame(advance);
    };

    if (document.fonts?.ready) void document.fonts.ready.then(run);
    else run();

    return () => {
      cancelled = true;
      if (revealFrame) cancelAnimationFrame(revealFrame);
      if (frame.current !== null) {
        cancelAnimationFrame(frame.current);
        frame.current = null;
      }
    };
  }, [limitAt, model.limitFractionOpen, nowFraction, settle]);

  useEffect(
    () => () => {
      if (frame.current !== null) cancelAnimationFrame(frame.current);
    },
    [],
  );

  const onScrub = useCallback(
    (raw: number) => {
      const fraction = raw / SCRUB_STEPS;
      setScrub(fraction);
      const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      settle(limitAt(fraction), !reduced);
    },
    [limitAt, settle],
  );

  const scrubUnix = timeline.startUnix + scrub * span;
  const segment = segmentAt(timeline.segments, scrubUnix);
  const advanceRate = segment?.isOpen ? model.advanceOpen : model.advanceClosed;
  const stamp = etStamp(scrubUnix, timeline.etOffsetHours);
  const note = segment?.note ?? "Market state unavailable";

  const scene = useMemo(
    () => buildShelfScene({ model, limitFraction, frozen }),
    [model, limitFraction, frozen],
  );

  return (
    <>
      <div className={styles.stage}>
        <div className={styles.text}>{children}</div>
        <Figure
          className={styles.figure}
          caption={
            <>
              <span>
                <b>{usdAuto(scene.figures.drawnUsd)}</b> drawn
              </span>
              <span>
                <b>{scene.figures.headroomUsd === null ? UNAVAILABLE : usdAuto(scene.figures.headroomUsd)}</b> headroom
              </span>
              <span>
                <b>{scene.figures.limitUsd === null ? UNAVAILABLE : usdAuto(scene.figures.limitUsd)}</b> limit
              </span>
            </>
          }
        >
          <SceneSvg scene={scene} label={label} />
        </Figure>
      </div>

      <Rail
        lead={
          <div>
            <span className={styles.when}>{stamp}</span>
            <span className={styles.state}>{note}</span>
          </div>
        }
        trailing={
          <Readout
            className={styles.rate}
            value={`${Math.round(advanceRate * 100)}%`}
            label="advance rate"
            align="right"
          />
        }
        hint="Drag the handle to walk the session from the last close to the next open. The shelf follows."
      >
        <div className={styles.slider}>
          <div className={styles.track} aria-hidden>
            {timeline.segments
              .filter((s) => s.isOpen)
              .map((s) => (
                <span
                  key={s.fromUnix}
                  className={styles.open}
                  style={{
                    left: `${((s.fromUnix - timeline.startUnix) / span) * 100}%`,
                    width: `${((s.toUnix - s.fromUnix) / span) * 100}%`,
                  }}
                />
              ))}
          </div>
          <input
            className={styles.input}
            type="range"
            min={0}
            max={SCRUB_STEPS}
            step={1}
            value={Math.round(scrub * SCRUB_STEPS)}
            onChange={(event) => onScrub(Number(event.target.value))}
            aria-label="Move through the market session"
            aria-valuetext={`${stamp}, ${note.replace(/·/g, "-")}, advance rate ${Math.round(advanceRate * 100)}%`}
          />
        </div>
        <div className={styles.ticks} aria-hidden>
          {timeline.ticks.map((tick) => (
            <span
              key={tick.atUnix}
              className={styles.tick}
              style={{ left: `${((tick.atUnix - timeline.startUnix) / span) * 100}%` }}
            >
              {tick.label}
            </span>
          ))}
        </div>
      </Rail>
    </>
  );
}
