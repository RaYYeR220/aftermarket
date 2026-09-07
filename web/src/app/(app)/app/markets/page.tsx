import type { Metadata } from "next";

import { appStyles, Bay, ReadFailure } from "@/components/app";
import { AssetBay } from "@/components/app/AssetBay";
import { Readout } from "@/components/primitives";
import { bpsAsWholePercent, durationHm, usdAuto } from "@/lib/format";
import { SESSION_PHRASE } from "@/lib/session";
import { orderedAssets, readProtocol } from "@/server/protocol";

/** Every figure on this screen is a live read of Base mainnet, so nothing here is prerendered. */
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Markets",
  description:
    "Every listed collateral asset on Base mainnet: both price sources, their ages, the divergence against this session's band, the advance rate, the borrow rate, and the oracle's verdict.",
};

/**
 * Every listed asset, and what the protocol will do about each of them right now.
 *
 * The table is deliberately not a table: an asset is a bay with four columns, and a refused asset
 * grows a fifth full-width row carrying the refusal record. A refusal is a state this product
 * designed, so it gets the space a state deserves rather than a red word in a cell.
 */
export default async function MarketsScreen() {
  const data = await readProtocol();

  if (!data.ok) {
    return (
      <div className={appStyles.screen}>
        <Header />
        <ReadFailure what="The market read" error={data.error} />
      </div>
    );
  }

  const protocol = data.value;
  const assets = orderedAssets(protocol);
  const quoted = assets.filter((asset) => asset.refusal === null);
  const refused = assets.filter((asset) => asset.refusal !== null);
  const totalDepth = assets.reduce((sum, asset) => sum + (asset.quote?.poolLiquidityUsd ?? 0), 0);

  return (
    <div className={appStyles.screen}>
      <Header />

      <Bay title="What the protocol is willing to price" note={`block ${protocol.blockNumber.toString()}`}>
        <div className={appStyles.readouts}>
          <Readout
            label="quoting"
            value={`${quoted.length} of ${assets.length}`}
            size="lg"
          />
          <Readout label="refusing" value={`${refused.length} of ${assets.length}`} size="lg" />
          <Readout label="advance rate in force" value={bpsAsWholePercent(protocol.advanceBps)} size="lg" />
          <Readout label="pool depth behind the marks" value={usdAuto(totalDepth)} size="lg" />
          <Readout
            label="next defensible print"
            value={`in ${durationHm(Math.max(0, protocol.nextOpenUnix - protocol.blockTimestampUnix))}`}
            size="lg"
          />
        </div>
        <p className={appStyles.explain}>
          {refused.length === 0
            ? `Every listed oracle is publishing a mark ${SESSION_PHRASE[protocol.session]}. The advance rate is the only thing the session is changing.`
            : `${refused.length === 1 ? "One asset" : `${refused.length} assets`} cannot be marked ${SESSION_PHRASE[protocol.session]}. The engine counts ${refused.length === 1 ? "it" : "them"} as worth zero — it will not lend against a price it would also refuse to seize on — and ${refused.length === 1 ? "it" : "they"} cannot be taken from anyone either, for the same reason.`}
        </p>
      </Bay>

      {assets.map((asset) => (
        <AssetBay asset={asset} protocol={protocol} key={asset.address} />
      ))}
    </div>
  );
}

function Header() {
  return (
    <header className={appStyles.head}>
      <h1 className={appStyles.headTitle}>Markets</h1>
      <p className={appStyles.headLede}>
        Six tokenized equities, each priced by a Chainlink total-return feed and checked against an Aerodrome
        Slipstream pool. When the two disagree by more than the session tolerates, the oracle publishes nothing
        at all — and this screen shows you which rule it broke and by how much.
      </p>
    </header>
  );
}
