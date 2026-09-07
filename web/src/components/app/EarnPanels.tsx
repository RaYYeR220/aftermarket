"use client";

import { useEffect, useState } from "react";
import type { Address } from "viem";
import { useAccount, useReadContracts } from "wagmi";

import { Button, Field, Readout } from "@/components/primitives";
import { erc20Abi, vaultAbi } from "@/lib/abi";
import { DEPLOYMENT } from "@/lib/deployment";
import { usdAuto, UNAVAILABLE } from "@/lib/format";
import { fromUsdc, scaled, toUsdc } from "@/lib/protocol";

import styles from "./app.module.css";
import { Bay } from "./index";
import { ActionGate, TxStatus, useTx } from "./write";

/**
 * The lender side of the vault: deposit USDC, hold `amUSDC`, withdraw.
 *
 * `maxWithdraw` is read rather than assumed. The vault only holds the USDC that is not currently
 * out on loan, so a lender's withdrawable balance is a live number, and this panel shows the one
 * the contract will actually honour instead of the share balance a naive interface would print.
 */

/**
 * What the server already read for {@link EarnPanelsProps.fallbackAddress}, as decimal strings.
 *
 * The first paint is therefore a real position rather than three `unavailable`s waiting on a
 * browser read that a public endpoint may throttle. The client read takes over as soon as it lands,
 * and entirely once a different account is connected.
 */
export interface EarnInitialState {
  shares: string | null;
  withdrawable: string | null;
  usdcBalance: string | null;
  usdcAllowance: string | null;
}

export interface EarnPanelsProps {
  /** Whose balances are read when no wallet is connected. */
  fallbackAddress: Address;
  /** The vault's share decimals, read on the server. */
  shareDecimals: number;
  shareSymbol: string;
  initial: EarnInitialState;
}

/** Parses one of the server's decimal strings, or `null` when the server could not read it. */
function big(value: string | null): bigint | null {
  if (value === null) return null;
  try {
    return BigInt(value);
  } catch {
    return null;
  }
}

const REFRESH_MS = 30_000;
const MAX_UINT = 2n ** 256n - 1n;

export function EarnPanels({ fallbackAddress, shareDecimals, shareSymbol, initial }: EarnPanelsProps) {
  const { address: connected } = useAccount();
  const subject = connected ?? fallbackAddress;
  /** The server's figures describe one account; they are only a fallback while that is the subject. */
  const serverKnows = subject.toLowerCase() === fallbackAddress.toLowerCase();

  const reads = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: DEPLOYMENT.vault, abi: vaultAbi, functionName: "balanceOf", args: [subject] },
      { address: DEPLOYMENT.vault, abi: vaultAbi, functionName: "maxWithdraw", args: [subject] },
      { address: DEPLOYMENT.usdc, abi: erc20Abi, functionName: "balanceOf", args: [subject] },
      { address: DEPLOYMENT.usdc, abi: erc20Abi, functionName: "allowance", args: [subject, DEPLOYMENT.vault] },
    ],
    query: { refetchInterval: REFRESH_MS },
  });

  const at = (index: number, fallback: string | null): bigint | null => {
    const entry = reads.data?.[index];
    if (entry !== undefined && entry.status === "success" && typeof entry.result === "bigint") {
      return entry.result;
    }
    return serverKnows ? big(fallback) : null;
  };

  const shares = at(0, initial.shares);
  const withdrawable = at(1, initial.withdrawable);
  const usdcBalance = at(2, initial.usdcBalance);
  const allowance = at(3, initial.usdcAllowance);

  const refresh = () => void reads.refetch();

  return (
    <>
      <Bay
        title="Your position"
        note={shares === null ? UNAVAILABLE : `${scaled(shares, shareDecimals).toLocaleString("en-US", { maximumFractionDigits: 6 })} ${shareSymbol}`}
      >
        <div className={styles.readouts}>
          <Readout size="lg" label="withdrawable now" value={withdrawable === null ? null : usdAuto(fromUsdc(withdrawable))} />
          <Readout size="lg" label={`${shareSymbol} held`} value={shares === null ? null : scaled(shares, shareDecimals).toLocaleString("en-US", { maximumFractionDigits: 6 })} />
          <Readout size="lg" label="USDC in wallet" value={usdcBalance === null ? null : usdAuto(fromUsdc(usdcBalance))} />
        </div>
        <p className={styles.explain}>
          Withdrawable is the vault&rsquo;s own <code>maxWithdraw</code>, not your share of its total. USDC that
          is out on loan cannot be handed back until it is repaid, and the vault says so rather than reverting
          when you try.
        </p>
      </Bay>

      <Deposit balanceRaw={usdcBalance} allowanceRaw={allowance} subject={subject} onDone={refresh} />
      <Withdraw withdrawableRaw={withdrawable} subject={subject} onDone={refresh} />
    </>
  );
}

