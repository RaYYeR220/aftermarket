import type { Metadata } from "next";

import { appStyles, AddressLink, Bay, Cell, ReadFailure } from "@/components/app";
import { AutoRepayPanel } from "@/components/app/AutoRepayPanel";
import { DemoStrip } from "@/components/app/Chrome";
import { Readout } from "@/components/primitives";
import { DEPLOYMENT } from "@/lib/deployment";
import { AUTO_REPAY_CODE, AutoRepayReason } from "@/lib/protocol";
import { DecisionLog } from "@/components/app/DecisionLog";
import { readActivity } from "@/server/activity";
import { readLine } from "@/server/line";
import { readProtocol } from "@/server/protocol";
import { readViewer } from "@/server/viewer";

/** Every figure on this screen is a live read of Base mainnet, so nothing here is prerendered. */
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "Auto-repay",
  description:
    "Grant a Base Spend Permission cap to the autonomous repayment agent, and read its decision log — including every occasion it refused to act, and why.",
};

/**
 * The agent, and the record of what it declined to do.
 *
 * An agent that acts is unremarkable. What makes one safe to point at somebody's collateral is that
 * it can say precisely why it is *not* acting, and that the saying is onchain: `poke` writes an
 * `AutoRepayRefused` event with the reason, so an outside party can audit restraint rather than
 * take a keeper's word for it.
 */
export default async function AutoRepayScreen() {
  const [data, viewer] = await Promise.all([readProtocol(), readViewer()]);

  if (!data.ok) {
    return (
      <div className={appStyles.screen}>
        <Header />
        <ReadFailure what="The protocol read" error={data.error} />
      </div>
    );
  }

  const lineData = await readLine(viewer.address, data.value);
  const line = lineData.ok ? lineData.value : null;
  const feed = await readActivity({ limit: 40 });
  const agentRows = feed.ok ? feed.value.entries.filter((entry) => entry.source === "agent") : [];

  return (
    <div className={appStyles.screen}>
      <Header />
      {viewer.isReference && <DemoStrip referenceLine={viewer.address} />}

      <AutoRepayPanel
        fallbackAddress={viewer.address}
        initial={
          line?.autoRepay === undefined || line?.autoRepay === null
            ? null
            : {
                enrolled: line.autoRepay.enrolled,
                enabled: line.autoRepay.enabled,
                reason: line.autoRepay.reason,
                willAct: line.autoRepay.willAct,
                amount: line.autoRepay.amountRaw.toString(),
                spendable: line.autoRepay.spendableRaw?.toString() ?? null,
                maxPerExecution: line.autoRepay.maxPerExecutionRaw.toString(),
                minInterval: line.autoRepay.minIntervalSeconds,
                triggerHealthBps: line.autoRepay.triggerHealthBps,
                lastExecutedAt: String(line.autoRepay.lastExecutedAtUnix),
                allowance: line.autoRepay.permissionAllowanceRaw.toString(),
              }
        }
      />

      <Bay
        title="The decision log"
        note={
          feed.ok ? (
            <>
              blocks {feed.value.fromBlock.toString()}–{feed.value.toBlock.toString()}
            </>
          ) : (
            "unavailable"
          )
        }
        lede="Every entry here was written by the contract, not by this interface. A refusal is an event with a reason code in it, which is the only way anyone outside the keeper can check that the agent stood down for the reason it claims."
      >
        {!feed.ok ? (
          <ReadFailure what="The decision log" error={feed.error} />
        ) : agentRows.length === 0 ? (
          <p className={appStyles.explain}>
            The agent has neither acted nor been asked to act inside this window. It writes an entry the first
            time a keeper pokes it — including the first time it declines.
          </p>
        ) : (
          <DecisionLog entries={agentRows} />
        )}
      </Bay>

      <Bay
        title="The nine answers it can give"
        note={<AddressLink address={DEPLOYMENT.autoRepayer} />}
        lede={
          <>
            <code>simulate</code> is a total function: it never reverts, for any account, any policy, or any
            behaviour of the credit engine, its oracles or the permission manager. These are the values it can
            return.
          </>
        }
      >
        <div className={appStyles.ledger}>
          <div className={`${appStyles.feedRow} ${appStyles.ledgerHead}`}>
            <span>code</span>
            <span>reason</span>
            <span>what it means</span>
            <span>outcome</span>
          </div>
          {REASONS.map((reason) => (
            <div className={appStyles.feedRow} key={reason}>
              <Cell label="code" className={appStyles.num}>
                {reason}
              </Cell>
              <Cell label="reason" className={appStyles.feedHeadline}>
                {AUTO_REPAY_CODE[reason]}
              </Cell>
              <Cell label="what it means" className={appStyles.feedDetail}>
                {SHORT[reason]}
              </Cell>
              <Cell label="outcome" className={appStyles.mono}>
                {reason === AutoRepayReason.NONE ? "acts" : "stands down"}
              </Cell>
            </div>
          ))}
        </div>
      </Bay>

      <Bay title="Where the authority comes from">
        <div className={appStyles.split}>
          <div>
            <Readout size="lg" label="the cap is not ours" value="Coinbase enforces it" />
            <p className={appStyles.explain}>
              The ceiling is enforced by{" "}
              <AddressLink address={DEPLOYMENT.spendPermissionManager} label="Coinbase's manager" />, a contract
              neither this protocol nor the keeper controls. Even a fully compromised keeper, or a bug in the
              agent&rsquo;s own sizing arithmetic, cannot move more than the account authorised.
            </p>
          </div>
          <div>
            <Readout size="lg" label="the agent holds nothing" value="zero balance, every path" />
            <p className={appStyles.explain}>
              USDC exists inside the agent only between the spend and the repayment, inside a single call, and
              the last thing it does is push its whole balance back to the borrower. There is no owner, no
              rescue function and no reason for a balance to persist.
            </p>
          </div>
        </div>
      </Bay>
    </div>
  );
}

