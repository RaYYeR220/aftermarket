"use client";

import { useEffect, useMemo, useState } from "react";
import type { Abi, Address } from "viem";
import { base } from "wagmi/chains";
import { useQuery } from "@tanstack/react-query";
import { useAccount, usePublicClient, useReadContract, useReadContracts } from "wagmi";

import { Button, Field, Readout } from "@/components/primitives";
import { creditAbi, erc20Abi, lensAbi, vaultAbi } from "@/lib/abi";
import { DEPLOYMENT } from "@/lib/deployment";
import { decodeRevert, type DecodedRevert } from "@/lib/errors";
import { usdAuto, UNAVAILABLE } from "@/lib/format";
import {
  creditErrorMeaning,
  fromUsdc,
  parseDecimal,
  PREVIEW_MEANING,
  PreviewReason,
  scaled,
  toPreviewReason,
  toUsdc,
} from "@/lib/protocol";

import styles from "./app.module.css";
import { Bay } from "./index";
import { ActionGate, TxStatus, useTx } from "./write";

/**
 * Deposit, draw, repay, withdraw -- with the session-dependent limit read live as the amount changes.
 *
 * Every amount is put to the chain twice. `AftermarketLens.previewDraw` and `previewWithdraw` are
 * total functions and supply the figures: the debt afterwards, the published borrowing power, the
 * health. The transaction itself is then simulated from the same account, and *that* is the verdict
 * the panel reports, because the two can legitimately disagree -- the lens declines to preview a
 * basket it cannot fully price, while the engine goes on acting against the legs it can price.
 *
 * Both reads work without a wallet. A visitor who has connected nothing still types an amount and
 * sees the engine's real answer for the reference line; only the send buttons need an account.
 */

export interface AssetOption {
  address: Address;
  symbol: string;
  underlying: string;
  decimals: number;
  /** True when the oracle will publish a mark for this asset right now. */
  quoting: boolean;
}

/**
 * What the server already read for {@link BorrowPanelsProps.fallbackAddress}, as decimal strings.
 *
 * The first paint of this screen is therefore real: a visitor with no wallet sees the reference
 * line's actual balances immediately, and would still see them if the browser's own read were
 * throttled by a public endpoint. The client read takes over the moment it lands, and entirely once
 * a different account is connected.
 */
export interface BorrowInitialState {
  debt: string;
  idle: string | null;
  usdcBalance: string | null;
  usdcAllowance: string | null;
  /** Indexed the same way as `assets`. */
  posted: (string | null)[];
  wallet: (string | null)[];
  allowance: (string | null)[];
}

export interface BorrowPanelsProps {
  assets: AssetOption[];
  /** Whose line is read when no wallet is connected. */
  fallbackAddress: Address;
  initial: BorrowInitialState;
}

/** Parses one of the server's decimal strings, or `null` when the server could not read it. */
function big(value: string | null | undefined): bigint | null {
  if (value === null || value === undefined) return null;
  try {
    return BigInt(value);
  } catch {
    return null;
  }
}

const REFRESH_MS = 30_000;
const USDC_DECIMALS = 6;
const MAX_UINT = 2n ** 256n - 1n;

