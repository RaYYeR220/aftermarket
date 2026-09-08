# Review this in five minutes

In order. Each step says what it costs you and what it should convince you of. Everything except the
last two steps is a read-only call against Base mainnet — no wallet, no key, no install beyond
[`cast`](https://book.getfoundry.sh/getting-started/installation).

```bash
export RPC=https://mainnet.base.org
```

## Before anything that needs the repository

Steps 1-4 need nothing but `cast` and a browser. Steps 0 and 5 need a clone, and a clone needs one
extra line, because four of the five Foundry dependencies are git submodules:

```bash
git clone https://github.com/RaYYeR220/aftermarket.git
cd aftermarket
git submodule update --init --recursive     # ~1 min, ~55 MB. Skip it and forge cannot compile.
```

Measured cold on Windows 11, git 2.52: clone 4 s, submodules 1 m 17 s. Without that second command
every `forge` invocation spends about a minute compiling and then dies in a wall of
`ParserError: Source "lib/openzeppelin-contracts/…" not found` — the tests in step 5 are real and
they pass, but not from an uninitialised tree. `git clone --recurse-submodules` does both at once.

Node ≥ 20.9 and pnpm 9 (`corepack enable`) are needed for `pnpm verify:onchain` below. You do **not**
need to run `pnpm install` first — the command installs and builds what it needs on its first run.

---

## The video — 3 minutes, if you would rather watch than type

**<https://youtu.be/ix3a1fEQlV8>** — 2:56. It walks the measurement, the refusal, the negative control side by side,
and the two `cast` calls in step 1 being run against mainnet. Everything it shows is reproducible below.

---

## 0 · The app — 20 seconds

**Live demo: <https://aftermarket-fawn.vercel.app>** — nothing to install, no wallet needed to read
it. The front end also runs from source:

```bash
pnpm install && cd web && pnpm dev      # http://localhost:3000
```

It is a Next.js 16 app over the same contracts — markets, credit line, borrow, earn, oracle inspector,
auto-repay. **Everything below is checkable without it.** If your five minutes are tight, skip it; the
evidence is on chain, not in the UI.

One command that prints the live evidence this whole project is built on. It needs Node and pnpm,
and it bootstraps itself — the first run installs the observer package and builds it, after that it
starts reading Base immediately. Cold, from the clone above: **42 seconds**, install included.

```bash
pnpm verify:onchain
```

---

## 1 · The two commands — 60 seconds

This is the product. Two calls, one asset that the oracle will mark and one it will not. **Pinned to
block 50,997,343** (2026-09-07 12:27:13 UTC) so they print these exact bytes whenever you run them:

```bash
export AT="--rpc-url $RPC --block 50997343"

# Answers. Sources agree: 105 bps of divergence inside a 300 bps band.
cast call 0x1E2b20B4703F97710c2600eA73179c6CD1E00b02 "price()(uint256)" $AT
# 2184594350000000000000000000000000000        -> $218.459435 per NVDAc

# Refuses. Sources disagree: 897 bps against the same 300 bps band.
cast call 0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C "price()(uint256)" $AT
# execution reverted, data: 0x1047f22b
#   ...0005  session    = 5  CLOSED_HOLIDAY
#   ...0381  divergence = 897 bps
#   ...012c  band       = 300 bps
```

`0x1047f22b` is `SourcesDiverged(uint8,uint256,uint256)` — check with
`cast sig "SourcesDiverged(uint8,uint256,uint256)"`.

That block is Labor Day. The last real Chainlink print was Friday 16:00 ET; the next was Tuesday
09:30 ET. **89 h 30 m apart.** At that block AMZNc's frozen anchor said $257.69 while the pool it
actually trades in printed $280.88. Aftermarket's oracle would not pick a winner, so it refused — and
because Morpho Blue reads `price()` only in `borrow`, `withdrawCollateral` and `liquidate`, that
refusal freezes new risk and freezes seizure while leaving repayment open.

**Now run the second call at block 51,043,143 — 23 minutes after Tuesday's opening bell.**

```bash
cast call 0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C "price()(uint256)" \
  --rpc-url $RPC --block 51043143
# 2568065370000000000000000000000000000     ($256.806537)
```

**It answers.** Same address, same code, same everything — nothing in this repository was edited, no
parameter retuned, no contract redeployed. The oracle stopped refusing because the condition it was
refusing over ended, at 09:30 ET, on schedule. `TradingCalendar.session()` at that block returns `0`,
`REGULAR`, worked out from `block.timestamp` against an onchain holiday table with no keeper and no
owner call. A refusal you cannot lift is a bug; a refusal that lifts itself is a measurement.

`pnpm verify:onchain` in step 0 prints the current gap for all thirteen, whatever the market is doing
when you run it.

### Now the one that makes it falsifiable — 30 seconds

```bash
cast call 0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58 "price()(uint256)" $AT
# execution reverted: SourcesDiverged(session=5, divergence=105, band=25)
```

That is an `AftermarketOracle` on the **same NVDAc**, the **same feed**, the **same pool**, the **same
calendar**, at the **same block** as the one that answered in the first command. One constructor
number differs: the divergence band, 25 bps instead of 300. It refuses where production answers.

Run it at the reopen block too: `SourcesDiverged(session=0 REGULAR, divergence=78, band=25)`. **It
still refuses, in an open session, on a 384-second-old feed.** If it only refused at weekends it
would be evidence that this oracle detects weekends. It refuses because 78 > 25, which means what it
tests is a constructor parameter — and the production answer at 300 bps is a threshold being applied
rather than a check that is always green. That is what a control is for.

A negative control that fires is the difference between "our check passed" and "our check works".

---

## 2 · The headline measurement — 60 seconds

Two archive calls at adjacent blocks, straddling the transaction that deposited **$1.00 of AMZNc** as
collateral into the live demo line:

```bash
U=0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f
for B in 51009976 51009977; do
  cast call 0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93 "draw(uint256,address)" 900000 $U \
    --from $U --rpc-url $RPC --block $B
done
```

```
before  ->  Undercollateralized(900000, 562916)
after   ->  Undercollateralized(900000, 562916)
```

**Borrowing power: 562,916 before. 562,916 after.**

An asset the oracle refuses to mark contributes exactly zero borrowing power — while remaining held,
withdrawable, and unseizable. The arithmetic closes with nothing left over: `515351` raw NVDAc ×
`2.18459435` × the 50% closed-session advance rate = `562916.45`.

And the other direction:

```bash
cast call 0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93 "flag(address)" $U --from $U \
  --rpc-url $RPC --block 51010200
# LineHealthy(debt = 500000, seizureThreshold = 1067288)     # both move; pinned here
```

The bar to seize this line was **2.13× the debt**, because `markLiquidate` is the optimistic mark and
the closed-session liquidation threshold (8500 bps) is *higher* than the open one (8000 bps). Shutting
the market makes the position harder to take, not easier.

### Then the market reopened, and the same line got its power back — 30 seconds

```bash
cast call 0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93 "draw(uint256,address)" 900000 $U \
  --from $U --rpc-url $RPC --block 51043143
# Undercollateralized(1400040, 1363253)
```

**562,916 → 1,363,253.** Same account, same two collateral balances, no transaction in between; block
51,043,143 is 23 minutes after Tuesday's bell. The basket supports **2.42×** what it did on Labor
Day, and it decomposes exactly:

```
NVDAc   515351 × 2.29414950 × 0.65 (advanceOpenBps)   =    768,489
AMZNc   356308 × 2.56806537 × 0.65                    =    594,764
                                                           ---------
                                                           1,363,253
```

The AMZNc leg went from **0** to **594,764** because the oracle will mark it again, and the advance
rate went from 5000 to 6500 bps because the engine reads the calendar on every call. The refusal was
never a write-down and never a permanent haircut. It was a hold, and it ended by itself.

Full workings both sides of the bell: [PROOF §2d and §3d](PROOF.md).

---

## 3 · The addresses — 30 seconds

All seventeen deployed contracts are source-verified **exact match** on Sourcify, with no explorer API
key — re-checked on 2026-09-08 with `scripts/verify-sources.sh status`, which asks both verifiers
directly and is the number to trust over any count written down here. Blockscout holds the ten
top-level contracts but not the seven oracles, which were created by `CREATE2` and have no creation
transaction for its verifier to match on. Sourcify matches *runtime* bytecode, which is the match
that proves the code running at those addresses is the source in this repository.

| | |
|---|---|
| `TradingCalendar` | [`0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9`](https://repo.sourcify.dev/8453/0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9) |
| `AttesterRegistry` | [`0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E`](https://repo.sourcify.dev/8453/0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E) |
| `RegSGate` | [`0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C`](https://repo.sourcify.dev/8453/0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C) |
| `SessionRateModel` | [`0x6d5152d81982DEb660736fC514761E18533a2343`](https://repo.sourcify.dev/8453/0x6d5152d81982DEb660736fC514761E18533a2343) |
| `AftermarketOracleFactory` | [`0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A`](https://repo.sourcify.dev/8453/0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A) |
| `AerodromeSwapAdapter` | [`0x71283dB3a0b784F0B9e9B0dFc2398877D0A8465E`](https://repo.sourcify.dev/8453/0x71283dB3a0b784F0B9e9B0dFc2398877D0A8465E) |
| `AftermarketCredit` | [`0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93`](https://repo.sourcify.dev/8453/0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93) |
| `AftermarketVault` | [`0x00ee99240Ad9a4b25DD06eAcD1b852C83fbd2697`](https://repo.sourcify.dev/8453/0x00ee99240Ad9a4b25DD06eAcD1b852C83fbd2697) |
| `AutoRepayer` | [`0xBe1EA7CA0Fabc93F86C43fBcB25bbB3f2a0A2404`](https://repo.sourcify.dev/8453/0xBe1EA7CA0Fabc93F86C43fBcB25bbB3f2a0A2404) |
| `AftermarketLens` | [`0x27BFaddEc57fF76d498Ef1a7b09C5951DeA6735D`](https://repo.sourcify.dev/8453/0x27BFaddEc57fF76d498Ef1a7b09C5951DeA6735D) |
| oracles | NVDAc [`0x1E2b20B4…00b02`](https://repo.sourcify.dev/8453/0x1E2b20B4703F97710c2600eA73179c6CD1E00b02) · AAPLc [`0x6cE58FE7…9a8dc`](https://repo.sourcify.dev/8453/0x6cE58FE71eD10b82c2C0A9a348E82D1ee6D9a8dc) · METAc [`0xf5Cc0cc9…8dEf2`](https://repo.sourcify.dev/8453/0xf5Cc0cc94ecF4866661373f2aa066af76e08dEf2) · GOOGLc [`0x203cDf7e…1C9aA`](https://repo.sourcify.dev/8453/0x203cDf7e33eA0d652cA54f4807c9d2d1d081C9aA) · TSLAc [`0x74058d51…c2C99`](https://repo.sourcify.dev/8453/0x74058d51B3b04Ba09be2aa51ab1CE930Dd3c2C99) · AMZNc [`0x6FEEF51B…3bb5C`](https://repo.sourcify.dev/8453/0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C) |
| negative control | [`0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58`](https://repo.sourcify.dev/8453/0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58) |
| Morpho Blue market | `0xfef5641f70e19a87e369304daa9ba823754f3db1e6481d757fcae0442cffe479` (funded, **tiny**: $0.50 total) |

```bash
scripts/verify-sources.sh status      # what each verifier holds, right now
```

**Basescan will show these as unverified.** We had no API key, so verification was done key-lessly.
The seven oracles are on Sourcify only — Blockscout indexed no creation transaction for a `CREATE2`
deploy made from inside the factory, and its verifier needs one. Full record, with the three
submission routes we tried and why each failed: [docs/verification.md](docs/verification.md).

Seven live demo transactions — attest, supply, two Aerodrome swaps, two collateral deposits, a draw —
are listed with block numbers and links in [PROOF.md §4](PROOF.md#4-live-demo-transactions).

---

## 4 · The keeper eval — 45 seconds

`AutoRepayer` lets a borrower delegate "repay my line if it gets close" through a capped, time-boxed
Coinbase Spend Permission. **There is no LLM in the decision path.** The scorecard:

```
32/32 correct · 0 false actions · 11/11 traps refused · 6/6 negative controls acted
invariant violations 0 · verdict PASS
answer key hash 271c4b7c7cafadba04e8faf9c69daf301bb7f14a4a017e8789f50428b2fdddd4
```

[`agent/eval/results/latest.txt`](agent/eval/results/latest.txt) — one row per scenario, three
verdicts per row (the hand-written expected label, the keeper engine, and the contract's own
`simulate()`), all three agreeing on all 32. Two of those three are implementations written by the
same author and the third is that author's answer key, so this is differential testing rather than
independent review; what it catches is the engine and the contract disagreeing, which is the failure
mode that would actually hurt.

Read the two columns that matter. **11/11 traps refused** — scenarios engineered to look actionable
and be wrong. **6/6 negative controls acted** — scenarios that must act, so a keeper that always
refuses scores 26/32, not 32/32. Both directions are scored, which is the only way the number means
anything.

---

## 5 · The self-audit — 90 seconds

[`contracts/audit/AUDIT.md`](contracts/audit/AUDIT.md). 2,107 lines (`wc -l`). **3 High, 11 Medium, 2 Low, 1
Informational**, all found by us in our own code before deployment, every one with a runnable Foundry
PoC that drives the real contracts at the real deploy parameters.

Fourteen fixed in code, one mitigated with the residual written down, three behaviours accepted by
design and documented in the contracts themselves. Then a **second adversarial pass over the fixes**,
on the premise that a fix is just new code — it found six more problems (including a reentrancy path
through the swap adapter that could have sent swap proceeds to the borrower instead of the vault) and
recorded two residuals rather than papering over them.

It also publishes **fifteen attacks that did not work** — including three separate attempts to
extract value by manipulating the shallow Aerodrome pools, all refuted by the `min`/`max` fusion and
all with a passing PoC. That section opens with a table saying, for each of the fifteen, whether it
is refuted by a dedicated PoC (four), by the whole `audit/refute/` suite (one), by a test already in
the repo's own suite (three), or by an argument from the code with no test of its own (seven). A
refutation of the form "this state is unreachable" has nothing positive to assert, and it seemed
better to say which is which than to let "each with a test" stand.

If you read one finding, read **A-17** (`## A-17` in that file). It is ours, it is unfixed on purpose,
and it costs users real money:

> Roughly **19% of every week** this protocol has no working oracle at all. Every weekday from 04:00
> to 09:30 ET, plus Monday 00:00–04:00 ET, `draw`, `withdrawCollateral`, `flag`, `cure` and
> `liquidate` revert for every user of every asset — because a Coinbase equity feed only prints during
> the regular session, so it is already twelve hours old by the time the PRE session opens against a
> six-hour budget. Repay and deposit stay open, so it is a freeze rather than a trap. It is still a
> real cost, and we accepted it rather than widen the budgets and mark collateral against a
> seventeen-hour-old print.

```bash
cd contracts && FOUNDRY_TEST=audit/poc forge test      # 43 passed, 0 failed
cd contracts && FOUNDRY_TEST=audit/refute forge test   # 39 passed, 0 failed
```

Both need the submodules from the top of this file. Measured cold from the clone above: 32 s and
27 s, each of which is mostly the one-time compile of the audit tree.

---

## 6 · If you have longer

| you have | read |
|---|---|
| +2 min | [PROOF.md](PROOF.md) — every claim as a link or a pasteable command |
| +2 min | [MOCKS.md](MOCKS.md) — the exact real-versus-simulated line, four simulated inputs, three project caveats |
| +2 min | [CLAIMS.md](CLAIMS.md) — 74 statements tagged `REPRODUCIBLE` / `VERIFIED-LIVE` / `MODELED` / `NOT-CLAIMED`, plus a 15-item explicit not-claimed list |
| +3 min | [README.md](README.md) — the product, the architecture, and the honest limits |
| +5 min | `cd contracts && forge test --no-match-path 'test/fork/*'` → 273 passed, 0 failed, 1 skipped |
| +5 min | `BASE_RPC_URL=<archive> base-forge test --match-path 'test/fork/*'` → 8 passed, against live and historical mainnet state |

## The things we would flag ourselves

Because you will find them, and it is better that we say them first.

1. **No Basescan verification.** No API key. Sourcify covers all 17
   contracts `exact_match`; Blockscout covers five of the top-level ones and structurally cannot cover the
   seven factory oracles.
2. **The Morpho Blue market is funded but tiny.** One supplier, one borrower, both the deployer,
   $0.50 total. It proves the `IOracle` integration end to end and it is not liquidity.
   [PROOF §11](PROOF.md#11-morpho-blue-integration).
2b. **The swap adapter was publicly callable until 2026-09-07, and one arbitrary EOA used it** to swap
   USDC into a tokenized US equity (tx `0xcf9150ed…1f9a37`). We had presented that transaction as
   evidence the component works; it is better read as evidence that we shipped a securities-swap
   endpoint with no jurisdiction check on it. `swapExactIn` is now `onlyCredit` on a redeployed
   adapter, and the correction is written up in [PROOF §4](PROOF.md). `sweepYield`, the in-protocol
   caller, still has not fired, because no B20 has had a corporate action.
3. **Demo eligibility is attested by our own registry, not Coinbase's** — we hold no Coinbase account.
   The Coinbase read path is real and proven against a genuinely attested third party
   (`0xc799DD32…bB6d7`, country `PL`), and the deployed gate reports the difference in its own return
   value: `source = 1` for that address, `source = 2` for ours. [MOCKS §1](MOCKS.md).
4. **The weekend replay's 11,557 → 6,921 borrowing-power contraction is modeled**, not measured: real
   historical chain state at real pinned blocks, but the fork fixture's risk parameters rather than the
   deployed ones. Labelled everywhere it appears. [MOCKS, project-level caveats](MOCKS.md).
5. **"An owner key cannot admit a US person" would be too strong.** What is true: the credit engine's
   gate address is immutable with no setter, and `RegSGate` reverts
   `UnitedStatesIsPermanentlyRestricted()` if asked to un-restrict `US`. What is still possible: the
   fallback registry behind the gate is owner-settable and its owner is implicitly an attester, so a
   jurisdiction can be asserted by our key rather than proven by Coinbase — which is what our own demo
   account does, visibly, as `source = 2`. [CLAIMS.md](CLAIMS.md) claims 68-74.
6. **A Builder Code is now wired in, but it is not minted, and nothing sent so far is attributed.**
   `NEXT_PUBLIC_BUILDER_CODE=bc_ftoaimc9` was issued to the deployer wallet by Base's own agent
   endpoint (`POST /v1/agents/builder-codes`) and the ERC-8021 suffix is wired end to end on the
   wagmi config. Issuance is not minting: as of block `51048364` on Base mainnet,
   `isRegistered("bc_ftoaimc9")` on Base's registry (`0x000000BC7…59C8E80`) returns `false` — rerun
   it, the relayer mints asynchronously and may have caught up by the time you read this. Either way,
   **every transaction this app has ever sent — the deployment, the demo lifecycle, the Morpho
   supply/collateral/borrow calls — went out before this code existed and is permanently
   unattributed**; only transactions sent after the code was set, once it is actually registered,
   pick up the suffix. The app itself *is* registered on base.dev (`aftermarket-fawn.vercel.app`,
   verified by a `base:app_id` meta tag), which is a different thing and attributes nothing on chain.
   [README → Attribution](README.md#attribution-erc-8021-builder-codes).
7. **The refutation suite was written mid-audit and has been re-pointed since.** Three fixes landed
   under it — `cure` now needs an open market, a sweep is capped at 10% of the position, and the
   multiplier checkpoint is a high-water mark — and each one makes an attack it probed strictly
   harder. The tests now assert what the shipped contract does, and
   `contracts/audit/refute/RefuteBase.sol` says so at the top rather than quietly.
