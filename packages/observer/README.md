# @aftermarket/observer

A judge-runnable evidence tool. It reads live Base mainnet state for every
Coinbase tokenized stock (B20) it can find and prints, side by side, what a
Chainlink-only price reader would see versus what the token's own Aerodrome
Slipstream pool is actually trading at. It never fabricates a number: if a
call fails or a pool doesn't exist, the field reads `unavailable`.

This is the mechanism Aftermarket is built around — Chainlink's total-return
feeds for these assets pause outside US market hours, but the Slipstream
pools trade around the clock. A protocol that only reads the feed can end up
marking collateral against a price that is many hours stale.

## Run it

From the repository root, after `pnpm install`:

```
pnpm verify:onchain
```

or directly:

```
node scripts/verify-onchain.mjs
```

Both build the package on first run and then execute the CLI against
`https://mainnet.base.org`. Override the endpoint with `BASE_RPC_URL`.

### Flags

| Flag | Effect |
|---|---|
| `--asset <TICKER>` | Report on a single asset, e.g. `--asset NVDAc`. Repeatable. |
| `--json` | Print the full machine-readable report instead of the table. |
| `--snapshot <path>` | Also write a timestamped JSON evidence file, so a claim in the docs can cite an exact block. `<path>` may be a directory (a filename is generated) or an exact `.json` file. |
| `-h`, `--help` | Usage text. |

The process exits `0` in every case except when the RPC itself cannot be
reached at all — an individual asset failing to read (a dead feed, a missing
pool) is reported as `unavailable`, not a fatal error.

## What each column means

**Supply / Mult.** — the B20 token's `totalSupply()` and `multiplier()`. B20
tokens don't move balances for stock splits or dividends; instead the
multiplier scales the redemption ratio between one token and one real share.
It launches at `1.000000` and rises as corporate actions land. These
contracts run as Base precompiles — `eth_getCode` returns `0xef` for all of
them, and there is no Solidity source to verify, because every integrator
shares one audited implementation rather than a separately deployed contract
per asset.

**Feed $ / Feed Age** — the Chainlink total-return feed's `latestRoundData()`
price and how long ago `updatedAt` was, measured against the block timestamp
this report was built from (not wall-clock time). Staleness matters because
these feeds report a *total return value* combining the underlying equity's
market price with the B20 multiplier, and — like the equities they track —
they are not obligated to update outside market hours. A protocol that reads
only this number has no way to tell "quiet market" apart from "broken feed."

**TWAP $ / Spot $** — the Aerodrome Slipstream pool's 30-minute
time-weighted average price, from `observe([1800, 0])`, and the pool's
instantaneous price from `slot0()`. Both are converted from the pool's raw
tick into a USDC price with the token0/token1 ordering and the 6-vs-8 decimal
gap between USDC and a B20 token accounted for explicitly — never assumed.
Slipstream pools trade whenever anyone wants to trade them, including
weekends and outside the 09:30–16:00 ET session, so this is the one price in
the table that cannot go stale for lack of market hours.

**Depth (USDC)** — the pool's USDC-side balance, a rough proxy for how much
size the TWAP can be trusted for. A price with $60k of depth behind it moves
much more on a single trade than one with $1.8M behind it.

**Div (bps)** — `|feed − TWAP| / feed`, in basis points. This is the number a
naive Chainlink-only integration is silently exposed to.

**Flag / Verdict** — `OK` (< 25 bps), `WATCH` (25–100 bps), `STALE` (≥ 100
bps), or `NO-POOL` when no Slipstream pool could be found for the asset. The
verdict line spells out the same judgment in one sentence per asset,
including the feed's age, so the table and the prose always agree.

The header also reports the block this report was built from, the block's
own timestamp, and whether the US equity market is open right now — computed
from that same chain timestamp, in US Eastern time with real DST rules (the
2nd Sunday of March through the 1st Sunday of November) and a hardcoded
2026/2027 NYSE holiday list, not from the machine's local clock.

## Asset coverage

Tracks NVDAc, AAPLc, METAc, GOOGLc, TSLAc, AMZNc, MSFTc, MSTRc, SNDKc, SPCXc,
COINc, CRCLc and INTCc. `COINc`, `CRCLc` and `INTCc` currently respond to
`symbol()`/`decimals()`/`multiplier()` but have zero `totalSupply()` and no
Slipstream pool at any tick spacing the CL factory has enabled — they show up
in the table with `unavailable` pool data rather than being silently dropped,
because that absence is itself evidence of how new some of this
infrastructure is. Addresses and discovered pools live in `src/assets.ts`,
each with a comment on how it was found.

## Architecture

- `src/chain.ts` — the viem client (multicall aggregation on, transport-level
  JSON-RPC batching off — see the comment there for why), retry helper, and
  the ABI fragments this tool reads.
- `src/assets.ts` — the asset list: B20 token address, Chainlink feed
  address, and Slipstream pool (or `null`) per ticker.
- `src/report.ts` — turns one multicall's worth of raw reads into a typed
  `ObserverReport`, including the TWAP/spot price math and the US
  market-hours calculation.
- `src/cli.ts` — argument parsing, table rendering, JSON output, and snapshot
  writing.
- `src/index.ts` — the same functionality as a library, for embedding this
  report in something else.

Every value that can fail to read is a `Fallible<T>` — `{ ok: true, value }`
or `{ ok: false, error }` — so a partial read never gets silently coerced
into a zero or an empty string.