const REASONS: readonly AutoRepayReason[] = [
  AutoRepayReason.NONE,
  AutoRepayReason.NOT_ENROLLED,
  AutoRepayReason.POLICY_DISABLED,
  AutoRepayReason.INTERVAL_NOT_ELAPSED,
  AutoRepayReason.ORACLE_UNTRUSTED,
  AutoRepayReason.LINE_HEALTHY,
  AutoRepayReason.NOTHING_TO_REPAY,
  AutoRepayReason.ABOVE_MAX_PER_EXECUTION,
  AutoRepayReason.PERMISSION_UNAVAILABLE,
];

/** One clause each, for a table that has to stay scannable. */
const SHORT: Record<AutoRepayReason, string> = {
  [AutoRepayReason.NONE]: "Every precondition holds.",
  [AutoRepayReason.NOT_ENROLLED]: "No mandate on this account.",
  [AutoRepayReason.POLICY_DISABLED]: "The mandate exists but is switched off.",
  [AutoRepayReason.INTERVAL_NOT_ELAPSED]: "It acted too recently.",
  [AutoRepayReason.ORACLE_UNTRUSTED]: "The protocol will not price this basket.",
  [AutoRepayReason.LINE_HEALTHY]: "The line is above its trigger and unflagged.",
  [AutoRepayReason.NOTHING_TO_REPAY]: "The repayment computes to zero.",
  [AutoRepayReason.ABOVE_MAX_PER_EXECUTION]: "The line needs more than the per-action cap.",
  [AutoRepayReason.PERMISSION_UNAVAILABLE]: "The permission is revoked, expired or exhausted.",
};

function Header() {
  return (
    <header className={appStyles.head}>
      <h1 className={appStyles.headTitle}>Auto-repay</h1>
      <p className={appStyles.headLede}>
        An agent that can repay on your behalf inside a cap you set, and that writes down every occasion it
        decided not to. The refusal is the feature: an automated system must never spend your USDC to fix a
        health factor derived from a price the protocol itself will not quote.
      </p>
    </header>
  );
}
