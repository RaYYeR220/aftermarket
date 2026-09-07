import { getAddress, isAddress, parseAbiItem, type Address, type PublicClient } from "viem";
import { describeError, withRateLimitRetry } from "./chain.js";

const ENROLLED_EVENT = parseAbiItem(
  "event Enrolled(address indexed user, bytes32 indexed permissionHash, (uint128,uint32,uint16,bool) policy)",
);
const WITHDRAWN_EVENT = parseAbiItem("event Withdrawn(address indexed user, bytes32 indexed permissionHash)");
const CANCELLED_EVENT = parseAbiItem(
  "event Cancelled(address indexed user, bytes32 indexed permissionHash, bool revoked)",
);

export interface RegistryOptions {
  readonly autoRepayer: Address;
  /** Lowest block worth scanning; the deployment block of `AutoRepayer`. */
  readonly fromBlock: bigint;
  /** Blocks per `eth_getLogs` request. Public endpoints cap this, so it is deliberately modest. */
  readonly chunkSize?: bigint;
  /** Accounts to watch regardless of what the scan finds. */
  readonly pinned?: readonly Address[];
}

/**
 * Which accounts the keeper watches.
 *
 * Enrolment is an on-chain event, so the watch list is derived from the chain rather than
 * configured: an account that enrols is picked up on the next tick without anybody editing a file,
 * and one that withdraws or cancels drops off. `KEEPER_ACCOUNTS` pins extra addresses on top, which
 * is what the eval harness and a local demo use.
 *
 * A withdrawn account is dropped from the scan result rather than kept and refused every tick.
 * The distinction matters for the audit trail: `NOT_ENROLLED` is a meaningful verdict about an
 * account somebody asked about, not a line the keeper should emit forever about every address that
 * has ever used the protocol.
 */
export class AccountRegistry {
  private readonly accounts = new Set<string>();
  private cursor: bigint;
  private readonly chunkSize: bigint;

  constructor(private readonly options: RegistryOptions) {
    this.cursor = options.fromBlock;
    this.chunkSize = options.chunkSize ?? 5_000n;
    for (const account of options.pinned ?? []) this.accounts.add(getAddress(account));
  }

  /** Every account currently watched, in a stable order. */
  list(): Address[] {
    return [...this.accounts].sort() as Address[];
  }

  /** Adds an account by hand, for `simulate` / `explain` on an address nobody has enrolled yet. */
  add(account: Address): void {
    this.accounts.add(getAddress(account));
  }

  /**
   * Advances the scan to `toBlock` and folds the enrolment events found into the watch list.
   *
   * Returns a note when the scan could not complete, so the caller can record that the watch list
   * may be incomplete rather than silently watching fewer accounts than it should.
   */
  async sync(client: PublicClient, toBlock: bigint): Promise<{ scannedTo: bigint; note: string | null }> {
    if (toBlock < this.cursor) return { scannedTo: this.cursor, note: null };

    let from = this.cursor;
    while (from <= toBlock) {
      const to = from + this.chunkSize - 1n > toBlock ? toBlock : from + this.chunkSize - 1n;
      try {
        const [enrolled, withdrawn, cancelled] = await Promise.all([
          withRateLimitRetry(() =>
            client.getLogs({ address: this.options.autoRepayer, event: ENROLLED_EVENT, fromBlock: from, toBlock: to }),
          ),
          withRateLimitRetry(() =>
            client.getLogs({ address: this.options.autoRepayer, event: WITHDRAWN_EVENT, fromBlock: from, toBlock: to }),
          ),
          withRateLimitRetry(() =>
            client.getLogs({ address: this.options.autoRepayer, event: CANCELLED_EVENT, fromBlock: from, toBlock: to }),
          ),
        ]);

        for (const log of enrolled) {
          if (log.args.user) this.accounts.add(getAddress(log.args.user));
        }
        for (const log of [...withdrawn, ...cancelled]) {
          if (log.args.user && !this.isPinned(log.args.user)) this.accounts.delete(getAddress(log.args.user));
        }
      } catch (error) {
        this.cursor = from;
        return { scannedTo: from, note: `enrolment scan stopped at block ${from}: ${describeError(error)}` };
      }
      from = to + 1n;
    }

    this.cursor = toBlock + 1n;
    return { scannedTo: toBlock, note: null };
  }

  private isPinned(account: Address): boolean {
    return (this.options.pinned ?? []).some((pinned) => pinned.toLowerCase() === account.toLowerCase());
  }
}

/** Parses the `KEEPER_ACCOUNTS` environment variable, rejecting anything that is not an address. */
export function parsePinnedAccounts(raw: string | undefined): Address[] {
  if (!raw) return [];
  return raw
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry !== "")
    .map((entry) => {
      if (!isAddress(entry)) throw new Error(`KEEPER_ACCOUNTS contains a value that is not an address: ${entry}`);
      return getAddress(entry);
    });
}
