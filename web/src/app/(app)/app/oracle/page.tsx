import type { Metadata } from "next";

import { appStyles, AddressLink, Bay, BlockLink, Notice, ReadFailure } from "@/components/app";
import { Instrument } from "@/components/app/Instrument";
import { Readout } from "@/components/primitives";
import { DEPLOYMENT } from "@/lib/deployment";
import { bpsExact, durationHm, price, UNAVAILABLE } from "@/lib/format";
import { SESSION_LABEL } from "@/lib/session";
import { readOracleBench } from "@/server/oracle";

/** Every figure on this screen is a live read of Base mainnet, so nothing here is prerendered. */
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Oracle",
  description:
    "Both price sources for every listed asset, their ages, the divergence against each oracle's band, the haircut, and what price() actually returns — beside a negative control that differs by one deployed parameter.",
};

/**
 * The transparency screen, and the one experiment on the site.
 *
 * Two NVDAc oracles are deployed on Base mainnet. They read the same Chainlink feed, the same
 * Aerodrome pool and the same trading calendar; they were constructed with the same parameters
 * except one, the divergence band. Both are peeked and both are asked for a price inside a single
 * `aggregate3`, so what you see below is one block, one set of inputs, and two different answers.
 *
 * That is the whole argument of this protocol, reduced to something a reader can check in fifteen
 * seconds with a Basescan tab.
 */
export default async function OracleScreen() {
  const data = await readOracleBench();

  if (!data.ok) {
    return (
      <div className={appStyles.screen}>
        <Header />
        <ReadFailure what="The oracle read" error={data.error} />
      </div>
    );
  }

  const bench = data.value;
  const { production, control } = bench;
  const productionBand = production?.quote?.divergenceBandBps ?? null;
  const controlBand = control?.quote?.divergenceBandBps ?? null;
  const divergence = production?.quote?.divergenceBps ?? null;
  const session = production?.quote?.session ?? null;
  const others = bench.readings.filter((reading) => !reading.isControl && reading.ticker !== "NVDAc");

  return (
    <div className={appStyles.screen}>
      <Header />

      <Bay
        title="The negative control"
        note={
          <>
            both read at block <BlockLink blockNumber={bench.blockNumber} />
          </>
        }
        lede="Same asset. Same feed, same pool, same calendar, same block. One constructor argument different — the basis points of disagreement the oracle will tolerate before it stops publishing. One of them answers; the other reverts."
      >
        <div className={appStyles.readouts}>
          <Readout
            size="lg"
            label="measured disagreement"
            value={divergence === null ? null : bpsExact(divergence)}
          />
          <Readout
            size="lg"
            label="production band"
            value={productionBand === null ? null : `${productionBand} bps`}
          />
          <Readout size="lg" label="control band" value={controlBand === null ? null : `${controlBand} bps`} />
          <Readout
            size="lg"
            label="session in force"
            value={session === null ? null : SESSION_LABEL[session]}
          />
        </div>

        <div className={`${appStyles.diptych} ${appStyles.stacked}`}>
          {production === null ? (
            <Notice strong title={`The production NVDAc oracle is ${UNAVAILABLE}`}>
              <p>This panel reads {DEPLOYMENT.lens} and holds no cache, so there is nothing to show in its place.</p>
            </Notice>
          ) : (
            <Instrument reading={production} />
          )}
          {control === null ? (
            <Notice strong title={`The negative control is ${UNAVAILABLE}`}>
              <p>This panel reads {DEPLOYMENT.negativeControl} and holds no cache, so there is nothing to show in its place.</p>
            </Notice>
          ) : (
            <Instrument reading={control} />
          )}
        </div>

        <p className={appStyles.explain}>
          {production?.price?.ok === true && control?.price?.ok === false
            ? `The production oracle publishes ${price(production.price.markUsd)} because ${divergence === null ? "the two sources agree" : `${bpsExact(divergence)} of disagreement`} sits inside its ${productionBand} bps band. The control, holding the same two numbers against a ${controlBand} bps band, reverts with ${control.price.failure?.name ?? "a typed error"} and publishes nothing. Neither oracle is broken. The difference is a risk parameter, and this is what a risk parameter looks like when it is actually enforced instead of documented.`
            : "Both oracles are currently in the same state. The control exists so that a refusal can be demonstrated rather than described, and it will diverge from production the moment the two sources move more than 25 basis points apart."}
        </p>

        <div className={appStyles.stacked}>
          <div className={appStyles.readouts}>
            <Readout
              size="sm"
              label="production oracle"
              value={production === null ? null : <AddressLink address={production.address} />}
            />
            <Readout size="sm" label="control oracle" value={<AddressLink address={DEPLOYMENT.negativeControl} />} />
            <Readout
              size="sm"
              label="Morpho Blue market"
              value={
                <a
                  className={appStyles.address}
                  href={`https://app.morpho.org/base/market/${DEPLOYMENT.morphoMarketId}`}
                  rel="noreferrer"
                  target="_blank"
                >
                  {DEPLOYMENT.morphoMarketId.slice(0, 10)}…{DEPLOYMENT.morphoMarketId.slice(-6)}
                </a>
              }
            />
          </div>
        </div>
      </Bay>

      <Bay
        title="Every other listed oracle"
        note={`${others.length} instruments`}
        lede="The same panel, one per asset. An oracle that answers shows the Morpho-scale mark it returned; an oracle that refuses shows the revert it raised and the arguments the contract put inside it."
      >
        <div className={appStyles.diptych}>
          {others.map((reading) => (
            <Instrument key={reading.address} reading={reading} />
          ))}
        </div>
      </Bay>

      <Bay title="What each rule is protecting against">
        <div className={appStyles.split}>
          <div>
            <Readout size="lg" label="divergence band" value="two sources, one truth" />
            <p className={appStyles.explain}>
              A Chainlink total-return feed and an Aerodrome pool are independent enough that a manipulation of
              one shows up as disagreement with the other. When they disagree past the band, the honest answer
              is that nobody knows the price — not that the more convenient of the two is right.
            </p>
          </div>
          <div>
            <Readout size="lg" label="staleness budget" value="a price has an age" />
            <p className={appStyles.explain}>
              A frozen feed is not a stable price. The budget is generous while the market is shut, because a
              closed market is supposed to be quiet, and tight while it is open, because a live tape that stops
              printing means something has gone wrong.
              {production?.quote !== null && production?.quote !== undefined
                ? ` Right now the budget is ${durationHm(production.quote.stalenessBudgetSeconds)}.`
                : ""}
            </p>
          </div>
        </div>
      </Bay>
    </div>
  );
}

function Header() {
  return (
    <header className={appStyles.head}>
      <h1 className={appStyles.headTitle}>Oracle</h1>
      <p className={appStyles.headLede}>
        Every number the protocol acts on, and the arithmetic that decides whether it will act at all. Both
        sources, both ages, the divergence against the band, the haircut — and what <code>price()</code>{" "}
        actually returned when it was called at this block.
      </p>
    </header>
  );
}