export function BorrowPanels({ assets, fallbackAddress, initial }: BorrowPanelsProps) {
  const { address: connected } = useAccount();
  const subject = connected ?? fallbackAddress;
  /** The server's figures describe one account; they are only a fallback while that is the subject. */
  const serverKnows = subject.toLowerCase() === fallbackAddress.toLowerCase();

  const line = useReadContract({
    address: DEPLOYMENT.lens,
    abi: lensAbi,
    functionName: "userView",
    args: [subject],
    query: { refetchInterval: REFRESH_MS },
  });

  const idle = useReadContract({
    address: DEPLOYMENT.vault,
    abi: vaultAbi,
    functionName: "idleAssets",
    query: { refetchInterval: REFRESH_MS },
  });

  const balances = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: DEPLOYMENT.usdc, abi: erc20Abi, functionName: "balanceOf", args: [subject] },
      { address: DEPLOYMENT.usdc, abi: erc20Abi, functionName: "allowance", args: [subject, DEPLOYMENT.credit] },
      ...assets.flatMap((asset) => [
        { address: asset.address, abi: erc20Abi, functionName: "balanceOf", args: [subject] } as const,
        {
          address: asset.address,
          abi: erc20Abi,
          functionName: "allowance",
          args: [subject, DEPLOYMENT.credit],
        } as const,
      ]),
    ],
    query: { refetchInterval: REFRESH_MS },
  });

  const amountAt = (index: number, fallback: string | null | undefined): bigint | null => {
    const entry = balances.data?.[index];
    if (entry !== undefined && entry.status === "success" && typeof entry.result === "bigint") {
      return entry.result;
    }
    return serverKnows ? big(fallback) : null;
  };

  const posted = useMemo(() => {
    const map = new Map<string, bigint>();
    const view = line.data;
    if (view !== undefined) {
      view.collateral.forEach((address, index) => map.set(address.toLowerCase(), view.amounts[index] ?? 0n));
      return map;
    }
    if (serverKnows) {
      assets.forEach((asset, index) => {
        const amount = big(initial.posted[index]);
        if (amount !== null) map.set(asset.address.toLowerCase(), amount);
      });
    }
    return map;
  }, [assets, initial.posted, line.data, serverKnows]);

  const refreshAll = () => {
    void line.refetch();
    void idle.refetch();
    void balances.refetch();
  };

  /*
   * "No line here" is a claim, and it is only made once the lens has actually answered. While the
   * read is in flight or has failed, the invitation to open one stays hidden rather than telling a
   * borrower with a live position that they have none.
   */
  const lineKnown = line.isSuccess && line.data !== undefined;
  const serverHasLine = serverKnows && big(initial.debt) !== null;
  const hasLine =
    lineKnown && line.data !== undefined
      ? line.data.debt > 0n || line.data.collateral.length > 0
      : serverHasLine;
  const debtRaw = line.data?.debt ?? (serverKnows ? big(initial.debt) : null);
  const idleRaw = idle.data ?? big(initial.idle);
  const usdcBalance = amountAt(0, initial.usdcBalance);
  const usdcAllowance = amountAt(1, initial.usdcAllowance);

  return (
    <>
      <OpenLine hidden={(!lineKnown && !serverKnows) || hasLine} onDone={refreshAll} />

      <PostCollateral
        assets={assets}
        walletAt={(index) => amountAt(2 + index * 2, initial.wallet[index])}
        allowanceAt={(index) => amountAt(3 + index * 2, initial.allowance[index])}
        onDone={refreshAll}
      />

      <DrawUsdc subject={subject} debtRaw={debtRaw} idleRaw={idleRaw} onDone={refreshAll} />

      <RepayUsdc
        debtRaw={debtRaw}
        balanceRaw={usdcBalance}
        allowanceRaw={usdcAllowance}
        onDone={refreshAll}
      />

      <WithdrawCollateral
        subject={subject}
        assets={assets}
        postedAt={(asset) => posted.get(asset.address.toLowerCase()) ?? 0n}
        onDone={refreshAll}
      />

      {line.isError && (
        <p className={styles.status}>
          The lens did not answer for this account, so the amounts above are {UNAVAILABLE}. The figures stay
          blank rather than standing in for a number that was never read.
        </p>
      )}
    </>
  );
}

/* ========================================================== open line ==== */

function OpenLine({ hidden, onDone }: { hidden: boolean; onDone: () => void }) {
  const tx = useTx();
  useConfirmed(tx.isConfirmed, onDone);

  if (hidden) return null;

  return (
    <Bay
      title="Open a line"
      lede="One transaction, no approval, no deposit. It records that this account has a line and nothing else; collateral is posted afterwards and can be withdrawn in full while the line carries no debt."
    >
      <ActionGate>
        <div className={styles.formActions}>
          <Button
            disabled={tx.isSending || tx.isConfirming}
            onClick={() =>
              void tx.send({ address: DEPLOYMENT.credit, abi: creditAbi, functionName: "openLine", args: [] })
            }
          >
            {tx.isSending ? "Waiting for your wallet…" : tx.isConfirming ? "Opening…" : "Open line"}
          </Button>
        </div>
      </ActionGate>
      <TxStatus tx={tx} done="Line opened." />
    </Bay>
  );
}

/* ==================================================== post collateral ==== */

