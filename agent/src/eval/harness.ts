import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  encodeAbiParameters,
  encodeFunctionData,
  getContractAddress,
  http,
  keccak256,
  pad,
  parseAbiParameters,
  toHex,
  type Abi,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type TestClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { aftermarketCreditAbi, autoRepayerAbi, erc20Abi, spendPermissionManagerAbi } from "../abi.js";
import { BASE_MAINNET, BASE_MAINNET_ORACLES } from "../addresses.js";
import { readPriceError } from "../reader.js";
import {
  aftermarketOracleAbi,
  mockAggregatorAbi,
  mockCalendarAbi,
  mockErc20Abi,
  mockPoolAbi,
  smartWalletAbi,
  smartWalletFactoryAbi,
  spendPermissionApproveAbi,
  vaultAbi,
} from "./abi.js";
import { ArtifactLoader, type Artifact } from "./artifacts.js";
import type { EnrollOptions, OracleState, PolicyInput, ScenarioApi, SessionName } from "./scenarios.js";

/** Coinbase's smart-wallet factory on Base. Verified live on the fork before the eval deploys anything. */
const SMART_WALLET_FACTORY = "0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a" as Address;

/** Anvil's first deterministic account, used as deployer, supplier, keeper and third-party repayer. */
const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as Hex;

/** `Session` ordinals, mirrored from `contracts/src/libraries/Types.sol`. */
const SESSION_ORDINAL: Record<SessionName, number> = {
  REGULAR: 0,
  PRE: 1,
  POST: 2,
  CLOSED_OVERNIGHT: 3,
  CLOSED_WEEKEND: 4,
  CLOSED_HOLIDAY: 5,
};

/**
 * The `AftermarketOracle` configuration every eval oracle is deployed with.
 *
 * These are the exact parameters the six mainnet oracles were deployed with, decoded from the
 * constructor arguments recorded in `contracts/deployments/8453.json`. Using the live policy rather
 * than a convenient one is the difference between an eval that tests Aftermarket and an eval that
 * tests a fixture: the 300 bps holiday divergence band the AMZNc oracle is currently breaching is
 * the same 300 bps the eval's own oracles enforce.
 */
const ORACLE_POLICY = {
  twapWindow: 1_800,
  stalenessBudget: [3_600, 21_600, 21_600, 90_000, 273_600, 360_000] as const,
  divergenceBandBps: [500, 500, 500, 200, 250, 300] as const,
  baseHaircutBps: 25,
  haircutSlopeBpsPerHour: 15,
  maxHaircutBps: 500,
  minPoolLiquidityUsd: 25_000n * 10n ** 18n,
  minMultiplier: 10n ** 16n,
  maxMultiplier: 1_000n * 10n ** 18n,
} as const;

const COLLATERAL_DECIMALS = 8;
const FEED_DECIMALS = 8;
const USDC_UNIT = 10n ** 6n;
const WAD = 10n ** 18n;

/** Risk policy for every eval collateral asset. Mirrors the shape `DeployCore` uses on mainnet. */
const ASSET_PARAMS = {
  advanceOpenBps: 5_000,
  advanceClosedBps: 3_500,
  liqThresholdOpenBps: 7_000,
  liqThresholdClosedBps: 8_000,
  liqBonusBps: 700,
  cap: 10_000_000n * 10n ** 8n,
} as const;

/** Every address the deployed fixture exposes, for the results artifact. */
export interface EvalDeployment {
  readonly credit: Address;
  readonly vault: Address;
  readonly autoRepayer: Address;
  readonly lens: Address;
  readonly calendar: Address;
  readonly eligibility: Address;
  readonly rateModel: Address;
  readonly swapAdapter: Address;
  readonly usdc: Address;
  readonly spendPermissionManager: Address;
  readonly smartWalletFactory: Address;
  readonly usdcBalanceSlot: number;
}

/** What the live mainnet oracles were doing at the forked block, recorded as evidence. */
export interface LiveOracleEvidence {
  readonly ticker: string;
  readonly oracle: Address;
  readonly verdict: number;
  readonly session: number;
  readonly divergenceBps: string;
  readonly divergenceBand: string;
  readonly feedAge: string;
  readonly priceReverts: boolean;
  readonly priceError: string | null;
}

export interface HarnessOptions {
  readonly rpcUrl: string;
  readonly repoRoot: string;
  /** How many collateral/feed/pool/oracle sets to pre-deploy — one per scenario. */
  readonly lineCount: number;
}

const artifactNames = {
  erc20: { name: "MockERC20" },
  calendar: { name: "MockCalendar" },
  eligibility: { name: "MockEligibility" },
  swapAdapter: { name: "MockSwapAdapter" },
  aggregator: { name: "MockAggregatorV3" },
  pool: { name: "MockCLPool" },
  oracle: { name: "AftermarketOracle" },
  rateModel: { name: "SessionRateModel" },
  credit: { name: "AftermarketCredit" },
  vault: { name: "AftermarketVault" },
  autoRepayer: { name: "AutoRepayer" },
  lens: { name: "AftermarketLens" },
} as const;

