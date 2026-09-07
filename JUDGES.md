# Review this in five minutes

In order. Each step says what it costs you and what it should convince you of. Everything except the
last two steps is a read-only call against Base mainnet — no wallet, no key, no install beyond
[`cast`](https://book.getfoundry.sh/getting-started/installation).

```bash
export RPC=https://mainnet.base.org
```

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

One command that needs nothing but Node, and prints the live evidence this whole project is built on:

```bash
pnpm verify:onchain
```

---

## 1 · The two commands — 60 seconds

This is the product. Two calls, one asset that the oracle will mark and one it will not.

```bash
# Answers. Sources agree: 105 bps of divergence inside a 300 bps band.
cast call 0x1E2b20B4703F97710c2600eA73179c6CD1E00b02 "price()(uint256)" --rpc-url $RPC
# 2184594350000000000000000000000000000        -> $218.459435 per NVDAc

# Refuses. Sources disagree: ~900 bps against the same 300 bps band.
cast call 0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C "price()(uint256)" --rpc-url $RPC
# execution reverted, data: 0x1047f22b
#   ...0005  session    = 5  CLOSED_HOLIDAY
#   ...0381  divergence = 897 bps          <- moves with the pool
#   ...012c  band       = 300 bps
```

`0x1047f22b` is `SourcesDiverged(uint8,uint256,uint256)` — check with
`cast sig "SourcesDiverged(uint8,uint256,uint256)"`.

Today is Labor Day. The last real Chainlink print was Friday 16:00 ET; the next is Tuesday 09:30 ET.
**89 h 30 m apart.** AMZNc's frozen anchor says $257.69 while the pool it actually trades in prints
$280.88. Aftermarket's oracle will not pick a winner, so it refuses — and because Morpho Blue reads
`price()` only in `borrow`, `withdrawCollateral` and `liquidate`, that refusal freezes new risk and
freezes seizure while leaving repayment open.

### Now the one that makes it falsifiable — 30 seconds

```bash
cast call 0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58 "price()(uint256)" --rpc-url $RPC
# execution reverted: SourcesDiverged(session=5, divergence=105, band=25)
```

That is an `AftermarketOracle` on the **same NVDAc**, the **same feed**, the **same pool**, the **same
calendar**, at the **same block** as the one that answered in the first command. One constructor
number differs: the divergence band, 25 bps instead of 300. It refuses where production answers.

A negative control that fires is the difference between "our check passed" and "our check works".

---

## 2 · The headline measurement — 60 seconds

Two archive calls at adjacent blocks, straddling the transaction that deposited **$1.00 of AMZNc** as
collateral into the live demo line:

```bash
U=0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f
for B in 50991631 50991632; do
  cast call 0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3 "draw(uint256,address)" 900000 $U \
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

And the other direction, at the head:

```bash
cast call 0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3 "flag(address)" $U --from $U --rpc-url $RPC
# LineHealthy(debt = 500011, seizureThreshold = 1069403)
```

The bar to seize this line is **2.14× the debt**, because `markLiquidate` is the optimistic mark and
the closed-session liquidation threshold (8500 bps) is *higher* than the open one (8000 bps). Shutting
the market makes the position harder to take, not easier.

---

## 3 · The addresses — 30 seconds

All seventeen deployed contracts are source-verified **exact match** on Sourcify, with no explorer API
key. The ten top-level ones are also on Blockscout.

| | |
|---|---|
| `TradingCalendar` | [`0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9`](https://repo.sourcify.dev/8453/0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9) |
| `AttesterRegistry` | [`0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E`](https://repo.sourcify.dev/8453/0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E) |
| `RegSGate` | [`0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C`](https://repo.sourcify.dev/8453/0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C) |
| `SessionRateModel` | [`0x6d5152d81982DEb660736fC514761E18533a2343`](https://repo.sourcify.dev/8453/0x6d5152d81982DEb660736fC514761E18533a2343) |
| `AftermarketOracleFactory` | [`0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A`](https://repo.sourcify.dev/8453/0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A) |
| `AerodromeSwapAdapter` | [`0xfF81282c6353dC3fB0Ca890Da3cdde9BAFcd68fF`](https://repo.sourcify.dev/8453/0xfF81282c6353dC3fB0Ca890Da3cdde9BAFcd68fF) |
| `AftermarketCredit` | [`0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3`](https://repo.sourcify.dev/8453/0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3) |
| `AftermarketVault` | [`0x00751166Ce3fa20a4143a1F0D848978Db73bd53f`](https://repo.sourcify.dev/8453/0x00751166Ce3fa20a4143a1F0D848978Db73bd53f) |
| `AutoRepayer` | [`0xEFC7ce780F5030489a027cebde8BeFb7e7ee681A`](https://repo.sourcify.dev/8453/0xEFC7ce780F5030489a027cebde8BeFb7e7ee681A) |
| `AftermarketLens` | [`0x5A18BdEB02B30b737a2464E02A2a669BF52bC049`](https://repo.sourcify.dev/8453/0x5A18BdEB02B30b737a2464E02A2a669BF52bC049) |
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
independent verdicts per row (expected label, keeper engine, the contract's own `simulate()`), all
three agreeing on all 32.

Read the two columns that matter. **11/11 traps refused** — scenarios engineered to look actionable
and be wrong. **6/6 negative controls acted** — scenarios that must act, so a keeper that always
refuses scores 26/32, not 32/32. Both directions are scored, which is the only way the number means
anything.

---

## 5 · The self-audit — 90 seconds

[`contracts/audit/AUDIT.md`](contracts/audit/AUDIT.md). 2,046 lines. **3 High, 11 Medium, 2 Low, 1
Informational**, all found by us in our own code before deployment, every one with a runnable Foundry
PoC that drives the real contracts at the real deploy parameters.

Fourteen fixed in code, one mitigated with the residual written down, three behaviours accepted by
design and documented in the contracts themselves. Then a **second adversarial pass over the fixes**,
on the premise that a fix is just new code — it found six more problems (including a reentrancy path
through the swap adapter that could have sent swap proceeds to the borrower instead of the vault) and
recorded two residuals rather than papering over them.

It also publishes **fifteen attacks that did not work**, each with a passing refutation test —
including three separate attempts to extract value by manipulating the shallow Aerodrome pools, all
refuted by the `min`/`max` fusion.

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
```

---

## 6 · If you have longer

| you have | read |
|---|---|
| +2 min | [PROOF.md](PROOF.md) — every claim as a link or a pasteable command |
| +2 min | [MOCKS.md](MOCKS.md) — the exact real-versus-simulated line, four simulated inputs, three project caveats |
| +2 min | [CLAIMS.md](CLAIMS.md) — 60 statements tagged `REPRODUCIBLE` / `VERIFIED-LIVE` / `MODELED` / `NOT-CLAIMED`, plus a 15-item explicit not-claimed list |
| +3 min | [README.md](README.md) — the product, the architecture, and the honest limits |
| +5 min | `cd contracts && forge test --no-match-path 'test/fork/*'` → 255 passed, 0 failed, 1 skipped |
| +5 min | `BASE_RPC_URL=<archive> base-forge test --match-path 'test/fork/*'` → 8 passed, against live and historical mainnet state |

## The four things we would flag ourselves

Because you will find them, and it is better that we say them first.

1. **No Basescan verification.** No API key. Sourcify covers all 17
   contracts `exact_match`; Blockscout covers the ten top-level ones and structurally cannot cover the
   seven factory oracles.
2. **The Morpho Blue market is funded but tiny**, and `AerodromeSwapAdapter.swapExactIn` has since
   fired directly on mainnet (0.4 USDC → 0.00172031 NVDAc, tx `0xcf9150ed…1f9a37`) — though `sweepYield`,
   the corporate-action path through it, still hasn't, because no B20 has had one. Both integrations
   are real and exercised; neither has volume. [PROOF §11](PROOF.md#11-morpho-blue-integration).
3. **Demo eligibility is attested by our own registry, not Coinbase's** — we hold no Coinbase account.
   The Coinbase read path is real and proven against a genuinely attested third party
   (`0xc799DD32…bB6d7`, country `PL`), and the deployed gate reports the difference in its own return
   value: `source = 1` for that address, `source = 2` for ours. [MOCKS §1](MOCKS.md).
4. **The weekend replay's 11,557 → 6,921 borrowing-power contraction is modeled**, not measured: real
   historical chain state at real pinned blocks, but the fork fixture's risk parameters rather than the
   deployed ones. Labelled everywhere it appears. [MOCKS, project-level caveats](MOCKS.md).