function PostCollateral({
  assets,
  walletAt,
  allowanceAt,
  onDone,
}: {
  assets: AssetOption[];
  walletAt: (index: number) => bigint | null;
  allowanceAt: (index: number) => bigint | null;
  onDone: () => void;
}) {
  const [index, setIndex] = useState(0);
  const [amount, setAmount] = useState("");
  const approve = useTx();
  const deposit = useTx();
  useConfirmed(approve.isConfirmed || deposit.isConfirmed, onDone);

  const asset = assets[index];
  if (asset === undefined) return null;

  const wallet = walletAt(index);
  const allowance = allowanceAt(index);
  const parsed = parseDecimal(amount, asset.decimals);
  const overBalance = parsed !== null && wallet !== null && parsed > wallet;
  const needsApproval = parsed !== null && allowance !== null && allowance < parsed;

  return (
    <Bay
      title="Post collateral"
      lede="Posting is always open. It is the one action the protocol accepts under every session and every oracle state, because more collateral can never make a line less safe."
      note={wallet === null ? UNAVAILABLE : `${scaled(wallet, asset.decimals).toLocaleString("en-US", { maximumFractionDigits: 8 })} ${asset.symbol} in wallet`}
    >
      <div className={styles.split}>
        <div className={styles.form}>
          <AssetSelect assets={assets} index={index} onChange={setIndex} id="post-asset" />
          <Field
            id="post-amount"
            label="Amount"
            value={amount}
            onChange={(event) => setAmount(event.target.value)}
            placeholder="0.00"
            inputMode="decimal"
            autoComplete="off"
            suffix={asset.symbol}
            invalid={amount !== "" && (parsed === null || overBalance)}
            hint={
              parsed === null && amount !== ""
                ? `Enter a number with at most ${asset.decimals} decimal places.`
                : overBalance
                  ? "That is more of this token than the account holds."
                  : undefined
            }
          />
          {wallet !== null && wallet > 0n && (
            <div className={styles.quickPicks}>
              <button
                className={styles.quickPick}
                type="button"
                onClick={() => setAmount(scaled(wallet, asset.decimals).toString())}
              >
                all {asset.symbol}
              </button>
            </div>
          )}
        </div>

        <div className={styles.form}>
          <ActionGate>
            <div className={styles.formActions}>
              {needsApproval && (
                <Button
                  variant="quiet"
                  disabled={approve.isSending || approve.isConfirming}
                  onClick={() =>
                    void approve.send({
                      address: asset.address,
                      abi: erc20Abi,
                      functionName: "approve",
                      args: [DEPLOYMENT.credit, MAX_UINT],
                    })
                  }
                >
                  {approve.isSending || approve.isConfirming ? "Approving…" : `Approve ${asset.symbol}`}
                </Button>
              )}
              <Button
                disabled={parsed === null || parsed === 0n || overBalance || needsApproval || deposit.isSending || deposit.isConfirming}
                onClick={() =>
                  parsed !== null &&
                  void deposit.send({
                    address: DEPLOYMENT.credit,
                    abi: creditAbi,
                    functionName: "depositCollateral",
                    args: [asset.address, parsed],
                  })
                }
              >
                {deposit.isSending ? "Waiting for your wallet…" : deposit.isConfirming ? "Posting…" : "Post collateral"}
              </Button>
            </div>
          </ActionGate>
          <TxStatus tx={approve} done={`${asset.symbol} approved.`} />
          <TxStatus tx={deposit} done="Collateral posted." />
        </div>
      </div>
    </Bay>
  );
}

/* =============================================================== draw ==== */

