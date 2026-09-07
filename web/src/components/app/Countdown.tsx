"use client";

import { useEffect, useState } from "react";

import { durationHm } from "@/lib/format";

export interface CountdownProps {
  /** The instant being counted down to, in unix seconds. */
  targetUnix: number;
  /** What the server measured the remaining time to be. Rendered until the browser takes over. */
  initial: string;
  /** Printed once the instant has passed. */
  passed?: string | undefined;
}

/**
 * The time left until the next defensible print.
 *
 * The first render is the server's own figure, so hydration matches exactly and a reader with
 * JavaScript disabled still sees a true number; the browser only takes over on the first tick.
 * Seconds are shown once the target is under an hour, because at that range a reader is waiting
 * rather than planning.
 */
export function Countdown({ targetUnix, initial, passed = "now" }: CountdownProps) {
  const [text, setText] = useState(initial);

  useEffect(() => {
    const tick = () => {
      const remaining = targetUnix - Math.floor(Date.now() / 1000);
      if (remaining <= 0) {
        setText(passed);
        return;
      }
      if (remaining < 3600) {
        const minutes = Math.floor(remaining / 60);
        const seconds = remaining % 60;
        setText(`${minutes}m ${String(seconds).padStart(2, "0")}s`);
        return;
      }
      setText(durationHm(remaining));
    };

    tick();
    const timer = window.setInterval(tick, 1000);
    return () => window.clearInterval(timer);
  }, [passed, targetUnix]);

  return <>{text}</>;
}
