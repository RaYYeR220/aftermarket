import type { Metadata } from "next";

import {
  appStyles,
  AddressLink,
  Bay,
  Cell,
  Meter,
  Notice,
  ReadFailure,
  RefusalBlock,
  SessionLadder,
} from "@/components/app";
import { DemoStrip } from "@/components/app/Chrome";
import { Countdown } from "@/components/app/Countdown";
import { ButtonLink, Figure, Readout, VerdictChip } from "@/components/primitives";
import { buildLineShelf } from "@/components/shelf/line-model";
import { buildShelfScene } from "@/components/shelf/scene";
import { SceneSvg } from "@/components/shelf/SceneSvg";
import { ShelfStage } from "@/components/shelf/ShelfStage";
import { bpsAsWholePercent, durationHm, etDayTime, price, usdAuto, UNAVAILABLE } from "@/lib/format";
import { advanceBpsOf, SESSION_PHRASE, SESSION_ORDER, Session } from "@/lib/session";
import { buildRailTimeline } from "@/server/calendar";
import { readLine, type LineSnapshot } from "@/server/line";
import { readProtocol, type ProtocolSnapshot } from "@/server/protocol";
import { readViewer } from "@/server/viewer";

/** Every figure on this screen is a live read of Base mainnet, so nothing here is prerendered. */
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Your line",
  description:
    "The collateral basket, what is drawn against it, what is left, and the borrowing power contracting as the US market closes.",
};

/**
 * The core screen: one credit line, drawn.
 *
 * Solid blue is the balance drawn, sage is the headroom under the ceiling plate, and the plate is
 * the limit the engine will act on. Drag the handle under the drawing and the ceiling follows the
 * session, because the advance rate does.
 *
 * The subtle part is what happens when an oracle in the basket refuses. `AftermarketCredit` values
 * a basket leg by leg and a leg it cannot price contributes nothing to either side of the
 * calculation -- so the ceiling drops to what the remaining legs support, and the refused bay
 * floats above it as an empty cage. Meanwhile the strict public views decline to state a total at
 * all, which is why every published figure beside the drawing reads `unavailable`. Both statements
 * are true at once, and this screen makes that legible instead of picking one.
 */