/**
 * The world the eval runs in: a fork of Base mainnet with a full Aftermarket deployment on top.
 *
 * Three things on that fork are real rather than simulated, and they are the three that matter.
 * The **USDC** every repayment moves is Circle's deployed token at its mainnet address. The
 * **spend permissions** are approved and spent through Coinbase's deployed `SpendPermissionManager`
 * — so `used + value <= allowance` is enforced by the same bytecode that enforces it in production,
 * not by a stub. And the borrowers are real **CoinbaseSmartWallet** accounts created through the
 * live factory, because that is the only account shape the manager can drive.
 *
 * What is deployed fresh is Aftermarket itself, compiled from the same sources as the mainnet
 * contracts, plus a controllable feed, pool and calendar per line. Those have to be controllable:
 * a graded eval needs a line that is exactly one basis point above its trigger, and a market that is
 * on a specific holiday, and neither of those can be arranged by waiting.
 */
export class EvalHarness {
  private readonly sendAsDeployer: (request: SendRequest) => Promise<Hex>;

  private constructor(
    readonly rpcUrl: string,
    readonly publicClient: PublicClient,
    readonly walletClient: WalletClient,
    readonly testClient: TestClient,
    readonly deployment: EvalDeployment,
    readonly deployer: Address,
    private readonly lines: DeployedLine[],
    private readonly usdcBalanceSlot: bigint,
  ) {
    this.sendAsDeployer = makeSender(publicClient, walletClient, deployer);
  }

  /** Deploys the whole fixture and returns it ready to run scenarios against. */
  static async deploy(options: HarnessOptions): Promise<EvalHarness> {
    const account = privateKeyToAccount(DEPLOYER_KEY);
    const transport = http(options.rpcUrl, { timeout: 60_000 });
    const publicClient = createPublicClient({ chain: base as Chain, transport });
    const walletClient = createWalletClient({ account, chain: base as Chain, transport });
    const testClient = createTestClient({ chain: base as Chain, mode: "anvil", transport });

    const loader = new ArtifactLoader(options.repoRoot);
    const artifacts = await loadArtifacts(loader);

    await assertLiveContract(publicClient, BASE_MAINNET.usdc, "USDC");
    await assertLiveContract(publicClient, BASE_MAINNET.spendPermissionManager, "SpendPermissionManager");
    await assertLiveContract(publicClient, SMART_WALLET_FACTORY, "CoinbaseSmartWalletFactory");

    const usdcBalanceSlot = await findUsdcBalanceSlot(publicClient, testClient);
    const deploy = makeDeployer(publicClient, walletClient, account.address);
    const send = makeSender(publicClient, walletClient, account.address);

    const calendar = await deploy(artifacts.calendar, [SESSION_ORDINAL.REGULAR, 0n]);
    const eligibility = await deploy(artifacts.eligibility, []);
    const swapAdapter = await deploy(artifacts.swapAdapter, []);
    // A zero-rate model. Interest is not what the eval is measuring, and a debt that drifts by a few
    // units between setting a scenario up and evaluating it would make the one-unit boundary
    // scenarios untestable. Every other parameter of the engine is the deployed one.
    const rateModel = await deploy(artifacts.rateModel, [
      calendar,
      0n,
      0n,
      0n,
      8n * 10n ** 17n,
      [WAD, WAD, WAD, WAD, WAD, WAD],
    ]);

    const nonce = await publicClient.getTransactionCount({ address: account.address });
    const predictedVault = getContractAddress({ from: account.address, nonce: BigInt(nonce) + 1n });
    const credit = await deploy(artifacts.credit, [
      BASE_MAINNET.usdc,
      predictedVault,
      calendar,
      eligibility,
      rateModel,
      swapAdapter,
      100,
      account.address,
    ]);
    const vault = await deploy(artifacts.vault, [BASE_MAINNET.usdc, credit, "Aftermarket USDC", "amUSDC"]);
    if (vault.toLowerCase() !== predictedVault.toLowerCase()) {
      throw new Error(`vault landed at ${vault}, expected ${predictedVault}`);
    }
    const autoRepayer = await deploy(artifacts.autoRepayer, [credit]);

    // The calendar has to be seeded before anything draws: `AftermarketCredit` refuses to open risk
    // it cannot promise a grace window for, and a calendar reporting no next open is exactly that.
    const now = await blockTimestamp(publicClient);
    await send({
      address: calendar,
      abi: mockCalendarAbi,
      functionName: "set",
      args: [SESSION_ORDINAL.REGULAR, 0n, now + 86_400n, now - 86_400n],
    });

    const lines: DeployedLine[] = [];
    for (let index = 0; index < options.lineCount; index += 1) {
      lines.push(
        await deployLine({
          index,
          artifacts,
          calendar,
          credit,
          deploy,
          send,
          publicClient,
        }),
      );
    }

    const lens = await deploy(artifacts.lens, [credit, autoRepayer, lines.map((line) => line.collateral)]);

    const deployment: EvalDeployment = {
      credit,
      vault,
      autoRepayer,
      lens,
      calendar,
      eligibility,
      rateModel,
      swapAdapter,
      usdc: BASE_MAINNET.usdc,
      spendPermissionManager: BASE_MAINNET.spendPermissionManager,
      smartWalletFactory: SMART_WALLET_FACTORY,
      usdcBalanceSlot: Number(usdcBalanceSlot),
    };

    const harness = new EvalHarness(
      options.rpcUrl,
      publicClient,
      walletClient,
      testClient,
      deployment,
      account.address,
      lines,
      usdcBalanceSlot,
    );

    // Fund the lender side so every scenario can actually draw.
    await harness.setUsdcBalance(account.address, 20_000_000n * USDC_UNIT);
    await send({
      address: BASE_MAINNET.usdc,
      abi: erc20Abi,
      functionName: "approve",
      args: [vault, 20_000_000n * USDC_UNIT],
    });
    await send({ address: vault, abi: vaultAbi, functionName: "deposit", args: [10_000_000n * USDC_UNIT, account.address] });

    return harness;
  }

