# CLAIMS

Every public statement Aftermarket makes, tagged by how strong the evidence behind it actually is,
with a link to that evidence. Written so that a reviewer never has to guess which tier a sentence
belongs to, and so that we cannot quietly upgrade one later.

## The tiers

| tag | means |
|---|---|
| **`REPRODUCIBLE`** | Deterministic. Run the command, get the same bytes. Block-pinned chain reads, test suites, source-verification status, file contents. |
| **`VERIFIED-LIVE`** | Observed on Base mainnet at a stated block or moment. The *behaviour* reproduces; the exact number may have moved since, and we say which numbers move. |
| **`MODELED`** | Produced by a simulation or a test fixture whose parameters we chose. The mechanism is real code on real data; the magnitude belongs to the model. Never presented as a measurement. |
| **`NOT-CLAIMED`** | Something a reader might reasonably assume we are asserting, that we are not. |

Reference blocks for the `--block` reads:

- **50,997,343** (2026-09-07 12:27:13 UTC) for every oracle read. The oracles, the calendar, the gate,
  the attester registry and the rate model were never redeployed and are at the addresses they always
  had, so these reads are unchanged.
- **51,010,200** (2026-09-07 19:35:47 UTC) for every credit-engine read. `AftermarketCredit`,
  `AftermarketVault`, `AutoRepayer`, `AftermarketLens` and `AerodromeSwapAdapter` were redeployed on
  2026-09-07 at 19:26 UTC to close two Regulation-S holes (claims 68-74). The old line was repaid and
  unwound in full first; [PROOF §4](PROOF.md) lists both halves.
- **51,043,143** (2026-09-08 13:53:53 UTC = 09:53 ET) for every read taken **after** the US market
  reopened, 23 minutes past the bell. Both blocks above sit inside the 89 h 30 m Labor Day closure;
  this one sits outside it, against the same contracts at the same addresses. Claims 32b-32g.

---

## Contracts and verification

| # | claim | tier | evidence |
|---|---|---|---|
| 1 | Ten protocol contracts, six production oracles and one negative control are deployed on Base mainnet (chainId 8453) at the addresses published. | `REPRODUCIBLE` | [`contracts/deployments/8453.json`](contracts/deployments/8453.json); `cast code <addr>` |
| 1b | Five of those ten were redeployed on 2026-09-07 at 19:26 UTC: the credit engine, the vault, the auto-repayer, the lens and the swap adapter. The six oracles, the negative control, the calendar, the gate, the attester registry, the rate model, the oracle factory and the Morpho Blue market did **not** change address. | `REPRODUCIBLE` | Deploy transactions in [PROOF §4](PROOF.md); the Morpho market references the oracle, not the engine |
| 2 | All seventeen are source-verified **exact match** on Sourcify, without an explorer API key. | `REPRODUCIBLE` | [docs/verification.md](docs/verification.md); `scripts/verify-sources.sh status` |
| 3 | Five top-level contracts - `TradingCalendar`, `AttesterRegistry`, `RegSGate`, `SessionRateModel`, `AftermarketOracleFactory` - are also source-verified on Blockscout. | `VERIFIED-LIVE` | Each observed `is_verified: true` on 2026-09-07; [docs/verification.md](docs/verification.md) |
| 3b | The five redeployed top-level contracts are verified on Blockscout. | **`NOT-CLAIMED`** | They are not. `base.blockscout.com/api` returned `503 Service Temporarily Unavailable` to every request, reads and submissions alike, from the moment they were deployed, so they could not be submitted. All five are `exact_match` on Sourcify with creation **and** runtime matches. [docs/verification.md](docs/verification.md) |
| 4 | The seven oracles are verified on Blockscout. | **`NOT-CLAIMED`** | They are not. Blockscout indexed no creation transaction for a `CREATE2` deploy from inside the factory (`creation_bytecode: null` in its own API) and its verifier matches on creation bytecode; three submission routes were tried and none landed. Verified `exact_match` on Sourcify, which matches runtime bytecode. [docs/verification.md](docs/verification.md) |
| 5 | Anything is verified on Basescan. | **`NOT-CLAIMED`** | No API key was available. Basescan pages will show unverified bytecode. |
| 6 | Compiler settings match the deploy exactly: solc 0.8.28, optimizer on, 200 runs, `evm_version = cancun`, `via_ir = false`. | `REPRODUCIBLE` | [`contracts/foundry.toml`](contracts/foundry.toml); Sourcify would not have produced an exact match otherwise |
| 7 | The negative control differs from the production NVDAc oracle in exactly one constructor field — the six-entry divergence band array (25 bps everywhere vs `500/500/500/200/250/300`). | `REPRODUCIBLE` | [`script/DeployNegativeControl.s.sol`](contracts/script/DeployNegativeControl.s.sol), `AftermarketConfig._oracleConfig`; `collateralToken()`/`loanToken()`/`feed()`/`pool()`/`calendar()` are identical on chain — [PROOF §2c](PROOF.md) |