function DrawUsdc({
  subject,
  debtRaw,
  idleRaw,
  onDone,
}: {
  subject: Address;
  debtRaw: bigint | null;
  idleRaw: bigint | null;
  onDone: () => void;
}) {
  const [amount, setAmount] = useState("");
  const parsed = toUsdc(amount);
  const debounced = useDebounced(parsed);
  const tx = useTx();
  useConfirmed(tx.isConfirmed, onDone);

  const preview = useReadContract({
    address: DEPLOYMENT.lens,
    abi: lensAbi,
    functionName: "previewDraw",
    args: [subject, debounced ?? 0n],
    query: { enabled: debounced !== null && debounced > 0n, refetchInterval: REFRESH_MS },
  });

  /*
   * The lens preview and the engine can disagree, and when they do the engine is what happens. The
   * lens declines to preview a basket it cannot fully price; the engine goes on working against the
   * legs it can price and values the rest at zero. So the transaction itself is simulated from this
   * account, and its verdict is the one this panel reports.
   */
  const attempt = useAttempt({
    enabled: debounced !== null && debounced > 0n,
    account: subject,
    functionName: "draw",
    args: [debounced ?? 0n, subject],
  });

  const result = preview.data;
  const reason = result === undefined ? null : toPreviewReason(result.reason);
  const outcome = attempt.data ?? null;

  return (
    <Bay
      title="Draw USDC"
      lede="The limit below is read from the engine for this exact amount, in this exact session. It is not an estimate of what might happen: it is what the transaction would do."
      note={idleRaw === null ? UNAVAILABLE : `${usdAuto(fromUsdc(idleRaw))} idle in the vault`}
      refused={outcome !== null && !outcome.ok}
    >
      <div className={styles.split}>
        <div className={styles.form}>
          <Field
            id="draw-amount"
            label="Amount to draw"
            value={amount}
            onChange={(event) => setAmount(event.target.value)}
            placeholder="0.00"
            inputMode="decimal"
            autoComplete="off"
            suffix="USDC"
            invalid={amount !== "" && parsed === null}
            hint={amount !== "" && parsed === null ? "Enter a number with at most six decimal places." : undefined}
          />
          <ActionGate>
            <div className={styles.formActions}>
              <Button
                disabled={parsed === null || parsed === 0n || tx.isSending || tx.isConfirming}
                onClick={() =>
                  parsed !== null &&
                  void tx.send({
                    address: DEPLOYMENT.credit,
                    abi: creditAbi,
                    functionName: "draw",
                    args: [parsed, subject],
                  })
                }
              >
                {tx.isSending ? "Waiting for your wallet…" : tx.isConfirming ? "Drawing…" : "Draw USDC"}
              </Button>
            </div>
          </ActionGate>
          <TxStatus tx={tx} done="Drawn. The USDC is in your wallet." />
        </div>

        <Preview
          outcome={outcome}
          lensReason={reason}
          pending={attempt.isPending || preview.isFetching}
          empty={debounced === null || debounced === 0n}
          emptyText={`Currently drawn: ${debtRaw === null ? UNAVAILABLE : usdAuto(fromUsdc(debtRaw))}. Enter an amount to see what the engine would do with it.`}
          rows={
            result === undefined
              ? []
              : [
                  { label: "debt afterwards", value: usdAuto(fromUsdc(result.debtAfter)) },
                  {
                    label: "published borrowing power",
                    value: result.borrowPower === 0n ? null : usdAuto(fromUsdc(result.borrowPower)),
                  },
                  {
                    label: "health afterwards",
                    value: result.healthBps === 0n ? null : `${(Number(result.healthBps) / 100).toFixed(1)}%`,
                  },
                ]
          }
        />
      </div>
    </Bay>
  );
}

/* ============================================================== repay ==== */

