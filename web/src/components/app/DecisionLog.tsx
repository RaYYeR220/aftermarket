import { shortAddress } from "@/lib/format";
import type { ActivityEntry } from "@/server/activity";

import { AddressLink, BlockLink, Cell, TxLink } from "./index";
import styles from "./app.module.css";

/**
 * A ledger of protocol events, including the ones where it declined to act.
 *
 * Refusals carry the hatch along their bottom edge and a rule down their left, so a reader
 * scanning the column can see restraint without reading a word of it. Every row links to the
 * transaction that produced it, because a log nobody can check is a claim.
 */
export function DecisionLog({ entries }: { entries: ActivityEntry[] }) {
  return (
    <div className={styles.ledger}>
      <div className={`${styles.feedRow} ${styles.ledgerHead}`}>
        <span>block</span>
        <span>what happened</span>
        <span>detail</span>
        <span>account</span>
      </div>
      {entries.map((entry) => (
        <div
          className={`${styles.feedRow} ${entry.isRefusal ? styles.feedRowRefusal : ""}`}
          key={entry.id}
        >
          <Cell label="block" className={styles.mono}>
            <BlockLink blockNumber={entry.blockNumber} />
          </Cell>
          <Cell label="what happened">
            <span className={styles.feedHeadline}>{entry.headline}</span>
            <span className={styles.feedEvent}>
              {entry.event} · <TxLink hash={entry.transactionHash} label={shortAddress(entry.transactionHash)} />
            </span>
          </Cell>
          <Cell label="detail" className={styles.feedDetail}>
            {entry.detail ?? ""}
          </Cell>
          <Cell label="account" className={styles.mono}>
            {entry.actor === null ? "" : <AddressLink address={entry.actor} />}
          </Cell>
        </div>
      ))}
    </div>
  );
}
