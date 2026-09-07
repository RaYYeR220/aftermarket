import type { Account, Address, Hex, PublicClient, WalletClient } from "viem";
import { autoRepayerAbi } from "./abi.js";
import { AuditTrail, buildRecord, buildUnavailableRecord } from "./audit.js";
import { describeError, isContractRevert } from "./chain.js";
import { agreesWithContract, decide } from "./engine.js";
import {
  readAccount,
  readBlock,
  readOracles,
  simulate,
  type BlockRef,
  type OracleTable,
  type ProtocolAddresses,
} from "./reader.js";
import { reasonName } from "./reasons.js";
import type { AccountRegistry } from "./registry.js";
import type { ActionOutcome, DecisionRecord, DecisionStatus, TickResult } from "./types.js";

export interface KeeperConfig {
  readonly chainId: number;
  readonly addresses: ProtocolAddresses;
  /**
   * Dry run is the default and has to be turned off explicitly. Nothing in this service sends a
   * transaction while it is true, including `poke`.
   */
  readonly dryRun: boolean;
  /**
   * Hard ceiling on transactions per `once`, and per tick of `watch`. Reached, the keeper stops
   * acting for the rest of the run and records why on every remaining account, rather than
   * continuing and hoping.
   */
  readonly maxTransactionsPerRun: number;
  /**
   * Whether a refusal is also written to the chain with `poke`, so the restraint is public
   * evidence rather than a line in this keeper's log file. Off by default because it costs gas.
   */
  readonly pokeOnRefusal: boolean;
  readonly audit: AuditTrail;
  /** Emits one line per decision as it happens. */
  readonly onRecord?: ((record: DecisionRecord) => void) | undefined;
}

/**
 * The keeper loop.
 *
 * Three properties are load-bearing and everything else is plumbing around them.
 *
 * **It never sends a transaction the contract's own simulation says will be refused.** Every
 * account goes through `simulate()` before `execute` is even considered, and the result is compared
 * against the keeper's own engine. When the two disagree the keeper stands down and records
 * `engine-mismatch`, because a keeper that breaks a tie between two implementations of the rules is
 * a keeper exercising judgement, which is precisely what this design refuses to have.
 *
 * **A refusal is output, not silence.** Every account evaluated writes a record every tick, whether
 * or not anything happened, with the inputs the decision was made from.
 *
 * **It cannot exceed what the borrower authorised even if it tries.** The transaction cap here is
 * an operational guard-rail; the real cap is `SpendPermissionManager.spend()`, which reverts on
 * `used + value > allowance` no matter what this process believes.
 */
export class Keeper {
  private transactionsSent = 0;

  constructor(
    private readonly publicClient: PublicClient,
    private readonly wallet: WalletClient | undefined,
    private readonly registry: AccountRegistry,
    private readonly config: KeeperConfig,
  ) {}

  /** The keeper's signing address, or `null` in a dry run with no key configured. */
  get signer(): Address | null {
    return (this.wallet?.account as Account | undefined)?.address ?? null;
  }

  /** Transactions sent since this instance was constructed. */
  get sent(): number {
    return this.transactionsSent;
  }

  /**
   * One full pass over every watched account.
   *
   * The block is read once and every subsequent read is pinned to it, so a tick is a coherent
   * snapshot rather than a series of reads that might straddle a reorg or a price update.
   */
  async tick(): Promise<TickResult> {
    const startedAt = new Date().toISOString();
    const records: DecisionRecord[] = [];
    const sentBefore = this.transactionsSent;

    let block: BlockRef;
    try {
      block = await readBlock(this.publicClient);
    } catch (error) {
      const record = buildUnavailableRecord({
        chainId: this.config.chainId,
        account: ZERO_ADDRESS,
        blockNumber: null,
        error: `could not read the chain head: ${describeError(error)}`,
        dryRun: this.config.dryRun,
      });
      records.push(record);
      this.config.onRecord?.(record);
      await this.config.audit.appendAll(records);
      return {
        startedAt,
        finishedAt: new Date().toISOString(),
        blockNumber: null,
        records,
        transactionsSent: 0,
      };
    }

    await this.registry.sync(this.publicClient, block.number);

    let oracles: OracleTable = new Map();
    try {
      oracles = await readOracles(this.publicClient, this.config.addresses, block);
    } catch (error) {
      // Without the lens the keeper can still evaluate lines — `positionOf` carries `priced` on its
      // own — it just cannot name the feed behind a refusal. Losing the explanation is not a reason
      // to stop, so the tick continues with an empty oracle table and every record says so.
      const record = buildUnavailableRecord({
        chainId: this.config.chainId,
        account: this.config.addresses.lens,
        blockNumber: block.number,
        error: `oracle state unreadable through the lens: ${describeError(error)}`,
        dryRun: this.config.dryRun,
      });
      records.push(record);
      this.config.onRecord?.(record);
    }

    for (const account of this.registry.list()) {
      const record = await this.evaluate(account, block, oracles);
      records.push(record);
      this.config.onRecord?.(record);
    }

    await this.config.audit.appendAll(records);
    return {
      startedAt,
      finishedAt: new Date().toISOString(),
      blockNumber: block.number,
      records,
      transactionsSent: this.transactionsSent - sentBefore,
    };
  }