  /** Reads the deployed mainnet oracles on the fork, so the results artifact cites live state. */
  async readLiveOracles(): Promise<LiveOracleEvidence[]> {
    const evidence: LiveOracleEvidence[] = [];
    for (const [ticker, oracle] of Object.entries(BASE_MAINNET_ORACLES)) {
      let quote;
      try {
        quote = await this.publicClient.readContract({ address: oracle, abi: aftermarketOracleAbi, functionName: "peek" });
      } catch {
        continue;
      }
      const priceError = await readPriceError(this.publicClient, oracle);
      evidence.push({
        ticker,
        oracle,
        verdict: quote.verdict,
        session: quote.session,
        divergenceBps: quote.divergenceBps.toString(),
        divergenceBand: quote.divergenceBand.toString(),
        feedAge: quote.feedAge.toString(),
        priceReverts: priceError !== null,
        priceError,
      });
    }
    return evidence;
  }

  /** Writes a USDC balance directly, the only way to fund an account on a fork of a live token. */
  async setUsdcBalance(account: Address, amount: bigint): Promise<void> {
    await this.testClient.setStorageAt({
      address: BASE_MAINNET.usdc,
      index: balanceSlotKey(account, this.usdcBalanceSlot),
      value: pad(toHex(amount), { size: 32 }),
    });
  }

  /** Puts the shared calendar back to a plain open market between scenarios. */
  async resetWorld(): Promise<void> {
    const now = await blockTimestamp(this.publicClient);
    await this.send({ address: this.deployment.calendar, abi: mockCalendarAbi, functionName: "setReverting", args: [false] });
    await this.send({
      address: this.deployment.calendar,
      abi: mockCalendarAbi,
      functionName: "set",
      args: [SESSION_ORDINAL.REGULAR, 0n, now + 86_400n, now - 86_400n],
    });
  }

  /** The scenario-facing API for line `index`, with its own asset, feed, pool, oracle and wallet. */
  async lineFor(index: number): Promise<EvalLine> {
    const line = this.lines[index];
    if (!line) throw new Error(`no line deployed at index ${index}`);
    const wallet = await this.createSmartWallet(index);
    return new EvalLine(this, line, wallet);
  }

  /** Creates a fresh CoinbaseSmartWallet through the live factory and makes the manager an owner. */
  private async createSmartWallet(index: number): Promise<BorrowerWallet> {
    const key = pad(toHex(BigInt(index) + 1_000_001n), { size: 32 }) as Hex;
    const owner = privateKeyToAccount(key);
    await this.testClient.setBalance({ address: owner.address, value: 10n ** 19n });

    const owners = [pad(owner.address, { size: 32 })] as Hex[];
    const address = await this.publicClient.readContract({
      address: SMART_WALLET_FACTORY,
      abi: smartWalletFactoryAbi,
      functionName: "getAddress",
      args: [owners, 0n],
    });

    const ownerWallet = createWalletClient({
      account: owner,
      chain: base as Chain,
      transport: http(this.rpcUrl, { timeout: 60_000 }),
    });
    const sendAsOwner = makeSender(this.publicClient, ownerWallet, owner.address);

    await sendAsOwner({
      address: SMART_WALLET_FACTORY,
      abi: smartWalletFactoryAbi,
      functionName: "createAccount",
      args: [owners, 0n],
      value: 0n,
    });
    // The manager drives the account through `execute`, so it has to be an owner. This is exactly
    // what a Base wallet does when a user grants a spend permission.
    await sendAsOwner({
      address,
      abi: smartWalletAbi,
      functionName: "addOwnerAddress",
      args: [BASE_MAINNET.spendPermissionManager],
    });

    return { address, owner: owner.address, send: sendAsOwner };
  }

