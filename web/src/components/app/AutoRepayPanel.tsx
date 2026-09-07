"use client";

import { useEffect, useMemo, useState } from "react";
import type { Address } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";

import { Button, Field, Readout } from "@/components/primitives";
import { autoRepayerAbi, spendPermissionManagerAbi } from "@/lib/abi";
import { DEPLOYMENT } from "@/lib/deployment";
import { durationHm, usdAuto, UNAVAILABLE } from "@/lib/format";
import { AUTO_REPAY_CODE, AUTO_REPAY_MEANING, AutoRepayReason, fromUsdc, toAutoRepayReason, toUsdc } from "@/lib/protocol";

import styles from "./app.module.css";
import { Bay, RefusalBlock } from "./index";
import { ActionGate, TxStatus, useTx } from "./write";

/**
 * The agent's mandate, and its current decision about this line.
 *
 * Two things are on this panel and the second one is the point. The first is the cap: a Base Spend
 * Permission naming `AutoRepayer` as spender, USDC as token, and an amount per period that the
 * manager enforces as an onchain invariant — not this protocol, and not the keeper that drives it.
 *
 * The second is `simulate`, which is a total function returning `(willAct, reason, amount)`. Every
 * reason the agent can stand down for is a distinct value, and this panel renders the reason rather
 * than the boolean, because an agent that can explain why it is *not* acting is the only kind that
 * is safe to point at somebody's collateral.
 */

/**
 * The agent's decision as the server already read it, so the first paint is a real answer rather
 * than a placeholder waiting on a browser read.
 */
export interface AutoRepayInitialState {
  enrolled: boolean;
  enabled: boolean;
  reason: number;
  willAct: boolean;
  /** USDC units, as decimal strings. */
  amount: string;
  spendable: string | null;
  maxPerExecution: string;
  minInterval: number;
  triggerHealthBps: number;
  lastExecutedAt: string;
  allowance: string;
}

export interface AutoRepayPanelProps {
  /** Whose mandate is read when no wallet is connected. */
  fallbackAddress: Address;
  initial: AutoRepayInitialState | null;
}

const REFRESH_MS = 30_000;
const ZERO_HASH = `0x${"0".repeat(64)}` as const;

/** Parses one of the server's decimal strings, or `null` when there was none. */
function parse(value: string | null | undefined): bigint | null {
  if (value === null || value === undefined) return null;
  try {
    return BigInt(value);
  } catch {
    return null;
  }
}
const DAY = 86_400;

/** A month of allowance, a year of validity: long enough to be useful, short enough to expire. */
const PERIOD_SECONDS = 30 * DAY;
const VALIDITY_SECONDS = 365 * DAY;