  /** Evaluates one account and, if warranted and permitted, acts on it. */
  async evaluate(account: Address, block: BlockRef, oracles: OracleTable): Promise<DecisionRecord> {
    let snapshot;
    let contract;
    try {
      snapshot = await readAccount(this.publicClient, this.config.addresses, account, block, oracles);
      contract = await simulate(this.publicClient, this.config.addresses, account, block);
    } catch (error) {
      return buildUnavailableRecord({
        chainId: this.config.chainId,
        account,
        blockNumber: block.number,
        error: describeError(error),
        dryRun: this.config.dryRun,
      });
    }

    const decision = decide(snapshot);

    if (!agreesWithContract(decision, contract)) {
      return buildRecord({
        chainId: this.config.chainId,
        snapshot,
        decision,
        contract,
        status: "engine-mismatch",
        action: {
          kind: "none",
          sent: false,
          txHash: null,
          repaid: null,
          note: "stood down: the keeper's rule engine and the contract's simulate() disagree",
        },
        dryRun: this.config.dryRun,
        explanation:
          `The keeper's own rule engine said ${reasonName(decision.reason)} and the contract's simulate() said ` +
          `${reasonName(contract.reason)}. Two implementations of the same rules disagree, so the keeper has no ` +
          `basis for choosing between them and does nothing.`,
      });
    }

    const action = contract.willAct ? await this.act(account, contract.amount) : await this.recordRefusal(account);
    const status: DecisionStatus = contract.willAct
      ? action.sent
        ? "acted"
        : action.note.startsWith("failed")
          ? "failed"
          : "would-act"
      : "refused";

    return buildRecord({
      chainId: this.config.chainId,
      snapshot,
      decision,
      contract,
      status,
      action,
      dryRun: this.config.dryRun,
    });
  }

  /**
   * Sends `execute` for an account the contract has already agreed to act on.
   *
   * `simulateContract` runs first even though `simulate()` has already said yes: the former is the
   * agent's own view of its preconditions, the latter is the node's view of the whole transaction
   * including the spend permission, the ERC-20 transfer and the repayment. A transaction that would
   * revert never leaves this process.
   */
  private async act(account: Address, amount: bigint): Promise<ActionOutcome> {
    if (this.config.dryRun) {
      return {
        kind: "execute",
        sent: false,
        txHash: null,
        repaid: amount,
        note: `dry run: would repay ${amount} USDC units; pass --live to send`,
      };
    }
    if (!this.wallet?.account) {
      return {
        kind: "execute",
        sent: false,
        txHash: null,
        repaid: amount,
        note: "no signer: set KEEPER_PRIVATE_KEY to let the keeper act",
      };
    }
    if (this.transactionsSent >= this.config.maxTransactionsPerRun) {
      return {
        kind: "execute",
        sent: false,
        txHash: null,
        repaid: amount,
        note: `per-run transaction cap of ${this.config.maxTransactionsPerRun} reached; stopped acting`,
      };
    }

    try {
      const { request } = await this.publicClient.simulateContract({
        address: this.config.addresses.autoRepayer,
        abi: autoRepayerAbi,
        functionName: "execute",
        args: [account],
        account: this.wallet.account,
      });
      const hash = await this.wallet.writeContract(request);
      this.transactionsSent += 1;
      const receipt = await this.publicClient.waitForTransactionReceipt({ hash });
      return {
        kind: "execute",
        sent: true,
        txHash: hash,
        repaid: amount,
        note: `execute mined in block ${receipt.blockNumber} (${receipt.status})`,
      };
    } catch (error) {
      return {
        kind: "execute",
        sent: false,
        txHash: null,
        repaid: amount,
        note: `failed to execute: ${describeError(error)}${isContractRevert(error) ? " (contract revert)" : ""}`,
      };
    }
  }

  /**
   * Optionally writes a refusal to the chain.
   *
   * `poke` is how restraint becomes auditable by somebody who does not run this keeper: it emits
   * `AutoRepayRefused(user, reason)` and changes nothing else. It is off by default because it
   * costs gas on every tick for every account, and the JSONL trail plus `simulate()` already give a
   * reader the same verdict for free.
   */
  private async recordRefusal(account: Address): Promise<ActionOutcome> {
    if (!this.config.pokeOnRefusal) {
      return { kind: "none", sent: false, txHash: null, repaid: null, note: "refusal recorded off-chain only" };
    }
    if (this.config.dryRun) {
      return { kind: "poke", sent: false, txHash: null, repaid: null, note: "dry run: would poke to log the refusal" };
    }
    if (!this.wallet?.account) {
      return { kind: "poke", sent: false, txHash: null, repaid: null, note: "no signer: cannot poke" };
    }
    if (this.transactionsSent >= this.config.maxTransactionsPerRun) {
      return {
        kind: "poke",
        sent: false,
        txHash: null,
        repaid: null,
        note: `per-run transaction cap of ${this.config.maxTransactionsPerRun} reached; did not poke`,
      };
    }

    try {
      const { request } = await this.publicClient.simulateContract({
        address: this.config.addresses.autoRepayer,
        abi: autoRepayerAbi,
        functionName: "poke",
        args: [account],
        account: this.wallet.account,
      });
      const hash: Hex = await this.wallet.writeContract(request);
      this.transactionsSent += 1;
      await this.publicClient.waitForTransactionReceipt({ hash });
      return { kind: "poke", sent: true, txHash: hash, repaid: null, note: "refusal written on-chain" };
    } catch (error) {
      return { kind: "poke", sent: false, txHash: null, repaid: null, note: `failed to poke: ${describeError(error)}` };
    }
  }
}

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;
