# Aftermarket — adversarial self-audit

> **Summary.** Three High findings, eleven Medium, two Low, one Informational — every one reproduced
> by a passing Foundry PoC driving the real contracts at the real mainnet deploy parameters
> (`script/config/base.json`), plus fourteen attacks that were tried and failed.
>
> **The pricing is sound.** The asymmetric `min`/`max` fusion does exactly what it claims: three
> separate attempts to extract value by manipulating the shallow Aerodrome pools were refuted with
> tests, the compliance gate's "a user can always repay and exit" property holds under a total oracle
> outage, the ERC-4626 share math and the Morpho-style debt ledger are correct, and the 2026–2027
> calendar table is exactly right on a day-by-day differential over all 730 days.
>
> **The problems are in the lifecycle, and they cost lenders money.** Once a line goes bad the loss is
> never written off — an ordinary liquidation cascade strands an unseizable crumb, `_realizeBadDebt`
> becomes unreachable, and the vault keeps compounding interest on debt nobody will ever pay until the
> first LP out is paid more than they deposited out of the last one's capital (A-12). A month of
> accrued interest can be erased for the cost of one transaction, or one flash loan, because the
> borrow rate is sampled once and applied backwards (A-13). And a single raw unit of a second
> collateral asset — or an issuer pausing that asset around a routine corporate action — vetoes flag
> and liquidate for an entire basket (A-02).
>
> Below that: the liquidation engine can be kept switched off indefinitely by a borrower for a few
> cents a day (A-01), the calendar runs out at the end of 2027 and cannot be replaced (A-06), roughly
> 19% of every week has no working oracle at all by construction (A-17), and the first real B20
> corporate action will either force-unwind opted-in borrowers or brick an asset's oracle permanently,
> depending on a convention nobody has been able to observe yet (A-03).


**Scope (commit as of 2026-09-07):**
`src/TradingCalendar.sol`, `src/AftermarketOracle.sol`, `src/AftermarketOracleFactory.sol`,
`src/RegSGate.sol`, `src/AttesterRegistry.sol`, `src/AftermarketCredit.sol`,
`src/AftermarketVault.sol`, `src/SessionRateModel.sol`, `src/adapters/AerodromeSwapAdapter.sol`,
`src/libraries/*`, `src/interfaces/*`.

**Out of scope (in flight during this review):** `src/AutoRepayer.sol`, `src/AftermarketLens.sol`,
`script/*`, `test/AutoRepayer.t.sol`.

**Baseline:** `forge test` at the start of this review — 177 passing, 1 skipped (the mainnet fork
test, no RPC configured), 0 failing. At the end of it the same suite is 240 passing, 1 skipped, 0
failing; the increase is the other agent adding tests for `AutoRepayer`, `AftermarketLens` and the
fork replays, not anything this review changed. Nothing in `src/`, `test/`, `script/`, `foundry.toml`
or `remappings.txt` was touched here.

**Method:** the two reference catalogs of the `web3-audit` skill (10 exploit-chain classes,
26 session-learned patterns) run against a lending-protocol-typed sweep, then an edge-case pass, then
PoCs. Every finding rated Medium or above has a runnable Foundry PoC under `audit/poc/`. Every PoC
runs the **real** `TradingCalendar`, the **real** `AftermarketOracle`, the **real** `SessionRateModel`,
the **real** `AftermarketCredit` and the **real** `AftermarketVault`, wired to each other exactly as
they would be on Base. Only the Chainlink aggregator and the Aerodrome Slipstream pool are doubles —
they cannot be run locally. Every parameter is read off the ACTUAL mainnet deploy config, `script/config/base.json` - not the
test defaults. That means: staleness 1h / 6h / 6h / 25h / 73h / 97h, divergence bands
200 / 400 / 400 / 800 / 1200 / 1500 bps, a 100bps + 10bps/h gap haircut capped at 1000bps, a
30-minute TWAP, a $25,000 pool-depth floor, multiplier bounds `[0.5e18, 100e18]`, advance rates
6500 / 5000 open/closed, liquidation thresholds 8000 / 8500 open/closed, a 700bps liquidation bonus,
a 100bps `sweepYield` slippage budget, and the shipped rate curve (2%% base, +6%% at the 80%% kink,
+100%% at full utilisation, session premiums 1.0/1.0/1.0/1.25/1.5/1.6).

## Running the PoCs

`audit/` is not one of foundry's compile paths and `foundry.toml` was left untouched, so point the
test dir at it for the run:

```
FOUNDRY_TEST=audit/poc forge test -vv
```

(Add `--skip AftermarketLens --skip AutoRepayer` if those two in-flight files are mid-edit and do not
compile at the moment you run it.)

| PoC | File | Status |
|---|---|---|
| A-01 nightly cure loop | `audit/poc/GraceLoop.t.sol` | 4/4 pass — **reproduces** |
| A-02 dust-asset basket veto | `audit/poc/BasketVeto.t.sol` | 4/4 pass — **reproduces** |
| A-03 corporate-action handling, all three branches | `audit/poc/SplitSweep.t.sol` | 6/6 pass — **reproduces** |
| A-04/A-05/A-07 + refuted oracle attacks | `audit/poc/OracleBounds.t.sol` | 6/6 pass — **reproduces** |
| A-06 calendar drift | `audit/poc/CalendarDrift.t.sol` | 3/3 pass — **reproduces** |
| A-17 permanent stale windows | `audit/poc/StaleWindows.t.sol` | 3/3 pass — **reproduces** |
| A-12/A-13/A-14/A-15 accounting | `audit/poc/Accounting.t.sol` | 9/9 pass — **reproduces** |
| shared harness (real calendar/oracle/engine/vault) | `audit/poc/Harness.sol` | — |

Total: **35/35 PoC tests pass**, and the repo's own suite is untouched and still green.

Supporting exploratory work — the exhaustive calendar probe whose output A-06 quotes
(`audit/scratch/CalendarProbe.t.sol`, 18 assertions over 108k+ timestamps), and the independent
accounting sweep that first surfaced A-12 to A-15 — lives in `audit/scratch/` and `audit/refute/`.
Those are working notes, not the deliverable; everything they claim that is cited in this report has
been independently re-derived in `audit/poc/`. Run them with `FOUNDRY_TEST=audit/scratch` if you want
them, and note that `CalendarProbe.t.sol::test_02_RevertSweep_2026_to_2100` needs a raised gas limit.

---

# Findings

| ID | Severity | Title |
|---|---|---|
| A-12 | **High** | Bad debt is never written off, because a collateral leg always strands below the seizure floor |
| A-13 | **High** | The borrow rate is sampled once and applied backwards, and the vault does not accrue |
| A-01 | Medium | A borrower can postpone liquidation indefinitely with one `cure()` per evening |
| A-02 | **High** | One raw unit of an unpriceable asset vetoes flag and liquidate for the entire basket |
| A-03 | Medium | Nothing in the system handles a multiplier change of corporate-action magnitude |
| A-17 | Medium | The staleness budgets ignore when the feed actually stops printing, so ~19% of every week has no oracle at all |
| A-04 | Medium | Pushing the pool to just inside the divergence band raises the seizure threshold for free |
| A-05 | Medium | `sweepYield` effective slippage tolerance is up to 24×, not the configured 1% |
| A-06 | Medium | The trading calendar runs out at the end of 2027 and cannot be replaced |
| A-07 | Medium | `minPoolLiquidityUsd` measures a raw balance, not tradeable depth |
| A-08 | Medium | `setAsset` never checks that the oracle it installs prices the asset it is installed for |
| A-09 | Medium | Liquidators receive Reg-S securities with no eligibility check |
| A-14 | Medium | The multiplier checkpoint is reset *downward*, fabricating distributions that never happened |
| A-15 | Medium | `withdrawCollateral` is the one risk-increasing action not blocked while flagged |
| A-10 | Low | `setSwapAdapter` accepts the zero address |
| A-16 | Low | `SessionRateModel` puts no ceiling on its rate parameters, and an absurd one bricks `repay` |
| A-11 | Informational | Orphaned NatSpec, an inverted error name, an interface/implementation mismatch, `_mulDown` |

(The table is in severity order. The write-ups below are grouped by theme - lifecycle, then oracle,
then configuration - so the numbering is not sequential.)

A-01 and A-03 were each subjected to a dedicated independent refutation pass: a fresh agent with no
access to this reasoning, instructed to assume the finding wrong and attack it, wrote 39 of its own
tests. It could not break either mechanism, but it did break the impact narrative of both, and both
are rated Medium here as a result rather than the High they were first written up as. Its counter-
evidence is folded into the sections below and into "Attacks that did not work".

---

## A-01 — Medium — A borrower can postpone liquidation indefinitely with one `cure()` per evening

**Status: fixed.** `cure` now runs only while the US market is open and is measured at open-session parameters, so a session change is no longer a cure. `audit/poc/GraceLoop.t.sol` proves the evening cure fails and the seizure lands the next morning.

**Files:** `src/AftermarketCredit.sol:470-494` (`flag`), `:501-515` (`cure`), `:570-588`
(`_requireSeizable`), `:950-964` (`_seizureThreshold`), `:927-929` (`_isOpen`);
`src/TradingCalendar.sol:238-258` (`_scanForwardToOpen`).

**PoC:** `audit/poc/GraceLoop.t.sol` — `test_01_BorrowerPostponesLiquidationForever`,
`test_02_TheWeekendMakesItWorse`. Both pass. `test_03` is the negative control and also passes.

### Root cause

Three individually-reasonable decisions compose into a cycle the borrower always wins:

1. `flag` (`:482-485`) sets
   `graceUntil = max(now + MIN_GRACE, calendar.nextOpen(now) + CURE_WINDOW)`.
   `TradingCalendar.nextOpen` returns the first regular open **strictly after** its argument
   (`TradingCalendar.sol:154`, `:251` — `if (open > timestamp)`). So a flag raised at *any* instant
   inside a regular session lands the deadline on the **next** trading day, not today.
2. `liquidate` (`:578-579`) requires both `block.timestamp >= graceUntil` **and**
   `calendar.isOpen(block.timestamp)`.
3. `cure` (`:501`) is permissionless and re-tests health **at the current session**.
   `_seizureThreshold` (`:962`) selects `liqThresholdClosedBps` the moment the regular session ends,
   and it applies it to a `markLiquidate` that the oracle has *already marked up* by the gap haircut
   (`AftermarketOracle.sol:362`).

The threshold therefore steps up twice at 16:00 ET — once because the factor goes 8000 → 8500 bps, and
once because `markLiquidate = max(anchor, pool) × (1 + haircut)`. A line whose LTV sits between the
open and closed thresholds is *unhealthy every morning and healthy every evening*, and the grace clock
started in the morning never reaches its deadline because the borrower clears the flag that evening.

There is no version of aggressive keeper behaviour that escapes it. A keeper cannot flag outside the
regular session — `flag` reverts `LineHealthy` because the closed threshold applies — and a flag
inside the regular session is always deferred to tomorrow by `nextOpen`'s strictly-after semantics.

### Failure scenario, at the shipping parameters

`advanceOpenBps 6500 / advanceClosedBps 5000`, `liqThresholdOpenBps 8000 / liqThresholdClosedBps 8500`,
`liqBonusBps 700`; oracle haircut `100 bps + 10 bps/h` capped at 1000 bps.

The trap band is `LTV ∈ (80.00%, 85.85%]` immediately after the close, widening toward
`(80.00%, 93.50%]` as the haircut accumulates over a long weekend. A borrower who draws at the
6500 bps advance rate lands in it after roughly a 20% price fall — an ordinary month in a single-name
equity.

Alice posts 100 NVDAc at $200 ($20,000) and draws $12,900 (just inside the $13,000 advance). NVDAc
falls to $155.

* Open (any time 09:30–16:00 ET): `markLiquidate = $155`, threshold `= 100 × 155 × 0.80 = $12,400`.
  Debt $12,900 > $12,400 → **flaggable**.
* Post-close (16:01 ET): haircut 100 bps, `markLiquidate = $156.55`,
  threshold `= 100 × 156.55 × 0.85 = $13,306.75`. Debt $12,900 < $13,306.75 → **curable**.

PoC output, five consecutive trading days with a keeper flagging at 10:00 every morning and trying to
seize on the hour all day:

```
after the drop, REGULAR threshold : 12400000000   ($12,400)
day 0  flagged 1772463600  graceUntil 1772550000  POST threshold 13306750000  debt 12900198641
day 1  flagged 1772550000  graceUntil 1772636400  POST threshold 13306750000  debt 12900939717
day 2  flagged 1772636400  graceUntil 1772722800  POST threshold 13306750000  debt 12901680837
day 3  flagged 1772722800  graceUntil 1772809200  POST threshold 13306750000  debt 12902422002
day 4  flagged 1772809200  graceUntil 1773064800  POST threshold 13306750000  debt 12903163211
final debt      : 12905170358
final threshold : 12400000000
```

Thirty `liquidate` attempts, all reverting `GraceNotExpired`. Zero collateral seized. The line ends the
week more underwater than it started, at an LTV of 83.3% against an 80% open threshold. Cost to the
borrower: five `cure()` transactions, a few cents each on Base.

`test_02` shows the weekend makes it worse, not better: flag Friday 11:00 → grace lands Monday 10:00;
cure Friday 16:01; the whole weekend runs with no flag at all (`flag` reverts all weekend because the
closed threshold says healthy); Monday's fresh flag defers to Tuesday.

### Impact

The protocol's only delevering mechanism is completely defeated in exactly the LTV band it was built
for. The gap between `liqThresholdOpenBps` (8000) and `liqThresholdClosedBps` (8500), widened further by the
closed-market haircut on `markLiquidate`, is not a grace period - it is a permanent parking space. Positions the protocol has itself judged unsafe accrue
interest at the closed-session premium and are carried by the vault until a single overnight gap
pushes them straight through the closed threshold into bad debt, with no intermediate delevering.
Because `AftermarketVault.maxWithdraw` (`:91`) clamps LP exits to idle USDC, the liquidity those lines
hold is also locked up for as long as the loop runs.

### Likelihood

Certain. No capital, no privileged access, no race — one transaction per evening, and the borrower is
the obviously-motivated actor. `cure` is permissionless, so it can also be run by a bot on the
borrower's behalf. The independent refutation pass measured the cure at **43,090 gas**, about
10.9M gas per trading year: cents on Base against 7% of debt saved per liquidation avoided. The cost
argument does not blunt it.

### Why this is Medium and not High

The refutation pass could not break the mechanism — an exhaustive sweep of 672 consecutive 15-minute
slots across a full week (including the DST transition) found **zero** flags whose entire grace period
fell inside one regular session, and confirmed that flaggable and curable are perfect complements
(134 flaggable slots, all REGULAR; 412 curable slots, none REGULAR). But it did break the impact
narrative, in four ways that matter:

1. **No insolvency at the time of the attack.** The worst true collateralisation the vault ever holds
   while a line is looping is the closed ceiling — 85.85% right after the bell, drifting to about
   86.9% by 04:00 ET as the haircut accumulates. Against a 700 bps liquidation bonus a liquidator
   needs 93.4% of value, so the position is still comfortably seizable *when it finally is seizable*.
   The loop does not create bad debt by itself; it removes the delevering step that would have
   prevented one.
2. **The exposure has the same shape the protocol already accepts by design.** `liqThresholdClosedBps`
   is the tolerance the protocol deliberately runs every weekend and every holiday. The loop converts
   a 65-hour tolerance into an indefinite one — it does not invent a new risk.
3. **One missed evening ends it.** This is a hard liveness requirement on the borrower, not a
   set-and-forget bypass. Miss a single 16:00-04:00 window and the line is seizable at 10:00.