function RepayUsdc({
  debtRaw,
  balanceRaw,
  allowanceRaw,
  onDone,
}: {
  debtRaw: bigint | null;
  balanceRaw: bigint | null;
  allowanceRaw: bigint | null;
  onDone: () => void;
}) {
  const [amount, setAmount] = useState("");
  const approve = useTx();
  const repay = useTx();
  useConfirmed(approve.isConfirmed || repay.isConfirmed, onDone);

  const parsed = toUsdc(amount);
  const needsApproval = parsed !== null && allowanceRaw !== null && allowanceRaw < parsed;
  const overBalance = parsed !== null && balanceRaw !== null && parsed > balanceRaw;

  return (
    <Bay
      title="Repay"
      lede="Repayment is never blocked. Not by a closed market, not by a refusing oracle, not by a flag on the line — a borrower can always cure, which is the other half of nobody being able to take."
      note={debtRaw === null ? UNAVAILABLE : `${usdAuto(fromUsdc(debtRaw))} owed`}
    >
      <div className={styles.split}>
        <div className={styles.form}>
          <Field
            id="repay-amount"
            label="Amount to repay"
            value={amount}
            onChange={(event) => setAmount(event.target.value)}
            placeholder="0.00"
            inputMode="decimal"
            autoComplete="off"
            suffix="USDC"
            invalid={amount !== "" && (parsed === null || overBalance)}
            hint={
              amount !== "" && parsed === null
                ? "Enter a number with at most six decimal places."
                : overBalance
                  ? "That is more USDC than the account holds."
                  : undefined
            }
          />
          <div className={styles.quickPicks}>
            {debtRaw !== null && debtRaw > 0n && (
              <button
                className={styles.quickPick}
                type="button"
                onClick={() => setAmount(fromUsdc(debtRaw).toFixed(USDC_DECIMALS))}
              >
                everything owed
              </button>
            )}
            {balanceRaw !== null && balanceRaw > 0n && (
              <button
                className={styles.quickPick}
                type="button"
                onClick={() => setAmount(fromUsdc(balanceRaw).toFixed(USDC_DECIMALS))}
              >
                wallet balance
              </button>
            )}
          </div>
        </div>

        <div className={styles.form}>
          <ActionGate>
            <div className={styles.formActions}>
              {needsApproval && (
                <Button
                  variant="quiet"
                  disabled={approve.isSending || approve.isConfirming}
                  onClick={() =>
                    void approve.send({
                      address: DEPLOYMENT.usdc,
                      abi: erc20Abi,
                      functionName: "approve",
                      args: [DEPLOYMENT.credit, MAX_UINT],
                    })
                  }
                >
                  {approve.isSending || approve.isConfirming ? "Approving…" : "Approve USDC"}
                </Button>
              )}
              <Button
                disabled={parsed === null || parsed === 0n || overBalance || needsApproval || repay.isSending || repay.isConfirming}
                onClick={() =>
                  parsed !== null &&
                  void repay.send({
                    address: DEPLOYMENT.credit,
                    abi: creditAbi,
                    functionName: "repay",
                    args: [parsed],
                  })
                }
              >
                {repay.isSending ? "Waiting for your wallet…" : repay.isConfirming ? "Repaying…" : "Repay"}
              </Button>
            </div>
          </ActionGate>
          <TxStatus tx={approve} done="USDC approved." />
          <TxStatus tx={repay} done="Repaid." />
          <p className={styles.status}>
            Repaying more than is owed is capped at the debt: the engine takes what it needs and leaves the rest
            in your wallet.
          </p>
        </div>
      </div>
    </Bay>
  );
}

/* =========================================================== withdraw ==== */

function WithdrawCollateral({
  subject,
  assets,
  postedAt,
  onDone,
}: {
  subject: Address;
  assets: AssetOption[];
  postedAt: (asset: AssetOption) => bigint;
  onDone: () => void;
}) {
  const [index, setIndex] = useState(0);
  const [amount, setAmount] = useState("");
  const tx = useTx();
  useConfirmed(tx.isConfirmed, onDone);

  const asset = assets[index];
  const parsed = asset === undefined ? null : parseDecimal(amount, asset.decimals);
  const debounced = useDebounced(parsed);

  const preview = useReadContract({
    address: DEPLOYMENT.lens,
    abi: lensAbi,
    functionName: "previewWithdraw",
    args: [subject, asset?.address ?? DEPLOYMENT.usdc, debounced ?? 0n],
    query: { enabled: asset !== undefined && debounced !== null && debounced > 0n, refetchInterval: REFRESH_MS },
  });

  const attempt = useAttempt({
    enabled: asset !== undefined && debounced !== null && debounced > 0n,
    account: subject,
    functionName: "withdrawCollateral",
    args: [asset?.address ?? DEPLOYMENT.usdc, debounced ?? 0n, subject],
  });

  const outcome = attempt.data ?? null;

  if (asset === undefined) return null;

  const posted = postedAt(asset);
  const result = preview.data;
  const reason = result === undefined ? null : toPreviewReason(result.reason);

  return (
    <Bay
      title="Withdraw collateral"
      lede="Taking collateral out is a risk-increasing action, so it is priced by the same oracle that prices a draw — and refused for the same reasons."
      note={`${scaled(posted, asset.decimals).toLocaleString("en-US", { maximumFractionDigits: 8 })} ${asset.symbol} posted`}
      refused={outcome !== null && !outcome.ok}
    >
      <div className={styles.split}>
        <div className={styles.form}>
          <AssetSelect assets={assets} index={index} onChange={setIndex} id="withdraw-asset" />
          <Field
            id="withdraw-amount"
            label="Amount to withdraw"
            value={amount}
            onChange={(event) => setAmount(event.target.value)}
            placeholder="0.00"
            inputMode="decimal"
            autoComplete="off"
            suffix={asset.symbol}
            invalid={amount !== "" && parsed === null}
            hint={
              amount !== "" && parsed === null
                ? `Enter a number with at most ${asset.decimals} decimal places.`
                : undefined
            }
          />
          {posted > 0n && (
            <div className={styles.quickPicks}>
              <button
                className={styles.quickPick}
                type="button"
                onClick={() => setAmount(scaled(posted, asset.decimals).toString())}
              >
                all posted
              </button>
            </div>
          )}
          <ActionGate>
            <div className={styles.formActions}>
              <Button
                disabled={parsed === null || parsed === 0n || tx.isSending || tx.isConfirming}
                onClick={() =>
                  parsed !== null &&
                  void tx.send({
                    address: DEPLOYMENT.credit,
                    abi: creditAbi,
                    functionName: "withdrawCollateral",
                    args: [asset.address, parsed, subject],
                  })
                }
              >
                {tx.isSending ? "Waiting for your wallet…" : tx.isConfirming ? "Withdrawing…" : "Withdraw"}
              </Button>
            </div>
          </ActionGate>
          <TxStatus tx={tx} done="Collateral withdrawn." />
        </div>

        <Preview
          outcome={outcome}
          lensReason={reason}
          pending={attempt.isPending || preview.isFetching}
          empty={debounced === null || debounced === 0n}
          emptyText="Enter an amount to see what the basket would support afterwards."
          rows={
            result === undefined
              ? []
              : [
                  {
                    label: "published borrowing power after",
                    value: result.borrowPowerAfter === 0n ? null : usdAuto(fromUsdc(result.borrowPowerAfter)),
                  },
                  {
                    label: "seizure threshold after",
                    value:
                      result.seizureThresholdAfter === 0n ? null : usdAuto(fromUsdc(result.seizureThresholdAfter)),
                  },
                  {
                    label: "health afterwards",
                    value: result.healthBps === 0n ? null : `${(Number(result.healthBps) / 100).toFixed(1)}%`,
                  },
                ]
          }
        />
      </div>
    </Bay>
  );
}