## The oracle, live

| # | claim | tier | evidence |
|---|---|---|---|
| 8 | `NVDAc.price()` returns `2184594350000000000000000000000000000` ($218.459435). | `REPRODUCIBLE` at block 50,997,343 | [PROOF §2a](PROOF.md) |
| 9 | That mark equals `min(anchor, pool) × (1 − 500 bps)` = `229.9573 × 0.95`, exactly. | `REPRODUCIBLE` | `peek()` at the same block — [PROOF §2a](PROOF.md) |
| 10 | `AMZNc.price()` reverts `SourcesDiverged(session=5 CLOSED_HOLIDAY, divergence, band=300)`, selector `0x1047f22b`. | `REPRODUCIBLE` at block 50,997,343 | [PROOF §2b](PROOF.md); `cast sig "SourcesDiverged(uint8,uint256,uint256)"`. **Not a standing claim:** the same call at block 51,043,143, after the reopen, returns `2568065370000000000000000000000000000` — claim 32c |
| 11 | The AMZNc divergence figure is a specific fixed number. | **`NOT-CLAIMED`** | It moves with the pool: **886** bps at block 50,991,632, **897** at 50,997,343, **912** in the Sunday snapshot. The session, the band and the refusal are what is stable. |
| 12 | The negative control reverts `SourcesDiverged(5, 105, 25)` on **NVDAc**, the same asset and block where the production oracle answers. | `REPRODUCIBLE` at block 50,997,343 | [PROOF §2c](PROOF.md) |
| 13 | The gap between the two real Chainlink prints either side of the 2026 Labor Day weekend was 89 h 30 m (Fri 2026-09-04 16:00 ET → Tue 2026-09-08 09:30 ET). | `REPRODUCIBLE` | `nextOpen` − `lastClose` = 1788874200 − 1788552000 = 322,200 s, from `peek()` — [PROOF §2a](PROOF.md) |
| 14 | Deployed oracle parameters are twap 1800 s, haircut 25 bps + 15 bps/h capped at 500 bps, depth floor $25,000, multiplier bounds `[0.01e18, 1e21]`. | `REPRODUCIBLE` | `cast call <oracle> "baseHaircutBps()(uint16)"` etc. — every one is a public immutable |

## The credit engine, live

| # | claim | tier | evidence |
|---|---|---|---|
| 15 | `draw(900000, self)` reverts `Undercollateralized(debtAfter, 562916)`, selector `0x5033ec12`. | `REPRODUCIBLE` at block 51,010,200 | [PROOF §3a](PROOF.md) |
| 16 | `flag(self)` reverts `LineHealthy(500000, 1067288)`, selector `0x0d007982` — a seizure bar 2.13× the debt. | `REPRODUCIBLE` at block 51,010,200 | [PROOF §3b](PROOF.md). At block 51,043,143 the same call returns `LineHealthy(500040, 1680041)`, a bar of 3.36× — claim 32f |
| 17 | **Borrowing power was 562,916 before depositing $1.00 of AMZNc and 562,916 after.** | `REPRODUCIBLE` | Two archive calls at blocks 51,009,976 and 51,009,977, both returning `Undercollateralized(900000, 562916)` — [PROOF §3c](PROOF.md). The same measurement on the retired engine, at blocks 50,991,631 and 50,991,632, returned the same two numbers |
| 18 | All 562,916 of that comes from the NVDAc leg: `515351 × 2.18459435 × 0.50 = 562916.45`. | `REPRODUCIBLE` | Arithmetic over on-chain values — [PROOF §3c](PROOF.md) |
| 19 | An asset whose oracle refuses to mark contributes zero borrowing power **and** zero seizure threshold, and can never be seized, while remaining held and withdrawable. | `REPRODUCIBLE` | `AftermarketCredit._borrowPower` / `_seizureThreshold` / `_quoteSeizure`; `audit/poc/BasketVeto.t.sol` (4/4); `test/fork/LiveB20.t.sol::test_amznDivergenceFreezesRiskAndSeizureButNotTheCure` |
| 20 | The exact debt and seizure-threshold figures are stable. | **`NOT-CLAIMED`** | Debt accrues every second; the threshold tracks the pool TWAP. Both are pinned by `--block`. |