  /** Sends a transaction as the deployer, simulating first. */
  send(request: SendRequest): Promise<Hex> {
    return this.sendAsDeployer(request);
  }

  /** Advances the fork clock and mines. */
  async warp(seconds: number): Promise<void> {
    const now = await blockTimestamp(this.publicClient);
    await this.testClient.setNextBlockTimestamp({ timestamp: now + BigInt(seconds) });
    await this.testClient.mine({ blocks: 1 });
  }

  /** Current block timestamp on the fork. */
  now(): Promise<bigint> {
    return blockTimestamp(this.publicClient);
  }
}

interface DeployedLine {
  readonly index: number;
  readonly collateral: Address;
  readonly feed: Address;
  readonly pool: Address;
  readonly oracle: Address;
}

interface BorrowerWallet {
  readonly address: Address;
  readonly owner: Address;
  readonly send: (request: SendRequest) => Promise<Hex>;
}

/** One scenario's borrower, plus the private feed, pool and oracle that price its collateral. */
export class EvalLine implements ScenarioApi {
  private oracleState: OracleState = { kind: "trusted" };
  private permission: PermissionStruct | null = null;
  private anchorUsd = 200n * WAD;

  constructor(
    private readonly harness: EvalHarness,
    private readonly line: DeployedLine,
    private readonly wallet: BorrowerWallet,
  ) {}

  /** The borrower's address — the account the keeper evaluates. */
  get account(): Address {
    return this.wallet.address;
  }

  async openLine(options: { collateralShares?: bigint; drawUsdc?: bigint } = {}): Promise<void> {
    const shares = options.collateralShares ?? 1_000n;
    const collateralRaw = shares * 10n ** BigInt(COLLATERAL_DECIMALS);
    const draw = options.drawUsdc ?? 95_000n * USDC_UNIT;

    await this.applyOracleState();
    await this.harness.send({
      address: this.line.collateral,
      abi: mockErc20Abi,
      functionName: "mint",
      args: [this.wallet.address, collateralRaw],
    });
    await this.harness.setUsdcBalance(this.wallet.address, 1_000_000n * USDC_UNIT);

    const credit = this.harness.deployment.credit;
    const calls = [
      {
        target: this.line.collateral,
        value: 0n,
        data: encodeFunctionData({ abi: mockErc20Abi, functionName: "approve", args: [credit, collateralRaw] }),
      },
      { target: credit, value: 0n, data: encodeFunctionData({ abi: aftermarketCreditAbi, functionName: "openLine" }) },
      {
        target: credit,
        value: 0n,
        data: encodeFunctionData({
          abi: aftermarketCreditAbi,
          functionName: "depositCollateral",
          args: [this.line.collateral, collateralRaw],
        }),
      },
      ...(draw > 0n
        ? [
            {
              target: credit,
              value: 0n,
              data: encodeFunctionData({
                abi: aftermarketCreditAbi,
                functionName: "draw",
                args: [draw, this.wallet.address],
              }),
            },
          ]
        : []),
    ];
    await this.wallet.send({ address: this.wallet.address, abi: smartWalletAbi, functionName: "executeBatch", args: [calls], value: 0n });
  }