export function AutoRepayPanel({ fallbackAddress, initial }: AutoRepayPanelProps) {
  const { address: connected } = useAccount();
  const subject = connected ?? fallbackAddress;
  /** The server's figures describe one account; they are only a fallback while that is the subject. */
  const server = subject.toLowerCase() === fallbackAddress.toLowerCase() ? initial : null;

  const decision = useReadContract({
    address: DEPLOYMENT.autoRepayer,
    abi: autoRepayerAbi,
    functionName: "simulate",
    args: [subject],
    query: { refetchInterval: REFRESH_MS },
  });

  const enrollment = useReadContract({
    address: DEPLOYMENT.autoRepayer,
    abi: autoRepayerAbi,
    functionName: "enrollmentOf",
    args: [subject],
    query: { refetchInterval: REFRESH_MS },
  });

  const extra = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: DEPLOYMENT.autoRepayer, abi: autoRepayerAbi, functionName: "spendableFor", args: [subject] },
      { address: DEPLOYMENT.autoRepayer, abi: autoRepayerAbi, functionName: "healthBpsOf", args: [subject] },
    ],
    query: { refetchInterval: REFRESH_MS },
  });

  const at = (index: number): bigint | null => {
    const entry = extra.data?.[index];
    if (entry === undefined || entry.status !== "success") return null;
    return typeof entry.result === "bigint" ? entry.result : null;
  };

  const reason =
    decision.data === undefined
      ? server === null
        ? null
        : toAutoRepayReason(server.reason)
      : toAutoRepayReason(decision.data[1]);
  const willAct = decision.data?.[0] ?? server?.willAct ?? false;
  const amount = decision.data?.[2] ?? parse(server?.amount);
  const spendable = at(0) ?? parse(server?.spendable);
  const enrolled =
    enrollment.data !== undefined
      ? enrollment.data.permissionHash !== ZERO_HASH
      : (server?.enrolled ?? false);

  const refresh = () => {
    void decision.refetch();
    void enrollment.refetch();
    void extra.refetch();
  };

  return (
    <>
      <Bay
        title="What the agent would do right now"
        note={decision.isFetching ? "reading" : `simulate(${subject.slice(0, 6)}…${subject.slice(-4)})`}
        refused={reason !== null && reason !== AutoRepayReason.NONE}
      >
        {reason === null ? (
          <p className={styles.status}>
            {decision.isPending ? "Reading the agent…" : `The agent's decision is ${UNAVAILABLE}.`}
          </p>
        ) : reason === AutoRepayReason.NONE ? (
          <div>
            <div className={styles.readouts}>
              <Readout size="lg" label="decision" value="it would repay" />
              <Readout size="lg" label="amount" value={amount === null ? null : usdAuto(fromUsdc(amount))} />
              <Readout size="lg" label="spendable this period" value={spendable === null ? null : usdAuto(fromUsdc(spendable))} />
            </div>
            <p className={styles.explain}>{AUTO_REPAY_MEANING[reason]}</p>
          </div>
        ) : (
          <RefusalBlock
            word="the agent stands down"
            signature={`simulate returns ${AUTO_REPAY_CODE[reason]}`}
            rule={AUTO_REPAY_MEANING[reason]}
            args={[
              { key: "willAct", value: String(willAct) },
              { key: "reason", value: `${reason} · ${AUTO_REPAY_CODE[reason]}` },
              { key: "amount", value: amount === null ? UNAVAILABLE : amount.toString() },
            ]}
            figures={
              <>
                <Readout size="sm" label="repayment computed" value={amount === null ? null : usdAuto(fromUsdc(amount))} />
                <Readout size="sm" label="spendable this period" value={spendable === null ? null : usdAuto(fromUsdc(spendable))} />
                <Readout
                  size="sm"
                  label="mandate"
                  value={enrolled ? (enrollment.data?.policy.enabled ? "live" : "switched off") : "none"}
                />
              </>
            }
          />
        )}
      </Bay>

      <Mandate
        subject={subject}
        enrolled={enrolled}
        maxPerExecution={enrollment.data?.policy.maxPerExecution ?? parse(server?.maxPerExecution)}
        minInterval={enrollment.data?.policy.minInterval ?? server?.minInterval ?? null}
        triggerHealthBps={enrollment.data?.policy.triggerHealthBps ?? server?.triggerHealthBps ?? null}
        enabled={enrollment.data?.policy.enabled ?? server?.enabled ?? false}
        lastExecutedAt={enrollment.data?.lastExecutedAt ?? parse(server?.lastExecutedAt)}
        allowance={enrollment.data?.permission.allowance ?? parse(server?.allowance)}
        onDone={refresh}
      />
    </>
  );
}

/* ============================================================ mandate ==== */