## Morpho Blue

| # | claim | tier | evidence |
|---|---|---|---|
| 21 | Morpho Blue reads `IOracle.price()` in exactly three functions — `borrow`, `withdrawCollateral`, `liquidate` — and in none of `supply`, `withdraw`, `repay`, `supplyCollateral`. | `REPRODUCIBLE` | `lib/morpho-blue/src/Morpho.sol:258`, `:337`, `:361`, `:518`; `grep -n "price()" contracts/lib/morpho-blue/src/Morpho.sol` |
| 22 | A reverting oracle therefore freezes new borrowing and seizure while leaving repayment and collateral supply open. | `REPRODUCIBLE` | Follows from 21, in Morpho's audited code, not ours |
| 23 | A Morpho Blue market exists with USDC loan, NVDAc collateral, our oracle, AdaptiveCurveIRM and 77% LLTV. | `REPRODUCIBLE` | `idToMarketParams(0xfef5641f…)` — [PROOF §11](PROOF.md) |
| 24 | That market has liquidity, users, or borrow activity in any volume sense. | **`NOT-CLAIMED`** | It has taken exactly one supply and one borrow, both from the deployer, totaling $0.50 — see claims 63–66 below. |

## Compliance

| # | claim | tier | evidence |
|---|---|---|---|
| 25 | The deployed `RegSGate` reads live Coinbase Verifications EAS attestations on Base and admits a genuinely attested third party as `(true, "PL", source=COINBASE)`. | `REPRODUCIBLE` | `cast call` on the deployed gate for `0xc799DD32…bB6d7` — [PROOF §5](PROOF.md) |
| 26 | The same gate returns `(false, 0x0000, SOURCE_NONE)` for an unattested address. | `REPRODUCIBLE` | Same section |
| 27 | `test_Fork_RealCoinbaseAttestationOnBaseMainnet` passes against mainnet. | `REPRODUCIBLE` | `BASE_RPC_URL=… forge test --match-test test_Fork_RealCoinbaseAttestationOnBaseMainnet` |
| 28 | The demo account is Coinbase-verified. | **`NOT-CLAIMED`** | It is not. It is attested by our own `AttesterRegistry` and the gate reports `source = 2` on chain. [MOCKS §1](MOCKS.md) |
| 29 | This constitutes legal Reg-S compliance. | **`NOT-CLAIMED`** | It is a jurisdiction gate in bytecode, on every protocol path that moves a tokenized security into an account. It is not legal advice and not a licence. It also does not reach what happens afterwards: the B20 token performs no per-transfer jurisdiction check, so an attested holder can transfer onward and this protocol has no say in it. |

## Systemic evidence

| # | claim | tier | evidence |
|---|---|---|---|
| 30 | At Base block 50,979,049 (Sun 2026-09-06 22:17 ET) five of the ten priced tokenized stocks were more than 150 bps from their Chainlink feed: AMZNc 912, MSFTc 479, SNDKc 221, SPCXc 154, MSTRc 153. | `REPRODUCIBLE` | [`docs/evidence/weekend-2026-09-06.json`](docs/evidence/weekend-2026-09-06.json) — block-pinned |
| 31 | Feed ages in that snapshot ran from 52.8 h (MSTRc) to 59.9 h (GOOGLc). | `REPRODUCIBLE` | Same file |
| 32 | Divergences of that size are present right now. | **`NOT-CLAIMED`** | They were a property of a closed market and they are not a standing condition. At block 51,043,143, 23 minutes into the session that followed, the widest of the ten was 81.6 bps and none was over 150 — claim 32b. `pnpm verify:onchain` regenerates the table at the current head, and what it prints depends entirely on when you run it. |
| 33 | These divergences represent a mispricing, an arbitrage, or a fault in Chainlink's feeds. | **`NOT-CLAIMED`** | The feeds are doing exactly what a total-return equity reference is specified to do. The gap is structural, not a bug in anyone's product. |

