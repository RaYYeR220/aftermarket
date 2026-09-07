"use client";

import { useCallback, useEffect, useState } from "react";
import { base } from "viem/chains";
import { createSiweMessage } from "viem/siwe";
import { useAccount, useConnect, useDisconnect, useSignMessage } from "wagmi";

import { Button } from "@/components/primitives";
import { SITE } from "@/lib/site";

import styles from "./SignIn.module.css";

/**
 * Sign in with Base.
 *
 * The wallet connects, the browser asks the server for a single-use nonce, the
 * account signs a SIWE message naming this exact origin and that exact nonce,
 * and the server checks the signature against Base mainnet before it will admit
 * who you are. Nothing is sent, and no allowance is asked for.
 */

type Stage = "checking" | "signedOut" | "working" | "signedIn";

interface SessionResponse {
  signedIn: boolean;
  address?: string | undefined;
  name?: string | undefined;
  error?: string | undefined;
}

export interface SignInProps {
  /** What the button says. The action the person is starting, not the plumbing under it. */
  label: string;
  /** One line under the button, saying exactly what pressing it does. */
  aside?: string | undefined;
  /**
   * `compact` fits the control into the application masthead: a quiet button, the account name on
   * one line, and no supporting copy. `block` is the landing page's treatment.
   */
  variant?: "block" | "compact" | undefined;
}

export function SignIn({ label, aside, variant = "block" }: SignInProps) {
  const compact = variant === "compact";
  const [stage, setStage] = useState<Stage>("checking");
  const [account, setAccount] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const { address, isConnected } = useAccount();
  const { connectAsync, connectors } = useConnect();
  const { disconnectAsync } = useDisconnect();
  const { signMessageAsync } = useSignMessage();

  useEffect(() => {
    let cancelled = false;
    void fetch("/api/auth/session")
      .then((response) => response.json() as Promise<SessionResponse>)
      .then((session) => {
        if (cancelled) return;
        if (session.signedIn && session.name) {
          setAccount(session.name);
          setStage("signedIn");
        } else {
          setStage("signedOut");
        }
      })
      .catch(() => {
        if (!cancelled) setStage("signedOut");
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const signIn = useCallback(async () => {
    setError(null);
    setStage("working");
    try {
      let signer = isConnected ? address : undefined;
      if (!signer) {
        const connector = connectors[0];
        if (!connector) throw new Error("No Base Account connector is configured.");
        const result = await connectAsync({ connector, chainId: base.id });
        signer = result.accounts[0];
      }
      if (!signer) throw new Error("The wallet returned no account.");

      const nonceResponse = await fetch("/api/auth/nonce");
      const { nonce } = (await nonceResponse.json()) as { nonce: string };

      const message = createSiweMessage({
        address: signer,
        chainId: base.id,
        domain: window.location.host,
        nonce,
        uri: window.location.origin,
        version: "1",
        statement: `Sign in to ${SITE.name}. This proves you control this account. It sends nothing and approves nothing.`,
      });

      const signature = await signMessageAsync({ message, account: signer });

      const verifyResponse = await fetch("/api/auth/verify", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ message, signature }),
      });
      const session = (await verifyResponse.json()) as SessionResponse;
      if (!verifyResponse.ok || !session.signedIn) {
        throw new Error(session.error ?? "Sign-in was not accepted.");
      }
      setAccount(session.name ?? signer);
      setStage("signedIn");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Sign-in did not complete.");
      setStage("signedOut");
    }
  }, [address, connectAsync, connectors, isConnected, signMessageAsync]);

  const signOut = useCallback(async () => {
    await fetch("/api/auth/session", { method: "DELETE" });
    await disconnectAsync().catch(() => undefined);
    setAccount(null);
    setStage("signedOut");
  }, [disconnectAsync]);

  if (stage === "signedIn" && account) {
    return (
      <div className={compact ? styles.rootCompact : styles.root}>
        <div className={compact ? `${styles.signedIn} ${styles.signedInCompact}` : styles.signedIn}>
          <span className={styles.account}>{account}</span>
          <button className={styles.signOut} type="button" onClick={() => void signOut()}>
            Sign out
          </button>
        </div>
        {!compact && (
          <p className={styles.aside}>
            Verified on Base. Every screen now reads your own line instead of the reference line.
          </p>
        )}
      </div>
    );
  }

  return (
    <div className={compact ? styles.rootCompact : styles.root}>
      <Button
        variant={compact ? "quiet" : "primary"}
        onClick={() => void signIn()}
        disabled={stage === "working" || stage === "checking"}
      >
        {stage === "working" ? "Waiting for your wallet…" : label}
      </Button>
      {error !== null ? (
        <p className={styles.error}>{error}</p>
      ) : (
        !compact && aside !== undefined && <p className={styles.aside}>{aside}</p>
      )}
    </div>
  );
}
