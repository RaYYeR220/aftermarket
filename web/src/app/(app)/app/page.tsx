import { redirect } from "next/navigation";

/**
 * `/app` has no screen of its own.
 *
 * The seven screens are peers rather than a hierarchy under a dashboard, and Markets is the one
 * that needs no account, no wallet and no context to be worth reading -- so that is where an
 * unannounced visitor lands.
 */
export default function AppIndex(): never {
  redirect("/app/markets");
}
