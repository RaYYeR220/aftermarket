# Contract source verification

Every Aftermarket contract deployed to Base mainnet, and exactly which verifier holds its source.

No Etherscan/Basescan API key was available for this project, so verification was done with the two
key-less verifiers Foundry supports: **Sourcify** and **Blockscout**. Basescan pages for these
addresses will therefore show unverified bytecode. That is a missing key, not a missing source — the
same sources are published and byte-matched elsewhere, and the reproduction commands are below.

Re-check the live state at any time:

```bash
scripts/verify-sources.sh status
```

---

## Result

**All 17 contracts: Sourcify `exact_match`.** Verified 2026-09-07, 11:10–11:17 UTC.

| # | Contract | Address | Sourcify | Blockscout |
|---|---|---|---|---|
| 1 | `TradingCalendar` | [`0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9`](https://repo.sourcify.dev/8453/0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9) | exact — creation + runtime | verified |
| 2 | `AttesterRegistry` | [`0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E`](https://repo.sourcify.dev/8453/0x53a64E3AF9B89386915E66cE810a1d9DDc7D361E) | exact — creation + runtime | verified |
| 3 | `RegSGate` | [`0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C`](https://repo.sourcify.dev/8453/0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C) | exact — creation + runtime | verified |
| 4 | `SessionRateModel` | [`0x6d5152d81982DEb660736fC514761E18533a2343`](https://repo.sourcify.dev/8453/0x6d5152d81982DEb660736fC514761E18533a2343) | exact — creation + runtime | verified |
| 5 | `AftermarketOracleFactory` | [`0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A`](https://repo.sourcify.dev/8453/0xD10f2f4a4e9052fD3fa87aAFC529983EdB1c1f8A) | exact — creation + runtime | verified |
| 6 | `AerodromeSwapAdapter` | [`0xfF81282c6353dC3fB0Ca890Da3cdde9BAFcd68fF`](https://repo.sourcify.dev/8453/0xfF81282c6353dC3fB0Ca890Da3cdde9BAFcd68fF) | exact — creation + runtime | verified |
| 7 | `AftermarketCredit` | [`0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3`](https://repo.sourcify.dev/8453/0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3) | exact — creation + runtime | verified |
| 8 | `AftermarketVault` | [`0x00751166Ce3fa20a4143a1F0D848978Db73bd53f`](https://repo.sourcify.dev/8453/0x00751166Ce3fa20a4143a1F0D848978Db73bd53f) | exact — creation + runtime | verified |
| 9 | `AutoRepayer` | [`0xEFC7ce780F5030489a027cebde8BeFb7e7ee681A`](https://repo.sourcify.dev/8453/0xEFC7ce780F5030489a027cebde8BeFb7e7ee681A) | exact — creation + runtime | verified |
| 10 | `AftermarketLens` | [`0x5A18BdEB02B30b737a2464E02A2a669BF52bC049`](https://repo.sourcify.dev/8453/0x5A18BdEB02B30b737a2464E02A2a669BF52bC049) | exact — creation + runtime | verified |
| 11 | `AftermarketOracle` — NVDAc | [`0x1E2b20B4703F97710c2600eA73179c6CD1E00b02`](https://repo.sourcify.dev/8453/0x1E2b20B4703F97710c2600eA73179c6CD1E00b02) | exact — runtime | **not verified** |
| 12 | `AftermarketOracle` — AAPLc | [`0x6cE58FE71eD10b82c2C0A9a348E82D1ee6D9a8dc`](https://repo.sourcify.dev/8453/0x6cE58FE71eD10b82c2C0A9a348E82D1ee6D9a8dc) | exact — runtime | **not verified** |
| 13 | `AftermarketOracle` — METAc | [`0xf5Cc0cc94ecF4866661373f2aa066af76e08dEf2`](https://repo.sourcify.dev/8453/0xf5Cc0cc94ecF4866661373f2aa066af76e08dEf2) | exact — runtime | **not verified** |
| 14 | `AftermarketOracle` — GOOGLc | [`0x203cDf7e33eA0d652cA54f4807c9d2d1d081C9aA`](https://repo.sourcify.dev/8453/0x203cDf7e33eA0d652cA54f4807c9d2d1d081C9aA) | exact — runtime | **not verified** |
| 15 | `AftermarketOracle` — TSLAc | [`0x74058d51B3b04Ba09be2aa51ab1CE930Dd3c2C99`](https://repo.sourcify.dev/8453/0x74058d51B3b04Ba09be2aa51ab1CE930Dd3c2C99) | exact — runtime | **not verified** |
| 16 | `AftermarketOracle` — AMZNc | [`0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C`](https://repo.sourcify.dev/8453/0x6FEEF51B6352895B17AEf6a4F36F8A9b76A3bb5C) | exact — runtime | **not verified** |
| 17 | `AftermarketOracle` — negative control | [`0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58`](https://repo.sourcify.dev/8453/0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58) | exact — runtime | **not verified** |

### Reading the Sourcify column

Sourcify reports two independent matches. A **runtime** match means the deployed bytecode at that
address is byte-identical to what these sources compile to; a **creation** match additionally matches
the contract's creation transaction, which also pins the constructor arguments.

Contracts 1–10 were deployed directly by the deployer EOA and carry both. Contracts 11–17 were
deployed by `AftermarketOracleFactory` using `CREATE2`, so they have no creation transaction of their
own for Sourcify to read, and it records `creationMatch: null`. The runtime match is exact for all
seven. Their constructor arguments are published in
[`contracts/deployments/8453.json`](../contracts/deployments/8453.json) under `constructorArgs.oracles`,
and every value in them is independently readable on chain as a public immutable:

```bash
O=0x1E2b20B4703F97710c2600eA73179c6CD1E00b02
for f in collateralToken loanToken feed pool calendar; do cast call $O "$f()(address)" --rpc-url $RPC; done
for f in twapWindow baseHaircutBps haircutSlopeBpsPerHour maxHaircutBps; do cast call $O "$f()(uint32)" --rpc-url $RPC; done
cast call $O "minPoolLiquidityUsd()(uint256)" --rpc-url $RPC
cast call $O "minMultiplier()(uint256)" --rpc-url $RPC
cast call $O "maxMultiplier()(uint256)" --rpc-url $RPC
```

### Reading the Blockscout column

`verified` means we observed `is_verified: true` and `is_fully_verified: true` on
`https://base.blockscout.com/api/v2/smart-contracts/<address>` on 2026-09-07. Some of those arrived
through our direct submissions and some through Blockscout's own Verifier Alliance import from
Sourcify.

**`not verified` is a real negative, and here is why.** Blockscout has not indexed a creation
transaction for the seven factory-deployed oracles — its own API returns
`"creation_transaction_hash": null` and `"creation_bytecode": null` for each of them, because they were
created by `CREATE2` from inside `AftermarketOracleFactory` rather than by a top-level transaction, and
Blockscout does not index internal contract creations on this instance. Its verifier matches against
creation bytecode, so it has nothing to match. We tried three routes:

1. `forge verify-contract --verifier blockscout` with the recorded constructor arguments — accepted
   with `Response: OK` and a GUID, no verified contract afterwards.
2. A direct `POST .../verification/via/standard-input` with `autodetect_constructor_args=true` —
   `{"message":"Smart-contract verification started"}`, no verified contract afterwards.
3. The same with `autodetect_constructor_args=false` plus the explicit `constructor_args` and
   `contract_name` — same response, same outcome.

Blockscout's free tier also rate-limited this IP heavily throughout
(`{"message":"Too many requests. Increase limits now at https://dev.blockscout.com"}`), which is why
some attempts never reached the verifier at all.

All seven are verified `exact_match` on Sourcify, which matches **runtime** bytecode and therefore does
not need a creation transaction. `scripts/verify-sources.sh status` reports both verifiers live, so if
Blockscout's indexer catches up later you will see it there rather than having to trust this table.

---

## Compiler settings

Verification only succeeds if these match the deploy exactly. They come from
[`contracts/foundry.toml`](../contracts/foundry.toml):

| setting | value |
|---|---|
| `solc` | `0.8.28` |
| `optimizer` | `true` |
| `optimizer_runs` | `200` |
| `evm_version` | `cancun` |
| `via_ir` | `false` |

## Reproducing it

```bash
# every contract, Sourcify
scripts/verify-sources.sh sourcify

# every contract, Blockscout (paced; the free tier rate-limits hard)
scripts/verify-sources.sh blockscout

# what each verifier holds right now
scripts/verify-sources.sh status
```

Or one contract by hand, from `contracts/`:

```bash
export BASESCAN_API_KEY=          # note: EMPTY, not unset — see below

forge verify-contract 0x9a29F81D951fE40ae3C937654bB73f0493EE0Dd9 \
  src/TradingCalendar.sol:TradingCalendar \
  --chain-id 8453 \
  --verifier sourcify --verifier-url https://sourcify.dev/server

forge verify-contract 0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3 \
  src/AftermarketCredit.sol:AftermarketCredit \
  --chain-id 8453 \
  --verifier blockscout --verifier-url https://base.blockscout.com/api \
  --constructor-args $(node -e "console.log(require('./deployments/8453.json').constructorArgs.credit)")
```

### The `BASESCAN_API_KEY` trap

`foundry.toml` carries an `[etherscan]` block that interpolates `${BASESCAN_API_KEY}`. This produces
two different failures depending on how the variable is set, and neither error message points at the
cause:

```
# unset
Error: environment variable `BASESCAN_API_KEY` not found

# set to any non-empty value — forge silently prefers Etherscan over the verifier you asked for
ETHERSCAN_API_KEY is set, defaulting to Etherscan verifier.
Error: Failed to obtain contract ABI ... Invalid API Key
```

Exporting it **empty** (`export BASESCAN_API_KEY=`) is what makes the key-less path work.
`scripts/verify-sources.sh` does this for you.

## Checking a verification without Foundry

```bash
# Sourcify: match status, as JSON
curl -s https://sourcify.dev/server/v2/contract/8453/0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3

# Blockscout: name, compiler settings, verification flags
curl -s https://base.blockscout.com/api/v2/smart-contracts/0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3

# The deployed runtime bytecode, straight from the chain
cast code 0x4dEc94380D35839E137Ca74d26688b8Fdd3bF4b3 --rpc-url https://mainnet.base.org | head -c 128
```

## What is not verified, and why

| item | state | reason |
|---|---|---|
| Basescan / Etherscan pages | not verified | No API key was available to this project. |
| Blockscout, the 7 factory oracles | not verified | Blockscout indexed no creation transaction or creation bytecode for a `CREATE2` deploy made from inside the factory, and its verifier matches on creation bytecode. Three submission routes tried; see above. Verified on Sourcify. |
| Sourcify creation match, the 7 factory oracles | not available | Same root cause — no creation transaction to read. Sourcify's **runtime** match is exact for all seven, which is the one that proves the deployed bytecode is these sources. |
