# Aftermarket fork tests

Two suites, both run against live Base mainnet state:

| file | what it proves |
|---|---|
| `LiveB20.t.sol` | the whole protocol working against the real B20 tokens, the real Chainlink feeds and the real Aerodrome pools, at the chain head |
| `WeekendReplay.t.sol` | the closed-market mechanism, replayed at real historical Base blocks across the 2026 Labor Day weekend |
| `ForkBase.sol` | the shared fixture: mainnet addresses, one deployment routine, and the collateral-acquisition helpers |

---

## These tests need `base-forge`, not `forge`

Coinbase's tokenized stocks on Base are **B20 tokens, and a B20 token is not an EVM contract**. It is a
Rust precompile hosted inside Base's execution client. `eth_getCode` on one returns a single byte:

```
$ cast code 0xb20000000000000000000078ee7ce2fE4908108C --rpc-url https://mainnet.base.org
0xef
```

`0xef` marks the account as having code, but it is not executable EVM bytecode. Stock `forge` and
stock `anvil` know nothing about Base's precompile set, so the interpreter tries to execute `0xef`
and halts. Running this suite under stock `forge` fails in `setUp`, on the very first token read:

```
$ forge test --match-path 'test/fork/LiveB20.t.sol' -vvvv
    │   ├─ [0] 0xb20000000000000000000078ee7ce2fE4908108C::decimals() [staticcall]
    │   │   └─ ← [OpcodeNotFound] EvmError: OpcodeNotFound
[FAIL: EvmError: Revert] setUp()
```

Base ships a fork of the toolchain — `base-forge`, `base-cast`, `base-anvil`, `base-chisel` — that
installs those precompiles into the EVM. `base-forge` hosts them in forge's own EVM, in process, with
no node to run. Install it alongside stock Foundry (it never touches your existing `forge`):

```bash
curl -L https://raw.githubusercontent.com/base/base-anvil/HEAD/foundryup/install | bash
base-foundryup
```

Upstream's own write-up of the mechanism is at `lib/base-std/LIVE_PRECOMPILE_TESTING.md`.

---

## Commands

Everything needs a Base mainnet **archive** RPC in `BASE_RPC_URL`. `WeekendReplay` pins blocks about
100,000 deep, so a pruned node will not serve it.

```bash
export BASE_RPC_URL=https://mainnet.base.org      # or your own archive endpoint

# both fork suites
base-forge test --match-path 'test/fork/*' -vv

# the live protocol only
base-forge test --match-path 'test/fork/LiveB20.t.sol' -vv

# the historical replay only, with its printed timeline
base-forge test --match-path 'test/fork/WeekendReplay.t.sol' -vv

# the single most important test in the repository
base-forge test --match-path 'test/fork/LiveB20.t.sol' \
  --match-test test_amznDivergenceFreezesRiskAndSeizureButNotTheCure -vv
```

Through the Makefile in the project root:

```bash
make test        # unit suite, stock forge, no network
make test-fork   # this directory, base-forge; skips with a message if BASE_RPC_URL is unset
make test-all    # both
```

The unit suite still runs under stock `forge` and touches no precompile:

```bash
forge test --no-match-path 'test/fork/*'
```

---

## `LiveB20.t.sol` — the whole protocol against real assets

Forks Base at the current head and deploys the entire stack — `TradingCalendar`, `AttesterRegistry`,
`RegSGate`, `SessionRateModel`, `AerodromeSwapAdapter`, one `AftermarketOracle` per equity,
`AftermarketCredit`, `AftermarketVault` — wired to the real B20 tokens, the real Chainlink
aggregators and the real Slipstream pools discovered from the factory at run time.

One exception: `test_amznDivergenceFreezesRiskAndSeizureButNotTheCure` re-forks at block
**50,997,343**. Its subject is a live market state rather than a property of the code — AMZNc's pool
disagreeing with its frozen anchor by more than the session band — and that state comes and goes. It
held all through the 2026-09-05 close and by Monday evening had closed to 145 bps, inside the 300
bps band, at which point the oracle correctly went back to marking AMZNc and an unpinned assertion
would have failed. A test that only passes while a market is dislocated will eventually report a
fault that is not there, so this one is pinned. Every other test in the file runs at head.

| test | what it proves |
|---|---|
| `test_lenderSuppliesRealUsdcAndReceivesShares` | a lender deposits real USDC into the ERC-4626 vault and is credited shares at a 1:1 price on an empty market |
| `test_borrowerDrawsAgainstRealNvdaCollateralAtTheLiveMark` | NVDAc bought through the live pool is posted, and the USDC drawn is exactly `collateral x markBorrow / 1e36 x advanceRate / 1e4` against the live oracle mark — one unit more is refused |
| `test_amznDivergenceFreezesRiskAndSeizureButNotTheCure` | **the headline.** See below. |
| `test_borrowerRepaysAndWithdrawsEndingWhole` | draw, repay, withdraw: the borrower gets every raw unit of NVDAc back, the lender redeems at least what they supplied, and a withdrawal that would leave the line undercollateralised is refused |
| `test_peekIsCoherentForEveryConfiguredAsset` | `peek()` answers for all six markets and never reverts, including for the one whose `price()` is refusing to quote |
| `test_sweepYield_simulatedMultiplierIncrease` | self-repaying collateral: the sold slice, the oracle-derived slippage floor, the real swap and the debt burn. **Contains the one simulated input in the file** — see the disclosure below. |