### The market reopened, and the same reads changed

The US equity market reopened at 09:30 ET on Tuesday 2026-09-08 after the 89 h 30 m closure every
claim above was measured inside. These are the same commands against the same addresses, 23 minutes
later, at block **51,043,143**. No contract was redeployed, no parameter retuned, no transaction
sent to any of them in between.

| # | claim | tier | evidence |
|---|---|---|---|
| 32b | All ten priced assets were inside 150 bps: MSTRc 81.6, NVDAc 77.8, GOOGLc 48.8, METAc 32.6, AAPLc 31.8, AMZNc 30.5, TSLAc 5.6, SPCXc 5.5, MSFTc 3.0, SNDKc 1.4. | `REPRODUCIBLE` at block 51,043,143 | [`docs/evidence/reopen-2026-09-08.json`](docs/evidence/reopen-2026-09-08.json) — block-pinned |
| 32c | Feed ages in that snapshot ran from **16 s** (METAc) to **1,564 s** (MSFTc), against 52.8-59.9 **hours** in the Sunday snapshot. | `REPRODUCIBLE` at block 51,043,143 | Same file, against claim 31 |
| 32d | `TradingCalendar.session()` returns `0` (`REGULAR`), unaided. | `REPRODUCIBLE` at block 51,043,143 | [PROOF §2d](PROOF.md). The session is derived from `block.timestamp` against an onchain holiday table; no transaction, keeper or owner call is involved |
| 32e | **`AMZNc.price()` answers again**, returning `2568065370000000000000000000000000000` ($256.806537), and `haircutBps` on both live oracles is `0`. | `REPRODUCIBLE` at block 51,043,143 | [PROOF §2d](PROOF.md). This is claim 10 ceasing to hold, on its own, because the condition it described ended |
| 32f | Borrowing power on the unchanged demo line went **562,916 → 1,363,253** (2.42×), and the seizure bar **1,067,288 → 1,680,041** (2.13× → 3.36× the debt). | `REPRODUCIBLE` at blocks 51,010,200 and 51,043,143 | [PROOF §3d](PROOF.md). Decomposes exactly: `515351 × 2.29414950 × 0.65 = 768489` plus `356308 × 2.56806537 × 0.65 = 594764` |
| 32g | **The 25 bps negative control still reverts, in an open session**: `SourcesDiverged(session=0 REGULAR, divergence=78, band=25)`. | `REPRODUCIBLE` at block 51,043,143 | [PROOF §2d](PROOF.md). It is testing a constructor parameter, not detecting a weekend |
| 32h | The convergence was uniform, or one-directional. | **`NOT-CLAIMED`** | It was neither. NVDAc is **wider** at the reopen (77.8 bps) than it was on Sunday night (62), and MSTRc's 81.6 bps is wider than five of the ten assets were at the weekend. The gap wanders both ways; what does not wander is that it exists for 135.5 hours a week |
| 32i | This will happen the same way at the next close. | **`NOT-CLAIMED`** | Three snapshots are three points, not a distribution. The mechanism is what reproduces; the magnitudes are whatever the market does |

## The weekend replay