  async setHealth(targetHealthBps: number): Promise<bigint> {
    const target = BigInt(targetHealthBps);
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const current = await this.health();
      if (current === 0n) throw new Error(`cannot set health on an unpriced line (${this.line.index})`);
      if (absDiff(current, target) <= 2n) return current;
      // The seizure threshold is linear in the anchor price, so one proportional step lands on the
      // target and the remaining passes only mop up integer truncation.
      this.anchorUsd = (this.anchorUsd * target) / current;
      if (this.anchorUsd === 0n) throw new Error("health target requires a non-positive price");
      await this.applyOracleState();
    }
    const settled = await this.health();
    if (absDiff(settled, target) > 25n) {
      throw new Error(`could not drive line ${this.line.index} to ${target} bps; settled at ${settled} bps`);
    }
    return settled;
  }

  /**
   * Moves the price until the repayment the agent would make equals `targetAmount`.
   *
   * Used by the allowance scenarios, where the interesting quantity is the size of the request
   * relative to what is left of the permission rather than the health that produced it.
   */
  async setHealthForAmount(targetAmount: bigint): Promise<bigint> {
    const debt = await this.debt();
    const policy = await this.policy();
    if (debt === 0n) throw new Error("cannot size a repayment against a line with no debt");
    const recoveryBps = BigInt(policy.triggerHealthBps) + 500n;
    // amount = debt - threshold * BPS / (trigger + margin), and health = threshold * BPS / debt,
    // so health = (debt - amount) * (trigger + margin) / debt.
    const health = ((debt - targetAmount) * recoveryBps) / debt;
    if (health <= 0n) throw new Error(`target repayment ${targetAmount} exceeds the whole debt`);
    return this.setHealth(Number(health));
  }

  async health(): Promise<bigint> {
    return this.harness.publicClient.readContract({
      address: this.harness.deployment.autoRepayer,
      abi: autoRepayerAbi,
      functionName: "healthBpsOf",
      args: [this.wallet.address],
    });
  }

  async debt(): Promise<bigint> {
    return this.harness.publicClient.readContract({
      address: this.harness.deployment.credit,
      abi: aftermarketCreditAbi,
      functionName: "debtOf",
      args: [this.wallet.address],
    });
  }

  async setOracle(state: OracleState): Promise<void> {
    this.oracleState = state;
    await this.applyOracleState();
  }

  /**
   * Re-applies the line's oracle state against the current block.
   *
   * Called again immediately before evaluation because a feed's age is measured from now: a
   * scenario that warps two hours to expire a permission would otherwise also make its perfectly
   * healthy feed stale, and fail for a reason it was not about.
   */
  async applyOracleState(): Promise<void> {
    const state = this.oracleState;
    const now = await this.harness.now();
    const answer = this.anchorUsd / 10n ** BigInt(18 - FEED_DECIMALS);

    switch (state.kind) {
      case "trusted": {
        await this.setFeed(answer, now);
        await this.setPoolDepth(0n);
        await this.setMultiplier(WAD);
        return;
      }
      case "stale": {
        await this.setFeed(answer, now - BigInt(Math.round(state.ageHours * 3_600)));
        await this.setPoolDepth(0n);
        await this.setMultiplier(WAD);
        return;
      }
      case "thin": {
        await this.setFeed(answer, now);
        await this.setPoolDepth(0n);
        await this.setMultiplier(WAD);
        return;
      }
      case "halted": {
        await this.setFeed(answer, now);
        await this.setPoolDepth(0n);
        // A multiplier outside the bounds the oracle was configured for is a corporate action in
        // flight: the redemption ratio between one token and one real share is being restated.
        await this.setMultiplier(ORACLE_POLICY.maxMultiplier * 2n);
        return;
      }
      case "trusted-closed": {
        await this.setFeed(answer, now);
        await this.setMultiplier(WAD);
        await this.setPoolDepth(250_000n * USDC_UNIT);
        await this.syncPoolToAnchor(0);
        return;
      }
      case "divergent": {
        await this.setFeed(answer, now);
        await this.setMultiplier(WAD);
        await this.setPoolDepth(250_000n * USDC_UNIT);
        await this.syncPoolToAnchor(state.poolPremiumBps);
        return;
      }
    }
  }

  async setSession(session: SessionName, closedForHours = 0): Promise<void> {
    const now = await this.harness.now();
    await this.harness.send({
      address: this.harness.deployment.calendar,
      abi: mockCalendarAbi,
      functionName: "set",
      args: [SESSION_ORDINAL[session], BigInt(Math.round(closedForHours * 3_600)), now + 86_400n, now - 86_400n],
    });
  }

  /** Makes `AftermarketCredit.positionOf` revert outright, by taking the calendar offline. */
  async breakCalendar(): Promise<void> {
    await this.harness.send({
      address: this.harness.deployment.calendar,
      abi: mockCalendarAbi,
      functionName: "setReverting",
      args: [true],
    });
  }

  async enroll(options: EnrollOptions = {}): Promise<void> {
    const now = await this.harness.now();
    const policy = { ...DEFAULT_POLICY, ...options.policy };
    const permission: PermissionStruct = {
      account: this.wallet.address,
      spender: this.harness.deployment.autoRepayer,
      token: BASE_MAINNET.usdc,
      allowance: options.allowance ?? 100_000n * USDC_UNIT,
      period: 30 * 86_400,
      start: Number(now) + (options.startsInSeconds ?? 0),
      end: Number(now) + (options.validForSeconds ?? 365 * 86_400),
      salt: BigInt(this.line.index) * 1_000n + BigInt(Math.floor(Number(now) % 1_000)),
      extraData: "0x",
    };
    this.permission = permission;

    await this.wallet.send({
      address: this.wallet.address,
      abi: smartWalletAbi,
      functionName: "executeBatch",
      value: 0n,
      args: [
        [
          {
            target: this.harness.deployment.spendPermissionManager,
            value: 0n,
            data: encodeFunctionData({ abi: spendPermissionApproveAbi, functionName: "approve", args: [permission] }),
          },
          {
            target: this.harness.deployment.autoRepayer,
            value: 0n,
            data: encodeFunctionData({ abi: autoRepayerAbi, functionName: "enroll", args: [permission, policy] }),
          },
        ],
      ],
    });
  }

  async setPolicy(policy: Partial<PolicyInput>): Promise<void> {
    const current = await this.policy();
    const next = { ...current, ...policy };
    await this.wallet.send({
      address: this.wallet.address,
      abi: smartWalletAbi,
      functionName: "execute",
      value: 0n,
      args: [
        this.harness.deployment.autoRepayer,
        0n,
        encodeFunctionData({ abi: autoRepayerAbi, functionName: "setPolicy", args: [next] }),
      ],
    });
  }

  async withdrawMandate(): Promise<void> {
    await this.wallet.send({
      address: this.wallet.address,
      abi: smartWalletAbi,
      functionName: "execute",
      value: 0n,
      args: [this.harness.deployment.autoRepayer, 0n, encodeFunctionData({ abi: autoRepayerAbi, functionName: "withdraw" })],
    });
  }

  async revokePermissionAtManager(): Promise<void> {
    if (!this.permission) throw new Error("no permission to revoke; enroll first");
    await this.wallet.send({
      address: this.wallet.address,
      abi: smartWalletAbi,
      functionName: "execute",
      value: 0n,
      args: [
        this.harness.deployment.spendPermissionManager,
        0n,
        encodeFunctionData({ abi: spendPermissionManagerAbi, functionName: "revoke", args: [this.permission] }),
      ],
    });
  }

  async flagLine(): Promise<void> {
    await this.harness.send({
      address: this.harness.deployment.credit,
      abi: aftermarketCreditAbi,
      functionName: "flag",
      args: [this.wallet.address],
    });
  }

  async cureLine(): Promise<void> {
    await this.harness.send({
      address: this.harness.deployment.credit,
      abi: aftermarketCreditAbi,
      functionName: "cure",
      args: [this.wallet.address],
    });
  }

  async repayFromThirdParty(usdc: bigint): Promise<void> {
    await this.harness.send({
      address: BASE_MAINNET.usdc,
      abi: erc20Abi,
      functionName: "approve",
      args: [this.harness.deployment.credit, usdc],
    });
    await this.harness.send({
      address: this.harness.deployment.credit,
      abi: aftermarketCreditAbi,
      functionName: "repayOnBehalf",
      args: [this.wallet.address, usdc],
    });
  }

  async executeNow(): Promise<bigint> {
    const before = await this.debt();
    await this.harness.send({
      address: this.harness.deployment.autoRepayer,
      abi: autoRepayerAbi,
      functionName: "execute",
      args: [this.wallet.address],
    });
    return before - (await this.debt());
  }

  async requiredAmount(): Promise<bigint> {
    const [, , amount] = await this.harness.publicClient.readContract({
      address: this.harness.deployment.autoRepayer,
      abi: autoRepayerAbi,
      functionName: "simulate",
      args: [this.wallet.address],
    });
    return amount;
  }

  async spendable(): Promise<bigint> {
    return this.harness.publicClient.readContract({
      address: this.harness.deployment.autoRepayer,
      abi: autoRepayerAbi,
      functionName: "spendableFor",
      args: [this.wallet.address],
    });
  }

  async policy(): Promise<PolicyInput> {
    const enrollment = await this.harness.publicClient.readContract({
      address: this.harness.deployment.autoRepayer,
      abi: autoRepayerAbi,
      functionName: "enrollmentOf",
      args: [this.wallet.address],
    });
    if (enrollment.permissionHash === ZERO_HASH) return { ...DEFAULT_POLICY };
    return {
      maxPerExecution: enrollment.policy.maxPerExecution,
      minInterval: enrollment.policy.minInterval,
      triggerHealthBps: enrollment.policy.triggerHealthBps,
      enabled: enrollment.policy.enabled,
    };
  }

  async warp(seconds: number): Promise<void> {
    await this.harness.warp(seconds);
    await this.applyOracleState();
  }

  /** The borrower's own USDC, used to prove that a refused scenario moved no money. */
  async usdcBalance(): Promise<bigint> {
    return this.harness.publicClient.readContract({
      address: BASE_MAINNET.usdc,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [this.wallet.address],
    });
  }

  private async setFeed(answer: bigint, updatedAt: bigint): Promise<void> {
    await this.harness.send({
      address: this.line.feed,
      abi: mockAggregatorAbi,
      functionName: "set",
      args: [answer, updatedAt],
    });
  }

  private async setMultiplier(multiplier: bigint): Promise<void> {
    await this.harness.send({
      address: this.line.collateral,
      abi: mockErc20Abi,
      functionName: "setMultiplier",
      args: [multiplier],
    });
  }

  private async setPoolDepth(usdc: bigint): Promise<void> {
    await this.harness.setUsdcBalance(this.line.pool, usdc);
  }

  /**
   * Points the pool's TWAP at the anchor price, plus an optional premium.
   *
   * Found by bisection on `peek().poolPrice` rather than by reimplementing Slipstream's tick maths
   * off chain. The oracle's own view of the pool is the only definition of "the pool price" that
   * matters here, and asking it directly cannot drift from what it will compute a block later.
   */
  private async syncPoolToAnchor(premiumBps: number): Promise<void> {
    const target = (this.anchorUsd * BigInt(10_000 + premiumBps)) / 10_000n;
    let low = -300_000;
    let high = 300_000;
    let best = 0;
    let bestDiff: bigint | null = null;

    for (let step = 0; step < 40 && low <= high; step += 1) {
      const mid = Math.trunc((low + high) / 2);
      const price = await this.poolPriceAtTick(mid);
      const diff = absDiff(price, target);
      if (bestDiff === null || diff < bestDiff) {
        bestDiff = diff;
        best = mid;
      }
      if (price === target) break;
      // Pool price falls as the tick rises for this token ordering (collateral is token1).
      if (price > target) low = mid + 1;
      else high = mid - 1;
    }

    await this.setTick(best);
    const settled = await this.poolPrice();
    const drift = (absDiff(settled, target) * 10_000n) / target;
    if (drift > 30n) {
      throw new Error(`could not point the pool at ${target} (settled ${settled}, ${drift} bps away)`);
    }
  }

  private async poolPriceAtTick(tick: number): Promise<bigint> {
    await this.setTick(tick);
    return this.poolPrice();
  }

  private async setTick(tick: number): Promise<void> {
    await this.harness.send({
      address: this.line.pool,
      abi: mockPoolAbi,
      functionName: "setMeanTick",
      args: [tick, ORACLE_POLICY.twapWindow],
    });
  }

  private async poolPrice(): Promise<bigint> {
    const quote = await this.harness.publicClient.readContract({
      address: this.line.oracle,
      abi: aftermarketOracleAbi,
      functionName: "peek",
    });
    return quote.poolPrice;
  }
}

