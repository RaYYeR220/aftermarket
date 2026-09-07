import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { Button, ButtonLink, Field, Figure, Hatch, Panel, Rail, Readout, VerdictChip } from "@/components/primitives";
import { SourceFigure } from "@/components/shelf/SourceFigure";
import { Verdict, VERDICT_MEANING } from "@/lib/verdict";

import styles from "./kitchen-sink.module.css";

/**
 * Every primitive, in every state it ships in.
 *
 * A development surface, not a page: it is `notFound()` in production so it
 * never appears in the nav, the sitemap or a crawl.
 */
export const metadata: Metadata = {
  title: "Primitives",
  robots: { index: false, follow: false },
};

const VERDICTS = [
  Verdict.TRUSTED,
  Verdict.TRUSTED_CLOSED,
  Verdict.UNTRUSTED_STALE,
  Verdict.UNTRUSTED_DIVERGENT,
  Verdict.UNTRUSTED_THIN,
  Verdict.UNTRUSTED_HALTED,
];

export default function KitchenSink() {
  if (process.env.NODE_ENV === "production") notFound();

  return (
    <div className={`wrap ${styles.page}`}>
      <h1 className={styles.title}>Shelf primitives</h1>
      <p className={styles.intro}>
        Eight components carry the whole product: Panel, Rail, Figure, Readout, Verdict, Hatch, Button and Field.
        Each one is shown below in the states it actually ships in, so a change to a token can be judged against
        all of them at once.
      </p>

      <section className={styles.group}>
        <div className={styles.groupHead}>
          <h2 className={styles.groupName}>Panel</h2>
          <p className={styles.groupNote}>housing · plain · flush</p>
        </div>
        <div className={styles.row}>
          <Panel className={styles.cell} title="Session policy" note="block 50986493">
            <Readout value="100h" label="staleness budget" />
          </Panel>
          <Panel className={styles.cell} variant="plain" title="Untitled surface">
            <Readout value="3.00%" label="divergence band" />
          </Panel>
          <Panel className={styles.cell} variant="flush">
            <Readout value="$281.14" label="AMZN, marked to pool" />
          </Panel>
        </div>
      </section>

      <section className={styles.group}>
        <div className={styles.groupHead}>
          <h2 className={styles.groupName}>Rail</h2>
          <p className={styles.groupNote}>lead · control · reading · hint</p>
        </div>
        <Rail
          className={styles.wide}
          lead={<Readout value="Mon 07 Sep" label="Labor Day" size="sm" />}
          trailing={<Readout value="50%" label="advance rate" align="right" />}
          hint="The centre cell takes any control. On the landing page it takes the session scrubber."
        >
          <Hatch className={styles.hatchDemo} />
        </Rail>
      </section>

      <section className={styles.group}>
        <div className={styles.groupHead}>
          <h2 className={styles.groupName}>Figure</h2>
          <p className={styles.groupNote}>a drawing sheet with a caption that survives the callouts dropping out</p>
        </div>
        <Figure
          captionAlways
          caption={
            <>
              <span>
                <b>Four</b> readings
              </span>
              <span>
                <b>One</b> plate
              </span>
              <span>
                <b>Six</b> possible verdicts
              </span>
            </>
          }
        >
          <SourceFigure />
        </Figure>
      </section>

      <section className={styles.group}>
        <div className={styles.groupHead}>
          <h2 className={styles.groupName}>Readout</h2>
          <p className={styles.groupNote}>sm · md · lg · unavailable</p>
        </div>
        <div className={styles.row}>
          <Readout size="sm" value="58h 18m" label="feed age" />
          <Readout value="$70,956" label="pool depth" />
          <Readout size="lg" value="9.10%" label="feed against pool" />
          <Readout value={null} label="pool price" />
        </div>
      </section>

      <section className={styles.group}>
        <div className={styles.groupHead}>
          <h2 className={styles.groupName}>Verdict</h2>
          <p className={styles.groupNote}>six states, each with a mark as well as a colour</p>
        </div>
        <div className={styles.stack}>
          {VERDICTS.map((state) => (
            <div key={state} className={styles.row}>
              <VerdictChip state={state} record="AMZN 0907-02" />
              <p className={styles.groupNote}>{VERDICT_MEANING[state]}</p>
            </div>
          ))}
        </div>
      </section>

      <section className={styles.group}>
        <div className={styles.groupHead}>
          <h2 className={styles.groupName}>Hatch</h2>
          <p className={styles.groupNote}>one pattern, one meaning</p>
        </div>
        <div className={styles.stack}>
          <Hatch className={styles.wide} block>
            No defensible mark between Fri 16:00 ET and Tue 09:30 ET
          </Hatch>
          <Hatch className={styles.wide} />
        </div>
      </section>

      <section className={styles.group}>
        <div className={styles.groupHead}>
          <h2 className={styles.groupName}>Button</h2>
          <p className={styles.groupNote}>primary · quiet · disabled · link</p>
        </div>
        <div className={styles.row}>
          <Button>Open a line</Button>
          <Button variant="quiet">Read the oracle</Button>
          <Button disabled>Waiting for your wallet…</Button>
          <ButtonLink variant="quiet" href="#">
            Repay in full
          </ButtonLink>
        </div>
      </section>

      <section className={styles.group}>
        <div className={styles.groupHead}>
          <h2 className={styles.groupName}>Field</h2>
          <p className={styles.groupNote}>label · suffix · hint · invalid</p>
        </div>
        <div className={styles.row}>
          <Field
            className={styles.cell}
            id="ks-draw"
            label="Draw"
            defaultValue="12,500.00"
            suffix="USDC"
            hint="Headroom is $18,204 while the market is shut."
            inputMode="decimal"
          />
          <Field
            className={styles.cell}
            id="ks-draw-invalid"
            label="Draw"
            defaultValue="46,000.00"
            suffix="USDC"
            invalid
            hint="That is past the limit this session allows."
            inputMode="decimal"
          />
        </div>
      </section>
    </div>
  );
}
