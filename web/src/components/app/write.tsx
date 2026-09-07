"use client";

import { useCallback, useState, type ReactNode } from "react";
import type { Abi, Address, Hex } from "viem";
import { base } from "wagmi/chains";
import { useAccount, useSwitchChain, useWaitForTransactionReceipt, useWriteContract } from "wagmi";

import { SignIn } from "@/components/auth/SignIn";
import { Button } from "@/components/primitives";
import { decodeRevert, errorMessage, isUserRejection, type DecodedRevert } from "@/lib/errors";
import { SITE } from "@/lib/site";

import styles from "./app.module.css";
import { TxLink } from "./index";

/* =============================================================== state ==== */

export interface TxFailure {
  message: string;
  /** The typed error the contract reverted with, when it carried one. */
  revert: DecodedRevert | null;
}

export interface TxController {
  send: (request: {
    address: Address;
    abi: Abi;
    functionName: string;
    args: readonly unknown[];
  }) => Promise<void>;
  hash: Hex | null;
  failure: TxFailure | null;
  isSending: boolean;
  isConfirming: boolean;
  isConfirmed: boolean;
  clear: () => void;
}

/**
 * One transaction, from the wallet prompt to the receipt, with the revert decoded.
 *
 * The ERC-8021 Builder Code rides on the wagmi config rather than on this call site, so every
 * transaction sent through here is attributed without the caller having to remember.
 */
export function useTx(): TxController {
  const { writeContractAsync, isPending } = useWriteContract();
  const [hash, setHash] = useState<Hex | null>(null);
  const [failure, setFailure] = useState<TxFailure | null>(null);

  const receipt = useWaitForTransactionReceipt(
    hash === null ? { query: { enabled: false } } : { hash, query: { enabled: true } },
  );

  const send = useCallback<TxController["send"]>(
    async (request) => {
      setFailure(null);
      setHash(null);
      try {
        const sent = await writeContractAsync({
          address: request.address,
          abi: request.abi,
          functionName: request.functionName,
          args: request.args,
          chainId: base.id,
        });
        setHash(sent);
      } catch (error) {
        setFailure({
          message: errorMessage(error),
          revert: isUserRejection(error) ? null : decodeRevert(error, request.abi),
        });
      }
    },
    [writeContractAsync],
  );

  const clear = useCallback(() => {
    setHash(null);
    setFailure(null);
  }, []);

  return {
    send,
    hash,
    failure,
    isSending: isPending,
    isConfirming: hash !== null && receipt.isLoading,
    isConfirmed: hash !== null && receipt.isSuccess,
    clear,
  };
}

/* ============================================================== status ==== */

/** What the transaction is doing, and — if it was refused — exactly what the contract said. */
export function TxStatus({ tx, done }: { tx: TxController; done: string }) {
  if (tx.failure !== null) {
    return (
      <div>
        <p className={`${styles.status} ${styles.statusError}`}>{tx.failure.message}</p>
        {tx.failure.revert !== null && (
          <p className={styles.args}>
            <span className={styles.arg}>
              <span className={styles.argValue}>{tx.failure.revert.name}</span>
            </span>
            {tx.failure.revert.args.map((arg) => (
              <span className={styles.arg} key={arg.key}>
                <span className={styles.argKey}>{arg.key}</span>
                <span className={styles.argValue}>{arg.value}</span>
              </span>
            ))}
          </p>
        )}
      </div>
    );
  }

  if (tx.hash === null) return null;

  return (
    <p className={styles.status}>
      {tx.isConfirmed ? done : "Waiting for the block."} <TxLink hash={tx.hash} label="View on Basescan" />
    </p>
  );
}

/* ================================================================ gate ==== */

export interface ActionGateProps {
  children: ReactNode;
  /** Rendered instead of the action when the protocol itself would refuse it. */
  blocked?: string | undefined;
}

/**
 * Everything on this surface is readable without a wallet; only the write actions need one.
 *
 * This is where that line is drawn. A visitor with no wallet still sees the form, the live preview
 * and the exact reason an action would or would not succeed -- they simply cannot send it, and the
 * gate says so instead of hiding the screen behind a connect button.
 */
export function ActionGate({ children, blocked }: ActionGateProps) {
  const { isConnected, chainId } = useAccount();
  const { switchChain, isPending } = useSwitchChain();

  if (blocked !== undefined) {
    return <p className={styles.status}>{blocked}</p>;
  }

  if (!isConnected) {
    return (
      <div className={styles.formActions}>
        <SignIn label="Sign in with Base to act" variant="compact" />
      </div>
    );
  }

  if (chainId !== base.id) {
    return (
      <div className={styles.formActions}>
        <Button variant="quiet" disabled={isPending} onClick={() => switchChain({ chainId: base.id })}>
          {isPending ? "Waiting for your wallet…" : `Switch to ${SITE.chainName}`}
        </Button>
        <p className={styles.status}>
          {SITE.name} exists only on {SITE.chainName} mainnet, chain {SITE.chainId}.
        </p>
      </div>
    );
  }

  return <>{children}</>;
}
