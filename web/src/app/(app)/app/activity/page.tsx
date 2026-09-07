import type { Metadata } from "next";

import { appStyles, AddressLink, Bay, ReadFailure } from "@/components/app";
import { DecisionLog } from "@/components/app/DecisionLog";
import { Readout } from "@/components/primitives";
import { DEPLOYMENT } from "@/lib/deployment";
import { readActivity } from "@/server/activity";
import { orderedAssets, readProtocol } from "@/server/protocol";

/** Every figure on this screen is a live read of Base mainnet, so nothing here is prerendered. */
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Activity",
  description:
    "Every event the protocol has emitted inside the current window — collateral, draws, repayments, flags, seizures and the occasions the agent refused to act — each linked to its transaction.",
};

/**
 * The protocol's own log.
 *
 * A feed that only shows what happened is a marketing surface. The rows worth reading here are the
 * ones where nothing happened on purpose: an agent that stood down with its reason recorded, and a
 * line marked for seizure and then given a grace window it cannot be taken inside.
 */
export default async function ActivityScreen() {
  const data = await readProtocol();
  const protocol = data.ok ? data.value : null;

  const symbols = new Map<string, string>();
  const decimals = new Map<string, number>();
  if (protocol !== null) {
    for (const asset of orderedAssets(protocol)) {
      symbols.set(asset.address.toLowerCase(), asset.symbol);
      decimals.set(asset.address.toLowerCase(), asset.decimals);
    }
  }

  const feed = await readActivity({ limit: 80, symbols, decimals });

  return (
    <div className={appStyles.screen}>
      <Header />

      {!feed.ok ? (
        <ReadFailure what="The activity feed" error={feed.error} />
      ) : (
        <>
          <Bay
            title="The window"
            note={
              <>
                blocks {feed.value.fromBlock.toString()}–{feed.value.toBlock.toString()}
              </>
            }
          >
            <div className={appStyles.readouts}>
              <Readout size="lg" label="events" value={feed.value.entries.length.toString()} />
              <Readout size="lg" label="refusals" value={feed.value.refusalCount.toString()} />
              <Readout
                size="lg"
                label="credit engine"
                value={<AddressLink address={DEPLOYMENT.credit} />}
              />
              <Readout size="lg" label="vault" value={<AddressLink address={DEPLOYMENT.vault} />} />
              <Readout size="lg" label="agent" value={<AddressLink address={DEPLOYMENT.autoRepayer} />} />
            </div>
            <p className={appStyles.explain}>
              {feed.value.windowTruncated
                ? "The public Base endpoint caps a log query at ten thousand blocks, so this feed reads the most recent stretch rather than the whole history. Everything before it is still onchain and still readable through the explorer links below."
                : "This feed covers every block since the deployment landed, so nothing that has happened to this protocol is missing from it."}
            </p>
          </Bay>

          <Bay title="Every event" note={`${feed.value.entries.length} rows, newest first`}>
            {feed.value.entries.length === 0 ? (
              <p className={appStyles.explain}>
                Nothing has happened inside this window. The feed fills as collateral moves, lines are drawn
                against and the agent is asked whether it will act.
              </p>
            ) : (
              <DecisionLog entries={feed.value.entries} />
            )}
          </Bay>
        </>
      )}
    </div>
  );
}

function Header() {
  return (
    <header className={appStyles.head}>
      <h1 className={appStyles.headTitle}>Activity</h1>
      <p className={appStyles.headLede}>
        Everything the contracts have said, in order, with a link to the transaction that said it. Refusals are
        in here too — a flag that deferred a seizure, an agent that stood down — because a protocol that only
        publishes its successes is not being audited by anyone.
      </p>
    </header>
  );
}
