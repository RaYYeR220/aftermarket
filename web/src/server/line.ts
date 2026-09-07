import "server-only";

import { cache } from "react";
import { decodeFunctionResult, type Abi, type Address, type Hex } from "viem";

import { autoRepayerAbi, creditAbi, erc20Abi, lensAbi, vaultAbi } from "@/lib/abi";
import { DEPLOYMENT } from "@/lib/deployment";
import { decodeRevert, type DecodedRevert } from "@/lib/errors";
import {
  AutoRepayReason,
  creditErrorMeaning,
  decodeCountry,
  fromUsdc,
  HEALTH_NO_DEBT,
  HEALTH_UNKNOWN,
  scaled,
  toAutoRepayReason,
} from "@/lib/protocol";
import { isTrusted, type Verdict } from "@/lib/verdict";

import { aggregate, failureText, publicClient, type Fallible, type RawCall } from "./chain";
import type { ProtocolSnapshot } from "./protocol";

/**
 * One credit line, read at one block.
 *
 * Everything an account-specific screen needs arrives in a single `aggregate3`: the line itself,
 * the agent's current decision about it, and the wallet balances and allowances the write forms
 * have to check before they can offer an action. Reading it on the server is what makes the
 * read-only walkthrough possible -- a visitor with no wallet still sees a real mainnet line,
 * because nothing here depends on a browser holding a key.
 */

export interface HoldingSnapshot {
  address: Address;
  symbol: string;
  underlying: string;
  decimals: number;
  /** Collateral of this asset posted to the line. */
  postedRaw: bigint;
  postedTokens: number;
  /** The account's own balance of the token, or `null` when the read failed. */
  walletRaw: bigint | null;
  walletTokens: number | null;
  /** How much of it the credit engine may pull, or `null` when the read failed. */
  allowanceRaw: bigint | null;
  /** The mark the engine lends against, or `null` when the oracle refuses. */
  markUsd: number | null;
  /** Posted collateral at that mark. */
  valueUsd: number | null;
  /** True when the oracle will publish a mark for this asset right now. */
  quoting: boolean;
  verdict: Verdict;
}

export interface AutoRepaySnapshot {
  /** A mandate exists, whether or not it is switched on. */
  enrolled: boolean;
  /** The mandate exists and is switched on. */
  enabled: boolean;
  maxPerExecutionUsdc: number;
  maxPerExecutionRaw: bigint;
  /** The ceiling the manager enforces per period, in USDC units. */
  permissionAllowanceRaw: bigint;
  minIntervalSeconds: number;
  triggerHealthBps: number;
  lastExecutedAtUnix: number;
  permissionHash: Hex;
  /** USDC still spendable under the permission in the current period. */
  spendableUsdc: number | null;
  spendableRaw: bigint | null;
  /** What `execute` would do right now. */
  willAct: boolean;
  reason: AutoRepayReason;
  /** The repayment the agent computed, non-zero even for some refusals. */
  amountUsdc: number;
  amountRaw: bigint;
}

export type HealthState = "no-debt" | "unpriced" | "measured";

/**
 * What the engine will actually act on, as opposed to what it will publish.
 *
 * `AftermarketCredit` values a basket asset by asset: a leg whose oracle refuses to mark contributes
 * nothing to either side of the risk calculation, rather than vetoing the whole line. The strict
 * public views refuse to state a total for a partially priced basket -- which is why `borrowPower`
 * reverts and the lens reports `priced: false` -- but `draw`, `withdrawCollateral` and `flag` go on
 * working against the legs that can be priced.
 *
 * Those two facts are both true and they look contradictory on a screen, so both are read. The
 * numbers below come from the engine's own typed reverts: an oversized `draw` answers
 * `Undercollateralized(debt, power)` and a `flag` on a healthy line answers `LineHealthy(debt,
 * threshold)`. Neither is a derivation -- they are the values the contract computed.
 */