4. **A funded keeper can break it.** Holding the Aerodrome TWAP roughly 6% below the anchor from 16:01
   through the night pushes the oracle to `UNTRUSTED_DIVERGENT`, so `cure` reverts along with
   everything else; release at the bell and seize at 10:00. Verified end to end (36 cure attempts, all
   blocked, then a successful seizure). It is expensive — a full night of one-sided TWAP pressure on a
   pool with a $25k depth floor, bleeding to arbitrageurs — but it exists, so "forever" is only true
   against a keeper unwilling to spend money.

What the refutation *strengthened*: interest does not rescue the position. Measured from a maxed draw,
a mid-band line takes **331 days at 50% utilisation and 186 days at 80%** to accrue its way out of the
band; at realistic utilisation it is over 900 days. This does not self-resolve. And per A-17, the one
keeper-favourable flag window — PRE, where `nextOpen` is *today's* bell and the grace would expire the
same morning — is permanently unusable because the oracle is always stale then.

### Recommended fix

Pick one; the first is the smallest change.

1. **Make the flag sticky across sessions.** Record the session in which the line was flagged and
   require `cure` to test health against the *strictest* of the flagged session and the current one
   — i.e. keep evaluating a line flagged during REGULAR at `liqThresholdOpenBps` until it is genuinely
   cured. Concretely, store `flaggedOpen` alongside `flaggedAt` and pass it into `_seizureThreshold`.
2. **Anchor the grace deadline to the flag, not to the next flag.** Keep a per-line
   `lastFlagClearedAt` and refuse to re-arm a full grace period more often than, say, once per week;
   a re-flag inside that window inherits the original deadline.
3. **Require a real cure, not a session change.** Make `cure` demand `debt <= _borrowPower(user, s)`
   (the advance rate) rather than the seizure threshold — curing should return the line to a state it
   could have been opened in, which is the meaning of "healthy" everywhere else in the contract.

Option 3 also removes the odd asymmetry that a line can be cured into a state from which it is
immediately flaggable again.

---

## A-02 — High — One raw unit of an unpriceable asset vetoes flag and liquidate for the entire basket

**Status: fixed.** An asset whose oracle refuses to mark contributes zero to both `_borrowPower` and `_seizureRisk` instead of aborting them, and `_quoteSeizure` still reverts so that asset can never be taken. `audit/poc/BasketVeto.t.sol` proves both triggers, and `test/fork/LiveB20.t.sol` proves it against the live AMZNc divergence on Base.

**Files:** `src/AftermarketCredit.sol:933-947` (`_borrowPower`), `:950-964` (`_seizureThreshold`),
`:938-941` and `:955-958` (the `if (amount == 0) continue;` guard);
`src/AftermarketOracle.sol:365-379` (verdict ladder), `:309-316` (`_enforce`).

**PoC:** `audit/poc/BasketVeto.t.sol` — `test_01` (attacker-driven), `test_02` (exogenous),
`test_00` (control), `test_03` (the borrower is still not trapped). All four pass.

### Root cause

Both risk functions iterate the borrower's posted-asset list and call the per-asset oracle for every
entry whose balance is non-zero — *including a balance of one raw unit*:

```solidity
uint256 amount = collateral[user][asset];
if (amount == 0) continue;
uint256 value = _mulDown(amount, c.oracle.markLiquidate(), ORACLE_SCALE);
```

`markLiquidate()` reverts whenever that asset's verdict is untrusted, and nothing on the seizure path
catches it. So the health of an eight-asset basket is a logical AND over eight independent oracles, and
the weakest one wins. A borrower controls which assets appear in that list.

### Failure scenario

Alice posts 100 NVDAc ($20,000, a deep and well-behaved market) **plus one raw unit of TSLAc**
(1e-8 TSLAc ≈ $0.000004). She draws $9,900. NVDAc falls to $100, so the line is seizable at every
parameter set: open threshold $8,000, closed threshold $9,350 (at the 1000 bps haircut cap), debt
$9,900. She is flagged and the grace period expires.

**(a) attacker-driven — `UNTRUSTED_DIVERGENT`.** Alice pushes the TSLAc pool 30-minute TWAP 3% away
from its Chainlink anchor. The shipped REGULAR divergence band is 200 bps, so the TSLAc oracle refuses
to mark. PoC output:

```
TSLAc divergenceBps : 299        (band 200)
NVDAc oracle        : TRUSTED, marks fine
positionOf().priced : false
liquidate(alice, NVDAc, 1000e6) -> SourcesDiverged(REGULAR, 299, 200)
cure(alice)                     -> reverts
debt still outstanding : 9900576295
NVDAc collateral held  : 10000000000
```

She picks whichever listed pool is shallowest, because she holds one wei of it and does not care what
it is worth. On Base today the shallowest live B20 pool is roughly $61k (MSFTc), against a position
size that can be arbitrarily large.

**(b) exogenous — `UNTRUSTED_HALTED`, no attacker at all.** The B20 issuer pauses transfers on TSLAc,
which is what happens around a corporate action. `AftermarketOracle._readMultiplier` (`:465-467`)
staticcalls `isPaused(PausableFeature.TRANSFER)` and an affirmative answer is an unconditional halt.
`flag(alice)` reverts `MarketHalted(1e18)` even though the position that is halted is worth four
millionths of a dollar. The same applies to a Chainlink outage on the dust asset, or to the dust
asset's pool falling below `minPoolLiquidityUsd` while the market is closed.

### Impact

A line can be made permanently unflaggable and unliquidatable while retaining its full debt. If the
price of the *good* collateral then falls, the loss is unbounded bad debt borne by the vault's LPs,
with no intervention possible. Combined with A-01 this is the second, capital-cheap way to switch the
liquidation engine off.

The one piece of good news is real and worth stating: `test_03` confirms the veto does **not** trap
the borrower. `repay` and `repayOnBehalf` read no oracle, and `withdrawCollateral` reads one only when
debt remains, so a borrower can always repay in full and walk out through a total oracle outage. That
property holds.

### Likelihood

(a) requires sustaining a TWAP push through the liquidation window in a $30–77k pool — a few thousand
dollars of adverse selection per day against a liquidation bonus that scales with the position. Worth
it above roughly a $100k position. (b) requires nothing at all and will happen on its own.

### Recommended fix

There is a genuine tension here: valuing an unpriceable asset at zero on the threshold side would make
*deflating* one asset a way to force-liquidate a healthy line, which is strictly worse. The fix has to
keep the veto but bound it:

1. **Bound what a dust position can veto.** Skip assets whose *last known* value is below a dust floor
   (e.g. `< 1e-4` of the basket) instead of only skipping `amount == 0` — a position too small to
   matter should not be able to block a seizure. This alone kills the cheap attacker version.
2. **Let a liquidation proceed against the priceable subset when the unpriceable subset is
   immaterial**, valuing the unpriceable assets at zero for `_borrowPower` (conservative) and leaving
   them un-seizable.
3. Enforce a minimum deposit per asset in `depositCollateral` so a one-wei position cannot be created
   in the first place. This is the cheapest partial mitigation and should ship regardless.

---

## A-03 — Medium — Nothing in the system handles a multiplier change of corporate-action magnitude

**Status: mitigated (branch A), accepted and documented (branches B and C).** `sweepYield` now refuses any slice above `MAX_SWEEP_BPS`, so a split-magnitude misfire is a revert rather than a 90% market order. The feed's unit convention (branch B) cannot be resolved before the first corporate action and is recorded as a live risk. Branch C is a configuration error and is fixed there: the multiplier bounds now ship at `[0.01e18, 1000e18]`.

**Files:** `src/AftermarketCredit.sol:666-703` (`sweepYield`), `:684` (the slice formula),
`:1115-1124` (`_rollMultiplierCheckpoint`); `src/AftermarketOracle.sol:453-474`
(`_readMultiplier` — static bounds only), `:346-362` (the multiplier appears nowhere in the price math).

**PoC:** `audit/poc/SplitSweep.t.sol` — `test_01` (branch A), `test_03`/`test_04` (branch B),
`test_00` (control: a real dividend behaves correctly), `test_02` (no escape hatch). All five pass.

The underlying defect is one sentence: **the oracle never uses the multiplier in its price math, so
the Chainlink anchor and the Aerodrome pool must already agree on which unit they quote — and the
multiplier is precisely the thing that can break that agreement.** `_readMultiplier` (`:453`) tests it
only against the static bounds `[0.5e18, 100e18]`, which are two orders of magnitude too wide to
notice any real corporate action, and which detect a *level*, never a *change*. Depending on which
convention the live Coinbase feed uses, that produces one of two High-severity outcomes. Both are
demonstrated below; the protocol is not prepared for either.

### Branch A — the feed tracks the raw unit: `sweepYield` force-sells the position

B20 signals **both** corporate actions through the same `multiplier()`.
`IB20Asset.multiplier` is documented as *"Holder balances are stored as raw units; the multiplier
scales them into a derived 'scaled' view, similar in shape to wstETH wrapping stETH"* — so the raw,
transferable unit is the wstETH-like wrapper.

* A **dividend** reinvested into the wrapper is value-accretive to the raw unit: the multiplier rises
  and so does the raw unit's price. The share of the position that is new value is `(m − m0)/m`.
* A **split** is value-**neutral** to the raw unit: a 10:1 split takes the multiplier from `1e18` to
  `10e18` while the per-share price falls to a tenth, so one raw unit is worth exactly what it was
  worth the second before. Neither the Chainlink total-return print nor the Aerodrome pool moves.

`sweepYield` assumes accretion unconditionally (`:684`):

```solidity
v.sold = _mulDown(balance, v.multiplierNow - v.multiplierWas, v.multiplierNow);
```

For a 10:1 split that is `balance × 9/10`.

`lib/base-std/docs/B20/Asset.md` confirms the mechanism explicitly: the multiplier *"lets issuers
rebase every balance at once — without rewriting individual balances — the shape is similar to wstETH
wrapping stETH, where the stored unit is the unwrapped quantity and the derived unit is the rebased
view"*, and `updateMultiplier` is described as *"rescal[ing] the displayed balance rather than moving
raw balances directly"*. A split **is** a rebase, and there is no other mechanism in `IB20Asset` to
express one without rewriting balances. `sweepYield`'s own NatSpec (`:643-645`) asserts the same
thing: *"B20 tokens carry corporate actions through an onchain `multiplier()` rather than by minting"*.

The oracle does not stop it: `_readMultiplier` (`:453`) halts only when the multiplier leaves
`[minMultiplier, maxMultiplier] = [0.5e18, 100e18]` (`script/config/base.json`), and a 10:1 split lands
at `10e18`, comfortably inside. The sweep
executes against a fully `TRUSTED` mark.

### Failure scenario

NVDA performed a 10:1 split in June 2024; TSLA a 3:1 in 2022. Alice holds 100 NVDAc ($20,000), owes
$5,000, and has enabled `setAutoRepay(true)` — the flagship "self-repaying collateral" opt-in that the
`AutoRepayer` keeper is being built for. NVDAc splits 10:1.

PoC output:

```
split: collateral before : 10000000000   (100 NVDAc)
split: sold raw units    :  9000000000   (90 NVDAc)
split: collateral after  :  1000000000   (10 NVDAc)
split: proceeds USDC     : 18000000000   ($18,000)
split: repaid USDC       :  5000000000
split: surplus to wallet : 13000000000
```

$18,000 of a $20,000 position sold on a market order into a pool with ~$62k of depth, on an event that
changed nobody's wealth by one cent. The realised cost is the execution slippage — and per A-05 the
floor `sweepYield` actually enforces is not the configured 1% but up to 24% once the gap haircut and
the divergence band are stacked, so as much as ~$4,300 of this $18,000 can be handed to a sandwicher —
plus a completely unwanted de-risking of the borrower's equity exposure, plus, for most jurisdictions,
a realised capital-gains event they did not choose.