| # | claim | tier | evidence |
|---|---|---|---|
| 34 | The mechanism — haircut widening with every closed hour, marks moving apart, seizure threshold rising while the market is shut, hard `UNTRUSTED_STALE` stop at the next bell — runs on real historical Base state at six pinned blocks. | `REPRODUCIBLE` | `test/fork/WeekendReplay.t.sol`, 2/2 passing under `base-forge` |
| 35 | Borrowing power on 100 NVDAc contracts **11,557 → 6,921** USDC across the weekend. | **`MODELED`** | Real chain state, but the **fork fixture's** risk parameters, not the deployed ones (haircut 100 bps + 25 bps/h capped 1500, advance 3500 closed). The deployed protocol would contract less. [MOCKS, project-level caveats](MOCKS.md) |
| 36 | AMZNc goes `TRUSTED → TRUSTED_CLOSED → UNTRUSTED_DIVERGENT → UNTRUSTED_STALE` over the same instants. | `REPRODUCIBLE` | Same test; the verdict transitions are driven by real historical feed and pool data |
| 37 | A healthy line becomes flaggable during a real closed market. | **`NOT-CLAIMED`** | It cannot, on real weekend data — that is the product. The flag/grace/liquidate test applies a labelled 50% shock to both sources to reach the rest of the machinery. [MOCKS §3](MOCKS.md) |

## Tests

| # | claim | tier | evidence |
|---|---|---|---|
| 38 | `forge test --no-match-path 'test/fork/*'` → **273 passed, 0 failed, 1 skipped**. | `REPRODUCIBLE` | Run on 2026-09-07; it was 255/0/1 before the Reg-S work added `AerodromeSwapAdapter.t.sol` and the eligibility cases. The skip is the Coinbase fork test, which needs `BASE_RPC_URL`. |
| 39 | `FOUNDRY_TEST=audit/poc forge test` → **43 passed, 0 failed**. | `REPRODUCIBLE` | Run on 2026-09-07 |
| 40 | `base-forge test --match-path 'test/fork/*'` → **8 passed, 0 failed** (6 `LiveB20`, 2 `WeekendReplay`). | `REPRODUCIBLE` | Run on 2026-09-07 with a Base mainnet archive RPC |
| 41 | The fork suite requires `base-forge`, because a B20 token is a Rust precompile and `eth_getCode` returns `0xef`. | `REPRODUCIBLE` | `cast code 0xb20000000000000000000078ee7ce2fE4908108C`; [`contracts/test/fork/README.md`](contracts/test/fork/README.md) |
| 42 | These test counts imply an absence of bugs. | **`NOT-CLAIMED`** | See the audit. We found seventeen problems in our own code; a passing suite is a floor, not a ceiling. |

## The keeper and its eval

| # | claim | tier | evidence |
|---|---|---|---|
| 43 | 32/32 correct · 0 false actions · 11/11 traps refused · 6/6 negative controls acted · 0 invariant violations. | `REPRODUCIBLE` | [`agent/eval/results/latest.txt`](agent/eval/results/latest.txt) |
| 44 | Answer key hash `271c4b7c7cafadba04e8faf9c69daf301bb7f14a4a017e8789f50428b2fdddd4`. | `REPRODUCIBLE` | [`agent/eval/results/latest.json`](agent/eval/results/latest.json), field `answerKeyHash` |
| 45 | Each scenario is scored against three independent verdicts — the expected label, the keeper engine, and the contract's own `simulate()` — and all three agree on all 32. | `REPRODUCIBLE` | The per-scenario columns in `latest.txt` |
| 46 | There is no LLM anywhere in the keeper's decision path. | `REPRODUCIBLE` | `agent/src/engine.ts` is a pure `bigint` function; the keeper stands down and records `engine-mismatch` rather than breaking a tie with the contract |
| 47 | The keeper cannot exceed the user's mandate. | `REPRODUCIBLE` | Coinbase `SpendPermissionManager` enforces `used + amount <= allowance` on chain; `AutoRepayer` sizes the repayment and fixes the recipient |
| 48 | The eval covers every failure mode a production keeper would meet. | **`NOT-CLAIMED`** | 32 scenarios is a scorecard, not a proof of coverage. |

## The self-audit