export interface ActionableLimits {
  /** Borrowing power the engine will act on, or `null` when it would refuse for another reason. */
  borrowPowerUsdc: number | null;
  /** Seizure threshold the flag and liquidate paths measure against. */
  seizureThresholdUsdc: number | null;
  /** The typed error a draw would hit before it ever reached the collateral test. */
  drawBlockedBy: DecodedRevert | null;
  /** What that error means, in the interface's own voice. */
  drawBlockedMeaning: string | null;
  /** True when the engine accepted the probe outright, which only happens with no cap in the way. */
  unlimited: boolean;
}

export interface LineSnapshot {
  address: Address;
  /** True once the account has called `openLine`. */
  isOpen: boolean;
  /** Whether the Reg-S gate currently admits this account. */
  eligible: boolean;
  /** ISO 3166-1 alpha-2 the account proved, or `null` when unproven. */
  country: string | null;

  debtRaw: bigint;
  debtUsdc: number;
  borrowPowerUsdc: number;
  seizureThresholdUsdc: number;
  /** Health in basis points of the seizure threshold. `null` unless {@link healthState} is `measured`. */
  healthBps: number | null;
  healthState: HealthState;
  /** True when every oracle in the basket produced a mark. */
  priced: boolean;

  flagged: boolean;
  flaggedAtUnix: number;
  /** Instant before which this line cannot be seized, zero when it is not flagged. */
  graceUntilUnix: number;
  openedAtUnix: number;

  holdings: HoldingSnapshot[];
  /** Every posted asset at its borrow mark, or `null` when any of them has no mark. */
  basketUsd: number | null;
  /** The part of the basket whose oracle is quoting. */
  lendableUsd: number;
  /** Assets in the basket the oracle is refusing to mark. */
  refusing: HoldingSnapshot[];

  usdcBalanceUsdc: number | null;
  usdcBalanceRaw: bigint | null;
  usdcAllowanceToCredit: bigint | null;
  usdcAllowanceToVault: bigint | null;

  vaultSharesRaw: bigint | null;
  vaultSharesTokens: number | null;
  /** USDC the account could withdraw from the vault right now. */
  vaultWithdrawableUsdc: number | null;
  vaultWithdrawableRaw: bigint | null;

  autoRepay: AutoRepaySnapshot | null;

  /** What the engine will act on right now, read from its own reverts. */
  limits: ActionableLimits;
}

export type LineRead = Fallible<LineSnapshot>;

const USDC_DECIMALS = 6;

/** A call to a contract this module knows the ABI of. */
function call(address: Address, abi: unknown, functionName: string, args?: readonly unknown[]): RawCall {
  return { address, abi: abi as Abi, functionName, ...(args === undefined ? {} : { args }) };
}

