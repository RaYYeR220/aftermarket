import { VerdictChip } from "@/components/primitives";
import { bpsExact, durationHm, price, usdCompact, UNAVAILABLE } from "@/lib/format";
import type { OracleReading } from "@/server/oracle";

import { AddressLink, Meter, SourceRow, Sources } from "./index";
import styles from "./app.module.css";

/**
 * One oracle, opened up.
 *
 * The panel is deliberately identical for every instrument, including the negative control, so that
 * placing two of them side by side leaves exactly one thing for the eye to land on: the parameter
 * that differs, and what it does to the answer.
 *
 * The block at the bottom is the point of the screen. It is not a status badge — it is what
 * `price()` actually returned at this block: a Morpho-scale mark, or the typed revert with its
 * arguments decoded, sitting on the hatch that means no defensible mark here.
 */
export function Instrument({ reading }: { reading: OracleReading }) {
  const { quote, price: outcome } = reading;

  return (
    <article className={`${styles.instrument} ${reading.isControl ? styles.instrumentControl : ""}`}>
      <header className={styles.instrumentHead}>
        <h3 className={styles.instrumentName}>{reading.label}</h3>
        {quote !== null && <VerdictChip state={quote.verdict} />}
      </header>

      <Sources>
        <SourceRow
          kind="feed"
          name="Chainlink"
          value={quote === null ? null : price(quote.anchorUsd)}
          aside={quote === null ? "no answer" : `printed ${durationHm(quote.feedAgeSeconds)} ago`}
        />
        <SourceRow
          kind="pool"
          name="Aerodrome"
          value={quote === null ? null : price(quote.poolUsd)}
          aside={quote === null ? "no answer" : `${usdCompact(quote.poolLiquidityUsd)} of depth`}
        />
      </Sources>

      <Meter
        value={quote === null ? null : quote.divergenceBps}
        limit={quote?.divergenceBandBps ?? 0}
        valueLabel={quote === null ? UNAVAILABLE : bpsExact(quote.divergenceBps)}
        limitLabel={quote === null ? UNAVAILABLE : `${quote.divergenceBandBps} bps band`}
      />

      <Answer reading={reading} />

      {reading.sentence !== null && <p className={styles.instrumentSentence}>{reading.sentence}</p>}

      <dl className={styles.instrumentFacts}>
        <Fact label="haircut applied" value={quote === null ? UNAVAILABLE : bpsExact(quote.haircutBps)} />
        <Fact
          label="staleness budget"
          value={quote === null ? UNAVAILABLE : durationHm(quote.stalenessBudgetSeconds)}
        />
        <Fact
          label="multiplier"
          value={quote === null ? UNAVAILABLE : quote.multiplier.toFixed(4)}
        />
        <Fact label="oracle" value={<AddressLink address={reading.address} />} />
        {reading.feed !== null && <Fact label="Chainlink feed" value={<AddressLink address={reading.feed} />} />}
        {reading.pool !== null && <Fact label="Aerodrome pool" value={<AddressLink address={reading.pool} />} />}
        {reading.collateralToken !== null && (
          <Fact label="collateral token" value={<AddressLink address={reading.collateralToken} />} />
        )}
      </dl>

      {outcome !== null && !outcome.ok && reading.guidance !== null && (
        <p className={styles.instrumentSentence}>{reading.guidance}</p>
      )}
    </article>
  );
}

/** What `price()` returned, verbatim: a Morpho-scale mark, or the decoded revert. */
function Answer({ reading }: { reading: OracleReading }) {
  const outcome = reading.price;

  if (outcome === null) {
    return (
      <div className={styles.instrumentAnswer}>
        <span className={styles.instrumentCall}>price() · IOracle</span>
        <span className={styles.instrumentResult}>{UNAVAILABLE}</span>
      </div>
    );
  }

  if (outcome.ok) {
    return (
      <div className={styles.instrumentAnswer}>
        <span className={styles.instrumentCall}>price() returned</span>
        <span className={styles.instrumentResult}>{price(outcome.markUsd)}</span>
        <span className={styles.instrumentCall}>{outcome.raw.toString()}</span>
      </div>
    );
  }

  return (
    <div className={`${styles.instrumentAnswer} ${styles.instrumentAnswerRefused}`}>
      <div className={styles.instrumentAnswerInner}>
        <span className={styles.instrumentCall}>price() reverted</span>
        <span className={styles.instrumentResult}>{outcome.failure?.name ?? "an undecodable revert"}</span>
        {outcome.failure !== null && (
          <p className={styles.args}>
            {outcome.failure.args.map((arg) => (
              <span className={styles.arg} key={arg.key}>
                <span className={styles.argKey}>{arg.key}</span>
                <span className={styles.argValue}>{arg.value}</span>
              </span>
            ))}
          </p>
        )}
      </div>
    </div>
  );
}

function Fact({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className={styles.factRow}>
      <dt className={styles.factKey}>{label}</dt>
      <dd className={styles.factValue}>{value}</dd>
    </div>
  );
}
