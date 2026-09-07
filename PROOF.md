# PROOF

Every claim Aftermarket makes, as a link you can click or a command you can paste. Nothing here needs
a wallet, a key or a deploy.

**Network:** Base mainnet, chainId 8453 · **Deployer/owner:** [`0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f`](https://base.blockscout.com/address/0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f)
· **Deploy block:** 50,987,282 (2026-09-07 06:51:51 UTC)

All live reads below are pinned to **block 50,997,343** (2026-09-07 12:27:13 UTC = 08:27 ET, Labor
Day) so you get exactly the bytes we got. Drop `--block` to read the head; two of the numbers move,
and we say which.

```bash
export RPC=https://mainnet.base.org      # any Base RPC; an archive node for the --block reads
export BLOCK=50997343
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
| `AerodromeSwapAdapter` | `0xfF81282c6353dC3fB0Ca890Da3cdde9BAFcd68fF` | [exact match](https://repo.sourcify.dev/8453/0xfF81282c6353dC3fB0Ca890Da3cdde9BAFcd68fF) | [source](https://base.blockscout.com/address/0xfF81282c6353dC3fB0Ca890Da3cdde9BAFcd68fF?tab=contract) |
| `AftermarketCredit` | `0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3` | [exact match](https://repo.sourcify.dev/8453/0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3) | [source](https://base.blockscout.com/address/0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3?tab=contract) |
| `AftermarketVault` | `0x00751166Ce3fa20a4143a1F0D848978Db73bd53f` | [exact match](https://repo.sourcify.dev/8453/0x00751166Ce3fa20a4143a1F0D848978Db73bd53f) | [source](https://base.blockscout.com/address/0x00751166Ce3fa20a4143a1F0D848978Db73bd53f?tab=contract) |
| `AutoRepayer` | `0xEFC7ce780F5030489a027cebde8BeFb7e7ee681A` | [exact match](https://repo.sourcify.dev/8453/0xEFC7ce780F5030489a027cebde8BeFb7e7ee681A) | [source](https://base.blockscout.com/address/0xEFC7ce780F5030489a027cebde8BeFb7e7ee681A?tab=contract) |
| `AftermarketLens` | `0x5A18BdEB02B30b737a2464E02A2a669BF52bC049` | [exact match](https://repo.sourcify.dev/8453/0x5A18BdEB02B30b737a2464E02A2a669BF52bC049) | [source](https://base.blockscout.com/address/0x5A18BdEB02B30b737a2464E02A2a669BF52bC049?tab=contract) |
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
6, NVDAc 8), so that is **$218.459435** per NVDAc. The full state behind it, read at the head a few
minutes later (`feedAge` and `divergenceBps` advance every block; everything else is stable):

```bash
cast call 0x1E2b20B4703F97710c2600eA73179c6CD1E00b02 \
  "peek()((uint8,uint8,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint64))" \
  --rpc-url $RPC
```

| field | value | meaning |
|---|---|---|
| `verdict` | `1` | `TRUSTED_CLOSED` |
| `session` | `5` | `CLOSED_HOLIDAY` |
| `anchorPrice` | `229.9573e18` | Chainlink Coinbase NVDA, frozen at Friday's close |
| `poolPrice` | `232.392563e18` | Aerodrome Slipstream 30-min TWAP, still moving |
| `markBorrow` | `2.18459435e36` | `min(anchor, pool) × (1 − 500 bps)` = `229.9573 × 0.95` |
| `markLiquidate` | `2.4401219115e36` | `max(anchor, pool) × (1 + 500 bps)` = `232.392563 × 1.05` |
| `feedAge` | `238182` s (66.2 h) | |
| `stalenessBudget` | `360000` s (100 h) | staleness is *not* what is being tested here |
| `divergenceBps` | `105` | |
| `divergenceBand` | `300` | 105 < 300, so the sources agree |
| `haircutBps` | `500` | at the cap: 25 bps base + 15 bps/h × 66 h |
| `multiplier` | `1e18` | no corporate action in flight |
| `poolLiquidityUsd` | `1,616,884e18` | well above the $25,000 floor |
| `nextOpen` / `lastClose` | `1788874200` / `1788552000` | Tue 09:30 ET / Fri 16:00 ET — **89 h 30 m apart** |

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
**0.00356308 AMZNc** against **0.500011 USDC** of debt.

### 3a. It refuses to lend more than the markable collateral supports

```bash
cast call 0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3 "draw(uint256,address)" \
  900000 0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f \
  --from 0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f --rpc-url $RPC --block $BLOCK
```

```
execution reverted, data: 0x5033ec12
  ...155ccb   debtAfter   = 1400011   ($1.400011)
  ...0896e4   borrowPower =  562916   ($0.562916)
```

`0x5033ec12` = `cast sig "Undercollateralized(uint256,uint256)"`.

### 3b. It refuses to seize while the market is shut

```bash
cast call 0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3 "flag(address)" \
  0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f \
  --from 0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f --rpc-url $RPC --block $BLOCK
```

```
execution reverted, data: 0x0d007982
  ...07a12b   debt             =  500011   ($0.500011)
  ...104f5b   seizureThreshold = 1069403   ($1.069403)
```

`0x0d007982` = `cast sig "LineHealthy(uint256,uint256)"`. The seizure threshold is **2.14× the debt**,
because `markLiquidate` is the optimistic mark (`max(anchor, pool) × 1.05`) and the closed-session
liquidation threshold is 8500 bps against 8000 bps when the market is open. Closing the market makes
the line *harder* to take, not easier.

> `debt` accrues every second, so the first number rises between blocks. The threshold moves with the
> pool TWAP. Both are pinned by `--block`.

### 3c. The headline: an unmarkable asset contributes exactly zero borrowing power

Two archive calls at adjacent blocks, straddling the transaction that deposited **$1.00 of AMZNc** as
collateral (tx [`0x9b6049f1…37cc76`](https://base.blockscout.com/tx/0x9b6049f1090c30fe665269dc9ea0c7645130d94cb80315b002210766d437cc76), block 50,991,632):

```bash
U=0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f
for B in 50991631 50991632; do
  cast call 0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3 "draw(uint256,address)" 900000 $U \
    --from $U --rpc-url $RPC --block $B
done
```

```
block 50991631  (before)  ->  Undercollateralized(900000, 562916)
block 50991632  (after)   ->  Undercollateralized(900000, 562916)
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
cast call 0x5A18BdEB02B30b737a2464E02A2a669BF52bC049 \
  "previewDraw(address,uint256)((bool,uint8,uint256,uint256,uint256))" \
  0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f 900000 --rpc-url $RPC
# (false, 5, 1400011, 0, 0)      reason 5 = UNPRICED
```

The lens is deliberately stricter than the engine: it reports `priced = false` and zeroes the numbers
whenever **any** asset in the basket is unmarkable, so a front end can never quietly render a partial
basket as a whole one. The engine is the one that does the per-asset arithmetic.

---

## 4. Live demo transactions

All Base mainnet, all successful (`status = 1`), all from the deployer, all inside the contest window
on 2026-09-07.

| # | step | block | transaction |
|---|---|---|---|
| 1 | eligibility attestation (`AttesterRegistry`) | 50,991,370 | [`0x35191d73…27422d`](https://base.blockscout.com/tx/0x35191d733f636ece63002a9f7ca086c9beedeef533afc976f33a88edae27422d) |
| 2 | supply 2.000000 USDC to `AftermarketVault` | 50,991,441 | [`0x29b54e7c…db7c95e`](https://base.blockscout.com/tx/0x29b54e7c8dbcdd04489acf20eee01ee0ba67a65a9259da3b253e9a680db7c95e) |
| 3 | swap 1.000000 USDC → 0.00356308 AMZNc on Aerodrome | 50,991,489 | [`0xcbe1f83c…113c77`](https://base.blockscout.com/tx/0xcbe1f83c51be52f6308c545bb7016d57b0b97f06bf605c9a9fbebbbed9113c77) |
| 4 | swap 1.200000 USDC → 0.00515351 NVDAc on Aerodrome | 50,991,539 | [`0x608c9266…1415160`](https://base.blockscout.com/tx/0x608c92665620e33b184368ac393555096ccfea5da6246a5610729d54d1415160) |
| 5 | deposit NVDAc collateral | 50,991,583 | [`0xb6c040b4…bdfd032`](https://base.blockscout.com/tx/0xb6c040b4dd840bcbd3b12591fc69b778d8c87fe75846520f76fa38608bdfd032) |
| 6 | deposit AMZNc collateral | 50,991,632 | [`0x9b6049f1…37cc76`](https://base.blockscout.com/tx/0x9b6049f1090c30fe665269dc9ea0c7645130d94cb80315b002210766d437cc76) |
| 7 | draw 0.500000 USDC | 50,991,648 | [`0x6081374c…6727b3`](https://base.blockscout.com/tx/0x6081374c8cc00c0053b0d7ee01e10a08a70bc138a99bb4247b330dc2056727b3) |

Check any of them:

```bash
cast receipt 0x6081374c8cc00c0053b0d7ee01e10a08a70bc138a99bb4247b330dc2056727b3 --rpc-url $RPC
```

Steps 3 and 4 call the Aerodrome `SwapRouter` (`0x698cb2b6…3a92f`) directly from the wallet — they are
how the demo account acquired collateral, not a protocol code path.
`AerodromeSwapAdapter` is the protocol's own venue and is exercised by `sweepYield` (see
[MOCKS.md](MOCKS.md)).

Protocol state right now, one call:

```bash
cast call 0x5A18BdEB02B30b737a2464E02A2a669BF52bC049 \
  "protocolView()((uint8,uint64,uint64,uint256,uint256,uint256,uint256,address[]))" --rpc-url $RPC
# (5, 1788874200, 1788552000, 500011, 2000011, 250002…, 1000003, [6 assets])
#  ^session CLOSED_HOLIDAY   ^nextOpen  ^lastClose  ^debt   ^supplied  ^utilisation  ^share price
```

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
# Ran 8 test suites: 255 tests passed, 0 failed, 1 skipped (256 total tests)
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

The market is **created and empty** — `market(id)` returns zero supply and zero borrow. It proves the
`IOracle` integration; it is not a funded market and we do not claim it is one.

Why the refusal is load-bearing there, from Morpho's own audited source:

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
- **Hosted at <https://aftermarket-fawn.vercel.app>.** The web app also runs from source
  (`cd web && pnpm dev`), and every claim on this page is checkable from a terminal without either.
- **The Morpho market has no liquidity.** See §11.
- **No third-party audit.** See §10 for exactly what our own audit is and is not.
