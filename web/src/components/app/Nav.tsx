"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { Route } from "next";

import styles from "./app.module.css";

/** The seven screens, in the order a reader should meet them. */
export const SCREENS: readonly { href: Route; label: string }[] = [
  { href: "/app/markets", label: "Markets" },
  { href: "/app/line", label: "Your line" },
  { href: "/app/borrow", label: "Borrow & repay" },
  { href: "/app/earn", label: "Earn" },
  { href: "/app/oracle", label: "Oracle" },
  { href: "/app/auto-repay", label: "Auto-repay" },
  { href: "/app/activity", label: "Activity" },
];

/**
 * The screen index.
 *
 * A tab strip rather than a sidebar: the app has seven screens and no hierarchy between them, and
 * a rail would move the content column off the page measure the masthead and the footer already
 * share. The active screen is marked by a 2px rule above it, which is the same classification rule
 * every bay on the page below carries.
 */
export function Nav() {
  const pathname = usePathname();
  return (
    <nav className={styles.nav} aria-label="Screens">
      {SCREENS.map((screen) => {
        const active = pathname === screen.href;
        return (
          <Link
            className={`${styles.navLink} ${active ? styles.navLinkActive : ""}`}
            href={screen.href}
            key={screen.href}
            aria-current={active ? "page" : undefined}
          >
            {screen.label}
          </Link>
        );
      })}
    </nav>
  );
}