export default async function LineScreen() {
  const [data, viewer] = await Promise.all([readProtocol(), readViewer()]);

  if (!data.ok) {
    return (
      <div className={appStyles.screen}>
        <Header />
        <ReadFailure what="The protocol read" error={data.error} />
      </div>
    );
  }

  const protocol = data.value;
  const lineData = await readLine(viewer.address, protocol);

  if (!lineData.ok) {
    return (
      <div className={appStyles.screen}>
        <Header />
        {viewer.isReference && <DemoStrip referenceLine={viewer.address} />}
        <ReadFailure what="The line read" error={lineData.error} />
      </div>
    );
  }

  const line = lineData.value;
  const shelf = buildLineShelf(line, protocol);
  const timeline = buildRailTimeline(protocol.blockTimestampUnix);
  const refusing = line.refusing;
  const posted = line.holdings.filter((holding) => holding.postedRaw > 0n);

  return (
    <div className={appStyles.screen}>
      <Header />
      {viewer.isReference && <DemoStrip referenceLine={viewer.address} />}

      {!line.isOpen ? (
        <Bay title="No line on this account">
          <p className={appStyles.explain}>
            {viewer.isReference
              ? "The reference line has been closed. Sign in with Base to open one of your own."
              : "Opening a line is a single transaction that costs nothing and approves nothing. You post collateral afterwards, and you can withdraw all of it at any time while the line carries no debt."}
          </p>
          <div className={appStyles.noticeActions}>
            <ButtonLink href="/app/borrow" variant="quiet">
              Open a line
            </ButtonLink>
          </div>
        </Bay>
      ) : (
        <>
          {shelf === null ? (
            <Bay title="Nothing posted yet">
              <p className={appStyles.explain}>
                The line is open and carries no collateral. Post a listed asset and the drawing appears with the
                ceiling the current session allows.
              </p>
              <div className={appStyles.noticeActions}>
                <ButtonLink href="/app/borrow" variant="quiet">
                  Post collateral
                </ButtonLink>
              </div>
            </Bay>
          ) : shelf.frozen || timeline === null ? (
            <Bay title="The line" note={`block ${protocol.blockNumber.toString()}`} refused={shelf.frozen}>
              <div className={appStyles.stage}>
                <Summary line={line} protocol={protocol} />
                <Figure className={appStyles.stageFigure}>
                  <SceneSvg
                    scene={buildShelfScene({ model: shelf.model, limitFraction: 0, frozen: true })}
                    label={`Isometric drawing of the credit line with no ceiling: ${usdAuto(line.debtUsdc)} drawn, and no leg of the basket priceable.`}
                  />
                </Figure>
              </div>
            </Bay>
          ) : (
            <Bay title="The line" note={`block ${protocol.blockNumber.toString()}`}>
              <ShelfStage
                model={shelf.model}
                timeline={timeline}
                label={`Isometric drawing of the credit line: ${usdAuto(line.debtUsdc)} drawn under a ${usdAuto(line.limits.borrowPowerUsdc ?? 0)} ceiling, on a basket of ${shelf.model.bays.length} posted assets.`}
              >
                <Summary line={line} protocol={protocol} />
              </ShelfStage>
            </Bay>
          )}

          {refusing.length > 0 && (
            <Bay title="What a refused leg does to this line" refused>
              <RefusalBlock
                word={`counted as zero · ${refusing.map((holding) => holding.symbol).join(", ")}`}
                signature="AftermarketCredit.borrowPower reverts · UnpricedCollateral(uint256)"
                rule="A leg the oracle will not mark contributes nothing to either side of the risk calculation. It is not a veto: the engine still lends against, and still seizes, everything it can price. What it will not do is publish a total for a basket it cannot fully price — which is why every strict figure on this screen reads unavailable while the ceiling above still has a height."
                figures={
                  <>
                    <Readout size="sm" label="drawn, still owed" value={usdAuto(line.debtUsdc)} />
                    <Readout
                      size="sm"
                      label="the engine will act on"
                      value={line.limits.borrowPowerUsdc === null ? null : usdAuto(line.limits.borrowPowerUsdc)}
                    />
                    <Readout size="sm" label="published borrowing power" value={null} />
                    <Readout
                      size="sm"
                      label="next defensible print"
                      value={
                        <Countdown
                          targetUnix={protocol.nextOpenUnix}
                          initial={durationHm(Math.max(0, protocol.nextOpenUnix - protocol.blockTimestampUnix))}
                          passed="the bell"
                        />
                      }
                    />
                  </>
                }
              />
              <p className={appStyles.explain}>
                The asymmetry is what keeps this safe. Ignoring a leg lowers the seizure threshold as well as
                the borrowing power, so on its own it would make deflating one leg a way to force-liquidate a
                healthy line. The refused asset therefore stays unseizable too: a liquidator reads{" "}
                <code>markLiquidate</code> directly and it still reverts. The exposure is bounded to losing
                priceable collateral at a defensible price, behind the full notice period.
              </p>
            </Bay>
          )}

          {line.flagged && (
            <Bay title="Flagged, and protected until the bell" refused>
              <Notice
                strong
                title={`You cannot be liquidated before ${etDayTime(line.graceUntilUnix, protocol.etOffsetHours)}.`}
              >
                <p>
                  This line was marked for seizure at {etDayTime(line.flaggedAtUnix, protocol.etOffsetHours)}.
                  Seizure is not possible until the grace deadline passes, and the deadline is set to half an
                  hour after the opening bell, so there is always a real market in which to trade out of
                  trouble. Repaying enough to bring the line back under its own advance rate clears the flag in
                  the same transaction.
                </p>
                <p className={appStyles.explain}>
                  Time remaining:{" "}
                  <Countdown
                    targetUnix={line.graceUntilUnix}
                    initial={durationHm(Math.max(0, line.graceUntilUnix - protocol.blockTimestampUnix))}
                    passed="the grace window has closed"
                  />
                </p>
              </Notice>
            </Bay>
          )}

          <Bay title="The basket" note={`${posted.length} posted`}>
            <div className={appStyles.ledger}>
              <div className={`${appStyles.basketRow} ${appStyles.ledgerHead}`}>
                <span>asset</span>
                <span>posted</span>
                <span>mark lent against</span>
                <span>counted as</span>
                <span>oracle</span>
              </div>
              {posted.map((holding) => (
                <div className={appStyles.basketRow} key={holding.address}>
                  <Cell label="asset">
                    <span className={appStyles.feedHeadline}>{holding.underlying}</span>
                    <span className={appStyles.feedEvent}>
                      <AddressLink address={holding.address} label={holding.symbol} />
                    </span>
                  </Cell>
                  <Cell label="posted" className={appStyles.num}>
                    {holding.postedTokens.toLocaleString("en-US", { maximumFractionDigits: 8 })}
                  </Cell>
                  <Cell
                    label="mark lent against"
                    className={holding.markUsd === null ? `${appStyles.num} ${appStyles.numQuiet}` : appStyles.num}
                  >
                    {holding.markUsd === null ? UNAVAILABLE : price(holding.markUsd)}
                  </Cell>
                  <Cell
                    label="counted as"
                    className={holding.valueUsd === null ? `${appStyles.num} ${appStyles.numQuiet}` : appStyles.num}
                  >
                    {holding.valueUsd === null ? "zero" : usdAuto(holding.valueUsd)}
                  </Cell>
                  <Cell label="oracle">
                    <VerdictChip state={holding.verdict} />
                  </Cell>
                </div>
              ))}
            </div>
          </Bay>
        </>
      )}

      <Bay
        title="What the session does to the ceiling"
        lede="The advance rate is the fraction of the basket the protocol will lend against. It is not a risk score that drifts; it is two numbers, and which one applies depends only on whether the US market is between its bells."
      >
        <SessionLadder
          entries={SESSION_ORDER.map((session) => ({
            session,
            fraction: advanceBpsOf(session) / advanceBpsOf(Session.REGULAR),
            value: bpsAsWholePercent(advanceBpsOf(session)),
            isCurrent: session === protocol.session,
          }))}
          caption={`During the regular session a borrower can react to a price and trade out of trouble, so the protocol advances more and seizes sooner. At every other hour — including pre- and post-market, which have a tape but not the depth to unwind into — nobody can hedge the gap, so it advances less and seizes later. Right now it is ${SESSION_PHRASE[protocol.session]}.`}
        />
      </Bay>
    </div>
  );
}

