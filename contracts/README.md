# Aftermarket — contracts

The Foundry project behind [Aftermarket](../README.md): a portfolio line of credit against Coinbase's
tokenized US stocks on Base, whose oracle refuses to produce a mark it cannot defend.

Deployed and source-verified on Base mainnet. Addresses, constructor arguments and the deploy block
are in [`deployments/8453.json`](deployments/8453.json); the verification record is in
[`../docs/verification.md`](../docs/verification.md).

## The contracts

| file | what it is |
|---|---|
| `src/TradingCalendar.sol` | An onchain NYSE/Nasdaq calendar: real US Eastern time with real DST, the real 2026–2027 exchange holidays and half days. No owner, no admin function, no upgrade path. Fails closed outside its seeded horizon. |
| `src/AftermarketOracle.sol` | Morpho Blue `IOracle`. Fuses the Chainlink anchor, an Aerodrome Slipstream TWAP, the B20 `multiplier()` corporate-action signal and the calendar into one verdict and two asymmetric marks. Reverts with a typed error rather than quoting a mark it cannot defend. `peek()` never reverts. |
| `src/AftermarketOracleFactory.sol` | Deterministic `CREATE2` deployer for the oracles. |
| `src/AftermarketCredit.sol` | The credit engine: a basket of up to eight collateral assets against one USDC debt, with session-aware advance rates and seizure thresholds, flag/grace/cure, liquidation, `sweepYield` and bad-debt write-off. |
| `src/AftermarketVault.sol` | ERC-4626 USDC vault (`amUSDC`). Accrues through the engine on every entry and exit; LP exits clamp to idle USDC. |
| `src/SessionRateModel.sol` | Kinked utilisation curve multiplied by a per-session premium, with every parameter bounded at construction. |
| `src/RegSGate.sol` | Reg-S jurisdiction gate. Reads live Coinbase Verifications EAS attestations, then falls back to `AttesterRegistry`. Reports which source admitted an account. |
| `src/AttesterRegistry.sol` | The fallback attester. |
| `src/AutoRepayer.sol` | Bounded auto-repayment mandate over a Coinbase Spend Permission. Sizes the repayment itself; the keeper only relays. |
| `src/AftermarketLens.sol` | Total read surface for a front end. Every function returns a fully populated struct under any oracle, calendar or rate-model failure — trust is reported through flags, never through whether the call reverted. |
| `src/adapters/AerodromeSwapAdapter.sol` | The protocol's swap venue for `sweepYield`. |

## Two toolchains

`forge` runs the unit suite. The fork suite needs **`base-forge`**, Base's fork of Foundry, because a
Coinbase B20 token is a Rust precompile inside Base's execution client rather than an EVM contract —
`eth_getCode` returns the single byte `0xef` and stock forge halts with `OpcodeNotFound` on the first
`decimals()` call.

```bash
curl -L https://raw.githubusercontent.com/base/base-anvil/HEAD/foundryup/install | bash
base-foundryup
```

Detail: [`test/fork/README.md`](test/fork/README.md).

## Commands

```bash
make test                                   # unit suite, no network      -> 273 passed, 0 failed, 1 skipped
BASE_RPC_URL=<archive> make test-fork       # live + historical mainnet   ->   8 passed, 0 failed
BASE_RPC_URL=<archive> make test-all        # both
FOUNDRY_TEST=audit/poc forge test           # the audit's PoCs            ->  43 passed, 0 failed
make sizes                                  # runtime bytecode vs EIP-170
make fmt-check                              # formatting
make help                                   # every target
```

The one skipped unit test is `RegSGate.t.sol::test_Fork_RealCoinbaseAttestationOnBaseMainnet`, which
skips rather than fails when `BASE_RPC_URL` is unset. With an RPC it passes and proves the Coinbase
attestation read path against a genuinely attested mainnet address.

`WeekendReplay.t.sol` pins blocks about 100,000 deep, so the fork suite needs an **archive** RPC.

## Compiler settings

`solc 0.8.28`, optimizer on, 200 runs, `evm_version = cancun`, `via_ir = false`. These must match
exactly for source verification to reproduce; they live in [`foundry.toml`](foundry.toml).

## Deploying

```bash
forge script script/DeployCore.s.sol:DeployCore --rpc-url base --broadcast
forge script script/DeployNegativeControl.s.sol:DeployNegativeControl --rpc-url base --broadcast
forge script script/CreateMorphoMarket.s.sol:CreateMorphoMarket --rpc-url base --broadcast
```

Every deploy parameter — assets, feeds, pools, staleness budgets, divergence bands, haircuts, advance
rates, liquidation thresholds and the calendar seed table — is read from
[`script/config/base.json`](script/config/base.json). The scripts write addresses and ABI-encoded
constructor arguments back to `deployments/8453.json`.

## The audit

[`audit/AUDIT.md`](audit/AUDIT.md) — our own adversarial review of this code before it shipped.
3 High, 11 Medium, 2 Low, 1 Informational, every finding rated Medium or above with a runnable PoC
under `audit/poc/`, plus fifteen attacks that were tried and did not work.
