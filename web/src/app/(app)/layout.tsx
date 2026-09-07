import { AppMasthead, SessionStrip } from "@/components/app/Chrome";
import { Footer } from "@/components/landing/Chrome";
import { readProtocol } from "@/server/protocol";

/**
 * Nothing on this surface is prerendered. Every screen states the block it was read at, and a
 * figure baked in at build time would be a claim about a block that has long since passed.
 */
export const dynamic = "force-dynamic";

/**
 * The shell every application route renders inside.
 *
 * Three fixed elements: the wordmark and account control, the screen index, and the session band
 * that states where the US market is and what that currently costs. The session band is on every
 * screen rather than on the one screen that happens to be about it, because it is the context that
 * decides what the protocol will and will not do at this moment.
 */
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const data = await readProtocol();
  const protocol = data.ok ? data.value : null;

  return (
    <>
      <AppMasthead />
      <SessionStrip protocol={protocol} />
      <main className="wrap">{children}</main>
      <Footer blockNumber={protocol === null ? null : protocol.blockNumber.toString()} />
    </>
  );
}