/* ============================================================= pieces ==== */

function AssetSelect({
  assets,
  index,
  onChange,
  id,
}: {
  assets: AssetOption[];
  index: number;
  onChange: (index: number) => void;
  id: string;
}) {
  return (
    <div>
      <label className={styles.selectLabel} htmlFor={id}>
        Asset
      </label>
      <select
        className={styles.select}
        id={id}
        value={index}
        onChange={(event) => onChange(Number(event.target.value))}
      >
        {assets.map((asset, position) => (
          <option key={asset.address} value={position}>
            {asset.underlying} · {asset.symbol}
            {asset.quoting ? "" : " · oracle refusing"}
          </option>
        ))}
      </select>
    </div>
  );
}

interface PreviewRow {
  label: string;
  value: string | null;
}

/**
 * What the engine says about this exact amount.
 *
 * The verdict comes from simulating the real transaction, so it is the outcome rather than a
 * forecast of it. When the call would revert the panel becomes the refusal: the typed error the
 * contract raises, the arguments it carries, and what the rule behind it means. There is no toast,
 * because a toast disappears and this is the most important thing on the screen.
 */
function Preview({
  outcome,
  lensReason,
  rows,
  pending,
  empty,
  emptyText,
}: {
  outcome: SimulationOutcome | null;
  lensReason: PreviewReason | null;
  rows: PreviewRow[];
  pending: boolean;
  empty: boolean;
  emptyText: string;
}) {
  if (empty) {
    return (
      <div className={styles.preview}>
        <p className={styles.status}>{emptyText}</p>
      </div>
    );
  }

  if (outcome === null) {
    return (
      <div className={styles.preview}>
        <p className={styles.status}>{pending ? "Asking the engine…" : `The preview is ${UNAVAILABLE}.`}</p>
      </div>
    );
  }

  const revert = outcome.ok ? null : outcome.revert;
  /*
   * `Undercollateralized` carries the two figures the lens has just declined to publish, in USDC
   * units, so they are read straight out of the revert rather than left as raw integers beside a
   * column of `unavailable`.
   */
  const measured =
    revert?.name === "Undercollateralized"
      ? [
          { label: "debt afterwards", value: usdcArg(revert.args[0]?.value) },
          { label: "the engine will act on", value: usdcArg(revert.args[1]?.value) },
        ]
      : null;
  const meaning =
    revert === null
      ? null
      : (creditErrorMeaning(revert.name) ??
        (lensReason === null ? null : PREVIEW_MEANING[lensReason]));

  return (
    <div className={`${styles.preview} ${outcome.ok ? "" : styles.previewRefused}`}>
      <div className={styles.previewHead}>
        <span className={styles.previewVerdict}>
          {outcome.ok ? "The engine accepts this" : "The engine refuses this"}
        </span>
        {revert !== null && <span className={styles.refusalSignature}>reverts · {revert.name}</span>}
      </div>

      {revert !== null && revert.args.length > 0 && (
        <p className={styles.args}>
          {revert.args.map((arg) => (
            <span className={styles.arg} key={arg.key}>
              <span className={styles.argKey}>{arg.key}</span>
              <span className={styles.argValue}>{arg.value}</span>
            </span>
          ))}
        </p>
      )}

      <div className={styles.previewFigures}>
        {(measured ?? rows).map((row) => (
          <Readout key={row.label} size="sm" label={row.label} value={row.value} />
        ))}
      </div>

      {meaning !== null && <p className={styles.previewReason}>{meaning}</p>}
      {outcome.ok === false && revert === null && (
        <p className={styles.previewReason}>{outcome.message}</p>
      )}
      {outcome.ok && lensReason !== null && lensReason !== PreviewReason.OK && (
        <p className={styles.previewReason}>{PREVIEW_MEANING[lensReason]}</p>
      )}
    </div>
  );
}

