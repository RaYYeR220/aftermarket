import { SignIn } from "@/components/auth/SignIn";
import { Hatch, VerdictChip } from "@/components/primitives";
import { SourceFigure } from "@/components/shelf/SourceFigure";
import {
  bpsAsPercent,
  bpsAsWholePercent,
  bpsExact,
  durationHm,
  etDayTime,
  price,
  usd,
  usdCompact,
} from "@/lib/format";
import { ORACLES } from "@/lib/deployment";
import { DEPLOYED_PARAMS, SITE, WORKED_EXAMPLE } from "@/lib/site";
import { isTrusted, Verdict, VERDICT_MEANING } from "@/lib/verdict";
import type { AssetRead, MarketRead } from "@/server/market-data";

import styles from "./landing.module.css";

/* ------------------------------------------------------------- status line */

export function StatusLine({ market }: { market: MarketRead | null }) {
  if (market === null) {
    return (
      <div className={styles.status}>
        <div className={`wrap ${styles.statusInner}`}>
          <span className={`${styles.dot} ${styles.dotClosed}`} aria-hidden />
          <span>Base mainnet did not answer this read, so no session figures are shown.</span>
        </div>
      </div>
    );
  }

  const { session } = market;
  const offset = session.etOffsetHours;

  return (
    <div className={styles.status}>
      <div className={`wrap ${styles.statusInner}`}>
        <span className={`${styles.dot} ${session.isOpen ? "" : styles.dotClosed}`} aria-hidden />
        {session.isOpen ? (
          <span>
            US equities open · regular session. The oracle is marking to the live print, and the advance rate is
            back to <b>{bpsAsWholePercent(DEPLOYED_PARAMS.advanceOpenBps)}</b>.
          </span>
        ) : (
          <span>
            US equities closed{" "}
            {session.previousCloseUnix !== null && <b>{etDayTime(session.previousCloseUnix, offset)}</b>}, next
            defensible mark{" "}
            {session.nextOpenUnix !== null ? <b>{etDayTime(session.nextOpenUnix, offset)}</b> : <b>unavailable</b>}
            {session.gapSeconds !== null && <> — {durationHm(session.gapSeconds)} between prints</>}.
          </span>
        )}
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------- hero */

function Provenance({ asset }: { asset: AssetRead | null }) {
  if (asset === null || asset.feedPriceUsd === null || asset.poolTwapUsd === null) {
    return (
      <p className={styles.provenance}>
        Marks — the Base mainnet read did not complete, so no price is quoted here. Nothing on this page is
        filled in from memory.
      </p>
    );
  }
  return (
    <p className={styles.provenance}>
      Marks — Chainlink {asset.underlying}/USD reference feed, last print{" "}
      {asset.feedAgeSeconds !== null ? durationHm(asset.feedAgeSeconds) : "unavailable"} ago,{" "}
      <b>{price(asset.feedPriceUsd)}</b>.
      <br />
      Aerodrome {asset.ticker}/USDC pool,{" "}
      {asset.poolDepthUsd !== null ? usd(asset.poolDepthUsd) : "unavailable"} depth,{" "}
      <b>{price(asset.poolTwapUsd)}</b>. The two are{" "}
      <b>{asset.divergenceBps !== null ? bpsAsPercent(asset.divergenceBps) : "unavailable"}</b> apart.
    </p>
  );
}

export interface HeroCopyProps {
  market: MarketRead | null;
}

export function HeroCopy({ market }: HeroCopyProps) {
  const state = market === null
    ? Verdict.UNTRUSTED_HALTED
    : market.session.isOpen
      ? Verdict.TRUSTED
      : Verdict.TRUSTED_CLOSED;

  return (
    <>
      <p className={styles.record}>
        <VerdictChip state={state} record={market === null ? "no read" : `block ${market.blockNumber}`} />
      </p>
      <h1 className={styles.claim}>When the market shuts, the ceiling comes down. Nothing else moves.</h1>
      <p className={styles.lead}>
        A portfolio line of credit against Coinbase tokenized stocks on Base. While the US market is closed the
        oracle will not publish a mark it cannot defend, so your limit contracts and your collateral stays exactly
        where it is.
      </p>
      <SignIn label="Open a line" aside="Signs you in with Base. Nothing is sent and nothing is approved." />
      <Provenance asset={market?.widestDivergence ?? null} />
    </>
  );
}

/* ----------------------------------------------------------------- haircut */

function bayNote(asset: AssetRead): { mark: number | null; lines: [string, string] } {
  if (asset.feedPriceUsd === null) {
    return { mark: asset.poolTwapUsd, lines: ["feed unreadable", "no anchor to check"] };
  }
  if (!isTrusted(asset.verdict) && asset.poolTwapUsd !== null) {
    return {
      mark: asset.poolTwapUsd,
      lines: [
        "marked to pool",
        asset.feedAgeSeconds !== null ? `feed ${durationHm(asset.feedAgeSeconds)} old` : "feed age unknown",
      ],
    };
  }
  return {
    mark: asset.feedPriceUsd,
    lines: [
      "feed and pool",
      asset.divergenceBps !== null ? `within ${bpsExact(asset.divergenceBps)}` : "not comparable",
    ],
  };
}

export function Haircut({ market }: { market: MarketRead | null }) {
  return (
    <section className={styles.band} id="mechanism">
      <div className="wrap">
        <div className={styles.bandTop}>
          <div>
            <h2>The haircut is the mechanism</h2>
            <p className={styles.delta}>
              <span className={styles.deltaFrom}>{bpsAsWholePercent(DEPLOYED_PARAMS.advanceOpenBps)}</span> →{" "}
              <span className={styles.deltaTo}>{bpsAsWholePercent(DEPLOYED_PARAMS.advanceClosedBps)}</span>
            </p>
            <p className={styles.note}>advance rate on listed collateral, market open → market closed</p>
          </div>
          <div>
            <p>
              A closed market means no new reference print, so every mark on the book is older than the pool it
              trades in. Aftermarket lowers the ceiling by{" "}
              {(DEPLOYED_PARAMS.advanceOpenBps - DEPLOYED_PARAMS.advanceClosedBps) / 100} points and stops there.
              No position is sold at a price the oracle would not publish itself.
            </p>
            <p>
              The liquidation threshold moves the other way, from{" "}
              {bpsAsWholePercent(DEPLOYED_PARAMS.liqThresholdOpenBps)} to{" "}
              {bpsAsWholePercent(DEPLOYED_PARAMS.liqThresholdClosedBps)}: with the market shut the protocol is
              less willing to seize, not more. The shelf comes down. The contents stay on it.
            </p>
          </div>
        </div>

        {market !== null && market.listed.length > 0 && (
          <dl className={styles.bays}>
            {market.listed.map((asset) => {
              const note = bayNote(asset);
              return (
                <div
                  key={asset.ticker}
                  className={`${styles.bay} ${isTrusted(asset.verdict) ? "" : styles.bayRefused}`}
                >
                  <dt>{asset.underlying}</dt>
                  <dd>{note.mark === null ? "unavailable" : price(note.mark)}</dd>
                  <small>
                    {note.lines[0]}
                    <br />
                    {note.lines[1]}
                  </small>
                </div>
              );
            })}
          </dl>
        )}
      </div>
    </section>
  );
}

/* --------------------------------------------------------------- mechanism */

const VERDICT_ORDER: Verdict[] = [
  Verdict.TRUSTED,
  Verdict.TRUSTED_CLOSED,
  Verdict.UNTRUSTED_STALE,
  Verdict.UNTRUSTED_DIVERGENT,
  Verdict.UNTRUSTED_THIN,
  Verdict.UNTRUSTED_HALTED,
];

export function Mechanism({ market }: { market: MarketRead | null }) {
  const budgetHours = Math.round((market?.session.stalenessBudgetSeconds ?? 0) / 3600);
  const band = market?.session.divergenceBandBps ?? null;

  return (
    <section className={styles.band}>
      <div className="wrap">
        <div className={styles.bandTop}>
          <div>
            <h2>Four readings, one plate</h2>
            <p className={styles.note}>
              {market === null
                ? "Session tolerances unavailable — the mainnet read did not complete."
                : `This session allows ${budgetHours} hours of staleness and ${
                    band === null ? "an unavailable" : bpsAsPercent(band, 2)
                  } of disagreement.`}
            </p>
          </div>
          <div>
            <p>
              Every quote is assembled from four onchain readings, and published only if all four agree that a
              price can be defended. The Chainlink total-return feed is the anchor. An Aerodrome
              {" "}{DEPLOYED_PARAMS.twapWindowSeconds / 60}-minute time-weighted price is the independent check on
              it. The B20 multiplier catches a split or a distribution that would otherwise look like a crash. The
              calendar says which of the six sessions we are in, and each session carries its own tolerance: one
              hour of staleness during regular trading, a hundred over a holiday weekend.
            </p>
            <p>
              When they disagree the oracle does not average them and it does not pick a side. It reverts, and the
              revert carries the reason.
            </p>
          </div>
        </div>

        <div className={styles.mechanism}>
          <SourceFigure />
          <dl className={styles.verdicts}>
            {VERDICT_ORDER.map((state) => (
              <div className={styles.verdictRow} key={state}>
                <dt>
                  <VerdictChip state={state} />
                </dt>
                <dd>
                  <p>{VERDICT_MEANING[state]}</p>
                </dd>
              </div>
            ))}
          </dl>
        </div>
      </div>
    </section>
  );
}

/* ---------------------------------------------------------------- evidence */

export function Evidence({ market }: { market: MarketRead | null }) {
  return (
    <section className={styles.band} id="evidence">
      <div className="wrap">
        <div className={styles.bandTop}>
          <div>
            <h2>What the oracle is looking at</h2>
            <p className={styles.note}>
              {market === null
                ? "Read from Base mainnet — this read did not complete."
                : `Read from Base mainnet at block ${market.blockNumber}.`}
            </p>
          </div>
          <div>
            {market === null ? (
              <p>
                The Base RPC endpoint did not answer this request. Rather than fall back to a remembered price,
                this section stays empty.
              </p>
            ) : (
              <p>
                {market.assets.length} Coinbase tokenized stocks trade on Base. {market.pricedCount} have an
                Aerodrome pool to check their reference feed against; {market.unpricedCount} do not, and cannot be
                collateral here for exactly that reason. Of the {market.listed.length} listed as collateral, the
                oracle would quote {market.quotingCount} right now and refuse {market.refusingCount}.
              </p>
            )}
          </div>
        </div>

        {market !== null && (
          <div className={styles.tableScroll}>
            <table className={styles.table}>
              <caption>
                Every row is a live read: the reference feed, the pool that checks it, and the verdict that comes
                out of the pair.
              </caption>
              <thead>
                <tr>
                  <th scope="col">Asset</th>
                  <th scope="col">Reference feed</th>
                  <th scope="col">Feed age</th>
                  <th scope="col">Pool, {DEPLOYED_PARAMS.twapWindowSeconds / 60}-min TWAP</th>
                  <th scope="col">Pool depth</th>
                  <th scope="col">Apart</th>
                  <th scope="col">Verdict</th>
                </tr>
              </thead>
              <tbody>
                {market.assets.map((asset) => (
                  <tr key={asset.ticker}>
                    <th scope="row" className={styles.tableTicker}>
                      {asset.underlying}
                      <span>{asset.isListed ? `${asset.ticker} · listed` : asset.ticker}</span>
                    </th>
                    <td className={asset.feedPriceUsd === null ? styles.tableUnavailable : undefined}>
                      {asset.feedPriceUsd === null ? "unavailable" : price(asset.feedPriceUsd)}
                    </td>
                    <td className={asset.feedAgeSeconds === null ? styles.tableUnavailable : undefined}>
                      {asset.feedAgeSeconds === null ? "unavailable" : durationHm(asset.feedAgeSeconds)}
                    </td>
                    <td className={asset.poolTwapUsd === null ? styles.tableUnavailable : undefined}>
                      {asset.poolTwapUsd === null ? "no pool" : price(asset.poolTwapUsd)}
                    </td>
                    <td className={asset.poolDepthUsd === null ? styles.tableUnavailable : undefined}>
                      {asset.poolDepthUsd === null ? "unavailable" : usdCompact(asset.poolDepthUsd)}
                    </td>
                    <td
                      className={
                        asset.divergenceBps === null
                          ? styles.tableUnavailable
                          : asset.divergenceBps > market.session.divergenceBandBps
                            ? styles.tableWide
                            : undefined
                      }
                    >
                      {asset.divergenceBps === null
                        ? "unavailable"
                        : asset.divergenceBps < 100
                          ? bpsExact(asset.divergenceBps)
                          : bpsAsPercent(asset.divergenceBps)}
                    </td>
                    <td>
                      <VerdictChip state={asset.verdict} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ limits */

export function Limits({ market }: { market: MarketRead | null }) {
  const thin = market?.assets.filter((asset) => asset.poolTwapUsd === null) ?? [];
  const refused = market?.listed.filter((asset) => !isTrusted(asset.verdict)) ?? [];
  const multiplierBps =
    market === null
      ? Math.max(...DEPLOYED_PARAMS.sessionMultiplierBps)
      : (DEPLOYED_PARAMS.sessionMultiplierBps[market.session.session] ?? 10_000);

  return (
    <section className={styles.band} id="limits">
      <div className="wrap">
        <div className={styles.bandTop}>
          <div>
            <h2>What this will not do</h2>
            <Hatch className={styles.hatchStrip} />
            <p className={styles.note}>
              The same pattern the session rail uses for a closed market: no defensible mark here.
            </p>
          </div>
          <div>
            <p>
              A protocol that refuses to mark is not a protocol without risk. It has moved the risk somewhere you
              can see it, and these are the four places it went.
            </p>
          </div>
        </div>

        <div className={styles.limits}>
          <div className={styles.limit}>
            <h3>The gap is carried, not avoided</h3>
            <p>
              If an underlying gaps down over a long weekend, nothing is liquidated while the market is shut, and
              the shortfall sits with the lenders until it reopens. That is the cost of not selling into a price
              nobody can check. It is priced into the borrow rate, which this session multiplies by{" "}
              {(multiplierBps / 10_000).toFixed(2)}× — rather than assumed away.
            </p>
          </div>

          <div className={styles.limit}>
            <h3>The independent check is thin</h3>
            <p>
              An Aerodrome pool is the only onchain price that can contradict the reference feed, and these pools
              are small. Below {usd(DEPLOYED_PARAMS.minPoolLiquidityUsd)} of depth the oracle stops believing the
              pool at all and refuses rather than marking against a price a single trade could move.
            </p>
          </div>

          <div className={styles.limit}>
            <h3>Not every tokenized stock can be collateral</h3>
            <p>
              {thin.length > 0
                ? `${thin.map((asset) => asset.underlying).join(", ")} trade on Base with a Chainlink feed and no Aerodrome pool at all. There is nothing to check the feed against, so they are not listed here.`
                : "A tokenized stock with no Aerodrome pool has nothing to check its feed against, so it is not listed as collateral here."}
            </p>
          </div>

          <div className={styles.limit}>
            <h3>A refusal is symmetric</h3>
            <p>
              {refused.length > 0
                ? `While ${refused.map((asset) => asset.underlying).join(" and ")} ${refused.length === 1 ? "is" : "are"} refused, nobody can liquidate you against `
                : "While an asset is refused, nobody can liquidate you against "}
              that collateral — and you cannot draw against it either. The protection and the restriction are the
              same rule seen from two sides.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------- integrators */

const QUICKSTART = `import { createPublicClient, http } from "viem";
import { base } from "viem/chains";
import { createOracleClient } from "${SITE.sdkPackage}";

const oracle = createOracleClient({
  publicClient: createPublicClient({ chain: base, transport: http() }),
  address: "${ORACLES.AMZNc}",
});

// peek() never reverts: the whole state, for a UI or a keeper.
const quote = await oracle.peek();

// price() reverts onchain; here the revert arrives decoded.
const mark = await oracle.price();
if (mark.ok) useMark(mark.price);
else refuse(mark.error.name, mark.error.session);`;

export function Integrate() {
  return (
    <section className={styles.band} id="integrate">
      <div className="wrap">
        <div className={styles.bandTop}>
          <div>
            <h2>The oracle is a package</h2>
            <p className={styles.note}>{SITE.sdkPackage}</p>
          </div>
          <div>
            <p>
              If you are listing a tokenized stock as collateral somewhere else, the part worth taking is the
              refusal. <code>AftermarketOracle</code> is a Morpho Blue-shaped price oracle: it answers{" "}
              <code>price()</code> with a mark, or reverts with a typed error naming the session, the age and the
              budget it blew.
            </p>
            <p>
              The package decodes those reverts for you, converts Morpho&rsquo;s 1e36 scale in both directions,
              turns a verdict into a sentence you can render, and ships optional wagmi hooks. Its{" "}
              <code>peek()</code> never reverts, so a UI or a keeper reads the full state without a try block.
            </p>
          </div>
        </div>

        <div className={styles.integrator}>
          <div>
            <pre className={styles.code}>
              <code>{QUICKSTART}</code>
            </pre>
          </div>
          <div>
            <p className={styles.note}>
              Deployed on {SITE.chainName} mainnet — one oracle per listed asset, each bound to its own feed and
              pool.
            </p>
            <dl className={styles.deployList}>
              {Object.entries(ORACLES).map(([ticker, address]) => (
                <div className={styles.deployRow} key={ticker}>
                  <dt>{ticker}</dt>
                  <dd>
                    <a href={`${SITE.explorer}/address/${address}`} rel="noreferrer">
                      {address.slice(0, 10)}…{address.slice(-6)}
                    </a>
                  </dd>
                </div>
              ))}
            </dl>
            <p className={styles.note}>
              Markets settle against Morpho Blue at a {bpsAsWholePercent(DEPLOYED_PARAMS.morphoLltvBps)} liquidation
              loan-to-value, with the session policy expressed in the mark rather than in the market parameters —
              a Morpho market carries one immutable LLTV, so session risk has to move the price, not the ceiling
              Morpho knows about.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}

/** Text for the hero drawing, so a screen reader gets the state rather than the artwork. */
export function shelfLabel(market: MarketRead | null): string {
  const shares = WORKED_EXAMPLE.sharesPerAsset;
  const session = market?.session.isOpen ? "open" : "closed";
  return (
    `An isometric shelving system standing for a worked example line: ${shares} shares of each listed tokenized stock, ` +
    "stacked one bay per asset on a base plate between four uprights. The lower part of the stack is filled solid blue — " +
    "the balance drawn. Above it a sage-green section is the remaining headroom, capped by a blue ceiling plate riding " +
    `the uprights at the borrowing limit the ${session} session allows. Above the plate the same bays continue as an ` +
    "empty wireframe: collateral this session will not lend against."
  );
}