const DEFAULT_POLICY: PolicyInput = {
  maxPerExecution: 50_000n * USDC_UNIT,
  minInterval: 3_600,
  triggerHealthBps: 11_000,
  enabled: true,
};

interface PermissionStruct {
  account: Address;
  spender: Address;
  token: Address;
  allowance: bigint;
  period: number;
  start: number;
  end: number;
  salt: bigint;
  extraData: Hex;
}

interface SendRequest {
  address: Address;
  abi: Abi | readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
}

type Deployer = (artifact: Artifact, args: readonly unknown[]) => Promise<Address>;

/**
 * Sends a transaction the way the keeper does: simulate, then write, with an explicit gas limit.
 *
 * Both halves are needed on a fork. `simulateContract` surfaces a revert as a decoded error instead
 * of a mined failure, and an explicit gas limit sidesteps `eth_estimateGas` occasionally
 * under-estimating a large call against forked state — which shows up as a transaction that mines
 * with status `reverted` and no revert data at all.
 */
function makeSender(
  publicClient: PublicClient,
  walletClient: WalletClient,
  from: Address,
): (request: SendRequest) => Promise<Hex> {
  return async (request) => {
    const account = walletClient.account ?? from;
    const { request: prepared } = await publicClient.simulateContract({
      address: request.address,
      abi: request.abi as Abi,
      functionName: request.functionName,
      ...(request.args ? { args: request.args } : {}),
      ...(request.value === undefined ? {} : { value: request.value }),
      account,
    });
    const hash = await walletClient.writeContract({ ...prepared, gas: 8_000_000n } as never);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      throw new Error(`${request.functionName} on ${request.address} reverted (tx ${hash})`);
    }
    return hash;
  };
}