### The AMZNc case

At block 50,997,343, straight off mainnet with no construction whatsoever (the figures below were
taken during the weekend before, at a comparable point in the same close):

```
AMZNc verdict          UNTRUSTED_DIVERGENT
AMZNc session          CLOSED_WEEKEND
AMZN feed age (s)      196202          (54h 30m, frozen at Friday's close)
AMZN staleness budget  273600          (76h - staleness is not what condemns it)
AMZN anchor            257.69 USD      (Chainlink)
AMZNc pool TWAP        281.13 USD      (Aerodrome Slipstream, 30 minutes)
divergence             909 bps
divergence band        250 bps
pool USDC depth        57,395 USD      (deep enough to corroborate, so not "thin" either)
```

The two sources disagree by 909 basis points against a 250 basis point weekend band. The oracle
declines to pick a winner and refuses to quote. The test then asserts each consequence individually:

- `price()`, `markBorrow()` and `markLiquidate()` all revert `SourcesDiverged`
- AMZNc adds **zero** borrowing power — thousands of dollars of it are posted and the line's
  drawable headroom does not move by one unit, because collateral the protocol cannot price is
  credited with nothing
- `quoteSeizure` on AMZNc reverts — the unpriceable asset itself can never be taken, by anybody, at
  any price
- `flag` refuses **on the merits**: the NVDAc leg the protocol *can* price still covers the debt, so
  the line is healthy. It is not refusing because one dark leg vetoed the question
- `liquidate` is unreachable — it demands a flag the priceable basket does not justify
- `depositCollateral` succeeds, twice — collateral only ever reduces risk
- `repay` succeeds, partially and then in full — a borrower must always be able to cure
- `withdrawCollateral` then returns the unpriceable AMZNc in full, because a debt-free borrower is
  never trapped

The zero-credit rule is what makes the seizure engine's availability independent of the worst oracle
in the basket. The asymmetry is what keeps it safe: the dark leg is worth nothing to the borrower
**and** cannot be seized by anybody, so the exposure is bounded to losing priceable collateral at a
defensible price, behind the full flag-and-grace notice period.

This test reads the chain head, so it asserts a live market condition: it holds while the US market
is shut and the AMZNc pool is off its frozen anchor, and it will stop holding once the aggregator
prints again at the next opening bell. The same divergence is pinned permanently at fixed historical
blocks in `WeekendReplay.t.sol`, which asserts AMZNc inside the band on the Saturday (67 bps) and
outside it on the Sunday (960 bps) at blocks 50,910,127 and 50,953,327.

---

## `WeekendReplay.t.sol` — the mechanism over real time

The replayed window is the 2026 Labor Day weekend: the US market closed on **Friday 2026-09-04 at
16:00 ET** and does not reopen until **Tuesday 2026-09-08 at 09:30 ET**, because Monday 2026-09-07 is
an exchange holiday. That is an 89.5-hour gap between two real prints.

### Pinned blocks

Base produces a block every two seconds with no gaps, so a height and a timestamp are
interchangeable. These were located by binary-searching `block.timestamp` from the chain head, and
every one is re-asserted at run time — a wrong pin fails the test rather than replaying the wrong
weekend.

| block | unix | UTC | ET | session |
|---|---|---|---|---|
| 50,875,927 | 1788541201 | 2026-09-04 17:00:01 | Fri 13:00:01 | `REGULAR` |
| 50,881,477 | 1788552301 | 2026-09-04 20:05:01 | Fri 16:05:01 | `POST` |
| 50,888,677 | 1788566701 | 2026-09-05 00:05:01 | Fri 20:05:01 | `CLOSED_OVERNIGHT` |
| 50,910,127 | 1788609601 | 2026-09-05 12:00:01 | Sat 08:00:01 | `CLOSED_WEEKEND` |
| 50,953,327 | 1788696001 | 2026-09-06 12:00:01 | Sun 08:00:01 | `CLOSED_WEEKEND` |
| 50,974,927 | 1788739201 | 2026-09-07 00:00:01 | Sun 20:00:01 | `CLOSED_WEEKEND` |

Two further rows are produced by `vm.warp` on top of block 50,974,927, because the chain has not got
there yet: Monday 2026-09-07 12:00 ET (Labor Day) and Tuesday 2026-09-08 09:30 ET (the next bell).
Warping advances `block.timestamp` and nothing else — the feed's `updatedAt`, the pool's
observations and the pool's depth stay exactly as they stood at that block. Rows are labelled
`pin <n>` or `warp` in the printed table so the two can never be confused.

### The timeline