async function read(user: Address, protocol: ProtocolSnapshot): Promise<LineRead> {
  const assets = protocol.assets;

  try {
    const calls: RawCall[] = [
      call(DEPLOYMENT.lens, lensAbi, "userView", [user]),
      call(DEPLOYMENT.credit, creditAbi, "positionOf", [user]),
      call(DEPLOYMENT.autoRepayer, autoRepayerAbi, "simulate", [user]),
      call(DEPLOYMENT.autoRepayer, autoRepayerAbi, "enrollmentOf", [user]),
      call(DEPLOYMENT.autoRepayer, autoRepayerAbi, "spendableFor", [user]),
      call(DEPLOYMENT.usdc, erc20Abi, "balanceOf", [user]),
      call(DEPLOYMENT.usdc, erc20Abi, "allowance", [user, DEPLOYMENT.credit]),
      call(DEPLOYMENT.usdc, erc20Abi, "allowance", [user, DEPLOYMENT.vault]),
      call(DEPLOYMENT.vault, vaultAbi, "balanceOf", [user]),
      call(DEPLOYMENT.vault, vaultAbi, "maxWithdraw", [user]),
      ...assets.map((asset) => call(asset.address, erc20Abi, "balanceOf", [user])),
      ...assets.map((asset) => call(asset.address, erc20Abi, "allowance", [user, DEPLOYMENT.credit])),
    ];

    const [results, limits] = await Promise.all([aggregate(calls), readActionableLimits(user)]);
    const bytesAt = (index: number): Hex | null => {
      const result = results[index];
      return result !== undefined && result.success ? result.returnData : null;
    };
    const uintAt = (index: number): bigint | null => {
      const data = bytesAt(index);
      return data === null ? null : decodeFunctionResult({ abi: erc20Abi, functionName: "balanceOf", data });
    };

    const userData = bytesAt(0);
    if (userData === null) {
      return { ok: false, error: "AftermarketLens did not answer for this account." };
    }
    const view = decodeFunctionResult({ abi: lensAbi, functionName: "userView", data: userData });

    const positionData = bytesAt(1);
    const position =
      positionData === null
        ? null
        : decodeFunctionResult({ abi: creditAbi, functionName: "positionOf", data: positionData });

    const posted = new Map<string, bigint>();
    view.collateral.forEach((address, index) => {
      posted.set(address.toLowerCase(), view.amounts[index] ?? 0n);
    });

    const base = 10;
    const holdings: HoldingSnapshot[] = assets.map((asset, index) => {
      const postedRaw = posted.get(asset.address.toLowerCase()) ?? 0n;
      const walletRaw = uintAt(base + index);
      const allowanceRaw = uintAt(base + assets.length + index);
      const markUsd = asset.quote === null || !isTrusted(asset.verdict) ? null : asset.quote.markBorrowUsd;
      const postedTokens = scaled(postedRaw, asset.decimals);
      return {
        address: asset.address,
        symbol: asset.symbol,
        underlying: asset.underlying,
        decimals: asset.decimals,
        postedRaw,
        postedTokens,
        walletRaw,
        walletTokens: walletRaw === null ? null : scaled(walletRaw, asset.decimals),
        allowanceRaw,
        markUsd,
        valueUsd: markUsd === null ? null : postedTokens * markUsd,
        quoting: isTrusted(asset.verdict),
        verdict: asset.verdict,
      };
    });

    const inBasket = holdings.filter((holding) => holding.postedRaw > 0n);
    const refusing = inBasket.filter((holding) => !holding.quoting);
    const lendableUsd = inBasket.reduce((sum, holding) => sum + (holding.valueUsd ?? 0), 0);
    const basketUsd = refusing.length === 0 ? lendableUsd : null;

    const healthState: HealthState =
      view.healthBps === HEALTH_NO_DEBT ? "no-debt" : view.healthBps === HEALTH_UNKNOWN ? "unpriced" : "measured";

    return {
      ok: true,
      value: {
        address: user,
        isOpen: position !== null && position.openedAt > 0n,
        eligible: view.eligible,
        country: decodeCountry(view.country),

        debtRaw: view.debt,
        debtUsdc: fromUsdc(view.debt),
        borrowPowerUsdc: fromUsdc(view.borrowPower),
        seizureThresholdUsdc: fromUsdc(view.seizureThreshold),
        healthBps: healthState === "measured" ? Number(view.healthBps) : null,
        healthState,
        priced: view.priced,

        flagged: view.flaggedAt > 0n,
        flaggedAtUnix: Number(view.flaggedAt),
        graceUntilUnix: Number(view.graceUntil),
        openedAtUnix: position === null ? 0 : Number(position.openedAt),

        holdings,
        basketUsd,
        lendableUsd,
        refusing,

        usdcBalanceUsdc: mapNullable(uintAt(5), fromUsdc),
        usdcBalanceRaw: uintAt(5),
        usdcAllowanceToCredit: uintAt(6),
        usdcAllowanceToVault: uintAt(7),

        vaultSharesRaw: uintAt(8),
        vaultSharesTokens: mapNullable(uintAt(8), (value) =>
          scaled(value, protocol.vaultDecimals ?? USDC_DECIMALS),
        ),
        vaultWithdrawableUsdc: mapNullable(uintAt(9), fromUsdc),
        vaultWithdrawableRaw: uintAt(9),

        autoRepay: readAutoRepay(bytesAt(2), bytesAt(3), uintAt(4)),
        limits,
      },
    };
  } catch (error) {
    return { ok: false, error: failureText(error) };
  }
}