`test_02` confirms there is no escape hatch. `_rollMultiplierCheckpoint` (`:1115`) deliberately blends
the checkpoint on deposit so the sellable slice stays the same size *in raw units* — correct for a
dividend, and it means topping up collateral after a split does not shrink the exposure by a single
unit (the 90e8 slice survives exactly, to 1 wei in the protocol's favour). The only defence is never
enabling auto-repay, and the borrower can still fire it themselves from a UI button labelled
"collect dividend".

### Impact

Direct, immediate loss of principal to every auto-repay borrower in a name that splits, of order
`(1 − 1/ratio) × position × slippage`, plus forced de-risking and a tax event. For a 10:1 split that
is 90% of the position routed through a shallow AMM.

### Likelihood

Certain, conditional on a listed name splitting and any borrower having opted in. Splits are routine;
the protocol's own NatSpec (`:643-653`) says the path is exercised against a *simulated* multiplier
increase because no real one has occurred yet — meaning the first real corporate action on a B20 name
will be the first time this code runs in production.

### Why this is Medium and not High

The independent refutation pass confirmed the premise (there is no other rebase primitive in
`IB20Asset`; `batchMint` is per-recipient, `MINT_ROLE`-gated and supply-capped, and cannot express a
split for holders sitting inside AMM pools) and confirmed that nothing in the oracle catches a
forward split. But it correctly cut the impact down:

1. **Net worth is preserved.** The borrower gets the $18,000 — debt repaid, surplus forwarded to their
   wallet — and the surviving line is healthy with zero debt. This is a forced unwind of leveraged
   equity exposure and an involuntary taxable disposal, not a theft of principal. The measured
   loss-of-funds is the *execution discount*, not the notional.
2. **The slippage guard is a real brake, and for most positions it turns the bug into a revert
   rather than a dump.** `minOut` is derived from `markBorrow` and `maxSlippageBps`, so a 90% market
   order that moves the pool more than the tolerance simply reverts `SlippageExceeded`. With the
   shipped $25k depth floor and 100-token asset caps, a 90% dump of any position of consequence is far
   outside a 1% impact budget. So the realistic outcomes are: small positions get unwound at up to the
   (wide, per A-05) tolerance; large positions get a `sweepYield` that reverts *permanently* — because
   `_rollMultiplierCheckpoint` preserves the raw slice across deposits, the self-repayment feature for
   that user and asset is bricked until the position shrinks. That second outcome is a liveness bug,
   not a loss.
3. **The precondition is a genuine gate.** `autoRepayEnabled` is off by default, `openLine` /
   `depositCollateral` / `draw` do not flip it, and `setAutoRepay(false)` is a complete and immediate
   defence available even after the split has landed.
4. **No cascade.** After the sweep the debt is zero and the line is healthy; there is no liquidation
   knock-on and no bad debt.

A High rating remains defensible for **branch B specifically** — if the Coinbase feed turns out to be
share-denominated, a split permanently bricks the asset's oracle for every holder, and that is a
protocol-wide freeze rather than one borrower's unwind. Since which branch is live is unknowable until
the first corporate action, the honest rating for the finding as a whole is Medium with an explicit
flag that it needs resolving *before* that event, not after.

### Recommended fix

The multiplier alone cannot distinguish the two events, so the contract must not try to infer it:

1. **Cross-check the slice against price.** A distribution should leave the *scaled* value roughly
   unchanged and raise the raw price; a split leaves the raw price unchanged. Require that the
   pre-sweep and post-sweep oracle marks are consistent with an accretion of `(m − m0)/m` — i.e.
   compare the raw mark now against the raw mark checkpointed alongside `multiplierCheckpoint`, and
   revert `NothingToSweep` when the raw price did not move with the multiplier.
2. **Cap the sweep.** Refuse any sweep where `sold > CAP_BPS × balance` (a few hundred bps). No real
   distribution is 90% of a position; a cap turns a catastrophic misfire into a revert.
3. **Require an explicit per-event authorisation.** Have the owner (or an issuer-announcement reader)
   whitelist `(asset, fromMultiplier, toMultiplier)` as a *distribution* before the slice can be sold.
   `IB20Asset.announce` exists precisely to bracket these events on-chain.

At minimum, ship (2) before any B20 name performs a corporate action.

### Branch B — the feed tracks the share: the oracle breaks instead

If the Chainlink "Coinbase &lt;TICKER&gt;" feed quotes the *share* rather than the raw wrapper, a 10:1 split
takes the anchor from $200 to $20 while the pool — which trades the raw unit — keeps printing $200.
Nothing reconciles the two. `test_03` (passes):

```
verdict       : 3   (UNTRUSTED_DIVERGENT)
divergenceBps : 89991   against a band of 200
draw / withdrawCollateral / flag : all revert, permanently
```

The asset's oracle is bricked for every holder, forever, because a divergence of 900% will never come
back inside a 100 bps band. And `test_04` shows the worse variant: if that pool's USDC balance ever
dips under `minPoolLiquidityUsd` during an open session (see A-07 — it is a raw balance, so one large
swap does it), `poolUsable` goes false, the divergence check stops applying, and the mark collapses
straight onto the tenfold-lower anchor:

```
threshold before : 14000000000   ($14,000)
threshold after  :  1400000000   ($1,400)
debt             :  9000000000   ($9,000)
-> flag() succeeds instantly, on a value-neutral corporate action
```

Every holder of that asset becomes liquidatable in one block.

**Which branch is live is not determinable from the code.** Every B20 multiplier on Base is still
exactly `1e18`, so the two conventions are observationally identical today and will stay that way
until the first corporate action. That is itself the finding: the protocol has a hard dependency on a
convention it has never observed, no assertion that it holds, and a failure mode in both directions.

### Branch C — the bounds themselves are the wrong tool, in the other direction

`script/config/base.json` ships `minMultiplierBps = 5000`, i.e. `minMultiplier = 0.5e18`. A 1:2 reverse
split lands *exactly* on that bound and survives (`current < minMultiplier` is false). Anything deeper
— 1:3, 1:5, 1:10, all routine for a fallen single name — puts the multiplier below it, and
`_readMultiplier` (`:460`) returns `halted = true` **permanently**. `AftermarketOracle` has no owner,
no setter and no upgrade path, and `minMultiplier` is `immutable`, so nothing can ever widen it.
`test_05` (passes):

```
multiplier 0.5e18  (1:2 reverse split) -> TRUSTED
multiplier 0.2e18  (1:5 reverse split) -> UNTRUSTED_HALTED, markBorrow() reverts
withdrawCollateral -> reverts   flag() -> reverts
```

Every holder of that asset is frozen out of `draw`, `withdrawCollateral` (while any debt remains) and
`flag`/`liquidate` forever, and the only remedy is deploying a new oracle and calling `setAsset` — at
which point the operator has to pick new bounds by hand while positions are stuck. The bound is doing
the job of a corporate-action *detector* with a static range that is simultaneously far too wide for
splits (100× headroom up) and far too narrow for reverse splits (2× headroom down).

**Additional fix for branch B:** record the multiplier at oracle deployment and require the live one
to stay within a tight band of it (or scale the anchor by `multiplier / multiplierAtDeploy` if the
feed is share-denominated). Either way the oracle must *know* about the multiplier rather than merely
bounds-checking it, and a movement of corporate-action magnitude must be an explicit
`UNTRUSTED_HALTED` until an operator has acknowledged it.

---

## A-12 — High — Bad debt is never written off, because a collateral leg always strands below the seizure floor

**Status: fixed.** The capped-seizure cost is rounded up, so it never floors to zero and every leg is clearable; the write-off fires on the residual basket's value rather than on `postedAssets.length`; and a permissionless `realizeBadDebt` recognises a residue too small to be worth a liquidator's gas.

**Files:** `src/AftermarketCredit.sol:604-622` (`_quoteSeizure`), `:616-621` (the cap branch),
`:554-557` (the `postedAssets[user].length == 0` gate), `:1031-1045` (`_realizeBadDebt`),
`:626-634` (`_removeCollateral` only drops a leg at exactly zero);
`src/AftermarketVault.sol:74-76` (`totalAssets`).

**PoC:** `audit/poc/Accounting.t.sol` — `test_A12a`, `test_A12b`. Both pass.

### Root cause

When the seizure is capped by the borrower's balance, the cost is re-derived downward:

```solidity
if (seized > balance) {
    seized = balance;
    cost = _mulDown(_mulDown(seized, mark, ORACLE_SCALE), BPS, bonus);
}
if (seized == 0 || cost == 0) revert ZeroAmount();
```

`cost` floors to zero — and the whole call reverts — for any `balance < (BPS + bonus) * 1e36 / (mark * BPS)`.
With the shipped 700 bps bonus that is `balance < 1.07e36 / mark`. This is not a theoretical corner:

* 8-decimal NVDAc at **$200** → `mark = 2e36` → the floor is 0.54 raw units, so a single unit clears.
* 8-decimal NVDAc at **$50** → `mark = 5e35` → the floor is **2.14 raw units**, so a leg of 1 or 2
  units can never be taken.
* 18-decimal collateral (which `IB20` supports — *"6-18, configurable per token"* — and which the
  repo own fixture already lists as AAPLc, and which `script/config/base.json` lists as a live asset)
  at $200 → `mark = 2e26` → the floor is **5.35e9 wei**, so everything below about a millionth of a
  cent is permanently unseizable.

Because `_removeCollateral` (`:630`) drops an asset from `postedAssets` only when the remaining
balance is exactly zero, and `_realizeBadDebt` (`:555`) fires only when `postedAssets.length == 0`,
the write-off is unreachable.

The important part: **this happens on its own.** No dust deposit, no adversary. `test_A12a` runs an
ordinary, well-behaved liquidation cascade against an insolvent line — a keeper repeatedly taking the
full close-factor amount — and the main NVDAc leg strands at **2 raw units** simply because the price
fell to $50:

```
NVDAc units stranded by ordinary liquidation: 2
liquidate(alice, NVDAc, 1000e6)  -> ZeroAmount()
quoteSeizure(alice, AAPLc, r)    -> ZeroAmount() for r in {1, 1e3, 1e6, 1e9}
withdrawCollateral(AAPLc, ...)   -> reverts (debt still exceeds borrow power)
postedAssets.length              : 2, forever
residual debt never written off  : 5270946666   ($5,270.95)
```

The borrower cannot clear it either, because `withdrawCollateral` requires `debt <= borrowPower` and
the line is insolvent. The leg is a permanent fixture of the ledger.

### Impact

`AftermarketVault.totalAssets()` (`:74`) is `idle + credit.totalDebtAssets()`, and
`totalDebtAssets` keeps counting — and `_accrue` keeps *compounding* — debt that is provably
unrecoverable. The share price is a fiction, and it is a fiction that grows. `test_A12b`, with two
equal $1,000,000 LPs:

```
phantom (unrecoverable) debt  : 5270936351
real idle USDC in the vault   : 1994729629629
vault.totalAssets() claims    : 2000000565980
--- one year later, still not written off ---
phantom after one year        : 5379960384
totalAssets after one year    : 2000109590013
--- the race ---
lp2 (first out)  redeemed     : 1000054795006   (+$54.80 vs deposit)
supplier (second) redeemed    :  994674834622   (-$5,325.17 vs deposit)
```

The LP who redeems first is paid *more than they put in* — including a share of the interest accrued
on debt nobody will ever pay — out of the real USDC belonging to the LP who redeems second, who eats
the entire shortfall. The gap between the two is exactly the unrealisable bad debt. There is no
keeper-callable "socialise the loss" entry point that would shorten the window, and it never closes on
its own.

This also converts A-01 and A-02 from "the liquidation engine is defeated" into "the loss is
silently transferred to whoever is slowest to leave". An LP who is watching the chain can deliberately
*prevent* a write-off — one liquidation sized to leave a crumb — and then exit at par.

### Likelihood

Certain, and it does not require anybody to act adversarially. Any liquidation cascade on a
sufficiently-fallen asset, or any borrower who has ever posted a small second leg, produces it.

### Recommended fix

1. **Gate the write-off on value, not on array length.** Fire `_realizeBadDebt` when the remaining
   basket's `_seizureThreshold` (or `_borrowPower`) is zero, not when `postedAssets.length == 0`.
2. **Round `cost` up, not down, when the cap binds.** `cost = max(1, ceil(seized * mark / 1e36 * BPS / bonus))`
   removes the revert and lets a liquidator clear the crumb for one wei. (Rounding up here is also the
   correct direction — it is the liquidator's payment.)
3. **Add a permissionless `realizeBadDebt(address user)`** that anybody can call once a line's basket
   is worth less than its debt at `markLiquidate` and no seizure is possible, so the vault's share
   price cannot stay wrong indefinitely.

---

## A-13 — High — The borrow rate is sampled once and applied backwards, and the vault does not accrue

**Status: fixed.** `AftermarketVault.deposit`, `mint`, `withdraw` and `redeem` all call `credit.accrue()` before they move any USDC, and `lastAccrual` now advances only once the elapsed time has actually been charged for.

**Files:** `src/AftermarketCredit.sol:744-760` (`_accrue`), specifically `:754-755`;
`:773-775` (`_totalSupplyAssets` reads `usdc.balanceOf(vault)`);
`src/AftermarketVault.sol:106-123` (`deposit`/`mint`/`withdraw`/`redeem` never call `credit.accrue()`).

**PoC:** `audit/poc/Accounting.t.sol` — `test_A13a`, `test_A13b`, `test_A13c`. All pass.

### Root cause

```solidity
uint256 rate = rateModel.ratePerSecondAt(debt, _totalSupplyAssets(debt), s);
uint256 interest = _mulDown(debt, _taylorCompounded(rate, elapsed), WAD);
```

One rate sample, taken at the utilisation prevailing *at the moment of the call*, applied to the
**entire** elapsed window. Morpho Blue does the same thing — but Morpho's `supply` and `withdraw` call
`_accrueInterest` **before** they change the market's liquidity, so the window is always closed at the
utilisation that actually prevailed during it. `AftermarketVault.deposit` does not. Neither does
`withdraw`, `mint` or `redeem`. And `utilization` is computed from `usdc.balanceOf(vault)` — a raw
balance — so a single-block change in the vault's liquidity retroactively reprices a month of interest.

### Failure scenario

Vault holds $1,000,000; Alice draws $900,000 (90% utilisation) and nobody touches the market for
30 days. `test_A13a`:

```
honest debt after 30d : 943880510381   (interest $43,880.51)
gamed  debt after 30d : 902728077526   (interest  $2,728.08)
interest erased       :  41152432855   ($41,152.43)
cost borne as an LP   :  30529413085
NET GAIN to borrower  :  10623019770   ($10,623.02)
```

Alice deposits $3,000,000 into the vault, calls the permissionless `accrue()`, and redeems — all in
one transaction. Utilisation is 23% for the one block that matters, so 30 days of borrowing are
repriced at the 23% rate. She eats her proportional LP share of the write-down ($30,529) and keeps the
rest; the difference is paid by the other LPs.

`test_A13b` is the version that needs **no capital at all**: Alice simply backruns somebody else's
ordinary large LP deposit with a call to `accrue()`.

```
honest debt : 943880510381
backrun debt: 902728077526
free saving :  41152432855   ($41,152.43, for the cost of one transaction)
```

Any borrower can watch the mempool for a large `vault.deposit` and land an `accrue()` behind it. On a
$900k loan that is $41k of interest erased for gas, repeatedly, every time a big LP arrives.

And the capital in `test_A13a` does not have to be theirs either: `vault.deposit → credit.accrue() →
vault.redeem` is three ordinary external calls with no same-block restriction anywhere, `maxRedeem`
clamps to idle USDC *which now includes the deposit itself*, and USDC flash loans are freely available
on Base. This is exactly the exploit-chain shape the classic flash-loan attacks have: a value the code
treats as stable within a block (utilisation), atomic control of its input (a one-block deposit), and
a downstream write (`totalDebtAssetsStored`) that commits before the value is re-validated.

### A-13c — the same function destroys the clock on rounding

`lastAccrual` is written at `:749`, **before** the `if (interest == 0) return s;` bail-out at `:756`.
Every elapsed second whose interest floors to zero is permanently destroyed, and `accrue()` is
permissionless. `test_A13c`, on a $500 line:

```
interest over 2000s, one accrue      : 635 wei
interest over 2000s, accrued every 2s:   0 wei
```

Anyone can pin a small market's interest at exactly zero by calling `accrue()` every Base block. Only
bites below roughly $800 of total debt at the floor rate, so it is a Low on its own — but the fix is
one line and it belongs with this finding.

### Recommended fix

1. **Accrue before every liquidity change.** `AftermarketVault.deposit`, `mint`, `withdraw` and
   `redeem` must call `credit.accrue()` first, exactly as Morpho's `supply`/`withdraw` do. This is the
   fix that closes both variants.
2. **Move the `lastAccrual` write below the `interest == 0` check** so a zero-interest accrual does not
   consume the elapsed time.
3. Optionally, sample utilisation from an internally-tracked supply figure rather than
   `usdc.balanceOf(vault)`, so a bare donation cannot move it either.

---

## A-14 — Medium — The multiplier checkpoint is reset *downward*, fabricating distributions that never happened

**Status: fixed (a) and (c); (b) accepted and documented.** The checkpoint is a high-water mark and never moves down, and a failed `multiplier()` read is distinguished from a multiplier of 1.0 and moves nothing. A genuine distribution declared after a reverse split remains unsweepable, which is the unavoidable other side of (a).

**File:** `src/AftermarketCredit.sol:1115-1124` (`_rollMultiplierCheckpoint`), specifically the
`m <= m0` branch at `:1119-1122`; `:1099-1105` (`_multiplierOf` swallows a revert and returns WAD).

**PoC:** `audit/poc/Accounting.t.sol` — `test_A14a`, `test_A14b`, `test_A14c`. All pass.

```solidity
if (oldBalance == 0 || m0 == 0 || m <= m0) {
    multiplierCheckpoint[user][asset] = m;   // <- resets DOWNWARD when the multiplier fell
    return;
}
```

Three consequences, all demonstrated:

**(a) A net-zero round trip becomes a 50% "dividend".** Reverse split 1:2 (multiplier `1e18 → 0.5e18`),
the borrower deposits **one raw unit**, the checkpoint is rewritten from `1e18` down to `0.5e18`; the
multiplier later returns to `1e18` and a keeper sweeps `(1 − 0.5)/1 = 50%` of the position:

```
sold on a net-zero action : 5000000000   (50 NVDAc)
proceeds                  : 10000000000  ($10,000)
forced onto the debt      :  5000000000
```

**(b) The mirror: real dividends become permanently unsweepable.** With no deposit, the checkpoint
stays above the live multiplier after any decrease, so `sweepYield` reverts `NothingToSweep` forever —
a genuine post-reverse-split distribution can never be collected:

```
checkpoint : 1000000000000000000
live       :  550000000000000000   (0.5 reverse split, then a real 10% distribution)
sweepYield -> NothingToSweep
```

**(c) A transient `multiplier()` outage arms the same phantom slice.** `_multiplierOf` catches a revert
and returns `WAD`, and `depositCollateral` reads **no oracle**, so it happily proceeds during an
outage in which `AftermarketOracle` would have refused to mark:

```
checkpoint before : 2000000000000000000
one deposit made while multiplier() reverts
checkpoint after  : 1000000000000000000   (the real multiplier never moved)
fabricated slice sold: 5000000000          (half the position)
```

**Fix:** never move the checkpoint downward on a deposit — take `max(existing, m)` — and distinguish
"the multiplier read failed" from "the multiplier is 1.0". `_multiplierOf` should return a success flag
and `_rollMultiplierCheckpoint` should skip the roll entirely when the read failed, rather than
silently substituting `WAD`.

---

## A-15 — Medium — `withdrawCollateral` is the one risk-increasing action not blocked while flagged

**Status: fixed.** A withdrawal that leaves the line inside its own advance rate clears the flag, so an expired grace clock can no longer survive into the next unhealthy episode.

**Files:** `src/AftermarketCredit.sol:377-397` (`withdrawCollateral`, no flag check) versus `:417`
(`draw` explicitly refuses `l.flaggedAt != 0`).

**PoC:** `audit/poc/Accounting.t.sol::test_A15` — passes.

The grace guarantee is per-*flag*, not per-unhealthy-*episode*, and `withdrawCollateral` does not clear
or re-arm it. So:

1. A line is flagged; `graceUntil` expires the next day. Nobody cures it (nothing forces them to —
   `cure` is only *needed* in order to `draw` again).
2. The price recovers, the line is healthy, and the borrower withdraws collateral down to their
   borrowing power. `withdrawCollateral` allows this — it checks only `debt <= borrowPower` — while
   `draw` of the same economic magnitude would have reverted `LineIsFlagged`.
3. The very next adverse tick, `liquidate` finds `flaggedAt != 0`, `block.timestamp >= graceUntil`,
   `isOpen`, and `debt > threshold`. Seizure happens **in the same block the line went unhealthy**,
   with no notice at all.

```
grace expired at        : (previous day)
still flagged           : true
withdrew while flagged  : 30e8 NVDAc
price ticks down, then:
seized with no fresh flag and no fresh grace: 719999999
```

The harm falls on the borrower, and they can avoid it by calling the free, permissionless `cure` — so
this is a footgun rather than an exploit. But it voids the protocol's headline guarantee on a path
nobody would think to check, and the asymmetry with `draw` is clearly unintentional.

**Fix:** either refuse `withdrawCollateral` while `flaggedAt != 0` (matching `draw`), or auto-clear the
flag inside `withdrawCollateral` when the post-withdrawal state is healthy — the latter is friendlier
and preserves the guarantee.

---

## A-16 — Low — `SessionRateModel` puts no ceiling on its rate parameters, and an absurd one bricks `repay`

**Status: fixed.** `SessionRateModel` bounds `base + slope1 + slope2` and every session premium at construction, and `AftermarketCredit._accrue` clamps the rate it applies, so no rate model can brick repayment.

**File:** `src/SessionRateModel.sol:93-119` (constructor validates `kink` and the session multipliers,
but not `baseRatePerSecond`, `slope1PerSecond` or `slope2PerSecond`);
`src/AftermarketCredit.sol:780-785` (`_taylorCompounded`).

`_taylorCompounded` forms `x * n`, `firstTerm * firstTerm` and `secondTerm * firstTerm` in checked
arithmetic. At the shipped parameters the worst case (100% utilisation, `CLOSED_HOLIDAY` ×1.6, one
year elapsed) is `rate = 5.48e10` WAD/s and nothing comes close to overflowing — verified. But
`setRateModel` accepts any `ISessionRateModel`, and a `SessionRateModel` deployed with, say,
`baseRatePerSecond = 1e32` overflows `firstTerm * firstTerm`. Because every state-changing entry point
begins with `_accrue()`, that reverts **`repay` too** — the one function the whole design promises can
never be blocked.

This is owner-trusted territory, so it is Low. It is also a two-line fix and worth taking, because it
is the only path found in this review that can trap a borrower's collateral.

**Fix:** bound `baseRatePerSecond + slope1PerSecond + slope2PerSecond` in the `SessionRateModel`
constructor (e.g. to a few hundred percent APR), and clamp `rate` inside `_accrue` so a bad model can
never brick the engine.

---

## A-17 — Medium — The staleness budgets ignore when the feed actually stops printing

**Status: accepted by design, documented.** The behaviour is unchanged. It is a freeze, not an exposure - nothing can be seized or over-borrowed, and `repay` and `depositCollateral` read no oracle - and widening the PRE/POST budgets would mark collateral against a seventeen-hour-old print during sessions the credit engine already treats as closed. The trade-off, and the exact config change that would reverse it, are written into `AftermarketOracle`'s NatSpec.

**Files:** `src/AftermarketOracle.sol:331` (`q.stalenessBudget = stalenessBudget(thresholdSession)`),
`:369-370` (the staleness verdict); `script/config/base.json` →
`stalenessBudgetSeconds: [3600, 21600, 21600, 90000, 262800, 349200]`.

**PoC:** `audit/poc/StaleWindows.t.sol` — `test_A17a`, `test_A17b`, `test_A17c`. All three pass.

The budgets are indexed by the session the query lands in, and compared against
`block.timestamp - updatedAt`. But a Coinbase equity feed only prints during the REGULAR session, so
the feed's age at the *start* of any other session is already the distance back to the previous 16:00
close. The two are inconsistent:

| session | budget | actual feed age when that session begins | verdict |
|---|---|---|---|
| PRE (04:00–09:30 ET) | 6h | **12h** (since yesterday's close), rising to 17.5h | always `UNTRUSTED_STALE` |
| CLOSED_OVERNIGHT, Mon 00:00–04:00 ET | 25h | **56h** (since Friday's close) | always `UNTRUSTED_STALE` |

Measured, at the shipped configuration:

```
Tuesday 09:00 ET  session PRE   feedAge 61260s (17.0h)  budget 21600s (6h)  -> markBorrow() reverts
Monday  02:00 ET  session OVN   feedAge 205260s (57.0h) budget 90000s (25h) -> markLiquidate() reverts
PRE half-hour slots from 04:00 to 09:00, all UNTRUSTED_STALE : 11 of 11
```

That is 5.5 hours every weekday plus four hours every Monday morning — roughly **19% of the week** —
in which `flag`, `cure`, `liquidate`, `draw` and `withdrawCollateral`-with-debt revert for every user
of every asset. The freeze is safe in the sense that nothing can be seized, but it is not the intended
behaviour: the session table clearly means to *widen* tolerance as the market stays shut, and instead
it tightens it at exactly the wrong moment (PRE gets a 6h budget after a 12h freeze, while
CLOSED_OVERNIGHT — which precedes it — gets 25h).

The consequence that actually costs something is the one in A-01: **PRE is the only session in which
`nextOpen` returns *today's* opening bell**, so a flag raised there would expire the same morning at
10:00 rather than deferring to tomorrow. `test_A17c` confirms the deadline arithmetic works and then
confirms `flag` reverts anyway, because the oracle will not mark. The single keeper-favourable window
in the whole design is permanently unusable.

**Fix:** budget staleness against the *previous regular close*, not against a per-session constant —
`closedFor(block.timestamp)` is already computed and already in the `Quote`. A budget of the form
`max(sessionBudget, closedFor + slack)` makes PRE and Monday-overnight behave, and makes the table
mean what it reads as. Failing that, set the PRE and POST budgets to at least
`20h + the session's offset from the previous close`.

---

## A-04 — Medium — Pushing the pool to just inside the divergence band raises the seizure threshold for free

**Status: fixed.** The pool may raise `markLiquidate` only while the anchor is not itself printing, i.e. outside the regular session, which is the only case the `max` leg exists for.

**Files:** `src/AftermarketOracle.sol:359-362`; `src/AftermarketCredit.sol:950-964`.

**PoC:** `audit/poc/OracleBounds.t.sol::test_A04_PoolPushJustInsideTheBandBlocksTheFlag` — passes.

The `min`/`max` fusion is genuinely one-sided in the protocol's favour on both of the directions that
would let an attacker *extract* value (see "Attacks that did not work"). What it does not bound is the
direction that lets a borrower *defend*: `markLiquidate = max(anchor, pool) × (1 + haircut)` follows
the pool upward for the whole width of the divergence band, and `_seizureThreshold` is linear in it.

PoC, at the shipped 200 bps REGULAR band:

```
honest threshold : 12888000000   ($12,888.00)   debt: 12900001953  -> flaggable
pool pushed +1.90% (divergenceBps 190, still TRUSTED)
pushed threshold : 13132864000   ($13,132.86)   -> flag() reverts LineHealthy
markBorrow       : unchanged, pinned to the $161.10 anchor
```

A borrower buys up to a full band's worth of headroom on the *threshold* without gaining any borrowing
power, because `markBorrow = min(anchor, pool)` ignores the push. It is a purely one-sided purchase.
Push further and you get A-02's veto instead, which is strictly better for the attacker — so in
practice this finding is the "cheap" tier of the same attack surface, useful when the borrower wants
the line to stay *priceable* (so they can keep drawing) while being unflaggable.

**Fix:** derive the seizure mark from the anchor whenever the pool is *above* it, i.e. use
`markLiquidate = anchor × (1 + haircut)` and reserve `max(anchor, pool)` for the case where the pool is
the *only* live witness (market closed). The pool's job is to catch a stale anchor that is too *high*;
letting it also raise the mark hands the attacker the side they want.

---

## A-05 — Medium — `sweepYield` effective slippage tolerance is up to 24×, not the configured 1%

**Status: fixed.** `sweepYield` runs only while the US market is open, where the gap haircut is zero by construction and the pool is deepest.

**Files:** `src/AftermarketCredit.sol:687-688` (the `minOut` derivation), `:708-714` (`_swapForUsdc`).

**PoC:** `audit/poc/OracleBounds.t.sol::test_A05_SweepSlippageFloorIsMuchWiderThanConfigured` — passes.

```solidity
v.minOut = _mulDown(_mulDown(v.sold, oracle.markBorrow(), ORACLE_SCALE), BPS - maxSlippageBps, BPS);
```

`markBorrow` is already the *pessimistic* mark: it is the lower of the two venues **and** it carries
the closed-market gap haircut. The swap is then executed against that same pool. So the floor the
adapter must clear is

```
anchor × (1 − divergence) × (1 − haircut) × (1 − maxSlippageBps)
```

not `fair × (1 − maxSlippageBps)`. With the deployment defaults during an overnight session the haircut
is 200 bps at 10 hours closed (1000 bps at the cap), the CLOSED_OVERNIGHT divergence band is 800 bps
(1500 bps over a holiday), and
`maxSlippageBps` is 100 bps. PoC output:

```
haircutBps    : 200
divergenceBps : 790
sold          : 196078431
proceeds      : 352941175
fair value    : 392156862
loss bps      : 1000
```

A fill 1000 bps below the honest anchor sails through a "1% slippage budget". Over a long holiday
weekend, where the haircut reaches its 1000 bps cap and the CLOSED_HOLIDAY band is 1500 bps, the
tolerance widens to `1 − 0.85 × 0.90 × 0.99 = 24.3%`. Anyone can trigger the sweep on an auto-repay borrower, so the
sandwich is a permissionless, repeatable extraction against the swept slice. It compounds badly with
A-03: a mis-fired split sweep is exactly when the swept slice is large.

**Fix:** derive `minOut` from an *undiscounted* reference — the anchor at `haircutBps = 0` — and let
`maxSlippageBps` be the only tolerance. Optionally refuse to sweep outside a regular session, when the
gap haircut is zero by construction and the pool is deepest.

---

## A-06 — Medium — The trading calendar runs out at the end of 2027 and cannot be replaced

**Status: fixed.** The calendar has an explicit horizon, `[SEEDED_FROM_DAY, SEEDED_UNTIL_DAY]`, and fails closed outside it: every instant reports `CLOSED_HOLIDAY`, `isOpen` is false, and the day scans answer zero instead of guessing.

**Files:** `src/TradingCalendar.sol:104-142` (constructor), `:88-92` and `:304-309` (`_dayFlag`
defaults unseeded days to `FLAG_NORMAL`); `src/AftermarketCredit.sol:109` and
`src/AftermarketOracle.sol:149` (`calendar` is `immutable` in both).

**PoC:** `audit/poc/CalendarDrift.t.sol` (3/3 pass) and `audit/scratch/CalendarProbe.t.sol`
(18/18 pass, 108k+ timestamps probed).

### The defect

The holiday and half-day table covers 2026 and 2027 only. `_dayFlag` reads any unseeded day as a normal
full trading day, the contract has no owner and no setter, and both consumers hold the calendar
`immutable`. From 2028-01-01 the protocol's single source of "is the US market open" is permanently
wrong.

The calendar probe confirms **every one of the 2,086 weekdays in 2028–2035 reports `REGULAR` at
15:00 UTC** — i.e. roughly 75 real NYSE full closures and every half day over that span read as open
sessions. A sample:

| date | calendar says |
|---|---|
| 2028-01-17 MLK | REGULAR, `isOpen() == true` |
| 2028-04-14 Good Friday | REGULAR, `isOpen() == true` |
| 2028-11-23 Thanksgiving | REGULAR, `isOpen() == true` |
| 2028-12-25 Christmas | REGULAR, `isOpen() == true` |
| 2028-11-24 (1pm early close) | REGULAR until 16:00 ET, `closedFor() == 0` |

### The downstream harm

`test_01_UnseededHalfDay_LiquidatesAfterTheRealClosingBell` is the sharp case. On Friday 2028-11-24 —
NYSE's 13:00 ET close after Thanksgiving — at 13:30 ET, thirty minutes after the real closing bell:

```
calendar.session()        : REGULAR
calendar.isOpen()         : true
calendar.closedFor()      : 0
oracle verdict            : TRUSTED
oracle haircutBps         : 0
feedAge / stalenessBudget : 2100s / 3600s
liquidate(...)            : succeeds, seized 1080000000 raw NVDAc for $1,000
```

Collateral is seized against a dead tape with **zero** gap haircut and the **open** liquidation
threshold. The protocol's central product promise — "never get liquidated while the US market is
closed" — is silently false. The window is bounded by the REGULAR one-hour staleness budget, so it is
roughly 13:00–14:00 ET on each of those days, on five known dates in 2028–2029 alone.

`test_00_SeededHalfDay_IsHandledCorrectly` is the A/B control on the *seeded* 2026-11-27 half day:
13:30 ET correctly reports `POST`, `isOpen() == false`, a live 100 bps haircut, and `liquidate` reverts
`MarketClosed(POST)`.

`test_02_UnseededFullHoliday_DegradesToAnOracleOutage` shows the failure inverts on a full holiday: the
calendar picks the tight REGULAR staleness budget against a 19-hour-old feed, so the verdict is
`UNTRUSTED_STALE` and the whole oracle reverts, instead of the well-behaved `TRUSTED_CLOSED` with a
104-hour budget and a gap haircut it should have produced. Seizure is blocked — **by the staleness
guard, not by the calendar**. That is a defence-in-depth success, and it is also the proof that the
calendar is not the last line of defence its NatSpec implies.

`flag`'s guarantee degrades too: the probe shows that flagging at the eve's closing bell on
2028-01-14 / 2028-04-13 / 2028-05-26 / 2028-11-22 / 2028-12-22 returns a `nextOpen` of 09:30 ET on a day
NYSE is shut, so `graceUntil = nextOpen + CURE_WINDOW` opens the borrower's cure window on a closed
market.

### Impact and likelihood

Certain and dated: 2028-01-01. Not a drain — the staleness guard masks the full-holiday case and the
half-day window is about an hour — but the guarantee the product is sold on is void, and the *only*
remedy is redeploying the calendar, every oracle, the credit engine and the vault (`credit` is
immutable in the vault too) and migrating every open position and every LP share. That is what moves
this above Low.

**Fix:** make the calendar extensible. Either add an owner-gated `seedDays(uint32[] days, uint8[] flags)`
that can only write *future* days and only for days not already seeded, or hold the calendar behind a
governance-settable pointer in the credit engine and the oracle factory. If immutability is the point,
seed at least ten years and document the sunset date prominently — but note that the observed-date
rules make hand-seeding error-prone, and the probe found the 2026/2027 table to be exactly right
against an independently written NYSE table over all 730 days, so the existing seeding process works
and should simply be extended.

---

## A-07 — Medium — `minPoolLiquidityUsd` measures a raw balance, not tradeable depth

**Status: fixed.** Depth is the harmonic mean of in-range liquidity over the same TWAP window, taken from the `secondsPerLiquidityCumulativeX128` pair `observe` already returns, capped by the raw balance.

**Files:** `src/AftermarketOracle.sol:537-541` (`_readPoolLiquidityUsd`), `:346` (`poolUsable`).

**PoC:** `audit/poc/OracleBounds.t.sol::test_A07_PoolDepthFloorIsDefeatedByABareTransfer` — passes.

```solidity
(bool ok, uint256 balance) = _staticcallWord(loanToken, abi.encodeCall(IERC20.balanceOf, (pool)));
return Math.mulDiv(balance, WAD, _loanUnit);
```

This is the pool's entire USDC balance, not its active in-range liquidity. In a concentrated-liquidity
pool the two are unrelated: a single-sided, far-out-of-range USDC position satisfies the floor while
contributing nothing to the depth that actually resists a TWAP push — and it carries no inventory risk,
so it can be added and removed for the cost of gas.

PoC: on a Saturday with a $1,000 pool the verdict is `UNTRUSTED_THIN` and `markLiquidate` reverts.
Restore the balance to $100,000 and the same pool, with the same tick, is promoted to `TRUSTED_CLOSED`
and its (attacker-set) TWAP becomes the seizure mark:

```
poolLiquidityUsd : 100000000000000000000000
poolPrice        : 203982568000000000000   (+2.0%, inside the 1200bps weekend band)
markLiquidate    : 2106120014600000000000000000000000000   (above the anchor)
```

The floor is meant to be the thing that stops a thin pool from corroborating a frozen feed. As written
it is a free-to-satisfy formality, which is what makes A-04 and A-02(a) cheap.

**Fix:** read `pool.liquidity()` (the active in-range liquidity) and convert it, or take the harmonic
mean of `secondsPerLiquidityCumulativeX128` across the TWAP window — `observe` already returns it and
the contract currently discards it (`:484`, second return value ignored). That measures liquidity
*during* the window, which is exactly the quantity a TWAP-manipulation cost depends on, and it cannot
be spoofed by a balance that was never in range.

---

## A-08 — Medium — `setAsset` never checks that the oracle it installs prices the asset it is installed for

**Status: fixed.** `setAsset` asserts `oracle.collateralToken() == asset` and `oracle.loanToken() == usdc`.

**File:** `src/AftermarketCredit.sol:231-255`, specifically `:245` `c.oracle = params.oracle;`.

`setAsset` validates the *shape* of the risk policy thoroughly — ordering of the advance and threshold
factors, the 9500 bps ceiling, the bonus cap, the posted-vs-cap invariant. It does not validate the
*wiring*. There is no check that

```solidity
params.oracle.collateralToken() == asset
params.oracle.loanToken()       == address(usdc)
```

Both getters exist on `IAftermarketOracle` and cost two staticcalls. This is the Rho Markets failure
mode verbatim: in July 2024 a deployment wired ETH's market to the WBTC/USD feed and an MEV bot
borrowed the pools dry for ~$7.6M. No code bug — a wiring error that nothing checked.

The consequences here are total for the asset: pointing NVDAc at the TSLAc oracle inflates or deflates
its entire valuation by the price ratio, letting either the borrower over-draw or a liquidator seize a
healthy line. `AftermarketOracleFactory.predictAddress` exists so the correct address can be computed
off-chain, which makes the missing on-chain assertion cheaper still to add.

Note also that `setAsset` may be called on an asset with live positions, so the oracle can be repointed
under existing borrowers with no timelock and no event beyond `AssetConfigured`.

**Fix:** assert both getters in `setAsset`. If the intent is to also support non-`IAftermarketOracle`
price sources, wrap the assertion in a try/catch that requires an affirmative match when the interface
is present.

---

## A-09 — Medium — Liquidators receive Reg-S securities with no eligibility check

**Status: originally accepted by design; now FIXED.**

*Original status, kept for the record:* accepted by design, documented. Gating liquidators would shrink the liquidator set and risk unliquidatable positions. The decision, and the fact that the Reg-S property covers origination rather than secondary distribution, was stated in `liquidate`'s NatSpec.

*Superseded on 2026-09-07, and the finding is now fixed in code.* Accepting it was the wrong call. This protocol exists to keep a Regulation-S offering inside its own terms, and "the Reg-S property covers origination only" is a sentence that describes a live, reachable path by which the protocol itself hands a US person a tokenized US equity at an 8% discount. No amount of documenting that makes it not a distribution channel.

The fix separates the two legs of a seizure, because only one of them carries the obligation. USDC comes in from `msg.sender`; the security goes out to a `receiver`. `liquidate` now checks `receiver` against `eligibility` and deliberately does not check `msg.sender`, so the liquidator set is bounded by who may HOLD the security rather than by who may send a transaction - a searcher's bot, a flash-loan router or a relayer can still fund a liquidation with no attestation of its own, provided the collateral lands with an attested non-US person. That answers the original objection (a liquidator set too small to clear a position is a solvency risk) without leaving the channel open. There is no way around it by naming a third party: the address checked is the address the tokens are transferred to. A four-argument `liquidate(user, asset, repayAssets, receiver)` names the receiver; the three-argument form is the same call with `receiver = msg.sender`.

`withdrawCollateral(asset, amount, to)` stays ungated, for the reason the original finding gives: it is an exit on collateral the borrower already holds, and a compliance rule that can trap somebody's assets is a bug. Covered by `test_eligibility_liquidationRefusesAnIneligibleCaller`, `..._RefusesAnIneligibleReceiver`, `..._AllowsAnIneligiblePayerForAnEligibleReceiver` and, against the live gate on real mainnet state, `test/fork/LiveB20.t.sol`.

**File:** `src/AftermarketCredit.sol:538-566` (`liquidate`), `:565`
`IERC20(collateralAsset).safeTransfer(msg.sender, seized);`.

The premise of the whole compliance design (`src/RegSGate.sol:17-30`) is that Coinbase's tokenized
equities are offered to non-US persons only, and that the B20 token itself *"performs no
per-transaction jurisdiction check; anything built on top of it inherits that gap"*. Aftermarket closes
that gap on the way in — `openLine`, `depositCollateral` and `draw` are all gated — but `liquidate` is
a distribution channel for the same securities and is completely ungated. Anybody, from anywhere, can
repay USDC and receive B20 tokenized equities at an 8% discount to the seizure mark.

This is a deliberate-looking omission (gating liquidators would shrink the liquidator set and risk
unliquidatable positions, which is a real trade-off) but it is not documented anywhere, and it
undercuts the property the protocol advertises. It should be an explicit decision, not an accident.

The related surface is benign: `withdrawCollateral(asset, amount, to)` sends to an arbitrary `to`, but
an eligible borrower could equally withdraw to themselves and transfer, so gating it would only trap
assets.

**Fix (pick one, and write it down either way):** gate the liquidator on `eligibility.check` and accept
the smaller liquidator set; or route seized collateral through a permissioned liquidation queue; or
state explicitly in the contract NatSpec and in the public docs that liquidation is an unrestricted
distribution and that the Reg-S property covers origination only.

---

## A-10 — Low — `setSwapAdapter` accepts the zero address

**Status: fixed.**

**File:** `src/AftermarketCredit.sol:289-292`.

Every other setter rejects zero (`setEligibility:271`, `setRateModel:280`, `setAsset:232`, and the
constructor at `:191-196`). `setSwapAdapter` does not, so a fat-fingered call bricks `sweepYield` for
every user until it is set again. Impact is limited (nothing else depends on the adapter, and the owner
can fix it), but the inconsistency is a trap.

**Fix:** `if (address(swapAdapter_) == address(0)) revert ZeroAddress();`

---

## A-11 — Informational — Orphaned NatSpec and an inverted error name

**Status: fixed (1, 2, 3, 5); mitigated (4).** The orphaned blocks are gone, `cure` reverts `CureIncomplete`, `ITradingCalendar` documents strictly-after, and the dead `m0 == 0` branch is gone. The mark multiplications in the risk paths and in `_quoteSeizure` now use `Math.mulDiv`.

1. **`src/AftermarketCredit.sol:257-265`** contains two complete `/// @notice` blocks documenting
   functions that do not exist — "Turns new deposits of `asset` on or off" and "Adjusts the
   protocol-wide posted cap for `asset`". Solidity attaches the *last* block before a declaration, so
   these two currently document nothing and the first of them will silently become `setEligibility`'s
   docs in some tooling. The behaviours they describe are only reachable by calling `setAsset` with a
   full `AssetParams` struct.

2. **`src/AftermarketCredit.sol:509`** — `cure` reverts `LineHealthy(debt, threshold)` when the line
   is **un**healthy. The same error is used correctly at `:480` and `:584`. A keeper reading the
   revert reason will conclude the opposite of what happened.

3. **`src/interfaces/ITradingCalendar.sol:63-64`** documents `nextOpen` as "the next regular open **at
   or after** `timestamp`", while `TradingCalendar._scanForwardToOpen:251` implements strictly-after
   (and `TradingCalendar.sol:154` documents it correctly). Measured skew at the opening bell:
   `nextOpen(bell − 1) == bell`, `nextOpen(bell) == bell + 86400`. Borrower-favourable, so not a
   safety issue, but it is load-bearing for A-01 and an integrator reading the interface would
   mis-size deadlines.

4. **`src/AftermarketCredit.sol:1063-1065`** — `_mulDown` is a naive `(x * y) / d` with the comment
   *"Every product this contract forms is bounded far below 2^256"*. That holds for the shipped 8-dec
   collateral / 6-dec USDC configuration, but the bound is not enforced anywhere: `_morphoScale` grows
   as `10 ** (18 + loanDec − collDec)`, so a 0-decimal collateral against an 18-decimal loan token
   gives `_morphoScale = 1e36` and a mark up to `1e66`, at which point `amount * mark` overflows for
   balances above ~1e11 and reverts inside `_seizureThreshold` — bricking liquidation for that asset.
   Not reachable with the intended assets; worth either a `Math.mulDiv` or an explicit decimals
   restriction at listing time. The public `quoteSeizure` (`:596-602`) is unbounded in `repayAssets`
   and panics above ~1.157e41 — off-chain callers only, since the on-chain path is capped by the close
   factor at `:586-587`, but a bot that passes `type(uint256).max` to probe the maximum gets a panic
   instead of a revert.

5. **`src/AftermarketCredit.sol:1119`** — the `m0 == 0` branch of `_rollMultiplierCheckpoint` is dead
   code: a position with a non-zero balance always has a non-zero checkpoint, and a position with a
   zero balance takes the `oldBalance == 0` branch first. Harmless, but it obscures the fact that the
   *reachable* branch of that condition is the `m <= m0` one, which is A-14.

---

# Attacks I tried that did NOT work

This section is as important as the findings. Each item below is a real attempt, with the reason it
failed. Several of them are the design working exactly as intended, and they are worth publishing.

### 1. Inflating `markBorrow` by pushing the Aerodrome TWAP up — REFUTED

**PoC:** `audit/poc/OracleBounds.t.sol::test_R1_PoolManipulationCannotInflateBorrowPower` — passes.

The obvious oracle-manipulation play on a $62k pool is to pump it and over-borrow.
`markBorrow = min(anchor, pool) × (1 − haircut) ≤ anchor` identically. Tested at +0.25%, +0.50%,
+0.95%, +10%, +100%, +900% and at an absurd tick: the mark never moved above the anchor at any of them,
and the last four were rejected outright as `UNTRUSTED_DIVERGENT` before they could even be read. The
`min` leg is doing real work — the pool can only ever *lower* borrowing power, never raise it.

### 2. Deflating `markLiquidate` by dumping the pool to force a liquidation — REFUTED

**PoC:** `audit/poc/OracleBounds.t.sol::test_R2_PoolManipulationCannotDeflateTheSeizureMark` — passes.

Mirror image: `markLiquidate = max(anchor, pool) × (1 + haircut) ≥ anchor`. Tested at −0.25%, −0.95%,
−10%, −50%, −99.5%. The seizure mark never fell below the anchor, so a whale cannot manufacture a
liquidation against a healthy line by selling into the shallow pool. The asymmetric fusion is not
cosmetic; it genuinely picks the defensive side on both of the value-extracting directions.

### 3. Poisoning a thin pool during a regular session — REFUTED

**PoC:** `audit/poc/OracleBounds.t.sol::test_R3_ThinPoolIsIgnoredWhileTheSessionIsOpen` — passes.

Drop the pool's USDC balance below `minPoolLiquidityUsd` and set an absurd tick. While a session is
running the oracle stays `TRUSTED` and the mark collapses cleanly onto the anchor — a thin pool is
treated as uninformative rather than as a price. The `!poolUsable && !sessionOpen` ordering at
`AftermarketOracle.sol:371` is correct.

### 4. Blocking liquidation with `UNTRUSTED_THIN` — REFUTED

Draining the pool's USDC below the floor produces `UNTRUSTED_THIN` only when the session is closed, and
`liquidate` already requires `calendar.isOpen(block.timestamp)`. There is no state where THIN blocks a
seizure that would otherwise have been legal. (It does block `flag` overnight, but a keeper can simply
flag in the morning.) A-02 had to go through `DIVERGENT`/`HALTED` instead.

### 5. Bricking the whole protocol through the calendar — REFUTED

`AftermarketCredit._accrue:745` calls `calendar.session()` unguarded, and
`AftermarketVault.totalAssets:74` reaches it transitively, so a reverting calendar would freeze
`repay`, `depositCollateral`, `withdrawCollateral` **and every LP withdrawal**. The oracle wraps its
calendar reads in `staticcall`-with-fallback; the credit engine does not.

The calendar probe hammered this: **108,112 probes** (daily from 2026-01-01 to 2100-01-01, four per
day, each exercising `sessionAt` + `closedFor` + `nextOpen` + `isOpen` ≈ 432k calls), plus 27,792
hourly probes across 2025-12→2029-02, plus three 20,000-run fuzz campaigns over `[1e9, 4e9]`,
`[864000, 4e9]` and the `block.timestamp` path. **Zero reverts.** `CalendarScanExhausted` is
unreachable because an unseeded weekday is always a trading day, so the ten-day scan always terminates;
`TimestampTooEarly` fires only below 864,000 (binary-searched to the second: last reverting timestamp
863,999, first accepted 864,000). Neither is reachable from `block.timestamp`.

This is a clean negative result, but it is worth recording that it holds *by accident of the default*:
the reason the scan always terminates is precisely the same defaulting behaviour that causes A-06. If
the flag table were ever extended in a way that could mark ten consecutive days as holidays, the
unguarded `calendar.session()` call in `_accrue` would become a protocol-wide freeze including
repayment. The calendar reads in `AftermarketCredit` should be made as defensive as the ones in
`AftermarketOracle`.

### 6. ERC-4626 first-depositor / donation inflation on the vault — REFUTED

`AftermarketVault._decimalsOffset()` returns 6 (`:83`), giving OZ v5's virtual `1e6` shares against
`1` virtual asset. Worked the arithmetic: an attacker who mints 1 wei of shares and donates $10,000
ends up owning `1e6` of `3e6` shares against $20,000 of assets — they get back ~$6,666 for a $10,000
outlay and *lose* ~$3,333, while the victim is diluted but not zeroed. The repo's own
`test_firstDepositorInflationAttackFails` covers this and it holds. `totalAssets` (`:74`) is
donation-sensitive, but only in the direction that gifts the pool.

### 7. Donating USDC to the vault to manipulate the interest rate — REFUTED *as a donation*

`AftermarketCredit._totalSupplyAssets:773` reads `usdc.balanceOf(address(vaultContract))` — a raw
balance, so utilisation is donation-manipulable. As a *donation* this is not an attack: the only
reachable direction is downward, and an irrecoverable gift to LPs dwarfs the interest saved. Pushing
utilisation *up* requires either borrowing (needs collateral) or redeeming shares (needs shares).

The reason it matters is not the donation but the *deposit*, and that turned out to be a real finding —
see **A-13**. Because the rate is sampled once and applied retroactively, and because the vault does
not accrue before changing its own liquidity, the manipulation only has to hold for one block and the
capital comes straight back. The initial "no attack" conclusion here was wrong for that reason, and it
is a good example of why the exploit-chain lens matters: the manipulable value was correctly
identified, but the question "is there a downstream payout that clears before the value is
re-validated?" was not asked until later.

### 8. Withdrawing collateral out of an *underwater* flagged line — REFUTED (but see A-15)

`withdrawCollateral` (`:377`) does not check `flaggedAt`, which looked like a way to strip an insolvent
line. It is not: `setAsset` enforces
`advanceClosedBps ≤ advanceOpenBps ≤ liqThresholdOpenBps ≤ liqThresholdClosedBps`, and the oracle
enforces `markBorrow ≤ markLiquidate`, so `_borrowPower ≤ _seizureThreshold` in every session. A line
that is *currently* underwater has `debt > threshold ≥ power`, so the `debt > power` check at `:391`
always fires. The two guards are consistent and the seizable collateral cannot be pulled out.

What the same missing check *does* enable is different and is written up as **A-15**: a line that was
flagged and has since *recovered* can be stripped while keeping an already-expired grace clock, so the
notice period is silently voided the next time it goes unhealthy. The refutation above is about the
underwater case only.

### 9. Self-flagging at a favourable moment to lock in a longer grace — REFUTED

`flag` is permissionless and `AlreadyFlagged` prevents a second flag, so a borrower can pre-empt a
keeper. But `graceUntil` is `max(now + 1h, nextOpen + 30m)` regardless of who calls it, and the only
regime where the two differ is a flag placed between 08:30 and 09:30 ET (where the one-hour floor
wins). A borrower gains nothing. The genuinely asymmetric fact is the *keeper*-side one: flagging
during PRE (04:00–09:30 ET) yields a **same-day** 10:00 liquidation window, whereas flagging during
REGULAR always defers to the next day. Keepers should flag pre-market whenever a line is unhealthy at
closed parameters — that is an operational recommendation, not a bug, and it is precisely the door that
A-01 closes for lines inside the 80.00-85.85% band.

### 10. Reentrancy through the swap adapter and the ERC-4626 hooks — REFUTED as material

`AftermarketCredit` uses `ReentrancyGuardTransient` on `depositCollateral`, `withdrawCollateral`,
`draw`, `repay`, `repayOnBehalf`, `liquidate` and `sweepYield`; `AftermarketVault` guards
`deposit`/`mint`/`withdraw`/`redeem`/`lend`/`settle`. `flag`, `cure`, `accrue`, `openLine` and
`setAutoRepay` are *not* guarded, and a malicious swap adapter (owner-settable, and the contract itself
calls it "the only untrusted contract in the system") could reach `flag` mid-`sweepYield`, at a moment
when the collateral slice has already been removed but the debt has not yet been reduced. The result is
that the borrower gets flagged and must `cure` — griefing, not theft, and it requires a hostile owner
or a hostile adapter, at which point the adapter can simply not swap. `_swapForUsdc` (`:708-714`) is
also correct about the thing that matters: the allowance is opened for exactly `amountIn` and closed
immediately, and the output is re-checked locally rather than trusting the venue.

CEI ordering was checked on every value-moving path and is correct throughout: `depositCollateral`
writes before `transferFrom` (`:358-366`), `withdrawCollateral` removes before `transfer`
(`:386-396`), `draw` books debt before `vault.lend` (`:419-430`), `liquidate` burns debt before
pulling USDC and before transferring collateral (`:547-565`), `_repayFrom` burns before pulling
(`:1013-1027`).

### 11. Arbitrary-call / approval-drain surface — REFUTED (there isn't one)

`ISwapAdapter` is deliberately a single fixed shape — sell exactly `amountIn` of `tokenIn` for at least
`minOut` — with no caller-supplied target, calldata or route. `AerodromeSwapAdapter` pulls from
`msg.sender` rather than trusting a pre-transfer, approves the router for exactly `amountIn`, and the
only owner-settable parameter is a tick spacing, which can cause a revert but never a bad fill. The
Li.Fi / Socket / Dexible class does not apply. The engine's one standing approval
(`usdc.forceApprove(vault, max)` at `:211`) points at a contract whose only USDC-moving functions are
`msg.sender == credit`-gated.

### 12. Compliance gate trapping a user — REFUTED, the claimed property holds

**PoC:** `audit/poc/BasketVeto.t.sol::test_03_TheVetoDoesNotTrapTheBorrower` — passes.

Traced every exit path. `repay` and `repayOnBehalf` (`:441`, `:451`) call neither
`eligibility.requireEligible` nor any oracle. `withdrawCollateral` (`:377`) is never gated on
eligibility and reads a mark only when `debt != 0` (`:388-392`). So a user whose attestation lapsed, or
whose jurisdiction became restricted, or who is in a total oracle outage, can always repay in full and
then withdraw everything. The PoC does exactly that with every oracle in the basket halted. The repo's
own `test_Safety_LapsedAttestationBlocksEntryButNotExit` and `test_oracleOutage_*` cover the same
ground and hold.

The one real limitation, which is intentional and documented but worth surfacing to users: a borrower
who loses eligibility cannot `depositCollateral` any more, so the only way to cure a position is to
repay USDC — they cannot top up collateral even though doing so would reduce risk.

### 13. `RegSGate` hostile-source escalation — REFUTED

The gate's defensive posture is genuinely strong. `check` is total, every external read is a gas-capped
`staticcall` with an exact `returndatasize` check (`:345-356`) so a return bomb is harmless, the
registry's answer is consumed word-by-word rather than `abi.decode`'d so dirty data degrades to
"unproven", and a valid Coinbase country attestation is conclusive so the fallback registry cannot
launder a US person. `_toCountryCode` uppercases before comparing, closing the lowercase bypass. US
cannot be un-restricted. All of this is already covered by `test_Hostile_*` and holds.

### 14. Beating the cure loop from inside the trap band — REFUTED, exhaustively

This one was an attempt to *break my own finding*, run by an independent agent with no access to this
reasoning. It swept all **672 consecutive 15-minute slots** of a full week (Mon 2026-03-02 →
Mon 2026-03-09, DST transition included), on a monotone clock with the feed refreshed on every
regular session, and asked at each one: is there any instant at which a keeper can flag an in-band
line such that the whole grace period runs inside a single regular session?

```
slots swept                 : 672
oracle reverting            : 126
flaggable slots             : 134   (all REGULAR)
curable slots               : 412   (none REGULAR)
both flaggable and curable  : 0
flags with NO cure window   : 0     <- the refutation criterion
```

Flag and cure are exact complements. Also refuted: no same-block escape at the closing bell
(`liquidate` fails `GraceNotExpired` at 15:59:59 and `MarketClosed` at 16:00:00, so ordering is
irrelevant); no immediate re-flag after a cure; and thin-pool griefing does not close the window
because the oracle counts POST as session-open. The only thing that *does* work is spending real money
to hold the pool divergent overnight (see A-01's severity section), which is why the finding is Medium
rather than High rather than why it is invalid.

### 15. Share-accounting drift in the debt ledger — REFUTED

The Morpho-style virtual shares (`VIRTUAL_SHARES = 1e6`, `VIRTUAL_ASSETS = 1`, `:66-67`) with
`_toSharesUp` on borrow and `_toAssetsUp` on read place every rounding step against the borrower. The
repo's existing invariant suite (`invariant_debtSharesSumToTheTotal`,
`invariant_vaultIsNeverInsolvent`, `invariant_vaultAccountingIsClosed`,
`invariant_debtOnlyFallsOnRepayment`) ran 128,000 calls per invariant at 256 runs during the baseline
and holds.

A separate campaign specifically targeting the ledger — 40 randomised draw / repay / warp steps across
5,000 seeds, asserting after **every** step that `totalDebtShares == Σ line shares` exactly, that
`Σ debtOf ≥ totalDebtAssets`, and the strict form `totalDebtShares ≤ 1e6 × totalDebtAssets` (which is
what stops `_burnDebt`'s `td - repaidAssets` at `:1000` from underflowing on a final full repay, and
which survives `_realizeBadDebt`'s rounded-*up* residual at `:1034`) — found no drift. Splitting a
repayment into `repay(debt-1)` then `repay(max)` costs the borrower **exactly** the same as
`repay(max)` in one call. 5,000 one-wei repayments burn shares 1 wei *slower* than the assets removed,
i.e. in the protocol's favour, leave no stranded dust, and do not move any other borrower's debt. The
share model is correct.

Note that A-12 and A-13 are **not** share-math bugs — the arithmetic is right; the problems are that
the write-off is gated on the wrong condition, and that the rate is sampled at the wrong time.

---

# What the existing test suite does not cover

The suite is unusually good — 177 tests, four stateful invariants, hostile-source fuzzing on the
compliance gate, a differential table over all 730 days of 2026–2027, and exact per-second session
boundary tests. The gaps that let A-01 through A-03 survive it are specific and worth naming:

1. **`test/AftermarketCredit.t.sol` never uses the real `TradingCalendar`.** It uses `StubCalendar`,
   whose `nextOpen` is a single value set once at deployment and whose session is set by hand. That
   makes multi-day flag/cure cycles inexpressible, which is exactly why A-01 is invisible: no test ever
   advances the clock across a real 16:00 close and back through a real 09:30 open with the real
   `nextOpen` semantics. A single test that runs the credit engine on the real calendar for a week
   would have caught it.
2. **No test combines a healthy oracle and an unhealthy oracle in one basket.** The `test_oracleOutage_*`
   family drives a single asset's oracle into a revert and asserts the freeze is total — which
   *confirms* the intended behaviour but never asks what happens when only one of eight assets is bad.
   A-02 lives entirely in that gap.
3. **No test exercises a multiplier change of split magnitude.** `sweepYield` is tested at dividend
   scale only. A test asserting `sold <= someCap × balance` would have caught A-03.
4. **No test crosses 2028.** `test_EveryTradingDayIn2026And2027` is exhaustive within the seeded range
   and stops there; nothing asserts what the contract does on the first unseeded holiday.
5. **No adversarial test on the pool side.** The oracle tests drive `MockCLPool` to express states, but
   never as an attacker choosing a tick to achieve an outcome downstream in the credit engine. A-04,
   A-05 and A-07 all need that framing.
6. **No test of `setAsset` wiring** (A-08) — `test_setAsset_validatesThePolicyShape` covers the numeric
   policy shape thoroughly and the oracle address not at all.
7. **The invariant handler does not call `flag`, `cure`, `liquidate` or `sweepYield`.** Its selectors
   are `depositCollateral`, `draw`, `passTime`, `redeem`, `repay`, `supply`, `withdrawCollateral`. The
   entire seizure and self-repayment surface is outside the stateful campaign — which is exactly where
   A-12 (`_realizeBadDebt` unreachable) and A-14 (checkpoint reset) live.
8. **`test_badDebt_isRealizedAndWrittenDown` uses a single-asset line at a price where the last raw
   unit happens to clear the seizure floor.** It therefore proves the write-off *can* happen without
   ever testing whether it *does* in the general case. A second collateral leg, or a lower price on the
   first one, flips the result (A-12).
9. **Nothing asserts that the vault accrues before changing its own liquidity.**
   `test_sharePriceRisesWithAccruedInterest` and `testFuzz_depositThenRedeemNeverMintsValue` both hold,
   because they never combine a deposit with an accrual over a long idle window (A-13).
10. **`sweepYield` is never tested with a DECREASING multiplier**, nor with a `multiplier()` that
   reverts mid-flow, so both A-14 branches are untested.

---

# Threat model

### What the protocol trusts, and must

* **Chainlink.** The anchor is the root of every mark. `markBorrow ≤ anchor ≤ markLiquidate` by
  construction, so a wrong anchor is a wrong protocol — there is no second opinion that can override
  it, only a pool that can veto it. A compromised or mis-specified Coinbase equity feed is unmitigated.
* **The B20 issuer.** Coinbase can pause transfers (which halts the oracle), move the multiplier
  (which drives A-03), and mint or burn. The protocol treats a pause as a halt, which is correct, and
  treats a multiplier move as a distribution, which is A-03.
* **The owner key.** `setAsset` can repoint any asset's oracle with no timelock (A-08), `setRateModel`
  can install an arbitrary rate curve, `setEligibility` can install an arbitrary gate, `setSwapAdapter`
  can install an arbitrary venue. `Ownable2Step` is used everywhere, which prevents a fat-fingered
  handover, but there is no timelock on any of it. A malicious owner can drain the protocol —
  by installing an oracle that marks collateral at zero and liquidating everyone, or an adapter that
  keeps the swap proceeds — and, per A-16, can also *brick repayment* with an unbounded rate model,
  which is the one thing the design promises is impossible. **This should be a timelocked multisig on
  day one, and the docs should say so.**
* **The trading calendar's table** for 2026–2027, which the probe verified is exactly right, and after
  which it silently is not (A-06).
* **The Aerodrome pool as a *veto*, not as a price.** The `min`/`max` fusion means the pool can lower
  borrowing power and raise the seizure mark but never the reverse. That is the right shape. What it
  cannot do is stop the pool being used to *block* the oracle entirely (A-02).

### Out of scope by design

* Chainlink feed correctness and liveness.
* Coinbase's identity, sanctions and Reg-S enforcement at B20 mint/redeem. `RegSGate` closes the
  per-transaction jurisdiction gap on the way *in*; it does not attempt to police secondary transfer
  (and A-09 notes where that shows).
* Aerodrome Slipstream's own correctness, and the Slipstream router's factory binding (which the
  adapter documents at length and verifies by construction argument, not on-chain assertion).
* Morpho Blue. The oracle implements `IOracle` and the revert-as-safety argument leans on Morpho's
  audited behaviour, but no Morpho market is deployed in this scope.
* Off-chain keeper liveness. Nothing forces anyone to call `flag`, `accrue` or `sweepYield`.

### What the protocol explicitly does not defend against

* **A price gap through the closed threshold.** This is the core, acknowledged risk: the protocol
  refuses to seize while the market is shut, so an overnight or weekend gap larger than the remaining
  cushion becomes bad debt. The gap haircut and the closed-session interest premium are the price
  charged for it, not a hedge against it. A-01 makes this materially worse by ensuring the position
  arrives at the gap *without having been delevered*.
* **A halted or unpriceable collateral asset.** The design is "no defensible price means no action" in
  both directions. That protects the borrower and it strands the lender (A-02).
* **Liquidity risk for LPs.** `maxWithdraw` clamps to idle USDC. There is no queue, no priority and no
  guarantee of exit; a fully-utilised market is a locked market.
* **Sub-cent precision.** Every rounding step is deliberately against the borrower and there is dust
  everywhere by construction.

### Scale, and what it does to these numbers

`script/config/base.json` lists six B20 names (NVDAc, AAPLc, METAc, GOOGLc, TSLAc, AMZNc) at
`capWholeTokens: 100` each. At current prices that is roughly $100k–$200k of collateral capacity
across the whole protocol at launch, and it bounds the absolute dollar impact of every finding here to
that order of magnitude on day one. That is a sensible launch posture and it should be said plainly.

It does not change the severities, for three reasons. The caps are a parameter the owner raises with
one transaction, not a property of the code. Several of the findings (A-01, A-02, A-12, A-13) get
*cheaper* per dollar as the protocol grows, because the attacker's cost is a fixed number of
transactions while the payoff scales with the position. And A-03, A-06 and A-14 are triggered by
external events — a corporate action, a date — whose probability is entirely independent of TVL.

### The honest residual risk a lender in this vault is taking

1. **You are long the gap.** You have explicitly given up the right to seize collateral overnight,
   over the weekend and over every holiday, in exchange for a session premium. With A-01 unfixed you
   have also given up the right to seize it during trading hours for any position sitting in the
   80.00-85.85% LTV band (wider over a long weekend). That is the single largest risk in the vault and
   it is a design choice, not a
   bug — but A-01 turns a bounded window into an unbounded one and must be fixed before mainnet.
2. **You are exposed to the shallowest pool in the basket, not the deepest.** Because health is an AND
   over every posted asset's oracle, the risk engine's availability is set by the worst asset any
   borrower chooses to hold one wei of. On Base today that is a ~$61k pool.
3. **Bad debt is, in practice, never written down at all** (A-12). The write-off fires only when a
   line's `postedAssets` list is empty, and `_quoteSeizure` reverts on any leg small enough that the
   liquidator's cost floors to zero — which ordinary liquidation of a fallen asset produces by itself.
   Until it fires, `totalDebtAssets` — and therefore `AftermarketVault.totalAssets` and the share
   price — keeps counting *and compounding interest on* debt that is provably unrecoverable. Whoever
   redeems first is paid more than they put in, out of the real USDC belonging to whoever redeems
   last. This is the mechanism by which A-01, A-02 and A-12 convert into an actual loss for a specific,
   identifiable set of LPs — the slow ones — and there is no keeper-callable "socialise bad debt"
   entry point to shorten the window.
4. **You are trusting an un-timelocked owner key** with the ability to repoint any oracle, any rate
   model, any compliance gate and the swap venue.
5. **From 2028-01-01 the calendar is wrong** and there is no in-place fix (A-06).
6. **The self-repaying feature has not run in production even once.** Every live B20 multiplier is
   still exactly `1e18`; `sweepYield` is a no-op until an issuer calls `updateMultiplier`. The first
   real corporate action will be the first execution, and A-03 says what happens if that action is a
   split.

---

# Remediation

Every finding above has been worked through. Fifteen are fixed in code, one is mitigated with the
residual risk written down, and two behaviours are accepted by design and documented in the
contracts themselves rather than coded around. Nothing in the findings text above was changed; the
`Status:` line under each heading is the only addition.

A-09 moved from the accepted column to the fixed column on 2026-09-07, after the contest's
eligibility rule made "the Reg-S property covers origination only" indefensible for a path the
protocol itself operates. Its original status line is preserved above the new one rather than
rewritten.

The audit's own PoCs under `audit/poc/` were rewritten in place. They previously passed by
*reproducing* each bug; they now pass by *proving it is gone*, against the same real contracts at the
same real deploy parameters. Where a finding is accepted rather than fixed, the PoC still reproduces
the behaviour and says so in its name and NatSpec.

## Verification

| Suite | Command | Result |
|---|---|---|
| Repository suite | `forge test` | **273 passed, 0 failed, 1 skipped** (was 240/0/1) |
| PoCs | `FOUNDRY_TEST=audit/poc forge test` | **43 passed, 0 failed** (was 35, all reproducing) |
| Mainnet fork | `BASE_RPC_URL=... base-forge test --match-path 'test/fork/*'` | **8 passed, 0 failed** |

Contract sizes at `optimizer_runs = 200`, all far inside the 24,576-byte limit:

| Contract | Runtime bytes | Margin |
|---|---|---|
| AftermarketCredit | 21,357 | 3,219 |
| AftermarketOracleFactory | 13,856 | 10,720 |
| AftermarketLens | 11,027 | 13,549 |
| AutoRepayer | 11,144 | 13,432 |
| AftermarketOracle | 8,239 | 16,337 |
| RegSGate | 6,667 | 17,909 |
| AftermarketVault | 6,253 | 18,323 |
| AerodromeSwapAdapter | 2,513 | 22,063 |
| AttesterRegistry | 2,494 | 22,082 |
| TradingCalendar | 2,136 | 22,440 |
| SessionRateModel | 2,132 | 22,444 |

## The three High findings

### A-12 — bad debt is now written off

Three changes, because the finding is three problems stacked.

1. **`_quoteSeizure` rounds the capped cost up.** When the borrower's balance caps a seizure the
   liquidator's payment is re-derived from the balance, and that division rounded *down*. Below
   `(BPS + bonus) / mark` raw units it floored to zero and the whole call reverted `ZeroAmount`, so
   the leg could never be removed. It is now `Math.mulDiv(..., Rounding.Ceil)` in both steps and
   clamped to what the liquidator offered. Rounding up is also the correct direction on its own
   merits: it is the liquidator's payment. Any non-zero balance is now clearable for one unit of the
   loan token.
2. **The write-off fires on value, not on array length.** `liquidate` used to call `_realizeBadDebt`
   only when `postedAssets[user].length == 0`. It now calls it when the remaining basket supports
   less than `1 / BAD_DEBT_DUST_DIVISOR` (1 bp) of the line's own debt — which includes the empty
   case — and never while any leg is unpriceable.
3. **`realizeBadDebt(address)` is new and permissionless.** It covers the residue a liquidator would
   never bother with, because their whole profit on it is orders of magnitude below the gas. It
   inherits every one of `liquidate`'s guarantees — flagged, grace expired, market open, every leg
   priceable — so nothing is ever written off without notice or on a price the protocol cannot
   defend. The borrower keeps the residual collateral; once the debt is gone it is unambiguously
   theirs.

Evidence: `audit/poc/Accounting.t.sol::test_A12a/b/c/d`. `test_A12a` runs the audit's own ordinary
cascade and it now drains every leg and recognises the loss in the same call; `test_A12b` shows the
race between suppliers is gone — both redeem at the same, honest share price. Regression tests in the
main suite: `test_regression_A12_*` in `test/AftermarketCredit.t.sol`.

**New risk introduced.** `realizeBadDebt` can be called on a line that still holds up to 1 bp of its
debt in collateral, so in principle a griefer can deny a liquidator the bonus on that residue. At the
shipped 700 bps bonus that is at most 0.07 bp of the debt, and the alternative — carrying the debt
and compounding interest on it — is strictly worse for every supplier.

### A-13 — accrual ordering

`AftermarketVault.deposit`, `mint`, `withdraw` and `redeem` now call `credit.accrue()` before they
move a single USDC, which is exactly what Morpho Blue's `supply` and `withdraw` do and the reason the
sample-once-apply-backwards rate model is sound there. `IAftermarketCredit` gained `accrue()` so the
vault can call it through the interface — an additive change, safe for the SDK.

The A-13c half — `lastAccrual` written before the `interest == 0` bail-out, so every second whose
interest floored to zero was destroyed — is fixed by **carrying the remainder, not by holding the
clock open**. `_accrue` now closes the window on every call and keeps the sub-unit interest in a new
`accrualRemainder` (WAD scale, packed alongside `lastAccrual`, so no extra storage slot).

The obvious one-line version of that fix — return early without advancing `lastAccrual` — is wrong,
and worse than the bug it fixes. It breaks the invariant the whole model rests on: that `accrue()`
closes the window. A market parked at a dust total debt (one wei holds it open for decades at the
shipped floor rate) would keep the window open indefinitely, and the next borrower's freshly-drawn
principal would then be charged for the whole of it — retroactively, and after `draw`'s own solvency
check had already passed on the un-accrued figure. Carrying the remainder gets the same result with
the invariant intact.

Evidence: `audit/poc/Accounting.t.sol::test_A13a/b/c/d/e` — the deposit-accrue-redeem round trip and
the capital-free backrun now both produce *exactly* the honest debt, `test_A13c` shows per-block
accrual now charges *exactly* what a single call charges (635 wei either way, where the original
destroyed all of it), and `test_A13e` pins the dust-debt case.
`test/AftermarketVault.t.sol::test_everyLiquidityChangeAccruesBeforeItMovesMoney` pins the ordering
directly by recording the vault's idle balance at the moment of each accrual. Regression tests:
`test_regression_A13_*`.

**Residual.** Accruing every block charges marginally *more* than accruing once (472 wei on $33k of
interest in `test_A13d`) — a thousand small compoundings against one large one. The direction costs
the protocol nothing and it is inherent to any discretely-compounding model. `_totalSupplyAssets`
still reads `usdc.balanceOf(vault)`, and a bare donation is *not* an entry point, so unlike a deposit
it does not close the window first: a donation landing immediately before an `accrue()` does reprice
the open window. What makes that uneconomic is the donation itself — it is irrecoverable, and
suppressing utilisation enough to matter means gifting the suppliers a multiple of the interest
saved. The recoverable version, a one-block deposit, is the one that had to be closed.

### A-02 — the basket veto

This is the subtle one, and the reasoning is written into `AftermarketCredit` above `_borrowPower`
rather than only here.

An asset whose oracle refuses to mark now contributes **nothing** to either side of the risk
calculation instead of aborting it. The rule that justifies it: a price the protocol would refuse to
seize on is also a price it must refuse to lend on. Crediting an unpriceable asset let it do both
jobs at once — support the debt that made a seizure necessary, and then block the seizure.

Valuing it at zero on the *borrowing* side is plainly conservative. On the *seizure* side it is not,
on its own: it lowers the threshold, so by itself it would make deflating one leg a way to
force-liquidate a healthy line, which is strictly worse than the veto it replaces. What makes it safe
is the asymmetry, not the valuation — `_quoteSeizure` still reads `markLiquidate` directly and still
reverts, so the unpriceable asset can never be taken by anybody at any price. The exposure a borrower
carries is therefore bounded to losing *priceable* collateral at a *defensible* price, behind the
full flag-and-grace notice period, with `repay`, `depositCollateral` and `cure` all still open to
them and none of them reading an oracle for the dark leg.

Two guards sit on top of it:

- **The public views still refuse a partial basket.** `borrowPower`, `seizureThreshold`, `riskOf` and
  `healthFactorStrict` revert `UnpricedCollateral`, so `positionOf().priced` keeps meaning what a
  keeper, the Lens, `AutoRepayer` and the UI already think it means. Only the engine's own internal
  decisions use the partial valuation.
- **A basket in which nothing at all can be priced is an outage, not insolvency.** That case also
  produces a threshold of zero, but for the vacuous reason that nothing was counted, so `flag` and
  `liquidate` reject it outright (`_actionableThreshold`) rather than letting a keeper start a grace
  clock against every borrower at once.

Evidence: `audit/poc/BasketVeto.t.sol` — `test_01` (attacker-driven divergence) and `test_02` (issuer
pause) now prove the seizure proceeds and that the dust asset itself stays untouchable; `test_04`
pins the total-outage guard; `test_03` confirms the borrower still exits through it. On mainnet,
`test/fork/LiveB20.t.sol::test_amznDivergenceFreezesRiskAndSeizureButNotTheCure` was rewritten and
now asserts, against the live AMZNc divergence, that thousands of dollars of unpriceable AMZNc buy
exactly zero borrowing power, that quoting a seizure of it still reverts, and that the flag refuses
on the merits rather than on a veto. Regression tests: `test_regression_A02_*`.

**New risk introduced, stated plainly.** An attacker who can hold a listed asset's pool out of its
divergence band for a whole grace period can lower the seizure threshold of every line holding that
asset and force a seizure of their *other*, priceable collateral at a 700 bps bonus. That is the
cost of removing the veto. It is bounded by four things: the borrower gets the full flag-and-grace
notice and can cure by repaying or topping up; the attacker must sustain a one-sided TWAP push
against arbitrageurs for the whole window, in a pool the A-07 fix now measures honestly; the seizure
is priced at a mark the protocol will defend; and the close factor caps each call at half the debt.
The alternative was an unbounded, silent, permanent loss for every supplier in the vault, arranged
for the cost of one wei.

## A-06 — the calendar horizon

`TradingCalendar` now publishes `SEEDED_FROM_DAY` (2025-12-22) and `SEEDED_UNTIL_DAY` (2027-12-31)
and fails closed outside them: `_classify` returns `CLOSED_HOLIDAY`, `isOpen` is false, and the two
day scans return **zero** rather than guessing. `AftermarketCredit.flag` rejects a zero `nextOpen`
with `CalendarHorizon`, because a grace deadline cannot be promised against a bell the calendar does
not know about.

The lower bound is new: the table now also carries the December 2025 run-in (Christmas Eve's early
close and Christmas Day), so a backward scan from the first days of January lands on a real previous
close instead of falling off the start of the range.

`draw` rejects a zero `nextOpen` too, and that half matters as much as the seizure half. Failing
closed only on seizure would leave the protocol a one-way ratchet past the horizon: the oracle still
marks (a permanent `CLOSED_HOLIDAY` is a valid session with a 100-hour staleness budget and a capped
haircut), so new debt could still be created — against collateral that can never be flagged, cured or
seized, at frozen closed-market risk parameters, with no on-chain remedy. No opening bell the
calendar will name means no session in which a position could ever be defended, so no new position.

Past the horizon the protocol otherwise degrades the way it degrades on any other day it cannot
price. `session()` and `isOpen()` stay total, so `_accrue`, `totalAssets`, `repay`,
`depositCollateral` and LP withdrawals are untouched. The scans returning zero make `closedFor`
saturate, which pins the gap haircut at its cap.

Extending the table is still a redeployment — the contract has no owner by design — but the sunset is
now a published constant instead of a silent drift, and the failure at it is a safe freeze instead of
a 13:00 half day silently promoted back into a full trading session with the open liquidation
threshold and a zero haircut applied to a dead tape.

Evidence: `audit/poc/CalendarDrift.t.sol` — the 2028-11-24 half day that the original PoC seized
collateral on now reads as closed and `liquidate` reverts `MarketClosed`; `test_03` pins the horizon
itself. `test/TradingCalendar.t.sol::test_HorizonFailsClosed` is the same property in the main suite,
`test_regression_A06_drawIsRefusedPastTheCalendarHorizon` pins the origination half, and the 502-day
differential digest over 2026–2027 is unchanged.

## The Mediums and Lows

**A-01 — the nightly cure loop. Fixed.** `cure` now runs **only while the US market is open** and is
measured at **open-session parameters**. That removes both halves of the evening step in one move:
the gap haircut on `markLiquidate` is zero by construction during a regular session, and
`liqThresholdOpenBps` is the factor that applies. A line parked in the 80–86% band is therefore
unhealthy whenever curing is possible at all. `LineHealthy` was replaced by `CureIncomplete` on that
path, which also fixes the inverted error name in A-11.2.

What the shape buys beyond closing the loop is that **cure and seizure become exact complements**.
`liquidate` seizes only while the market is open and only when `debt > threshold`; `cure` clears only
while the market is open and only when `debt <= threshold`, both at the same parameters. So in any
session a seizure could happen in, every line is exactly one of curable or seizable — never both,
never neither. A borrower who recovers can always clear the flag before the next adverse move, so a
flag can never outlive the condition that raised it and nobody is seized on an expired clock left
over from an episode that has passed. A borrower who has not recovered keeps their flag and their
notice, which is the point.

The first attempt at this fix tested `cure` against `_borrowPower` (the advance rate) instead. It
closed the loop just as well, but it broke the complement: every line between its advance rate and
its seizure threshold — which at the shipped parameters is LTV 65–80%, i.e. most healthy borrowers —
would have been left permanently flagged with an already-expired grace clock, and therefore seizable
with no notice the moment the price crossed 80%. That is A-15 re-introduced on the partial-repay
path, and it is why the open-threshold form is the one shipped.

Evidence: `audit/poc/GraceLoop.t.sol::test_01` (the evening cure is refused as `MarketClosed`, the
morning cure as `CureIncomplete`, and the seizure lands next morning), `test_01b` (a real cure, by
repaying or by topping up, still works), `test_02` (the weekend variant). Regression test:
`test_regression_A01_cureAndSeizureAreExactComplements`.

**Behaviour change worth stating:** curing is now a market-hours action. A borrower who fixes their
line on a Saturday cannot clear the flag until Monday's bell, and `draw` stays blocked until they do.
Nothing can be seized in that window either — `liquidate` has always required an open market — and
the grace deadline is always at least thirty minutes past an opening bell, so there is always a real
session in which to cure before the deadline.

**A-03 — corporate actions. Mitigated; branches B and C addressed separately.** `sweepYield` refuses
any slice above `MAX_SWEEP_BPS` (1000 bps) of the balance. A 10:1 split asks it to sell 90% of the
position on an event that moved nobody's wealth; no real distribution is close to that, so the cap
turns a catastrophic misfire into a revert an operator can see. Branch C — a routine reverse split
falling outside `minMultiplier` and halting the asset's oracle permanently — was a configuration
error and is fixed in `script/config/*.json`, which now ship `[0.01e18, 1000e18]`; the oracle's
NatSpec explains why a static range is a garbage filter and never a corporate-action detector.
Branch B — whether the Chainlink feed quotes the share or the raw wrapper — is not determinable from
the code and is left as a recorded risk: the oracle's response (refusing to quote) is the safe one,
and the remedy is deploying a rescaled oracle and calling `setAsset`.
Evidence: `audit/poc/SplitSweep.t.sol::test_01`, `test_02`, `test_05`; `test_00` shows a real 1%
dividend still sweeps exactly as before.

**A-04 — the pool raising the seizure threshold. Fixed.** `markLiquidate` takes the pool leg of the
`max` only while the anchor is *not itself printing*, i.e. outside the regular session. That is the
only case the `max` leg was ever for: a frozen reference that is too high, with the pool as the sole
live witness. The `min` leg is untouched, so a pool below the anchor still lowers borrowing power in
every session.
Evidence: `audit/poc/OracleBounds.t.sol::test_A04` and `test_A04b`.

**A-05 — the sweep slippage floor. Fixed.** `sweepYield` runs only while the US market is open, where
the gap haircut is zero by construction and the pool is at its deepest — which is also simply the
right time to send a market order in an equity. The residual tolerance is the divergence band plus
the configured budget, and the pool leg of that is the executable price rather than a discount.
Evidence: `audit/poc/OracleBounds.t.sol::test_A05`.
*Behaviour change worth stating:* self-repaying collateral now only runs during US market hours. The
mainnet fork test was updated to warp to the next opening bell for that reason.

**A-07 — pool depth. Fixed.** Depth is now the harmonic mean of the pool's *in-range* liquidity over
the same TWAP window whose price is being trusted, recovered from the
`secondsPerLiquidityCumulativeX128` pair `observe` already returns and the contract previously
discarded, converted at the mean tick to the loan-side virtual reserve, and capped by the raw
balance. Liquidity that was never in range during the window never enters the average, so a bare
transfer or an out-of-range single-sided position no longer buys corroboration.
Evidence: `audit/poc/OracleBounds.t.sol::test_A07`. Validated against live Base pools:
`test/fork/LiveB20.t.sol::test_peekIsCoherentForEveryConfiguredAsset` and the whole `WeekendReplay`
timeline still pass unchanged.

**A-08 — `setAsset` wiring. Fixed.** `setAsset` asserts `params.oracle.collateralToken() == asset` and
`params.oracle.loanToken() == address(usdc)`. Two staticcalls against the Rho Markets failure mode.

**A-09 — ungated liquidators. Accepted by design, documented.** Gating liquidators on `eligibility`
would shrink the liquidator set to attested non-US persons, and a liquidator set that is too small is
how a position becomes unliquidatable and a solvent protocol an insolvent one. The decision, and the
fact that the Reg-S property this protocol enforces covers *origination* rather than secondary
distribution — the same scope the B20 token itself has — is now stated in `liquidate`'s NatSpec so
nobody has to infer it from the absence of a modifier.

**A-10 — `setSwapAdapter(0)`. Fixed.**

**A-14 — the multiplier checkpoint. Fixed (a) and (c); (b) accepted.** The checkpoint is a
high-water mark of value already accounted for and never moves down on an existing position, so a
multiplier merely returning to where it started is not a dividend. A failed `multiplier()` read now
reports failure instead of substituting WAD, and moves the checkpoint not at all. The mirror case —
a genuine distribution declared *after* a reverse split can never be swept — is the unavoidable
other side of that rule, and is accepted: it costs an opt-in convenience feature for one asset until
the position is closed and reopened, against a fabricated sale of half the position, which is a loss.
Evidence: `audit/poc/Accounting.t.sol::test_A14a/b/c`.

**A-15 — withdrawing while flagged. Fixed.** Surviving `withdrawCollateral`'s post-withdrawal
borrowing-power check is exactly what `cure` demands, so the withdrawal clears the flag. The next
unhealthy moment needs a fresh flag and therefore a fresh, full grace period.
Evidence: `audit/poc/Accounting.t.sol::test_A15`.

**A-16 — unbounded rate parameters. Fixed.** `SessionRateModel` bounds `base + slope1 + slope2` at
`MAX_TOTAL_RATE_PER_SECOND` (~1000% APR, ten times the shipped curve) and every session premium at
`MAX_SESSION_MULTIPLIER`, and `AftermarketCredit._accrue` clamps the rate it applies regardless of
which model is installed. A mis-specified curve can now make credit expensive; it can never brick
`repay`.

**A-17 — the permanently stale windows. Accepted by design, documented.** Left exactly as it is. It
is a freeze rather than an exposure: nothing can be seized and nothing over-borrowed, and `repay` and
`depositCollateral` read no oracle at all, so the borrower's exit is never affected. Widening the PRE
and POST budgets to cover the overnight gap would make those sessions mark collateral against a print
up to seventeen hours old — the exact thing the staleness rule exists to prevent — during sessions
the credit engine already treats as closed, so the only new capability it buys is starting a grace
clock a few hours earlier. The full write-up, including the cost (the one keeper-favourable PRE flag
window is unusable, so every flag defers to the following trading day) and the exact config change
that would reverse it, is in `AftermarketOracle`'s NatSpec. `audit/poc/StaleWindows.t.sol` is
unchanged and still reproduces the behaviour, which is now its purpose.

**A-11 — informational.** The two orphaned NatSpec blocks are gone; `cure` reverts `CureIncomplete`
instead of an inverted `LineHealthy`; `ITradingCalendar` documents `nextOpen` as strictly-after and
notes the zero sentinel; the dead `m0 == 0` branch is gone with the checkpoint rewrite. For (4), the
mark multiplications in `_borrowPower`, `_seizureRisk` and `_quoteSeizure` now use `Math.mulDiv`, so
the 512-bit intermediate is available exactly where an exotic decimals combination could have
overflowed and bricked liquidation for an asset.

## A second pass over the fixes themselves

The remediation was reviewed as adversarially as the original code, on the assumption that a fix is
just new code. Six things came out of it and are folded in above; two are recorded as residual.

**The accrual clock (fixed, see A-13).** The one-line version of the A-13c fix reintroduced a
retroactive-repricing bug in the opposite direction. Replaced with a carried remainder.

**The calendar's origination half (fixed, see A-06).** Failing closed on seizure alone left a
one-way ratchet past the horizon.

**`cure` measured at the advance rate (fixed, see A-01).** It closed the loop but left most healthy
borrowers permanently flagged with an expired clock. Replaced with the open-threshold complement.

**Reentrancy on the unguarded writers (fixed).** `flag`, `cure`, `realizeBadDebt` and `accrue` are
now `nonReentrant`. `sweepYield` hands control to the swap adapter - the only untrusted contract in
the system - at a moment when the collateral slice has been removed and the debt has not yet been
reduced. An adapter reaching `realizeBadDebt` from there could make `_applyProceeds` see a debt of
zero and forward the entire swap proceeds to the borrower instead of the vault.

**A sweep that clears the debt now clears the flag (fixed).** `_applyProceeds` did not do what
`_repayFrom` does, so a sweep that zeroed a flagged line left the flag standing and `draw` blocked.

**An absent multiplier checkpoint is no longer read as a multiplier of zero (fixed).** A first
deposit made while `multiplier()` was not answering left the checkpoint unset; a later sweep then
sized the slice at the *entire* position and reverted `SweepTooLarge` forever. The checkpoint is now
initialised on the next successful read, `sweepYield` refuses an unset one outright, and the blend
uses `Math.mulDiv` so a hostile multiplier cannot revert `depositCollateral`.

**Both `observe` array lengths are validated (fixed).** The depth read consumes the second returned
array, so its length is now checked alongside the first.

**Residual: a dark leg still blocks the write-off.** `realizeBadDebt` and the write-off inside
`liquidate` both refuse while any leg is unpriceable - they must, because an outage must never
trigger a permanent loss on the supplier side. A borrower can therefore hold one wei of an asset
whose oracle is untrusted and delay recognition of their own bad debt, which is the A-12b race
narrowed to an actor who is both the borrower and a large LP and who can hold a listed pool divergent
through every regular session until they exit. It gains an ordinary borrower nothing (the write-off
frees them), only a third party can create the divergence and only the borrower can add to their own
basket, and `maxWithdraw` clamps an LP exit to idle USDC. Left as a stated residual rather than
weakened, because every alternative amounts to writing off a debt against collateral the protocol
cannot price.

**Residual: `_realizeBadDebt` rounds the residual assets up while burning shares exactly**, which
moves `totalDebtShares <= 1e6 * totalDebtAssets` in the unsafe direction - and that inequality is
what stops `_burnDebt`'s final-repay subtraction from underflowing. No reachable break was found
(at exact equality every line's share balance is a multiple of `1e6`, and any accrued interest opens
slack far larger than the ceiling can consume), but the write-off is a new writer of it, so it is now
asserted continuously: `invariant_debtSharesNeverOutrunTheAssetCeiling`.

**Gas.** `liquidate` walks the basket twice now (once to test seizability, once to test whether what
is left is worth taking). Measured at the `MAX_ASSETS` cap in `test_maxAssets_isBounded`: 143k gas of
engine work, plus up to seventeen oracle reads at ~22k each (`test_Gas_PriceAndPeek`), so roughly
520k for the worst basket the protocol allows - an order of magnitude inside a Base block, and the
test now fails if it ever exceeds 3M.

## Interface and configuration changes

The frozen interfaces changed only where a fix required it. All of it is additive except one
documentation correction:

- `src/interfaces/IAftermarketCredit.sol`: added `accrue()` (the vault must be able to close the
  accrual window through the interface) and six errors — `CureIncomplete`, `UnpricedCollateral`,
  `SweepTooLarge`, `OracleAssetMismatch`, `CalendarHorizon`, `LineNotDust`. No existing signature,
  struct or event changed.
- `src/interfaces/ITradingCalendar.sol`: documentation only. `nextOpen` is now documented as
  strictly-after (it always was — A-11.3) and as returning zero when the implementation cannot
  answer. **SDK integrators must treat a zero `nextOpen` or `lastClose` as "unknown", not as a
  timestamp.**
- `src/libraries/Types.sol`: unchanged.

New public surface on `AftermarketCredit`: `realizeBadDebt(address)`, `MAX_SWEEP_BPS`,
`BAD_DEBT_DUST_DIVISOR`. `flag`, `cure`, `realizeBadDebt` and `accrue` became `nonReentrant`, and
`cure` gained a market-open precondition. New internal storage: `accrualRemainder`, packed into the
slot `lastAccrual` already occupies. New public surface on `TradingCalendar`: `SEEDED_FROM_DAY`,
`SEEDED_UNTIL_DAY`. New public surface on `SessionRateModel`: `MAX_TOTAL_RATE_PER_SECOND`,
`MAX_SESSION_MULTIPLIER`.

`script/config/base.json`, `base-sepolia.json` and the operator's working copy at
`deployments/base.json`: `oracle.minMultiplierBps` 5000 → 100 and `oracle.maxMultiplierBps`
1000000 → 10000000 (A-03 branch C). Those two values are hashed into the oracle CREATE2 salt, so
this is a **new oracle set**: `DeployCore` will deploy six fresh oracles at fresh addresses and
`setAsset` will repoint each market at them. Existing positions are unaffected by the repoint itself,
but the migration should be run while the market is open and watched, because `setAsset` has no
timelock.

## Tests that were changed rather than added, and why

None were weakened. Each of these encoded behaviour a fix deliberately changed:

- `test_liquidate_seizureIsCappedByTheUserBalance` — the capped-seizure cost is rounded up now, so
  the expected payment is one unit higher.
- `test_oracleOutage_debtClearingWithdrawStillWorks` and `test_oracleOutage_drawIsFrozen` — both
  still assert the action is frozen, but the revert is now `Undercollateralized(debt, 0)` rather than
  the bubbled oracle error, because unpriceable collateral carries no borrowing power.
- `test_oracleOutage_flagIsFrozen` and `test_oracleOutage_liquidateIsFrozen` — same, with
  `UnpricedCollateral`.
- `test_maxAssets_isBounded` — every listed asset needs its own oracle now that `setAsset` asserts
  the wiring.
- `test_EveryTradingDayIn2026And2027` — walks to the seeded horizon and stops there instead of
  stepping into an unseeded 2028 session. The 502-day digest is unchanged.
- `testFuzz_CalendarInvariants` — bounded to the last seeded open, with the horizon covered by its
  own test.
- `test/fork/LiveB20.t.sol::test_amznDivergenceFreezesRiskAndSeizureButNotTheCure` — rewritten for
  the A-02 semantics, as described above.
- `test/fork/LiveB20.t.sol::test_sweepYield_simulatedMultiplierIncrease` — warps to the next opening
  bell, because the sweep no longer runs while the market is shut. That adds a second clearly
  labelled simulated input: the live Chainlink answer re-issued with a fresh `updatedAt`.
- `test/fork/WeekendReplay.t.sol::_mockTwap` — hands back the pool's *real*
  `secondsPerLiquidityCumulativeX128` pair instead of zeros, since the oracle now inverts it to
  measure depth. Substituting zeros would have simulated a pool with no liquidity rather than a pool
  at a different price.
- `test/mocks/MockOracle.sol` gained `setTokens`, `test/mocks/MockCLPool.sol` gained `setLiquidity`
  and a synthesised seconds-per-liquidity cumulative, and the vault's `MockCredit` gained `accrue()`
  plus two counters used to pin the accrual ordering.

## What was not fixed

- **A-03 branch B.** Which unit the live Coinbase feed quotes is unknowable until the first corporate
  action. The oracle fails closed either way, and the remedy is operational.
- **A-14 (b).** A distribution declared after a reverse split cannot be swept. Fixing it requires the
  contract to distinguish a reverse split from a fall in the multiplier, which the multiplier alone
  cannot express.
- **A-17.** Accepted by design, with the reasoning in the contracts. (A-09 was in this list until
  2026-09-07 and is now fixed; see its status line.)
- **A-12's write-off can still be delayed by an unpriceable leg**, and `_realizeBadDebt`'s rounding
  direction is now pinned by an invariant rather than proved impossible. Both are written up under
  "A second pass over the fixes themselves".
- **The un-timelocked owner key**, which the threat model already names. `setAsset` now validates the
  oracle it installs, which removes the accidental version of the worst case, but a malicious owner
  can still repoint any oracle, rate model or swap venue. The compliance gate is no longer on that
  list: `AftermarketCredit.eligibility` is immutable as of 2026-09-07 and `setEligibility` is gone,
  because a jurisdiction rule an owner key can lift in one transaction is not a rule. The rest should
  be a timelocked multisig on day one, and the docs should say so.
- **The calendar still cannot be extended in place.** The horizon is explicit and safe; reaching it
  still means a redeployment of the calendar, every oracle and the engine. If in-place extension
  matters more than immutability, the constructor should take the seed table as a parameter.