function makeDeployer(publicClient: PublicClient, walletClient: WalletClient, from: Address): Deployer {
  return async (artifact, args) => {
    const hash = await walletClient.deployContract({
      abi: artifact.abi,
      bytecode: artifact.bytecode,
      args: args as never,
      account: walletClient.account ?? from,
      gas: 12_000_000n,
    } as never);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success" || !receipt.contractAddress) {
      throw new Error(`deployment reverted (tx ${hash})`);
    }
    return receipt.contractAddress;
  };
}

async function loadArtifacts(loader: ArtifactLoader): Promise<Record<keyof typeof artifactNames, Artifact>> {
  const entries = await Promise.all(
    Object.entries(artifactNames).map(async ([key, value]) => [key, await loader.load(value.name)] as const),
  );
  return Object.fromEntries(entries) as Record<keyof typeof artifactNames, Artifact>;
}

async function deployLine(context: {
  index: number;
  artifacts: Record<keyof typeof artifactNames, Artifact>;
  calendar: Address;
  credit: Address;
  deploy: Deployer;
  send: (request: SendRequest) => Promise<Hex>;
  publicClient: PublicClient;
}): Promise<DeployedLine> {
  const { index, artifacts, calendar, credit, deploy, send, publicClient } = context;
  const symbol = `EVL${String(index).padStart(2, "0")}c`;

  const collateral = await deploy(artifacts.erc20, [`Eval Equity ${index}`, symbol, COLLATERAL_DECIMALS]);
  const now = await blockTimestamp(publicClient);
  const feed = await deploy(artifacts.aggregator, [FEED_DECIMALS, 200n * 10n ** BigInt(FEED_DECIMALS), now]);
  // Token ordering mirrors the live NVDAc/USDC Slipstream pool: USDC is token0, the equity token1.
  const pool = await deploy(artifacts.pool, [BASE_MAINNET.usdc, collateral, 10]);
  const oracle = await deploy(artifacts.oracle, [
    {
      collateralToken: collateral,
      loanToken: BASE_MAINNET.usdc,
      feed,
      pool,
      calendar,
      multiplierRegistry: "0x0000000000000000000000000000000000000000",
      twapWindow: ORACLE_POLICY.twapWindow,
      stalenessBudget: ORACLE_POLICY.stalenessBudget,
      divergenceBandBps: ORACLE_POLICY.divergenceBandBps,
      baseHaircutBps: ORACLE_POLICY.baseHaircutBps,
      haircutSlopeBpsPerHour: ORACLE_POLICY.haircutSlopeBpsPerHour,
      maxHaircutBps: ORACLE_POLICY.maxHaircutBps,
      minPoolLiquidityUsd: ORACLE_POLICY.minPoolLiquidityUsd,
      minMultiplier: ORACLE_POLICY.minMultiplier,
      maxMultiplier: ORACLE_POLICY.maxMultiplier,
    },
  ]);

  await send({
    address: credit,
    abi: aftermarketCreditAbi,
    functionName: "setAsset",
    args: [
      collateral,
      {
        oracle,
        advanceOpenBps: ASSET_PARAMS.advanceOpenBps,
        advanceClosedBps: ASSET_PARAMS.advanceClosedBps,
        liqThresholdOpenBps: ASSET_PARAMS.liqThresholdOpenBps,
        liqThresholdClosedBps: ASSET_PARAMS.liqThresholdClosedBps,
        liqBonusBps: ASSET_PARAMS.liqBonusBps,
        cap: ASSET_PARAMS.cap,
        enabled: true,
      },
    ],
  });

  return { index, collateral, feed, pool, oracle };
}