Printed to the console and written to `deployments/weekend-timeline.txt`, then copied here as
`weekend-timeline.txt` by `make test-fork`. It shows borrowing power against an unchanged basket of
100 NVDAc contracting at every step and the gap haircut saturating at its 1500 bps ceiling on the
Labor Day Monday. The test asserts the monotonicity rather than merely printing it.

> **Why `deployments/` and not this directory.** `foundry.toml` grants tests write access to
> `./deployments` and nothing else, `fs_permissions` is not overridable by an environment variable or
> a CLI flag, and that config file is not this harness's to edit. Point
> `WEEKEND_TIMELINE_OUT=test/fork/weekend-timeline.txt` at this directory once a wider permission
> exists.

### `test_weekendMechanismFlagGraceAndSeizure`

Pinned once at Friday mid-session and then moved through time with `vm.warp`. Carrying a live
position across separate pinned forks is impossible — a fresh fork has mainnet's token balances, not
the ones the test created — so every instant after the first is warped, and the oracle keeps reading
the Friday block's feed and pool state. That is the conservative direction: the anchor genuinely
would not have moved.

The first half is entirely real data and makes the protocol's central claim:

```
debt drawn on Friday          29,899.83 USDC
seizure threshold Friday      41,935.05 USDC
seizure threshold Saturday    50,458.10 USDC
seizure threshold Labor Day   55,263.64 USDC
```

**A weekend cannot make you liquidatable.** The optimistic mark carries the gap haircut *upwards* and
the closed-market liquidation threshold is more forgiving than the open one, so a line that was
healthy at Friday's close is strictly healthier on Saturday, on Sunday and on the holiday Monday.
`flag` reverts `LineHealthy` at every one of those instants.

That is also why the second half needs a shock: there is no honest way to get an underwater line out
of this weekend's real data. With both price sources marked down 50% (see the disclosure below), the
test then drives the full mechanism:

- `flag` succeeds on Saturday, and `graceUntil` lands at **Tuesday 10:00 ET** — the next real opening
  bell plus the 30-minute cure window, skipping the Labor Day Monday entirely
- `liquidate` is refused on Saturday, on Sunday, on the holiday Monday and at Tuesday 09:35 ET, all
  with `GraceNotExpired`
- `repay` succeeds on the Sunday while the line is flagged and no one can seize it
- once grace has expired, `liquidate` at Tuesday 20:30 ET is refused with `MarketClosed` — the
  calendar guard, not the clock
- at Wednesday 10:00 ET, in a genuinely open market, the liquidation executes and real NVDAc moves to
  the liquidator, priced exactly as `quoteSeizure` said it would be

---

## Everything that is simulated

Nothing else in these two files is mocked, stubbed or replaced.

1. **Starting USDC balances.** `deal(USDC, ...)` writes a balance into the real USDC contract's
   storage rather than bridging tokens in. The token contract, its proxy, its transfer logic and every
   allowance check are the live Base deployment. Used in `ForkBase._seedUsdc`.

2. **A raised B20 `multiplier()`**, in `test_sweepYield_simulatedMultiplierIncrease` only. Every live
   B20 equity still reports `multiplier() == 1e18` — the test asserts that against mainnet before
   touching anything — because no dividend or split has been distributed since the 2026-08-24 launch.
   The distribution is therefore mocked by intercepting `multiplier()` on the NVDAc precompile and
   returning `1.05e18`. Everything downstream is real: the collateral is NVDAc bought through the live
   pool, the slice is computed by the production contract, the sale is a real swap through the real
   Slipstream router against the real pool, and the proceeds really do burn debt shares.

3. **A 50% adverse price move**, in `test_weekendMechanismFlagGraceAndSeizure` only. Applied to both
   the Chainlink answer and the pool TWAP together, which is how a real gap behaves — the pool tracks
   the underlying, so the two stay in agreement while both fall. The feed's `updatedAt` is left
   untouched, so the staleness half of the oracle keeps running on real data.

4. **One reopening print**, in the same test. At a fork pinned to Friday there is no Wednesday round
   to read, so the shocked answer is re-issued once with a fresh `updatedAt` to stand in for the
   aggregator's print at the bell.

5. **One opening bell**, in `test_sweepYield_simulatedMultiplierIncrease` only. `sweepYield` sends a
   market order and therefore runs only while the US market is open, where the gap haircut folded
   into its slippage floor is zero by construction and the pool is deepest. A fork pinned outside
   those hours has no in-session round to read, so the test warps to the next real opening bell and
   re-issues the *live* Chainlink answer with a fresh `updatedAt`: the timing of the print is
   simulated, its value is not.

The 50% shock in point 3 replaces only the pool's tick cumulatives. The pool's real
`secondsPerLiquidityCumulativeX128` pair is read first and handed straight back, because the oracle
inverts that pair to measure the in-range depth backing the window - substituting zeros there would
simulate a pool with no liquidity at all rather than a pool at a different price.

Collateral is *not* simulated. It is bought with real USDC through the real Slipstream router against
the real pool, which is preferred over impersonating a holder found from `Transfer` logs: there is no
address that can go stale, it proves the pool is genuinely tradable at the sizes used, and it
exercises a real B20 precompile transfer in both directions.