| # | claim | tier | evidence |
|---|---|---|---|
| 49 | 3 High, 11 Medium, 2 Low, 1 Informational — seventeen findings, all found by us before deployment. | `REPRODUCIBLE` | [`contracts/audit/AUDIT.md`](contracts/audit/AUDIT.md), findings table |
| 50 | Fifteen are fixed in code, one is mitigated with the residual written down, two behaviours are accepted by design and documented in the contracts. | `REPRODUCIBLE` | The `Status:` line under each finding; the Remediation section. A-09 moved from accepted to fixed on 2026-09-07 and its original status line is preserved above the new one rather than rewritten. |
| 51 | Every finding rated Medium or above has a runnable Foundry PoC driving the real contracts. | `REPRODUCIBLE` | `FOUNDRY_TEST=audit/poc forge test` → 43 passed |
| 52 | Fifteen attacks were tried and did not work. Four are refuted by a dedicated PoC, one by the whole `audit/refute/` suite, three by tests that were already in the repo's own suite, and seven are arguments from the code with no test of their own. | `REPRODUCIBLE` | "Attacks I tried that did NOT work" — the table at the head of that section names the test for each of the fifteen, or says there is none. `FOUNDRY_TEST=audit/refute forge test` → 39 passed, 0 failed |
| 53 | A second adversarial pass over the fixes found six further problems (all fixed) and recorded two residuals. | `REPRODUCIBLE` | "A second pass over the fixes themselves" |
| 54 | Some worked examples in the audit quote parameters that changed before deploy. | `REPRODUCIBLE` | e.g. the audit's "100 bps + 10 bps/h capped 1000" vs the deployed 25 + 15 capped 500. [MOCKS, project-level caveats](MOCKS.md) |
| 55 | This is a third-party audit, or equivalent to one. | **`NOT-CLAIMED`** | It is a self-audit. It is adversarial, it is evidenced, and it is not independent. |

## The protocol's own costs

Stated as claims because they are, and because a reviewer should be able to check them.

| # | claim | tier | evidence |
|---|---|---|---|
| 56 | Roughly **19% of every week** the protocol has no working oracle at all: all 5.5 h of PRE every weekday, plus 4 h of Monday overnight. `draw`, `withdrawCollateral`, `flag`, `cure` and `liquidate` revert for every user of every asset. | `REPRODUCIBLE` | Audit A-17 and `audit/poc/StaleWindows.t.sol` (3/3): PRE half-hour slots 04:00–09:00, 11 of 11 `UNTRUSTED_STALE` |
| 57 | That freeze cannot cause a loss: `repay`, `supplyCollateral` and vault `deposit` read no oracle. | `REPRODUCIBLE` | Audit A-17 status; `audit/poc/BasketVeto.t.sol::test_03_TheVetoDoesNotTrapTheBorrower` |
| 58 | The trading calendar covers days 20444–21183 (2025-12-22 to 2027-12-31) and fails closed outside that window; it cannot be extended in place. | `REPRODUCIBLE` | `SEEDED_FROM_DAY()` / `SEEDED_UNTIL_DAY()` on chain; audit A-06 |
| 59 | The owner is a single un-timelocked EOA that can repoint any oracle, rate model or swap venue on the credit engine. | `REPRODUCIBLE` | `cast call <credit> "owner()(address)"` → `0x0AF7aFC7…C5c8f`; audit, "What was not fixed" |
| 60 | Two of the six listed Aerodrome pools held under $70k of USDC in the Sunday snapshot (AMZNc ~$55k, TSLAc ~$67k). | `REPRODUCIBLE` | [`docs/evidence/weekend-2026-09-06.json`](docs/evidence/weekend-2026-09-06.json) |

## New evidence, since the rest of this document was written

Both previously-inert integrations fired on mainnet on 2026-09-07, after the deploy and the demo
transactions above. Added here rather than folded quietly into the sections above, so the update is
itself visible.