function Mandate({
  subject,
  enrolled,
  maxPerExecution,
  minInterval,
  triggerHealthBps,
  enabled,
  lastExecutedAt,
  allowance,
  onDone,
}: {
  subject: Address;
  enrolled: boolean;
  maxPerExecution: bigint | null;
  minInterval: number | null;
  triggerHealthBps: number | null;
  enabled: boolean;
  lastExecutedAt: bigint | null;
  allowance: bigint | null;
  onDone: () => void;
}) {
  const [cap, setCap] = useState("50");
  const [perAction, setPerAction] = useState("25");
  const [trigger, setTrigger] = useState("115");
  const [interval, setInterval] = useState("6");

  const approve = useTx();
  const enroll = useTx();
  const update = useTx();
  const exit = useTx();
  useRefreshOnConfirm([approve.isConfirmed, enroll.isConfirmed, update.isConfirmed, exit.isConfirmed], onDone);

  /*
   * The permission hash the manager approves and the hash `enroll` stores must be the same struct,
   * so the issuing instant is fixed once per visit rather than recomputed between the two clicks.
   */
  const [issuedAt] = useState(() => Math.floor(Date.now() / 1000));

  const capRaw = toUsdc(cap);
  const perActionRaw = toUsdc(perAction);
  const triggerBps = Math.round(Number(trigger) * 100);
  const intervalSeconds = Math.round(Number(interval) * 3600);

  // The two policy fields are a uint16 and a uint32 onchain; an out-of-range value would be
  // rejected by the encoder rather than by the contract, so it is caught here instead.
  const triggerValid = Number.isFinite(triggerBps) && triggerBps > 0 && triggerBps <= 65_535;
  const intervalValid = Number.isFinite(intervalSeconds) && intervalSeconds >= 0 && intervalSeconds <= 4_294_967_295;
  const valid =
    capRaw !== null && capRaw > 0n && perActionRaw !== null && perActionRaw > 0n && triggerValid && intervalValid;

  /**
   * The permission is derived from the form rather than stored, so the exact struct shown here is
   * the struct both calls receive. The salt is fixed to the account so that re-granting replaces the
   * same permission at the manager instead of accumulating dead ones.
   */
  const permission = useMemo(
    () => ({
      account: subject,
      spender: DEPLOYMENT.autoRepayer,
      token: DEPLOYMENT.usdc,
      allowance: capRaw ?? 0n,
      period: PERIOD_SECONDS,
      start: issuedAt,
      end: issuedAt + VALIDITY_SECONDS,
      salt: BigInt(subject),
      extraData: "0x" as const,
    }),
    [capRaw, issuedAt, subject],
  );

  const policy = {
    maxPerExecution: perActionRaw ?? 0n,
    minInterval: intervalSeconds,
    triggerHealthBps: triggerBps,
    enabled: true,
  };

  return (
    <>
      <Bay
        title={enrolled ? "The mandate in force" : "Grant a spend cap"}
        lede={
          enrolled
            ? "Everything the agent could otherwise decide for itself — how much, how often, how bad it has to get — is fixed here by the account that pays."
            : "A Base Spend Permission names this agent as the spender, USDC as the token and a ceiling per period. The manager enforces that ceiling as an onchain invariant: no bug in this protocol and no misbehaving keeper can move more than you authorise."
        }
        note={enrolled ? (enabled ? "live" : "switched off") : "not enrolled"}
      >
        {enrolled && (
          <div className={styles.readouts}>
            <Readout size="lg" label="cap per action" value={maxPerExecution === null ? null : usdAuto(fromUsdc(maxPerExecution))} />
            <Readout size="lg" label="allowance per period" value={allowance === null ? null : usdAuto(fromUsdc(allowance))} />
            <Readout
              size="lg"
              label="acts below"
              value={triggerHealthBps === null ? null : `${(triggerHealthBps / 100).toFixed(0)}% health`}
            />
            <Readout
              size="lg"
              label="minimum interval"
              value={minInterval === null ? null : minInterval === 0 ? "none" : durationHm(minInterval)}
            />
            <Readout
              size="lg"
              label="last acted"
              value={
                lastExecutedAt === null || lastExecutedAt === 0n
                  ? "never"
                  : new Date(Number(lastExecutedAt) * 1000).toISOString().replace("T", " ").slice(0, 16)
              }
            />
          </div>
        )}

        <div className={`${styles.split} ${enrolled ? styles.stacked : ""}`}>
          <div className={styles.form}>
            <Field
              id="ar-cap"
              label="Allowance per 30 days"
              value={cap}
              onChange={(event) => setCap(event.target.value)}
              inputMode="decimal"
              autoComplete="off"
              suffix="USDC"
              invalid={capRaw === null}
              hint="The hard ceiling the manager enforces. The agent can never spend past this in a period, whatever it decides."
            />
            <Field
              id="ar-per-action"
              label="Cap per single repayment"
              value={perAction}
              onChange={(event) => setPerAction(event.target.value)}
              inputMode="decimal"
              autoComplete="off"
              suffix="USDC"
              invalid={perActionRaw === null}
              hint="If the line needs more than this, the agent refuses outright rather than spending what it is allowed. A cap that clamps can be drained in small bites; a cap that refuses cannot."
            />
          </div>
          <div className={styles.form}>
            <Field
              id="ar-trigger"
              label="Act below this health"
              value={trigger}
              onChange={(event) => setTrigger(event.target.value)}
              inputMode="decimal"
              autoComplete="off"
              suffix="% of threshold"
              invalid={!triggerValid}
              hint="100% sits exactly on the seizure threshold, so anything above it buys margin before seizure is possible at all."
            />
            <Field
              id="ar-interval"
              label="Minimum time between actions"
              value={interval}
              onChange={(event) => setInterval(event.target.value)}
              inputMode="decimal"
              autoComplete="off"
              suffix="hours"
              invalid={!intervalValid}
              hint="The agent stands down inside this window even if the line still qualifies."
            />
          </div>
        </div>

        <div className={styles.stacked}>
          <ActionGate>
            <div className={styles.formActions}>
              <Button
                variant="quiet"
                disabled={!valid || approve.isSending || approve.isConfirming}
                onClick={() =>
                  void approve.send({
                    address: DEPLOYMENT.spendPermissionManager,
                    abi: spendPermissionManagerAbi,
                    functionName: "approve",
                    args: [permission],
                  })
                }
              >
                {approve.isSending || approve.isConfirming ? "Approving…" : "1 · Approve the cap at the manager"}
              </Button>
              <Button
                disabled={!valid || enroll.isSending || enroll.isConfirming}
                onClick={() =>
                  void enroll.send({
                    address: DEPLOYMENT.autoRepayer,
                    abi: autoRepayerAbi,
                    functionName: "enroll",
                    args: [permission, policy],
                  })
                }
              >
                {enroll.isSending || enroll.isConfirming ? "Granting…" : "2 · Grant the mandate"}
              </Button>
              {enrolled && (
                <Button
                  variant="quiet"
                  disabled={!valid || update.isSending || update.isConfirming}
                  onClick={() =>
                    void update.send({
                      address: DEPLOYMENT.autoRepayer,
                      abi: autoRepayerAbi,
                      functionName: "setPolicy",
                      args: [policy],
                    })
                  }
                >
                  {update.isSending || update.isConfirming ? "Updating…" : "Change the mandate only"}
                </Button>
              )}
            </div>
          </ActionGate>
          <TxStatus tx={approve} done="Cap approved at the manager." />
          <TxStatus tx={enroll} done="Mandate granted. The agent may now act inside it." />
          <TxStatus tx={update} done="Mandate changed." />
          <p className={styles.status}>
            Two transactions, and they are separable on purpose: the first grants an allowance at Coinbase&rsquo;s
            manager, the second tells this agent what it may do inside that allowance. Changing the mandate
            afterwards never needs a new permission.
          </p>
        </div>
      </Bay>

      {enrolled && (
        <Bay title="Stand the agent down" lede="Two exits, and the difference matters.">
          <ActionGate>
            <div className={styles.formActions}>
              <Button
                variant="quiet"
                disabled={exit.isSending || exit.isConfirming}
                onClick={() =>
                  void exit.send({
                    address: DEPLOYMENT.autoRepayer,
                    abi: autoRepayerAbi,
                    functionName: "withdraw",
                    args: [],
                  })
                }
              >
                Withdraw the mandate
              </Button>
              <Button
                disabled={exit.isSending || exit.isConfirming}
                onClick={() =>
                  void exit.send({
                    address: DEPLOYMENT.autoRepayer,
                    abi: autoRepayerAbi,
                    functionName: "cancel",
                    args: [],
                  })
                }
              >
                Withdraw and revoke the permission
              </Button>
            </div>
          </ActionGate>
          <TxStatus tx={exit} done="The agent has no authority over this account." />
          <p className={styles.status}>
            Withdrawing deletes the mandate and leaves the permission in place, so re-enrolling later costs no
            signature. Cancelling also hands the permission back to the manager, which makes the allowance
            provably dead onchain rather than merely unreachable through this contract.
          </p>
        </Bay>
      )}
    </>
  );
}

/** Re-reads the mandate and the agent's decision once a transaction has landed in a block. */
function useRefreshOnConfirm(flags: boolean[], onDone: () => void) {
  const anyConfirmed = flags.some(Boolean);
  useEffect(() => {
    if (anyConfirmed) onDone();
    // The callback is rebuilt on every render of the parent; depending on it would refetch forever.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [anyConfirmed]);
}