/** One decoded revert argument as a USDC amount, or `null` when it is not one. */
function usdcArg(raw: string | undefined): string | null {
  if (raw === undefined) return null;
  try {
    return usdAuto(fromUsdc(BigInt(raw)));
  } catch {
    return null;
  }
}

/** The outcome of running the real transaction against the current block as a call. */
interface SimulationOutcome {
  ok: boolean;
  revert: DecodedRevert | null;
  message: string;
}

/**
 * Runs one credit-engine transaction as an `eth_call` from `account` and reports what it did.
 *
 * Deliberately not wagmi's `useSimulateContract`: that hook is disabled until a wallet is
 * connected, because it exists to prepare a transaction for one. This preview has to answer for a
 * visitor who has connected nothing, so it goes through the public client and names the account
 * itself.
 *
 * A revert comes back as *data*, not as a query error, because a revert is the engine answering.
 * Only a read that never reached the chain is an error, and that is the one case this reports as
 * unavailable rather than as a refusal.
 */
function useAttempt(options: {
  enabled: boolean;
  account: Address;
  functionName: "draw" | "withdrawCollateral";
  args: readonly unknown[];
}) {
  const client = usePublicClient({ chainId: base.id });

  return useQuery<SimulationOutcome>({
    queryKey: [
      "aftermarket:attempt",
      options.functionName,
      options.account,
      options.args.map((arg) => String(arg)).join(","),
    ],
    enabled: options.enabled && client !== undefined,
    refetchInterval: REFRESH_MS,
    staleTime: REFRESH_MS,
    retry: 2,
    queryFn: async (): Promise<SimulationOutcome> => {
      if (client === undefined) throw new Error("No Base client is configured.");
      try {
        await client.simulateContract({
          address: DEPLOYMENT.credit,
          abi: creditAbi,
          functionName: options.functionName,
          args: options.args as never,
          account: options.account,
        });
        return { ok: true, revert: null, message: "" };
      } catch (error) {
        const revert = decodeRevert(error, creditAbi as unknown as Abi);
        // No decodable revert means the call never reached the engine; that is a failure, not a refusal.
        if (revert === null) throw error;
        return { ok: false, revert, message: "" };
      }
    },
  });
}

/* ============================================================== hooks ==== */

/** Waits until typing stops before asking the chain what an amount would do. */
function useDebounced(value: bigint | null, delay = 350): bigint | null {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    const timer = window.setTimeout(() => setSettled(value), delay);
    return () => window.clearTimeout(timer);
  }, [value, delay]);
  return settled;
}

/** Re-reads every balance once a transaction has actually landed in a block. */
function useConfirmed(confirmed: boolean, onDone: () => void) {
  useEffect(() => {
    if (confirmed) onDone();
    // The callback is rebuilt on every render of the parent; depending on it would refetch forever.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [confirmed]);
}