function Deposit({
  balanceRaw,
  allowanceRaw,
  subject,
  onDone,
}: {
  balanceRaw: bigint | null;
  allowanceRaw: bigint | null;
  subject: Address;
  onDone: () => void;
}) {
  const [amount, setAmount] = useState("");
  const approve = useTx();
  const deposit = useTx();
  const parsed = toUsdc(amount);
  const overBalance = parsed !== null && balanceRaw !== null && parsed > balanceRaw;
  const needsApproval = parsed !== null && allowanceRaw !== null && allowanceRaw < parsed;

  useConfirmedRefresh(approve.isConfirmed || deposit.isConfirmed, onDone);

  return (
    <Bay
      title="Deposit"
      lede="Lend USDC to the borrowers. You are paid the borrow rate less the share that stays with borrowers, and a closed market pays more because the vault is carrying a gap nobody can hedge until the bell."
      note={balanceRaw === null ? UNAVAILABLE : `${usdAuto(fromUsdc(balanceRaw))} in wallet`}
    >
      <div className={styles.split}>
        <div className={styles.form}>
          <Field
            id="earn-deposit"
            label="Amount to deposit"
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
          {balanceRaw !== null && balanceRaw > 0n && (
            <div className={styles.quickPicks}>
              <button className={styles.quickPick} type="button" onClick={() => setAmount(fromUsdc(balanceRaw).toFixed(6))}>
                wallet balance
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
                      address: DEPLOYMENT.usdc,
                      abi: erc20Abi,
                      functionName: "approve",
                      args: [DEPLOYMENT.vault, MAX_UINT],
                    })
                  }
                >
                  {approve.isSending || approve.isConfirming ? "Approving…" : "Approve USDC"}
                </Button>
              )}
              <Button
                disabled={parsed === null || parsed === 0n || overBalance || needsApproval || deposit.isSending || deposit.isConfirming}
                onClick={() =>
                  parsed !== null &&
                  void deposit.send({
                    address: DEPLOYMENT.vault,
                    abi: vaultAbi,
                    functionName: "deposit",
                    args: [parsed, subject],
                  })
                }
              >
                {deposit.isSending ? "Waiting for your wallet…" : deposit.isConfirming ? "Depositing…" : "Deposit"}
              </Button>
            </div>
          </ActionGate>
          <TxStatus tx={approve} done="USDC approved." />
          <TxStatus tx={deposit} done="Deposited." />
        </div>
      </div>
    </Bay>
  );
}

function Withdraw({
  withdrawableRaw,
  subject,
  onDone,
}: {
  withdrawableRaw: bigint | null;
  subject: Address;
  onDone: () => void;
}) {
  const [amount, setAmount] = useState("");
  const tx = useTx();
  const parsed = toUsdc(amount);
  const overMax = parsed !== null && withdrawableRaw !== null && parsed > withdrawableRaw;
  useConfirmedRefresh(tx.isConfirmed, onDone);

  return (
    <Bay
      title="Withdraw"
      lede="Withdrawal is limited by the USDC actually sitting in the vault. Anything out on loan comes back as borrowers repay."
      note={withdrawableRaw === null ? UNAVAILABLE : `${usdAuto(fromUsdc(withdrawableRaw))} available`}
    >
      <div className={styles.split}>
        <div className={styles.form}>
          <Field
            id="earn-withdraw"
            label="Amount to withdraw"
            value={amount}
            onChange={(event) => setAmount(event.target.value)}
            placeholder="0.00"
            inputMode="decimal"
            autoComplete="off"
            suffix="USDC"
            invalid={amount !== "" && (parsed === null || overMax)}
            hint={
              amount !== "" && parsed === null
                ? "Enter a number with at most six decimal places."
                : overMax
                  ? "More than the vault can hand back right now. The rest returns as borrowers repay."
                  : undefined
            }
          />
          {withdrawableRaw !== null && withdrawableRaw > 0n && (
            <div className={styles.quickPicks}>
              <button
                className={styles.quickPick}
                type="button"
                onClick={() => setAmount(fromUsdc(withdrawableRaw).toFixed(6))}
              >
                everything available
              </button>
            </div>
          )}
        </div>
        <div className={styles.form}>
          <ActionGate>
            <div className={styles.formActions}>
              <Button
                disabled={parsed === null || parsed === 0n || overMax || tx.isSending || tx.isConfirming}
                onClick={() =>
                  parsed !== null &&
                  void tx.send({
                    address: DEPLOYMENT.vault,
                    abi: vaultAbi,
                    functionName: "withdraw",
                    args: [parsed, subject, subject],
                  })
                }
              >
                {tx.isSending ? "Waiting for your wallet…" : tx.isConfirming ? "Withdrawing…" : "Withdraw"}
              </Button>
            </div>
          </ActionGate>
          <TxStatus tx={tx} done="Withdrawn." />
        </div>
      </div>
    </Bay>
  );
}

/** Re-reads every balance once a transaction has actually landed in a block. */
function useConfirmedRefresh(confirmed: boolean, onDone: () => void) {
  useEffect(() => {
    if (confirmed) onDone();
    // The callback is rebuilt on every render of the parent; depending on it would refetch forever.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [confirmed]);
}
