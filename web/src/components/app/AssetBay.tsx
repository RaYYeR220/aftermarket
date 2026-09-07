import { Readout, VerdictChip } from "@/components/primitives";
import { bpsAsWholePercent, bpsExact, durationHm, price, usdCompact, UNAVAILABLE } from "@/lib/format";
import { VERDICT_WORD } from "@/lib/verdict";
import type { AssetSnapshot, ProtocolSnapshot } from "@/server/protocol";

import { AddressLink, Bay, Meter, RefusalBlock, SourceRow, Sources } from "./index";
import styles from "./app.module.css";

/**
 * One listed asset, read left to right: what it is, what its two sources say, how far apart they
 * are against the band this session allows, and what the protocol will therefore do about it.
 *
 * An asset the oracle refuses does not merely go red. Its classification rule darkens, its policy
 * column reports no mark, and a refusal record opens under the whole row carrying the rule, the
 * measured value, the limit and the instant a defensible number is next expected. No dollar figure
 * is printed anywhere on a refused row: the quote still holds a computable mark, and printing it
 * would be quoting a price the protocol has just declined to stand behind.
 */
export function AssetBay({ asset, protocol }: { asset: AssetSnapshot; protocol: ProtocolSnapshot }) {
  const { quote, refusal } = asset;
  const refused = refusal !== null;
  const untilOpen = Math.max(0, protocol.nextOpenUnix - protocol.blockTimestampUnix);

  return (
    <Bay refused={refused} label={`${asset.underlying}, ${asset.symbol}`}>
      <div className={styles.assetGrid}>
        <div className={styles.assetIdentity}>
          <span className={styles.assetUnderlying}>{asset.underlying}</span>
          <span className={styles.assetTicker}>
            {asset.symbol} · {asset.decimals} dec
          </span>
          <div className={styles.assetMeta}>
            <span className={styles.mono}>
              oracle <AddressLink address={asset.oracle} />
            </span>
            <span className={styles.mono}>
              token <AddressLink address={asset.address} />
            </span>
            <span className={styles.mono}>
              posted {asset.postedTokens.toLocaleString("en-US", { maximumFractionDigits: 6 })} of{" "}
              {asset.capTokens.toLocaleString("en-US", { maximumFractionDigits: 0 })} cap
            </span>
          </div>
        </div>

        <Sources>
          <SourceRow
            kind="feed"
            name="Chainlink"
            value={quote === null ? null : price(quote.anchorUsd)}
            aside={quote === null ? "no answer" : `last printed ${durationHm(quote.feedAgeSeconds)} ago`}
          />
          <SourceRow
            kind="pool"
            name="Aerodrome"
            value={quote === null ? null : price(quote.poolUsd)}
            aside={quote === null ? "no answer" : `${usdCompact(quote.poolLiquidityUsd)} of depth`}
          />
        </Sources>

        <div className={styles.assetInstruments}>
          <Meter
            value={quote === null ? null : quote.divergenceBps}
            limit={quote?.divergenceBandBps ?? 0}
            valueLabel={quote === null ? UNAVAILABLE : bpsExact(quote.divergenceBps)}
            limitLabel={quote === null ? UNAVAILABLE : `${quote.divergenceBandBps} bps`}
          />
          <Meter
            value={quote === null ? null : quote.feedAgeSeconds}
            limit={quote?.stalenessBudgetSeconds ?? 0}
            valueLabel={quote === null ? UNAVAILABLE : durationHm(quote.feedAgeSeconds)}
            limitLabel={quote === null ? UNAVAILABLE : durationHm(quote.stalenessBudgetSeconds)}
          />
        </div>

        <div className={styles.assetPolicy}>
          <VerdictChip state={asset.verdict} />
          <div className={styles.assetPolicyRow}>
            <Readout
              size="sm"
              label="mark lent against"
              value={refused || quote === null ? null : price(quote.markBorrowUsd)}
            />
            <Readout
              size="sm"
              label="haircut applied"
              value={quote === null ? null : bpsExact(quote.haircutBps)}
            />
          </div>
          <div className={styles.assetPolicyRow}>
            <Readout size="sm" label="advance rate" value={bpsAsWholePercent(asset.advanceBps)} />
            <Readout size="sm" label="borrow APR" value={`${asset.borrowAprPercent.toFixed(2)}%`} />
          </div>
        </div>

        {refusal !== null && (
          <div className={styles.assetRefusal}>
            <RefusalBlock
              word={VERDICT_WORD[asset.verdict]}
              signature={`price() reverts · ${refusal.signature}`}
              rule={refusal.rule}
              figures={
                <>
                  <Readout size="sm" label="measured" value={refusal.observed} />
                  <Readout size="sm" label="allowed in this session" value={refusal.allowed} />
                  <Readout size="sm" label="next defensible print" value={`in ${durationHm(untilOpen)}`} />
                  <Readout
                    size="sm"
                    label="posted, now counted as zero"
                    value={`${asset.postedTokens.toLocaleString("en-US", { maximumFractionDigits: 8 })} ${asset.symbol}`}
                  />
                </>
              }
            />
          </div>
        )}
      </div>
    </Bay>
  );
}