/**
 * Finds the storage slot holding USDC's balance mapping, by writing a probe and reading it back.
 *
 * Hard-coding the slot would be shorter and would silently break the day the token is upgraded.
 * The probe is forty cheap calls against a local node and it verifies itself, so the eval either
 * knows the slot or says it does not.
 */
async function findUsdcBalanceSlot(publicClient: PublicClient, testClient: TestClient): Promise<bigint> {
  const probe = "0x00000000000000000000000000000000000f1e1d" as Address;
  const sentinel = 123_456_789n;

  for (let slot = 0n; slot <= 40n; slot += 1n) {
    const key = balanceSlotKey(probe, slot);
    await testClient.setStorageAt({ address: BASE_MAINNET.usdc, index: key, value: pad(toHex(sentinel), { size: 32 }) });
    const balance = await publicClient.readContract({
      address: BASE_MAINNET.usdc,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [probe],
    });
    await testClient.setStorageAt({ address: BASE_MAINNET.usdc, index: key, value: pad(toHex(0n), { size: 32 }) });
    if (balance === sentinel) return slot;
  }
  throw new Error("could not locate USDC's balance mapping slot on this fork");
}

function balanceSlotKey(account: Address, slot: bigint): Hex {
  return keccak256(encodeAbiParameters(parseAbiParameters("address, uint256"), [account, slot]));
}

async function assertLiveContract(publicClient: PublicClient, address: Address, label: string): Promise<void> {
  const code = await publicClient.getCode({ address });
  if (!code || code === "0x") {
    throw new Error(`${label} has no code at ${address} on this fork — is the fork block before it was deployed?`);
  }
}

async function blockTimestamp(publicClient: PublicClient): Promise<bigint> {
  const block = await publicClient.getBlock({ blockTag: "latest" });
  return block.timestamp;
}

function absDiff(a: bigint, b: bigint): bigint {
  return a > b ? a - b : b - a;
}

const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
