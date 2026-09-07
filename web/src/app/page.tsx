import { Footer, Masthead } from "@/components/landing/Chrome";
import landing from "@/components/landing/landing.module.css";
import {
  Evidence,
  Haircut,
  HeroCopy,
  Integrate,
  Limits,
  Mechanism,
  shelfLabel,
  StatusLine,
} from "@/components/landing/Sections";
import { buildShelfModel } from "@/components/shelf/model";
import { ShelfStage } from "@/components/shelf/ShelfStage";
import { buildRailTimeline } from "@/server/calendar";
import { readMarket } from "@/server/market-data";

/**
 * Rendered on the server against Base mainnet and refreshed every minute.
 *
 * A block is roughly two seconds on Base, so a minute-old read is honest about
 * being a read rather than a ticker, and the page says which block it came
 * from. Every branch below has an unavailable path: if the chain does not
 * answer, the page still renders and simply declines to quote a number.
 */
export const revalidate = 60;

export default async function LandingPage() {
  const data = await readMarket();
  const market = data.ok ? data.value : null;
  const model = market === null ? null : buildShelfModel(market);
  const timeline = market === null ? null : buildRailTimeline(market.blockTimestampUnix);

  return (
    <>
      <Masthead />
      <StatusLine market={market} />

      <main>
        <div className="wrap">
          {model !== null && timeline !== null ? (
            <ShelfStage model={model} timeline={timeline} label={shelfLabel(market)}>
              <HeroCopy market={market} />
            </ShelfStage>
          ) : (
            <div className={landing.heroFallback}>
              <HeroCopy market={market} />
            </div>
          )}
        </div>

        <Haircut market={market} />
        <Mechanism market={market} />
        <Evidence market={market} />
        <Limits market={market} />
        <Integrate />
      </main>

      <Footer blockNumber={market?.blockNumber ?? null} />
    </>
  );
}