function Header() {
  return (
    <header className={appStyles.head}>
      <h1 className={appStyles.headTitle}>Your line</h1>
      <p className={appStyles.headLede}>
        Solid blue is what you have drawn. Sage is the headroom left under the ceiling. The plate is the limit
        the engine will act on, and it comes down when the market shuts — because the price under it stops
        being something anyone can trade against.
      </p>
    </header>
  );
}

function Summary({ line, protocol }: { line: LineSnapshot; protocol: ProtocolSnapshot }) {
  const actionable = line.limits.borrowPowerUsdc;
  const available = actionable === null ? null : Math.max(0, actionable - line.debtUsdc);

  return (
    <div>
      <div className={appStyles.readouts}>
        <Readout size="lg" label="drawn" value={usdAuto(line.debtUsdc)} />
        <Readout size="lg" label="available to draw" value={available === null ? null : usdAuto(available)} />
        <Readout
          size="lg"
          label={line.priced ? "borrowing limit" : "limit the engine will act on"}
          value={actionable === null ? null : usdAuto(actionable)}
        />
      </div>

      <div className={`${appStyles.readouts} ${appStyles.stacked}`}>
        <Readout
          size="sm"
          label="seizure threshold"
          value={
            line.limits.seizureThresholdUsdc === null ? null : usdAuto(line.limits.seizureThresholdUsdc)
          }
        />
        <Readout
          size="sm"
          label="advance rate in force"
          value={`${bpsAsWholePercent(protocol.advanceBps)} of ${bpsAsWholePercent(protocol.advanceOpenBps)} open`}
        />
        <Readout
          size="sm"
          label="published borrowing power"
          value={line.priced ? usdAuto(line.borrowPowerUsdc) : null}
        />
        <Readout
          size="sm"
          label="eligibility"
          value={line.eligible ? `admitted${line.country === null ? "" : ` · ${line.country}`}` : "not admitted"}
        />
      </div>

      {line.healthState === "measured" && line.healthBps !== null ? (
        <div className={appStyles.stacked}>
          <Meter
            value={line.healthBps}
            limit={10_000}
            valueLabel={`${(line.healthBps / 100).toFixed(1)}% of threshold`}
            limitLabel="100%"
            direction="above-is-safe"
          />
        </div>
      ) : (
        <p className={appStyles.explain}>
          {line.healthState === "no-debt"
            ? "Nothing is drawn, so there is no health to measure and nothing that can be seized."
            : "Health is a ratio of two published totals, and the engine will not publish one for a basket it cannot fully price. The debt and the acting limit above are both exact; only their ratio is withheld."}
        </p>
      )}
    </div>
  );
}
