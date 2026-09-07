# PROOF

Every claim Aftermarket makes, as a link you can click or a command you can paste. Nothing here needs
a wallet, a key or a deploy.

**Network:** Base mainnet, chainId 8453 · **Deployer/owner:** [`0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f`](https://base.blockscout.com/address/0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f)
· **Deploy block:** 50,987,282 for the oracles, the calendar, the gate, the registry and the rate
model; **51,009,779** for the credit engine, vault, auto-repayer, lens and swap adapter, which were
redeployed the same day for the Reg-S changes described in [CLAIMS.md](CLAIMS.md).

Live reads below are pinned to one of two blocks, and each command says which:

- **`$BLOCK` = 50,997,343** (2026-09-07 12:27:13 UTC = 08:27 ET, Labor Day) for §2, the oracles. Those
  contracts did not change and neither did their addresses, so every oracle read on this page is the
  same read it always was.
- **`$CBLOCK` = 51,010,200** (2026-09-07 19:35:47 UTC) for §3, the credit engine, which is at a
  new address as of 19:26 UTC.

Drop `--block` to read the head; the numbers that move are called out where they appear.

```bash
export RPC=https://mainnet.base.org      # any Base RPC; an archive node for the --block reads
export BLOCK=50997343                    # the oracle reads, §2
export CBLOCK=51010200                   # the credit engine reads, §3
```

---

## 1. Source verification

All seventeen deployed contracts are verified **exact match** on Sourcify, with no explorer API key
involved. Re-run or re-check it yourself:

```bash
scripts/verify-sources.sh status      # what each verifier holds, right now
scripts/verify-sources.sh sourcify    # re-submit everything
```

| Contract | Address | Sourcify | Blockscout |
|---|---|---|---|
| `TradingCalendar` | `0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9` | [exact match](https://repo.sourcify.dev/8453/0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9) | [source](https://base.blockscout.com/address/0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9?tab=contract) |
| `AttesterRegistry` | `0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E` | [exact match](https://repo.sourcify.dev/8453/0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E) | [source](https://base.blockscout.com/address/0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E?tab=contract) |
| `RegSGate` | `0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C` | [exact match](https://repo.sourcify.dev/8453/0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C) | [source](https://base.blockscout.com/address/0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C?tab=contract) |
| `SessionRateModel` | `0x6d5152d81982DEb660736fC514761E18533a2343` | [exact match](https://repo.sourcify.dev/8453/0x6d5152d81982DEb660736fC514761E18533a2343) | [source](https://base.blockscout.com/address/0x6d5152d81982DEb660736fC514761E18533a2343?tab=contract) |
| `AftermarketOracleFactory` | `0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A` | [exact match](https://repo.sourcify.dev/8453/0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A) | [source](https://base.blockscout.com/address/0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A?tab=contract) |
| `AerodromeSwapAdapter` | `0x71283dB3a0b784F0B9e9B0dFc2398877D0A8465E` | [exact match](https://repo.sourcify.dev/8453/0x71283dB3a0b784F0B9e9B0dFc2398877D0A8465E) | [source](https://base.blockscout.com/address/0x71283dB3a0b784F0B9e9B0dFc2398877D0A8465E?tab=contract) |
| `AftermarketCredit` | `0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93` | [exact match](https://repo.sourcify.dev/8453/0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93) | [source](https://base.blockscout.com/address/0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93?tab=contract) |
| `AftermarketVault` | `0x00ee99240Ad9a4b25DD06eAcD1b852C83fbd2697` | [exact match](https://repo.sourcify.dev/8453/0x00ee99240Ad9a4b25DD06eAcD1b852C83fbd2697) | [source](https://base.blockscout.com/address/0x00ee99240Ad9a4b25DD06eAcD1b852C83fbd2697?tab=contract) |
| `AutoRepayer` | `0xBe1EA7CA0Fabc93F86C43fBcB25bbB3f2a0A2404` | [exact match](https://repo.sourcify.dev/8453/0xBe1EA7CA0Fabc93F86C43fBcB25bbB3f2a0A2404) | [source](https://base.blockscout.com/address/0xBe1EA7CA0Fabc93F86C43fBcB25bbB3f2a0A2404?tab=contract) |
| `AftermarketLens` | `0x27BFaddEc57fF76d498Ef1a7b09C5951DeA6735D` | [exact match](https://repo.sourcify.dev/8453/0x27BFaddEc57fF76d498Ef1a7b09C5951DeA6735D) | [source](https://base.blockscout.com/address/0x27BFaddEc57fF76d498Ef1a7b09C5951DeA6735D?tab=contract) |
| `AftermarketOracle` NVDAc | `0x1E2b20B4703F97710c2600eA73179c6CD1E00b02` | [exact match](https://repo.sourcify.dev/8453/0x1E2b20B4703F97710c2600eA73179c6CD1E00b02) | see note |
| `AftermarketOracle` AAPLc | `0x6cE58FE71eD10b82c2C0A9a348E82D1ee6D9a8dc` | [exact match](https://repo.sourcify.dev/8453/0x6cE58FE71eD10b82c2C0A9a348E82D1ee6D9a8dc) | see note |
| `AftermarketOracle` METAc | `0xf5Cc0cc94ecF4866661373f2aa066af76e08dEf2` | [exact match](https://repo.sourcify.dev/8453/0xf5Cc0cc94ecF4866661373f2aa066af76e08dEf2) | see note |
| `AftermarketOracle` GOOGLc | `0x203cDf7e33eA0d652cA54f4807c9d2d1d081C9aA` | [exact match](https://repo.sourcify.dev/8453/0x203cDf7e33eA0d652cA54f4807c9d2d1d081C9aA) | see note |
| `AftermarketOracle` TSLAc | `0x74058d51B3b04Ba09be2aa51ab1CE930Dd3c2C99` | [exact match](https://repo.sourcify.dev/8453/0x74058d51B3b04Ba09be2aa51ab1CE930Dd3c2C99) | see note |
| `AftermarketOracle` AMZNc | `0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C` | [exact match](https://repo.sourcify.dev/8453/0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C) | see note |
| `AftermarketOracle` **negative control** | `0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58` | [exact match](https://repo.sourcify.dev/8453/0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58) | see note |

**Note on Blockscout and Basescan.** We had no Etherscan/Basescan API key, so Basescan pages for these
addresses show unverified bytecode — that is a missing key, not a missing source. Blockscout holds the
ten top-level contracts. It does **not** hold the seven oracles, and we could not make it: those were
created by `CREATE2` from inside `AftermarketOracleFactory`, Blockscout indexed no creation
transaction for them (`creation_transaction_hash: null`, `creation_bytecode: null` in its own API), and
its verifier matches on creation bytecode. Three submission routes were tried and all three failed the
same way. Full detail, including the exact requests: **[docs/verification.md](docs/verification.md)**.

Sourcify matches **runtime** bytecode as well as creation bytecode, so the same fact that defeats
Blockscout costs Sourcify only the creation half: all seven carry a runtime `exact_match`, which is the
match that proves the code running at those addresses is the source in this repository. Their
constructor arguments are in
[`contracts/deployments/8453.json`](contracts/deployments/8453.json) and every immutable they set is
independently readable on chain — see §2c.

---

## 2. The live refusals

### 2a. NVDAc answers

```bash
cast call 0x1E2b20B4703F97710c2600eA73179c6CD1E00b02 "price()(uint256)" --rpc-url $RPC --block $BLOCK
```

```
2184594350000000000000000000000000000
```

Morpho's `price()` is scaled `1e36 · 10^(loanDecimals) / 10^(collateralDecimals)` = `1e34` here (USDC
6, NVDAc 8), so that is **$218.459435** per NVDAc. The full state behind it, pinned to the same block
(`feedAge` and `divergenceBps` advance every block; everything else is stable):

```bash
cast call 0x1E2b20B4703F97710c2600eA73179c6CD1E00b02 \
  "peek()((uint8,uint8,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint64))" \
  --rpc-url $RPC --block $BLOCK
```

| field | value | meaning |
|---|---|---|
| `verdict` | `1` | `TRUSTED_CLOSED` |
| `session` | `5` | `CLOSED_HOLIDAY` |
| `anchorPrice` | `229.9573e18` | Chainlink Coinbase NVDA, frozen at Friday's close |
| `poolPrice` | `232.392563e18` | Aerodrome Slipstream 30-min TWAP, still moving |
| `markBorrow` | `2.18459435e36` | `min(anchor, pool) × (1 − 500 bps)` = `229.9573 × 0.95` |
| `markLiquidate` | `2.4401219115e36` | `max(anchor, pool) × (1 + 500 bps)` = `232.392563 × 1.05` |
| `feedAge` | `238978` s (66.4 h) | |
| `stalenessBudget` | `360000` s (100 h) | staleness is *not* what is being tested here |
| `divergenceBps` | `105` | |
| `divergenceBand` | `300` | 105 < 300, so the sources agree |
| `haircutBps` | `500` | at the cap: 25 bps base + 15 bps/h × 66 h |
| `multiplier` | `1e18` | no corporate action in flight |
| `poolLiquidityUsd` | `1,611,046e18` | well above the $25,000 floor |
| `nextOpen` / `lastClose` | `1788874200` / `1788552000` | Tue 09:30 ET / Fri 16:00 ET — **89 h 30 m apart** |

> `feedAge`, `divergenceBps` and `poolLiquidityUsd` all move every block — the pool's TWAP window keeps
> sliding even when the price it reports doesn't. Drop `--block` and all three will differ from the
> table above; `verdict`, `session`, `anchorPrice`, `haircutBps` and the calendar timestamps will not,
> until the next bell or the next haircut tick.

### 2b. AMZNc refuses

```bash
cast call 0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C "price()(uint256)" --rpc-url $RPC --block $BLOCK
```

```
execution reverted, data: 0x1047f22b
  0000000000000000000000000000000000000000000000000000000000000005   session  = 5 (CLOSED_HOLIDAY)
  0000000000000000000000000000000000000000000000000000000000000381   divergence = 897 bps
  000000000000000000000000000000000000000000000000000000000000012c   band       = 300 bps
```

`0x1047f22b` = `cast sig "SourcesDiverged(uint8,uint256,uint256)"`. Verify it:

```bash
cast sig "SourcesDiverged(uint8,uint256,uint256)"      # 0x1047f22b
```

AMZNc's Chainlink anchor is frozen at **$257.69** while the pool it trades in prints **$280.88**. The
oracle will not pick a winner, so it refuses.

> **The divergence number moves.** It was 886 bps at block 50,991,632, 897 at the pinned block, and
> 912 in the Sunday snapshot. The pool keeps trading; the anchor does not. The *session*, the *band*
> and the *refusal* are stable, and that is the claim. Anything without `--block` will differ.

### 2c. The negative control — a green check that could have been red

`0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58` is an `AftermarketOracle` on the **same** NVDAc token,
the **same** Chainlink feed, the **same** Aerodrome pool and the **same** calendar as the production
NVDAc oracle. One constructor field differs: the six-entry divergence band array is **25 bps in every
session** instead of the production `500 / 500 / 500 / 200 / 250 / 300`.

```bash
cast call 0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58 "price()(uint256)" --rpc-url $RPC --block $BLOCK
```

```
execution reverted, data: 0x1047f22b
  ...0005   session    = 5 (CLOSED_HOLIDAY)
  ...0069   divergence = 105 bps
  ...0019   band       =  25 bps
```

Same asset, same block, same 105 bps of divergence. Production answers because 105 < 300; the control
refuses because 105 > 25. The check in §2a is falsifiable, and here is the falsification.

Prove the two are otherwise identical:

```bash
for O in 0x1E2b20B4703F97710c2600eA73179c6CD1E00b02 0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58; do
  for F in collateralToken loanToken feed pool calendar; do
    printf '%s %-16s ' "${O:0:10}" "$F"; cast call $O "$F()(address)" --rpc-url $RPC
  done
done
# both: collateral 0xb20000000000000000000078ee7ce2fE4908108C
#       loan       0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
#       feed       0x04689a41629776563E6822F76f2e57D148d28513
#       pool       0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9
#       calendar   0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9
```

---

## 3. The credit engine, live

The demo line at `0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f` holds **0.00515351 NVDAc** and
**0.00356308 AMZNc** against **0.500000 USDC** of debt. Same collateral, same borrower, re-seeded onto
the redeployed engine on 2026-09-07 at 19:3x UTC — see §4.

### 3a. It refuses to lend more than the markable collateral supports

```bash
cast call 0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93 "draw(uint256,address)" \
  900000 0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f \
  --from 0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f --rpc-url $RPC --block $CBLOCK
```

```
execution reverted, data: 0x5033ec12
  ...155cc0   debtAfter   = 1400000   ($1.400000)
  ...0896e4   borrowPower =  562916   ($0.562916)
```

`0x5033ec12` = `cast sig "Undercollateralized(uint256,uint256)"`.

### 3b. It refuses to seize while the market is shut

```bash
cast call 0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93 "flag(address)" \
  0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f \
  --from 0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f --rpc-url $RPC --block $CBLOCK
```

```
execution reverted, data: 0x0d007982
  ...07a120   debt             =  500000   ($0.500000)
  ...104918   seizureThreshold = 1067800   ($1.067800)
```

`0x0d007982` = `cast sig "LineHealthy(uint256,uint256)"`. The seizure threshold is **2.14× the debt**,
because `markLiquidate` is the optimistic mark (`max(anchor, pool) × 1.05`) and the closed-session
liquidation threshold is 8500 bps against 8000 bps when the market is open. Closing the market makes
the line *harder* to take, not easier.

> `debt` accrues every second, so the first number rises between blocks. The threshold moves with the
> pool TWAP. Both are pinned by `--block`.

### 3c. The headline: an unmarkable asset contributes exactly zero borrowing power

Two archive calls at adjacent blocks, straddling the transaction that deposited **$1.00 of AMZNc** as
collateral (tx [`0xcbeeef4f…f29155`](https://base.blockscout.com/tx/0xcbeeef4f98773d8d75818322f7a82cdba489067f77069702e38ddcf765f29155), block 51,009,977):

```bash
U=0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f
for B in 51009976 51009977; do
  cast call 0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93 "draw(uint256,address)" 900000 $U \
    --from $U --rpc-url $RPC --block $B
done
```

```
block 51009976  (before)  ->  Undercollateralized(900000, 562916)
block 51009977  (after)   ->  Undercollateralized(900000, 562916)
```

**Borrow power before: 562,916. Borrow power after: 562,916.**

And the arithmetic closes exactly. All 562,916 comes from the NVDAc leg alone:

```
515351 raw NVDAc  ×  2.18459435 (markBorrow / 1e36)  ×  0.50 (advanceClosedBps)  =  562916.45  ->  562916
```

There is nothing left over for AMZNc. It is held, it is withdrawable, it is unseizable, and it is
worth zero borrowing power for as long as the oracle refuses to mark it. An outage is a freeze, never
a loss and never a licence.

You can see the same thing from the lens, which never reverts:

```bash
cast call 0x27BFaddEc57fF76d498Ef1a7b09C5951DeA6735D \
  "previewDraw(address,uint256)((bool,uint8,uint256,uint256,uint256))" \
  0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f 900000 --rpc-url $RPC --block $CBLOCK
# (false, 5, 1400000, 0, 0)      reason 5 = UNPRICED
```

The lens is deliberately stricter than the engine: it reports `priced = false` and zeroes the numbers
whenever **any** asset in the basket is unmarkable, so a front end can never quietly render a partial
basket as a whole one. The engine is the one that does the per-asset arithmetic.

---

## 4. Live demo transactions

All Base mainnet, all successful (`status = 1`), all from the deployer, all on 2026-09-07.

The demo line was opened twice that day, because the credit engine was redeployed in the afternoon to
close two Regulation-S holes (audit **A-09**, and the swap adapter's open `swapExactIn`). The first
line was repaid and unwound in full before the second was opened, so nothing is stranded on the
retired contracts and the collateral in the table below is the same collateral throughout. Both
halves are listed; nothing has been quietly replaced.

**The line as it stands now, on the engine at `0xD5d4A08C…94Ee93`:**

| # | step | block | transaction |
|---|---|---|---|
| 1 | eligibility attestation (`AttesterRegistry` — unchanged by the redeploy, so this one attestation still governs) | 50,991,370 | [`0x35191d73…27422d`](https://base.blockscout.com/tx/0x35191d733f636ece63002a9f7ca086c9beedeef533afc976f33a88edae27422d) |
| 2 | swap 1.000000 USDC → 0.00356308 AMZNc on Aerodrome | 50,991,489 | [`0xcbe1f83c…113c77`](https://base.blockscout.com/tx/0xcbe1f83c51be52f6308c545bb7016d57b0b97f06bf605c9a9fbebbbed9113c77) |
| 3 | swap 1.200000 USDC → 0.00515351 NVDAc on Aerodrome | 50,991,539 | [`0x608c9266…1415160`](https://base.blockscout.com/tx/0x608c92665620e33b184368ac393555096ccfea5da6246a5610729d54d1415160) |
| 4 | supply 2.000000 USDC to `AftermarketVault` | 51,009,875 | [`0x9afff88f…8d00f9`](https://base.blockscout.com/tx/0x9afff88f6d8ee40f7016ac9be0e7f179af9ca8eba54e6fec1cbb2605838d00f9) |
| 5 | open line | 51,009,900 | [`0x6283620d…f4c3c7`](https://base.blockscout.com/tx/0x6283620dde56d34a23be809df054916bcd78659aa2c41965ecbba16edef4c3c7) |
| 6 | deposit NVDAc collateral | 51,009,936 | [`0xc159dc25…a5517c`](https://base.blockscout.com/tx/0xc159dc2567abd8435ea7077d5d4a878c72c85eda4c68e776470252b7cca5517c) |
| 7 | deposit AMZNc collateral | 51,009,977 | [`0xcbeeef4f…f29155`](https://base.blockscout.com/tx/0xcbeeef4f98773d8d75818322f7a82cdba489067f77069702e38ddcf765f29155) |
| 8 | draw 0.500000 USDC | 51,010,003 | [`0x64f704e6…2b2f6b`](https://base.blockscout.com/tx/0x64f704e602b34a91e2d411c9c458fae2ccabaec6f16779bdea72d19d1f2b2f6b) |

Check any of them:

```bash
cast receipt 0x64f704e602b34a91e2d411c9c458fae2ccabaec6f16779bdea72d19d1f2b2f6b --rpc-url $RPC
```

Steps 2 and 3 call the Aerodrome `SwapRouter` (`0x698cb2b6…3a92f`) directly from the wallet — they are
how the demo account acquired collateral, not a protocol code path.

**Unwinding the first line, before the redeploy.** Every one of these ran against the retired engine
at `0x4dEc9438…3bF4b3` and its vault at `0x00751166…3bd53f`, which are the addresses this document
used to carry. They are listed so that "we redeployed" is checkable rather than asserted, and so that
the retired contracts can be seen to hold nothing:

| # | step | block | transaction |
|---|---|---|---|
| r1 | repay the line in full (0.500035 USDC) | 51,009,463 | [`0x1f3551c5…3e5c68`](https://base.blockscout.com/tx/0x1f3551c5a57f33f2e3fe90d9ced44753fa2794af2bc7f3a55e81b355933e5c68) |
| r2 | withdraw 0.00515351 NVDAc | 51,009,473 | [`0x2009e132…1519ff`](https://base.blockscout.com/tx/0x2009e13270c8c1469adb9624372b74dee0f78c1671170f0ee24fe69ae01519ff) |
| r3 | withdraw 0.00356308 AMZNc | 51,009,493 | [`0x0d749644…90cef7`](https://base.blockscout.com/tx/0x0d749644b98bb3500979119c51c68dde915866fa8725bcb90ff55ebbf390cef7) |
| r4 | redeem every vault share (2.000034 USDC) | 51,009,599 | [`0xac5b64d2…289292`](https://base.blockscout.com/tx/0xac5b64d2119b2bdde90bddf9b98bf9403b2c91d8fa8cdca67a23613b88289292) |

```bash
# the retired engine and vault hold nothing
cast call 0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3 "totalDebtAssets()(uint256)" --rpc-url $RPC   # 0
cast call 0x00751166Ce3fa20a4143a1F0D848978Db73bd53f "totalAssets()(uint256)"    --rpc-url $RPC   # 1 — one unit of rounding dust, no shares outstanding
```

### The swap adapter, and one transaction that needs its label corrected

`AerodromeSwapAdapter` fired on mainnet on 2026-09-07 at block 50,998,717, swapping 0.400000 USDC into
0.00172031 NVDAc: tx
[`0xcf9150ed…1f9a37`](https://base.blockscout.com/tx/0xcf9150edf881cc45bb43df9a9ede54af3aedfd6230e338fd9f643dadd51f9a37).

**Earlier versions of this document presented that as evidence the component works. That framing was
wrong and is withdrawn.** What the transaction actually shows is an arbitrary externally-owned
account calling `swapExactIn` on a deployed, source-verified contract of ours and receiving a
tokenized US equity, with no jurisdiction check anywhere on the path. The adapter's `swapExactIn` was
`external` with no caller restriction, which made it a securities-swap endpoint this project
published — not a feature, a hole. It is the same hole the review of A-09 found on `liquidate`, in a
second place.

The honest reading is narrower and still worth something: **the adapter's code path was exercised
against real Slipstream liquidity before it was locked down.** The transfer in, the transfer out, the
router hop and the `minOut` assertion all executed on mainnet. That is a fact about the routing code,
which is unchanged. It is not a fact about an entry point anybody should be able to reach.

The deployed adapter is now `0x71283dB3…A8465E`, its `swapExactIn` is `onlyCredit`, and the caller is
an immutable fixed at construction with no setter. The old transaction is preserved above rather than
deleted, because it is the evidence for both halves of that sentence. Confirm the gate yourself:

```bash
A=0x71283dB3a0b784F0B9e9B0dFc2398877D0A8465E
cast call $A "credit()(address)" --rpc-url $RPC
# 0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93   — the credit engine, and nobody else

cast call $A "swapExactIn(address,address,uint256,uint256,address)(uint256)"   0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 0xb20000000000000000000078ee7ce2fE4908108C   100000 0 0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f   --from 0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f --rpc-url $RPC
# execution reverted, data: 0xc20d0a87…0af7afc7…   = NotCredit(0x0AF7aFC7…C5c8f)
```

`sweepYield`, the in-protocol caller, still has not fired: it needs a B20 corporate action that has
never occurred. That is a fact about Coinbase's tokens rather than about this contract; see
[MOCKS §2](MOCKS.md).

Protocol state at the reference block, one call:

```bash
cast call 0x27BFaddEc57fF76d498Ef1a7b09C5951DeA6735D \
  "protocolView()((uint8,uint64,uint64,uint256,uint256,uint256,uint256,address[]))" --rpc-url $RPC --block $BLOCK
# (5, 1788874200, 1788552000, 500011, 2000011, 250004124977312624, 1000005, [6 assets])
#  ^session CLOSED_HOLIDAY   ^nextOpen  ^lastClose  ^debt   ^supplied  ^utilisation         ^share price
```

> `debt`, `supplied`, `utilisation` and `share price` all move — debt accrues every second and the
> vault's share price ticks up with it. Drop `--block` and every one of the last four fields will have
> moved by the time you read this; `session`, `nextOpen` and `lastClose` will not, until the next bell.

---

## 5. Compliance: the Coinbase read path is real

`RegSGate` reads live Coinbase Verifications EAS attestations on Base — the real EAS predeploy
`0x4200…0021` and the real Coinbase indexer `0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C`, against the
real `verifiedCountry` and `verifiedAccount` schemas. Two calls against the **deployed** gate prove it:

```bash
GATE=0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C

# A genuinely Coinbase-attested third party (not us, no relationship to this project)
cast call $GATE "check(address)(bool,bytes2,uint8)" 0xc799DD327b5D6c6E4Ed5bbEC510b49A1ce4bB6d7 --rpc-url $RPC
# true    0x504c ("PL")    1   <- source 1 = SOURCE_COINBASE

# An address with no attestation
cast call $GATE "check(address)(bool,bytes2,uint8)" 0x000000000000000000000000000000000000dEaD --rpc-url $RPC
# false   0x0000           0   <- source 0 = SOURCE_NONE

# Our own demo account
cast call $GATE "check(address)(bool,bytes2,uint8)" 0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f --rpc-url $RPC
# true    0x504c ("PL")    2   <- source 2 = SOURCE_REGISTRY (our AttesterRegistry, not Coinbase)
```

That third result is the honest one and it is deliberately visible on chain: we hold no Coinbase
account, so our demo eligibility comes through our own fallback attester. The Coinbase path is real,
proven, and *not* what the demo used. [MOCKS.md](MOCKS.md) says so in full.

The same thing as a test, which also asserts the negative:

```bash
cd contracts
BASE_RPC_URL=$RPC forge test --match-test test_Fork_RealCoinbaseAttestationOnBaseMainnet -vv
```

```
[PASS] test_Fork_RealCoinbaseAttestationOnBaseMainnet() (gas: 1934115)
  attested account 0xc799DD327b5D6c6E4Ed5bbEC510b49A1ce4bB6d7
  country PL
  source 1
Suite result: ok. 1 passed; 0 failed; 0 skipped
```

(This is the "1 skipped" in the main suite — it skips rather than fails when `BASE_RPC_URL` is unset.)

### 5b. The gate is on every path that admits a security, and it cannot be lifted

Three reads against the deployed engine. Nothing here needs a wallet.

```bash
C=0xD5d4A08CA636C06a60Ea4e6266807cb8D994Ee93
U=0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f
DEAD=0x000000000000000000000000000000000000dEaD
NVDA=0xb20000000000000000000078ee7ce2fE4908108C

# 1. An account with no proven jurisdiction cannot receive seized collateral.
cast call $C "liquidate(address,address,uint256)(uint256,uint256)" $U $NVDA 100000   --from $DEAD --rpc-url $RPC
# execution reverted: 0x5dfbdbef…dead   = AttestationMissing(0x…dEaD)

# 2. Nor can it be named as the receiver by somebody who is attested.
cast call $C "liquidate(address,address,uint256,address)(uint256,uint256)" $U $NVDA 100000 $DEAD   --from $U --rpc-url $RPC
# execution reverted: 0x5dfbdbef…dead   = AttestationMissing(0x…dEaD)

# 3. An attested receiver clears the gate, and the next check — the one about risk — bites instead.
cast call $C "liquidate(address,address,uint256)(uint256,uint256)" $U $NVDA 100000   --from $U --rpc-url $RPC
# execution reverted: 0x71f55348…0af7   = NotFlagged(0x0AF7aFC7…C5c8f)
```

`0x5dfbdbef` = `cast sig "AttestationMissing(address)"`, `0x71f55348` = `cast sig "NotFlagged(address)"`.
Reads 1 and 2 are the difference between a compliance gate and a compliance disclaimer: the address
checked is the address the tokens would be transferred to, so an ineligible account cannot reach the
collateral directly *or* by naming somebody else. `msg.sender` is deliberately not checked — the USDC
leg carries no Reg-S obligation, so an unattested bot or relayer can still fund a liquidation for an
attested receiver, which is what keeps the liquidator set large enough to be real. Audit
[A-09](contracts/audit/AUDIT.md) has the full reasoning, including why it was accepted before and is
not accepted now.

And the gate address itself cannot be moved:

```bash
cast call $C "eligibility()(address)" --rpc-url $RPC
# 0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C   — a public immutable

cast call $C "setEligibility(address)" 0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C --rpc-url $RPC
# execution reverted   — there is no such function
```

That is narrower than it sounds and the limit is worth stating precisely: the *address* of the gate is
frozen, and `RegSGate` can never un-restrict `US`. What is **not** frozen is what the gate answers.
`RegSGate.setRegistry` can still repoint the fallback source, and the `AttesterRegistry` owner is
implicitly an attester, so a country code can still be *asserted* by our key rather than *proven* by
Coinbase — which is exactly what the demo account's `source = 2` above is telling you.
[CLAIMS.md](CLAIMS.md) states both halves as separate claims.

---

## 6. Systemic evidence: it is not just AMZNc

[`docs/evidence/weekend-2026-09-06.json`](docs/evidence/weekend-2026-09-06.json) is a block-pinned
snapshot taken at Base block **50,979,049** (2026-09-07 02:17:25 UTC, Sunday 22:17 ET). It reads
thirteen Coinbase B20 tokens, their Chainlink feeds and their Aerodrome pools. Ten have pools. Five
of those ten were more than 150 bps away from the number a Chainlink-only lender would have used:

| asset | feed | pool TWAP | divergence | feed age | USDC in the pool |
|---|---:|---:|---:|---:|---:|
| AMZNc | $257.69 | $281.10 | **912 bps** | 54.2 h | $55,112 |
| MSFTc | $499.78 | $523.79 | **479 bps** | 58.6 h | $62,288 |
| SNDKc | $1732.87 | $1770.87 | **221 bps** | 54.0 h | $83,955 |
| SPCXc | $148.10 | $150.59 | **154 bps** | 54.4 h | $90,531 |
| MSTRc | $142.63 | $144.89 | **153 bps** | 52.8 h | $62,902 |
| NVDAc | $229.96 | $231.40 | 62 bps | 56.2 h | $1,933,290 |
| TSLAc | $353.33 | $355.53 | 62 bps | 54.2 h | $67,470 |
| METAc | $615.23 | $613.87 | 22 bps | 55.1 h | $635,992 |
| GOOGLc | $338.71 | $338.56 | 4 bps | 59.9 h | $915,740 |
| AAPLc | $320.08 | $320.70 | 19 bps | 54.3 h | $641,807 |

(The last column is the observer's raw USDC-side pool balance. The oracle's own depth measure is
stricter — the harmonic mean of in-range liquidity over the TWAP window, capped by that balance — and
it refuses below a $25,000 floor.)

COINc, CRCLc and INTCc have a live feed but no Slipstream pool, so there is no second source to check
them against at all.

Regenerate the live version — no key, no wallet:

```bash
pnpm verify:onchain
node scripts/verify-onchain.mjs --asset NVDAc      # one asset, ~6 calls
node scripts/verify-onchain.mjs --json --snapshot docs/evidence/
```

Sampled again at block 50,997,xxx while writing this, for NVDAc: feed $229.96 (66.8 h old), pool TWAP
$232.37, divergence 105.1 bps, USDC depth $1,616,529 — the same numbers the deployed oracle's `peek()`
returns in §2a, from an independent client.

> The full 13-asset sweep makes about eighty RPC calls. On the public `https://mainnet.base.org`
> endpoint that can trip the rate limiter, and the table then fills with `unavailable` / `NO-POOL` —
> that is the RPC refusing, not the chain. Point `BASE_RPC_URL` at your own endpoint, or use
> `--asset`.

---

## 7. Historical replay: the mechanism across the whole weekend

`contracts/test/fork/WeekendReplay.t.sol` replays the real 2026 Labor Day weekend at **six pinned
historical Base blocks** plus two clock warps, holding a basket of 100 NVDAc fixed and watching the
borrowing power contract as the haircut saturates:

```
when                      source                 unix  session           verdict          feed age   div  band  hcut   mark USD   power USDC
Fri 13:00 ET  mid-session pin 50875927     1788541201  REGULAR           TRUSTED             1h 8m    17   150     0     231.14     11557.08
Fri 16:05 ET  bell + 5m   pin 50881477     1788552301  POST              TRUSTED             2h 0m    15   200   100     227.65      7968.02
Fri 20:05 ET  post over   pin 50888677     1788566701  CLOSED_OVERNIGHT  TRUSTED_CLOSED      6h 0m     7   250   200     225.35      7887.53
Sat 08:00 ET              pin 50910127     1788609601  CLOSED_WEEKEND    TRUSTED_CLOSED    17h 55m    24   250   500     218.45      7646.08
Sun 08:00 ET              pin 50953327     1788696001  CLOSED_WEEKEND    TRUSTED_CLOSED    41h 55m    75   250  1100     204.66      7163.16
Sun 20:00 ET  last block  pin 50974927     1788739201  CLOSED_WEEKEND    TRUSTED_CLOSED    53h 55m    61   250  1400     197.76      6921.71
Mon 12:00 ET  Labor Day   warp             1788796800  CLOSED_HOLIDAY    TRUSTED_CLOSED    69h 55m    60   300  1500     195.46      6841.22
Tue 09:30 ET  next bell   warp             1788874200  REGULAR           UNTRUSTED_STALE   91h 25m    60   150     0     229.95      blocked
```

**11,557 → 6,921 USDC** of borrowing power on the same 100 NVDAc, and then a hard stop at Tuesday's
bell, because a feed that has not printed in 91 hours when the market says it should be printing is
the one case that *is* staleness.

AMZNc over the same instants — the market that actually broke:

```
Fri 13:00 ET  TRUSTED                0 bps
Fri 16:05 ET  TRUSTED                0 bps
Fri 20:05 ET  TRUSTED_CLOSED        33 bps
Sat 08:00 ET  TRUSTED_CLOSED        67 bps
Sun 08:00 ET  UNTRUSTED_DIVERGENT  960 bps
Sun 20:00 ET  UNTRUSTED_DIVERGENT  930 bps
Mon 12:00 ET  UNTRUSTED_DIVERGENT  930 bps
Tue 09:30 ET  UNTRUSTED_STALE      930 bps
```

Artifact: [`contracts/deployments/weekend-timeline.txt`](contracts/deployments/weekend-timeline.txt).

```bash
cd contracts
BASE_RPC_URL=<archive-rpc> base-forge test --match-path 'test/fork/WeekendReplay.t.sol' -vv
```

> **Read this before quoting those numbers.** The replay runs the real contracts against real
> historical chain state, but with the fork fixture's own risk parameters, which are **not** the
> deployed mainnet parameters — the fixture uses a 100 bps + 25 bps/h haircut capped at 1500 bps and a
> 3500 bps closed advance rate, where mainnet ships 25 bps + 15 bps/h capped at 500 bps and 5000 bps.
> The mechanism is real; the specific 11,557 → 6,921 figures belong to the fixture. Spelled out in
> [MOCKS.md](MOCKS.md) and [CLAIMS.md](CLAIMS.md).

---

## 8. Tests

Every count below was produced by running the command, on 2026-09-07, in this repository.

```bash
cd contracts

forge test --no-match-path 'test/fork/*'
# Ran 9 test suites: 273 tests passed, 0 failed, 1 skipped (274 total tests)
#   the 1 skip is the Coinbase-attestation fork test, which needs BASE_RPC_URL — see §5

FOUNDRY_TEST=audit/poc forge test
# Ran 7 test suites: 43 tests passed, 0 failed, 0 skipped

BASE_RPC_URL=<archive-rpc> base-forge test --match-path 'test/fork/*'
# Ran 2 test suites: 8 tests passed, 0 failed, 0 skipped
#   LiveB20.t.sol      6 passed  — the whole protocol against live B20/Chainlink/Aerodrome state
#   WeekendReplay.t.sol 2 passed — the historical replay above
```

The fork suites need [`base-forge`](https://github.com/base/base-anvil), not stock `forge`: a B20 token
is a Rust precompile inside Base's execution client, `eth_getCode` returns the single byte `0xef`, and
stock forge halts with `OpcodeNotFound` on the first `decimals()` call. Detail:
[`contracts/test/fork/README.md`](contracts/test/fork/README.md).

---

## 9. The keeper eval

`AutoRepayer` is a bounded, on-chain-enforced mandate: a user grants a capped, time-boxed Coinbase
Spend Permission, and the keeper may only relay `execute(user)` when the contract's own `simulate(user)`
says it would act. **There is no LLM in the decision path** — `agent/src/engine.ts` is a pure `bigint`
function that mirrors `AutoRepayer._evaluate` line for line, and the two are diffed on every tick.

32 scenarios, scored against a hashed answer key:

```
32/32 correct · 0 false actions · 11/11 traps refused · 6/6 negative controls acted
invariant violations 0 · verdict PASS
answer key hash 271c4b7c7cafadba04e8faf9c69daf301bb7f14a4a017e8789f50428b2fdddd4
```

Every scenario compares three independent verdicts — the expected label, the keeper engine's decision,
and the contract's own `simulate()` — and they agree on all 32. The eleven traps are cases engineered
to look actionable and are not; the six negative controls are cases that must act, so a keeper that
simply always refuses scores 26/32, not 32/32.

Artifacts: [`agent/eval/results/latest.txt`](agent/eval/results/latest.txt) (the scorecard),
[`agent/eval/results/latest.json`](agent/eval/results/latest.json) (machine-readable, with the hash),
[`agent/eval/results/eval-audit.jsonl`](agent/eval/results/eval-audit.jsonl) (per-decision audit log),
[`agent/eval/answer-key.json`](agent/eval/answer-key.json).

---

## 10. The self-audit

[`contracts/audit/AUDIT.md`](contracts/audit/AUDIT.md) — 2,046 lines, written by us, against our own
code, before deployment.

**3 High · 11 Medium · 2 Low · 1 Informational.** Fourteen fixed in code, one mitigated with the
residual written down, three behaviours accepted by design and documented in the contracts themselves.
Every finding rated Medium or above has a runnable Foundry PoC that drives the **real** contracts at
the **real** mainnet deploy parameters. Plus **fifteen attacks that were tried and did not work**,
each with its own passing refutation test — including three separate attempts to extract value by
manipulating the shallow Aerodrome pools.

A second adversarial pass was then run over the fixes themselves, on the premise that a fix is just
new code. It found six more problems (all fixed — including a reentrancy path through the swap adapter
that could have forwarded swap proceeds to the borrower instead of the vault) and recorded two
residuals rather than papering over them.

```bash
cd contracts && FOUNDRY_TEST=audit/poc forge test -vv     # 43 passed
```

| PoC | file |
|---|---|
| A-01 nightly cure loop | `audit/poc/GraceLoop.t.sol` |
| A-02 dust-asset basket veto | `audit/poc/BasketVeto.t.sol` |
| A-03 corporate actions, all three branches | `audit/poc/SplitSweep.t.sol` |
| A-04/05/07 + the refuted oracle attacks | `audit/poc/OracleBounds.t.sol` |
| A-06 calendar drift | `audit/poc/CalendarDrift.t.sol` |
| A-17 permanent stale windows | `audit/poc/StaleWindows.t.sol` |
| A-12/13/14/15 accounting | `audit/poc/Accounting.t.sol` |

---

## 11. Morpho Blue integration

Market id `0xfef5641f70e19a87e369304daa9ba823754f3db1e6481d757fcae0442cffe479`:

```bash
cast call 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
  "idToMarketParams(bytes32)(address,address,address,address,uint256)" \
  0xfef5641f70e19a87e369304daa9ba823754f3db1e6481d757fcae0442cffe479 --rpc-url $RPC
# 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913   loan  = USDC
# 0xb20000000000000000000078ee7ce2fE4908108C   coll  = NVDAc
# 0x1E2b20B4703F97710c2600eA73179c6CD1E00b02   oracle = ours
# 0x46415998764C29aB2a25CbeA6254146D50D22687   irm    = AdaptiveCurveIRM
# 770000000000000000                           lltv   = 77%
```

The market is **funded, and Morpho's own health check has authorised a borrow against our oracle.**
Four direct calls to Morpho Blue (`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`) on 2026-09-07, all from
the deployer, none through `AftermarketCredit` — this exercises the raw `IOracle` integration on its
own, independent of the app:

| step | action | block | transaction |
|---|---|---|---|
| 1 | `supply` 0.500000 USDC | 50,998,739 | [`0xba462df4…2c3553`](https://base.blockscout.com/tx/0xba462df444de272a76396dbba4db1fcec0f275a70ec4574a1ba1af3f972c3553) |
| 2 | `supplyCollateral` 0.00172031 NVDAc | 50,998,741 | [`0x9b39dbe2…eb78c6`](https://base.blockscout.com/tx/0x9b39dbe2bdd98bf69230cc5e360bfdabc2a8efce2876cb0baad37fb8edeb78c6) |
| 3 | `borrow` 0.150000 USDC — **reverted, status 0** | 50,998,742 | [`0xe879cd3e…7a0bd2`](https://base.blockscout.com/tx/0xe879cd3ea9d7f1f557d07c54822a52b37ab7e92cbf62846fedd83bd15c7a0bd2) |
| 4 | `borrow` 0.150000 USDC — succeeded | 50,998,798 | [`0x16d8c7ef…35cabc`](https://base.blockscout.com/tx/0x16d8c7ef8b26a354debdd0391827f10723a797a0d6ef93859376a2e50635cabc) |

Step 3 is in here on purpose. It carries **byte-identical calldata** to step 4 — same `assets`, same
`onBehalf`, same `receiver` — submitted one block after the collateral deposit landed, and it burned
its entire gas limit (`gasUsed == gasLimit == 229,436`) without a revert reason surfacing: an
out-of-gas revert from a gas estimate raced against the collateral deposit, not an unhealthy position —
the collateral (`172031`) was already on chain by the block step 3 executed in. Two minutes later, the
identical call resubmitted with a larger gas limit (`250,546`, using `247,415`) succeeded. A protocol
whose whole argument is "we do not select evidence" does not get to leave the failed one out.

```bash
cast receipt 0xe879cd3ea9d7f1f557d07c54822a52b37ab7e92cbf62846fedd83bd15c7a0bd2 --rpc-url $RPC
# status 0 · gasUsed 229436 == gasLimit 229436
cast receipt 0x16d8c7ef8b26a354debdd0391827f10723a797a0d6ef93859376a2e50635cabc --rpc-url $RPC
# status 1 · gasUsed 247415 of 250546
```

Market state now:

```bash
cast call 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
  "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)" \
  0xfef5641f70e19a87e369304daa9ba823754f3db1e6481d757fcae0442cffe479 --rpc-url $RPC
# totalSupplyAssets 500000 · totalSupplyShares 500000000000
# totalBorrowAssets 150000 · totalBorrowShares 150000000000
# lastUpdate 1788786943 · fee 0

cast call 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
  "position(bytes32,address)(uint256,uint128,uint128)" \
  0xfef5641f70e19a87e369304daa9ba823754f3db1e6481d757fcae0442cffe479 \
  0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f --rpc-url $RPC
# supplyShares 500000000000 · borrowShares 150000000000 · collateral 172031
```

The successful `borrow` in step 4 could not have gone through without Morpho Blue's own `_isHealthy`
calling `IOracle.price()` on our oracle first — that call site is `Morpho.sol:258`, in the table below,
and it is Morpho's audited code, not ours, that decided the position was solvent. This is the strongest
form of the composability claim in this repository: not "our oracle implements the interface", but "a
protocol we do not control called our `price()` and used the answer to authorise real debt."

The market is small — half a dollar of supply, fifteen cents of debt — and we are not claiming
otherwise. It is no longer empty, and the borrow that funded it is not the only attempt on record.

The same `price()` call site that just authorised a borrow is also, elsewhere, the one that refuses
one — that is the mechanism this whole repository is built around, and it is load-bearing precisely
because it is Morpho's own audited source calling it, not ours:

| function | reads `price()` | `lib/morpho-blue/src/Morpho.sol` |
|---|---|---|
| `borrow` | yes | `:258` → `_isHealthy` → `:518` |
| `withdrawCollateral` | yes | `:337` → `_isHealthy` → `:518` |
| `liquidate` | yes | `:361` |
| `supply` / `withdraw` / `repay` / `supplyCollateral` | **no** | — |

```bash
grep -n "price()" contracts/lib/morpho-blue/src/Morpho.sol
```

---

## What we could not prove

Listed here rather than left for you to notice.

- **No Basescan verification.** No API key was available. The sources are verified key-lessly on
  Sourcify (all 17, exact match) and on Blockscout (the top-level contracts). Basescan pages for these
  addresses will show unverified bytecode.
- **The seven oracles are not verified on Blockscout, and could not be.** Blockscout indexed no
  creation transaction for a `CREATE2` deploy made from inside the factory, and its verifier needs
  creation bytecode. Three routes tried, all accepted and none landing. They are verified exact-match
  on Sourcify, which matches runtime bytecode. `scripts/verify-sources.sh status` reports the true
  state at the moment you run it; we do not claim a checkmark we did not see.
- **Hosted at <https://aftermarket-fawn.vercel.app>, source at <https://github.com/RaYYeR220/aftermarket>.**
  The web app also runs from source (`cd web && pnpm dev`), and every claim on this page is checkable
  from a terminal without either.
- **The Morpho market is small.** Half a dollar of supply, fifteen cents of debt — see §11. It is
  funded and has taken a real borrow, but it is not liquidity in any volume sense.
- **No third-party audit.** See §10 for exactly what our own audit is and is not.