function mapNullable<T, U>(value: T | null, map: (value: T) => U): U | null {
  return value === null ? null : map(value);
}

/**
 * An amount no basket in this deployment could ever support, used only to make `draw` answer with
 * the borrowing power it measured. Well inside `uint128`, so it trips the collateral test rather
 * than the accounting overflow guard.
 */
const PROBE_AMOUNT = 10n ** 18n;

async function readActionableLimits(user: Address): Promise<ActionableLimits> {
  const [draw, flag] = await Promise.all([
    probe(() =>
      publicClient.simulateContract({
        address: DEPLOYMENT.credit,
        abi: creditAbi,
        functionName: "draw",
        args: [PROBE_AMOUNT, user],
        account: user,
      }),
    ),
    probe(() =>
      publicClient.simulateContract({
        address: DEPLOYMENT.credit,
        abi: creditAbi,
        functionName: "flag",
        args: [user],
        account: user,
      }),
    ),
  ]);

  const undercollateralized = draw?.name === "Undercollateralized" ? draw : null;
  const healthy = flag?.name === "LineHealthy" ? flag : null;

  return {
    borrowPowerUsdc: undercollateralized === null ? null : usdcArg(undercollateralized, 1),
    seizureThresholdUsdc: healthy === null ? null : usdcArg(healthy, 1),
    drawBlockedBy: undercollateralized === null ? draw : null,
    drawBlockedMeaning: undercollateralized !== null || draw === null ? null : creditErrorMeaning(draw.name),
    unlimited: draw === null,
  };
}

/** Runs a state-changing call as an `eth_call` and hands back the typed revert it produced. */
async function probe(run: () => Promise<unknown>): Promise<DecodedRevert | null> {
  try {
    await run();
    return null;
  } catch (error) {
    return decodeRevert(error, creditAbi as unknown as Abi);
  }
}

/** The `index`-th argument of a decoded revert, read as a USDC amount. */
function usdcArg(revert: DecodedRevert, index: number): number | null {
  const raw = revert.args[index]?.value;
  if (raw === undefined) return null;
  try {
    return fromUsdc(BigInt(raw));
  } catch {
    return null;
  }
}

function readAutoRepay(
  simulateData: Hex | null,
  enrollmentData: Hex | null,
  spendable: bigint | null,
): AutoRepaySnapshot | null {
  if (simulateData === null || enrollmentData === null) return null;

  const [willAct, reason, amount] = decodeFunctionResult({
    abi: autoRepayerAbi,
    functionName: "simulate",
    data: simulateData,
  });
  const enrollment = decodeFunctionResult({
    abi: autoRepayerAbi,
    functionName: "enrollmentOf",
    data: enrollmentData,
  });

  const enrolled = enrollment.permissionHash !== `0x${"0".repeat(64)}`;
  return {
    enrolled,
    enabled: enrolled && enrollment.policy.enabled,
    maxPerExecutionUsdc: fromUsdc(enrollment.policy.maxPerExecution),
    maxPerExecutionRaw: enrollment.policy.maxPerExecution,
    permissionAllowanceRaw: enrollment.permission.allowance,
    minIntervalSeconds: enrollment.policy.minInterval,
    triggerHealthBps: enrollment.policy.triggerHealthBps,
    lastExecutedAtUnix: Number(enrollment.lastExecutedAt),
    permissionHash: enrollment.permissionHash,
    spendableUsdc: mapNullable(spendable, fromUsdc),
    spendableRaw: spendable,
    willAct,
    reason: toAutoRepayReason(reason),
    amountUsdc: fromUsdc(amount),
    amountRaw: amount,
  };
}

/** Deduplicated per request, keyed on the address. */
export const readLine = cache(read);