| # | claim | tier | evidence |
|---|---|---|---|
| 61 | The swap adapter's routing code was exercised on mainnet against real Slipstream liquidity: 0.400000 USDC → 0.00172031 NVDAc, with the transfer in, the router hop, the `minOut` assertion and the transfer out all executing. | `REPRODUCIBLE` | tx [`0xcf9150ed…1f9a37`](https://base.blockscout.com/tx/0xcf9150edf881cc45bb43df9a9ede54af3aedfd6230e338fd9f643dadd51f9a37), block 50,998,717 — [PROOF §4](PROOF.md) |
| 61b | That transaction is evidence that an open swap endpoint is a feature. | **`NOT-CLAIMED`** | It is the opposite, and earlier versions of `PROOF.md` framed it wrongly. It shows an arbitrary EOA swapping USDC into a Reg-S tokenized equity through a contract this project deployed and advertised, with no jurisdiction check on the path. It was a hole. The adapter deployed since restricts `swapExactIn` to the credit engine (claim 68), and the framing is corrected in [PROOF §4](PROOF.md). |
| 62 | `sweepYield` itself — the corporate-action path through that adapter — has still never fired. | **`NOT-CLAIMED`** | No B20 has had a corporate action; `multiplier()` is still exactly `1e18` on every listed asset. [MOCKS §2](MOCKS.md) |
| 63 | The Morpho Blue NVDAc market has taken a real supply, a real collateral deposit and a real borrow. | `REPRODUCIBLE` | `market(id)`: totalSupplyAssets 500000, totalBorrowAssets 150000; `position(id, deployer)`: collateral 172031 — [PROOF §11](PROOF.md) |
| 64 | That borrow was authorised by Morpho Blue's own `_isHealthy` calling our oracle's `price()` — not by our code asserting it was fine. | `REPRODUCIBLE` | Follows from claim 21 (`Morpho.sol:258` calls `price()` inside `borrow`) plus the successful call itself — [PROOF §11](PROOF.md) |
| 65 | An earlier borrow attempt at the same market, with byte-identical calldata, reverted. | `REPRODUCIBLE` | tx [`0xe879cd3e…7a0bd2`](https://base.blockscout.com/tx/0xe879cd3ea9d7f1f557d07c54822a52b37ab7e92cbf62846fedd83bd15c7a0bd2), status 0, block 50,998,742, one block after the collateral deposit — `gasUsed == gasLimit` (229,436), an out-of-gas revert from a gas estimate that raced the collateral deposit, not an unhealthy position. [PROOF §11](PROOF.md) |
| 66 | This is a funded, adopted market. | **`NOT-CLAIMED`** | One supplier, one borrower, both the deployer, $0.50 total. It is no longer empty; it is not liquidity. |
| 67 | The repository is public and the app is hosted. | `REPRODUCIBLE` | <https://github.com/RaYYeR220/aftermarket>; <https://aftermarket-fawn.vercel.app> |

## Regulation S, after the 2026-09-07 redeployment

An adversarial review found that two paths in this protocol moved a Coinbase B20 tokenized US equity
into an account with no jurisdiction check on it, and that a third claim about the compliance gate was
broader than what the code enforced. All three are addressed below, and the claims are written to be
exactly as strong as the code and no stronger.

| # | claim | tier | evidence |
|---|---|---|---|
| 68 | `AerodromeSwapAdapter.swapExactIn` reverts `NotCredit(caller)` for every caller except `AftermarketCredit`, and the permitted caller is a public immutable with no setter anywhere in the contract. | `REPRODUCIBLE` | `cast call` on the deployed adapter from any address — [PROOF §4](PROOF.md); `credit()` is a public immutable; `contracts/test/AerodromeSwapAdapter.t.sol` (12/12) |
| 69 | `AftermarketCredit.liquidate` checks `eligibility` on the account the seized collateral is transferred to, and an ineligible account cannot reach it directly or by being named as `receiver`. | `REPRODUCIBLE` | Two live reverts, `AttestationMissing(0x…dEaD)`, in [PROOF §5b](PROOF.md); `test_eligibility_liquidationRefusesAnIneligibleCaller` and `..._RefusesAnIneligibleReceiver` |
| 70 | `liquidate` does **not** check `msg.sender`, deliberately, so an account with no attestation of its own can still fund a liquidation for an attested receiver. | `REPRODUCIBLE` | `test_eligibility_liquidationAllowsAnIneligiblePayerForAnEligibleReceiver`; the reasoning is in `liquidate`'s NatSpec and in audit A-09 |
| 71 | `AftermarketCredit.eligibility` is immutable and the engine exposes no `setEligibility`, so no owner transaction can point this engine at a different gate. | `REPRODUCIBLE` | `cast call <credit> "setEligibility(address)" →` reverts, there is no such function — [PROOF §5b](PROOF.md); `test_eligibility_theGateIsImmutable` |
| 72 | `RegSGate.setRestricted` reverts `UnitedStatesIsPermanentlyRestricted()` when asked to un-restrict `US`. | `REPRODUCIBLE` | `contracts/src/RegSGate.sol`; `contracts/test/RegSGate.t.sol` |
| 73 | Taken together, those five make it impossible for an owner key to admit a US person. | **`NOT-CLAIMED`** | They do not, and this is the sentence that used to be too broad. What is impossible is repointing the engine's gate (71) and un-restricting `US` inside `RegSGate` (72). What remains possible: `RegSGate.setRegistry` can repoint the fallback source, and the `AttesterRegistry` owner is implicitly an attester, so a country code can be **asserted** by our key rather than **proven** by Coinbase. The gate publishes which of the two happened as `source`, and the demo account returns `source = 2`. See claim 28 and [MOCKS §1](MOCKS.md). |
| 74 | Whether an attested holder later transfers a B20 token onward is constrained by this protocol. | **`NOT-CLAIMED`** | It is not. The B20 token performs no per-transfer jurisdiction check, which is the gap `RegSGate` exists to close **for this protocol's own paths** and nowhere else. |

---

## The explicit NOT-CLAIMED list

Everything above tagged `NOT-CLAIMED`, gathered in one place so it cannot be missed.

1. **No Basescan verification.** No API key. Sourcify (all 17, exact match) and Blockscout (the ten
   top-level contracts) are what we have.
2. **The seven oracles are not verified on Blockscout.** Its verifier needs creation bytecode, which it
   never indexed for a `CREATE2` deploy from inside the factory. Sourcify's runtime `exact_match`
   covers all seven.
3. **The Morpho Blue market has no liquidity in any volume sense.** It has taken exactly one supply and
   one borrow, both the deployer's own, totaling $0.50. It is no longer empty (claim 63), but it is not
   liquidity.
4. **The demo account is not Coinbase-verified.** Our own registry attested it, and the chain says so.
5. **This is not legal Reg-S compliance**, not legal advice, and not a licence to distribute
   securities. Every protocol path that moves a tokenized security into an account is gated, including
   liquidation; what happens after an attested holder receives one is outside this protocol, because
   the B20 token itself performs no per-transfer jurisdiction check.
6. **No third-party audit.** The audit in this repository is ours.
6b. **It is not impossible for an owner key to admit a US person.** The engine's gate address is
    immutable and `RegSGate` can never un-restrict `US`, and that is the whole of it. The registry
    behind the gate is still owner-settable and its owner is implicitly an attester, so jurisdiction
    can be asserted by our key rather than proven by Coinbase. Claims 71-73.
7. **No formal verification**, no fuzzing campaign beyond the suite in this repo, no bug bounty.
8. **The 11,557 → 6,921 weekend contraction is modeled**, on the fork fixture's parameters rather than
   the deployed ones.
9. **We have never seen a real B20 corporate action.** `sweepYield` has never fired on mainnet, the
   feed's post-split unit convention is unknown (audit A-03 branch B), and the multiplier is still
   exactly `1e18` on every listed asset.
10. **`sweepYield` — the corporate-action path through `AerodromeSwapAdapter` — has not fired.**
    `swapExactIn` itself has (claim 61); `sweepYield` needs a multiplier increase that has never
    happened, for the same reason as item 9.
11. **No claim about the security of Coinbase's B20 tokens, Chainlink's feeds, Aerodrome's pools,
    Morpho Blue or the EAS predeploy.** We read them; we did not audit them.
12. **No audience, revenue, TVL, user or partnership claim of any kind.** The only user of this
    protocol is the deployer's demo wallet.
13. **The specific divergence, debt and seizure-threshold figures are not stable.** They move with the
    pool and the clock. Pin a block.
14. **A passing test suite is not an absence of bugs**, and 32 eval scenarios are not proof of keeper
    coverage.
15. **No attribution claim.** `NEXT_PUBLIC_BUILDER_CODE` is unset, so every transaction this app has
    ever sent went out without an ERC-8021 suffix. The encoder, the wagmi wiring and the env plumbing
    are shipped and correct; the value is empty because a Builder Code is claimed in Base's registry
    rather than derived, and we would rather ship an empty field than a string that encodes cleanly
    and resolves to nobody. The app **is** registered on base.dev — `aftermarket-fawn.vercel.app`,
    proved by the `base:app_id` meta tag in `web/src/app/layout.tsx` — and that is deliberately not
    offered as attribution: an app registration puts no suffix on any transaction.
