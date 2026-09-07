# @aftermarket/agent

The off-chain keeper for **Aftermarket**'s `AutoRepayer` — the agent layer of a portfolio line of
credit against Coinbase's tokenized US stocks on Base.

Its job is not to be clever. `AutoRepayer` is deployed and frozen on Base mainnet at
[`0xBe1EA7CA0Fabc93F86C43fBcB25bbB3f2a0A2404`](https://basescan.org/address/0xBe1EA7CA0Fabc93F86C43fBcB25bbB3f2a0A2404),
and every one of its refusals is enforced by the contract rather than promised by whoever runs this
process. **The keeper has no power the contract does not already grant it.** What it adds is
legibility: it evaluates the same eight preconditions in the same order, writes down what it saw and
what it decided — including, especially, every decision to do nothing — and never signs a
transaction the contract's own simulation says would be refused.

---

## The gate is code, not a prompt

**There is no LLM anywhere in this service.** The decision to spend a borrower's USDC is made by
[`src/engine.ts`](src/engine.ts), a pure function over a snapshot of chain state, with `bigint`
arithmetic that mirrors `AutoRepayer._evaluate` line for line.

That is the point rather than a shortcut. The whole value of `AutoRepayer` is that its authority is
bounded on chain: a user grants a capped, time-boxed Base **Spend Permission**, and Coinbase's
`SpendPermissionManager` enforces `used + amount <= allowance` as an on-chain invariant that neither
this keeper nor the protocol controls. Putting a non-deterministic step in front of a deterministic
guarantee would give back exactly the discretion the design spent its complexity budget removing.

The keeper's engine and the contract's `simulate()` are two independent implementations of one
specification, and they are diffed on **every tick**. When they disagree the keeper does not pick a
winner — it stands down and records `engine-mismatch`, because a keeper that breaks that tie is a
keeper exercising judgement.

---

## What it can and cannot do

**Can**

- Read every enrolled account (discovered from `Enrolled` / `Withdrawn` / `Cancelled` events, plus
  any address pinned with `--account` or `KEEPER_ACCOUNTS`).
- Call `AutoRepayer.execute(user)` when — and only when — `simulate(user)` returns `willAct`.
- Call `AutoRepayer.poke(user)` on a refusal, so the restraint is on-chain evidence rather than a
  line in this process's log file.
- Write a structured decision record for every account on every tick.
- Serve those records over a small read-only HTTP endpoint.

**Cannot**

- Choose the amount. `AutoRepayer` sizes the repayment; the keeper only relays it.
- Choose the recipient. USDC moves from the borrower's account to the borrower's own debt, and the
  agent contract ends every call holding nothing.
- Exceed the borrower's per-execution cap, or the remaining allowance on their spend permission.
  Both are checked by the contract, and the second by a contract Coinbase deploys.
- Act on a price the protocol will not stand behind.
- Act at all without `--live`. Dry run is the default.
- Read a private key from anywhere but the `KEEPER_PRIVATE_KEY` environment variable. There is no
  flag, file path or keystore option that will do it.

---

## The eight checks, in the contract's order

The keeper evaluates these in exactly the order `AutoRepayer._evaluate` does. `keeper reasons`
prints the same table.

| # | Code | Reason | Meaning |
|---|---|---|---|
| — | 0 | `NONE` | Every precondition holds. The agent will repay. |
| 1 | 1 | `NOT_ENROLLED` | No mandate: never enrolled, or withdrawn. The agent has no authority here at all. |
| 2 | 2 | `POLICY_DISABLED` | Enrolled, but the borrower switched the mandate off. |
| 3 | 3 | `INTERVAL_NOT_ELAPSED` | The agent acted too recently, per the borrower's own `minInterval`. |
| 4 | 4 | `ORACLE_UNTRUSTED` | The protocol will not produce a risk reading it stands behind. |
| 5 | 5 | `LINE_HEALTHY` | Neither flagged nor below the borrower's trigger health. |
| 6 | 6 | `NOTHING_TO_REPAY` | In the acting band, but the repayment computes to zero. |
| 7 | 7 | `ABOVE_MAX_PER_EXECUTION` | Larger than the per-action ceiling. Refused outright, never clamped. |
| 8 | 8 | `PERMISSION_UNAVAILABLE` | The spend permission is revoked, outside its window, or short of allowance. |

Two of those orderings are load-bearing and worth stating plainly.

**`ORACLE_UNTRUSTED` is decided before `LINE_HEALTHY`.** "The line is healthy" is itself a claim
about a price. When the oracle refuses to produce a mark, the agent cannot tell a healthy line from
a doomed one and certainly cannot size a repayment, so it reports that it has no mark rather than
asserting a health the protocol does not currently know. This is not hypothetical: as of the block
this README was written against, the AMZNc oracle on Base mainnet reverts with

```
SourcesDiverged(session=CLOSED_HOLIDAY, divergence=898bps, band=300bps)
```

at block 50 995 435 — the exact line recorded under `liveOracles` in
[`eval/results/latest.json`](eval/results/latest.json) — because Monday 7 September is Labor Day and
the market does not reopen until Tuesday 09:30 ET. The keeper decodes that revert through
[`@aftermarket/session-oracle`](../packages/session-oracle) and puts the sentence in the audit
trail, next to the plain-English explanation the SDK renders for the verdict.

**A repayment over the cap is refused, not clamped.** Spending the largest permitted slice would
look friendlier and be worse: a clamped repayment does not clear the trigger, so the line stays in
the acting band and the cap gets drained one bite per interval — turning "at most this much per
action" into "all of it, eventually".

---

## Refusals are the primary output

Every account, every tick, produces one JSONL record — whether or not anything happened. Each record
carries the block it was taken at, the reason code and its human explanation, the inputs the verdict
was reached from (session, oracle verdict, divergence, health, allowance remaining, cap, interval),
what the contract's own `simulate()` said, and what the keeper did or did not do.

```jsonc
{
  "schema": "aftermarket.keeper.decision/1",
  "timestamp": "2026-09-07T10:21:28.299Z",
  "chainId": 8453,
  "blockNumber": "50993569",
  "account": "0x82eAc15172A7EFd9e06633F9bcaaE5180c12dd58",
  "status": "refused",
  "reason": 1,
  "reasonName": "NOT_ENROLLED",
  "explanation": "This account has no mandate: it has never enrolled, or it withdrew. …",
  "inputs": {
    "session": "CLOSED_HOLIDAY",
    "priced": true,
    "healthBps": null,
    "allowanceRemaining": null,
    "oracles": [],
    "unavailable": null
  },
  "contract": { "willAct": false, "reason": 1, "reasonName": "NOT_ENROLLED", "amount": "0" },
  "action": { "kind": "none", "sent": false, "txHash": null, "note": "refusal recorded off-chain only" },
  "dryRun": true
}
```

`status` is one of `acted`, `refused`, `would-act` (a dry run that would have acted), `unavailable`
(the chain could not be read — never a fabricated verdict), `engine-mismatch`, or `failed`.

### HTTP endpoint

`watch` serves the trail on `127.0.0.1:8787` by default. Four `GET` routes, no write path, no
authentication and nothing that could turn a dashboard into a way to make the keeper act.

| Route | Returns |
|---|---|
| `GET /health` | Wiring, signer, dry-run state, watch list, last tick. RPC credentials are stripped. |
| `GET /decisions?limit=&account=` | Decision records, newest first. |
| `GET /accounts` | The addresses currently watched. |
| `GET /reasons` | The refusal vocabulary, in evaluation order. |

---

## Usage

From the repository root:

```bash
pnpm install
pnpm --filter @aftermarket/agent build
```

```bash
# Verify this build is wired to the contracts it thinks it is
node agent/dist/cli.js doctor

# One pass over every enrolled account. Dry run.
node agent/dist/cli.js once

# Poll forever, serving the decision endpoint on :8787
node agent/dist/cli.js watch --interval 60

# The contract's own verdict for one account
node agent/dist/cli.js simulate 0x…

# A full human-readable report for one account
node agent/dist/cli.js explain 0x…

# The refusal vocabulary, in the order the contract evaluates it
node agent/dist/cli.js reasons

# The graded evaluation, on a local fork of Base mainnet
node agent/dist/cli.js eval
```

| Flag | Effect |
|---|---|
| `--rpc <url>` | Base endpoint. Default `$BASE_RPC_URL`, else `https://mainnet.base.org`. |
| `--live` | Actually send transactions. Everything is a dry run without it. |
| `--poke` | Also write refusals on-chain with `poke()`. Off by default; it costs gas. |
| `--max-tx <n>` | Hard ceiling on transactions per run or per tick. Default 3. |
| `--interval <s>` | Seconds between ticks in `watch`. Default 60. |
| `--port <n>` / `--no-serve` | The decision endpoint in `watch`. Default port 8787. |
| `--audit <path>` | JSONL trail. Default `audit/decisions.jsonl`, relative to the working directory. |
| `--account <address>` | Watch an address whether or not it is enrolled. Repeatable. |
| `--json` | Machine-readable output. |

| Environment | Purpose |
|---|---|
| `BASE_RPC_URL` | Base mainnet endpoint. |
| `KEEPER_PRIVATE_KEY` | The keeper's signing key. The only way to give this service a signer. |
| `KEEPER_ACCOUNTS` | Comma-separated addresses to watch in addition to the enrolment scan. |
| `KEEPER_AUDIT_PATH` | Default audit trail path. |
| `ANVIL_BIN` | Override the `base-anvil` the evaluation launches. |

### Safety

- **Dry run by default.** `--live` is required before anything is signed.
- **`simulate()` first, always.** The keeper calls `AutoRepayer.simulate(user)`, then
  `eth_call`-simulates the whole `execute` transaction, before it will sign. A transaction the chain
  says would revert never leaves the process.
- **Hard per-run transaction cap.** Reached, the keeper stops acting and records why on every
  remaining account rather than continuing and hoping.
- **Key from the environment only.** No file, no flag, no keystore path.
- **RPC failures record `unavailable`.** Never a health of zero, never a verdict carried forward
  from a previous tick. A contract revert is information and is recorded as such; an unreachable
  node is the absence of information and is recorded as that.
- The cap that actually binds is none of the above. It is `SpendPermissionManager.spend()`, which
  reverts when `used + amount` exceeds the allowance the borrower signed, whatever this process
  believes.

---

## The graded evaluation

A **pre-registered, hidden-answer-key evaluation** of 32 scenarios, run against a local `base-anvil`
fork of Base mainnet. Stock anvil cannot host it: Coinbase's B20 tokenized stocks are Rust
precompiles rather than deployed bytecode, so a vanilla EVM has nothing to execute for them.

### The current scorecard

```
32/32 correct · 0 false actions · 11/11 traps refused · 6/6 negative controls acted

Measure                       Value
----------------------------  -----
scenarios                     32
correct                       32/32
false actions (hard failure)  0
traps refused                 11/11
negative controls acted       6/6
invariant violations          0
verdict                       PASS
```

Reproduce it in one command (see [Reproducing](#reproducing) for the two prerequisites):

```bash
pnpm --filter @aftermarket/agent build && node agent/dist/cli.js eval
```

Artifacts land in [`eval/results/`](eval/results): `latest.json` (the full machine-readable
document, including per-scenario oracle state and USDC/debt deltas), `latest.txt` (the tables),
`scorecard-<timestamp>.json` (one per run), and `eval-audit.jsonl` — the keeper's own decision trail
for the run, so every scored verdict can be traced back to the inputs it was reached from. A partial
run (`--only`) writes `partial-<timestamp>.json` instead and never touches `latest.*`, so debugging
one scenario cannot overwrite the committed evidence for a full one.

### Pre-registration

Every expected verdict was written **before** the harness was ever pointed at a fork, and lives in
[`eval/answer-key.json`](eval/answer-key.json) with a SHA-256 over the canonical form of the
claims — scenario id, category, trap/control flags, and the expected `(willAct, reason)` pair. Prose
is deliberately excluded from the hash: rewording a rationale should not invalidate a
pre-registration, and changing an expected verdict must.

Before scoring, the runner recomputes that hash from the scenario definitions it is about to run and
**refuses to proceed if it differs from the committed key**. An expectation cannot be quietly edited
to match a result; doing so changes the hash, and the change is visible in `git diff`.

```
answer key verified — 32 pre-registered expectations, hash 271c4b7c7cafadba…
```

### What is real on the fork, and what is not

Being specific about this matters more than the headline number.

**Real, at their mainnet addresses:**

- **USDC.** Every repayment moves Circle's deployed token. Balances are written with
  `anvil_setStorageAt`, into a balance slot the harness *finds by probing and verifying* rather than
  hard-coding.
- **`SpendPermissionManager`** (`0xf85210…67Ad`). Permissions are approved and spent through
  Coinbase's deployed bytecode, so `used + value <= allowance` is enforced by the same code that
  enforces it in production.
- **`CoinbaseSmartWalletFactory`** (`0x0BA5ED…428a`). Every borrower is a real Coinbase Smart
  Wallet, created through the live factory, with the manager added as an owner — the only account
  shape the manager can drive.
- **The six deployed `AftermarketOracle`s.** Read at the forked block and recorded in
  `latest.json` under `liveOracles`, so the scorecard cites the live market state it was produced
  against. Five answer; AMZNc reverts.

**Deployed fresh, from the same sources as the mainnet contracts:** `AftermarketCredit`,
`AftermarketVault`, `AutoRepayer`, `AftermarketLens`, and — per scenario — a real
`AftermarketOracle` configured with the exact parameters the six mainnet oracles were deployed with
(1 800 s TWAP window, the same six staleness budgets, the same six divergence bands including the
300 bps holiday band, the same haircut curve and multiplier bounds).

**Controllable, because a graded eval needs states that cannot be arranged by waiting:** each line
gets its own Chainlink aggregator, Slipstream pool and collateral token, and the trading calendar is
a driveable double. This is how the eval reaches all six oracle verdicts *through the real oracle's
own logic* — a stale feed is a genuinely stale `updatedAt`, a divergence is a genuine tick offset
against a funded pool, a halt is a genuine multiplier outside its configured bounds. The typed
reverts recorded for those scenarios in `latest.json` are the oracle's own:

```
S12  SourcesDiverged(session=CLOSED_HOLIDAY, divergence=910bps, band=300bps)
S13  StaleFeed(session=REGULAR, age=187200s, budget=3600s)
S14  MarketHalted(multiplier=2000000000000000000000)
S15  PoolTooThin(liquidityUsd=0, min=25000000000000000000000)
S17  SourcesDiverged(session=CLOSED_WEEKEND, divergence=1200bps, band=250bps)
```

**Simplified deliberately, and stated:** the interest-rate model is deployed at zero rate. Interest
is not what the eval measures, and a debt drifting by a few units between setting a scenario up and
evaluating it would make the one-unit boundary scenarios untestable. Every other engine parameter is
the deployed one.

### Methodology

For each scenario the runner:

1. resets the shared calendar to a plain open market;
2. creates a fresh Coinbase Smart Wallet, its own collateral token, feed, pool and oracle;
3. runs the scenario's setup — post collateral, draw, move the price to a target health, enrol,
   flag, warp, revoke, whatever the scenario is about;
4. re-applies the line's oracle state, so a scenario that warped two hours to expire a permission
   has not accidentally also made its healthy feed stale;
5. measures the borrower's USDC and the line's debt;
6. runs **the real `Keeper`** — not a test double — in `--live` mode with a cap of exactly one
   transaction and `poke` enabled, so a refusal leaves an `AutoRepayRefused` event on the fork and
   an action leaves an `AutoRepaid`;
7. measures again, and grades.

A scenario is **correct** only when the keeper's own engine, the contract's `simulate()`, and the
action actually taken all match the pre-registered verdict.

Three invariants are checked on top of the verdict, and a violation fails the scenario:

- `AutoRepayer` holds zero USDC after every tick — it is not a vault, and money exists inside it
  only between `spend()` and `repayOnBehalf()`.
- On a scenario that must be refused, **no USDC moved and no debt moved**.
- On a scenario that must be acted on, the borrower's USDC fell by exactly the repaid amount and the
  debt fell by exactly the same.

### Scoring

- **Correct** — the plain hit rate against the key.
- **False actions** — acting where the key says refuse. Counted separately and treated as a **hard
  failure**, never a warning. Every other mistake this keeper can make costs a borrower some delay;
  a false action costs them money out of a permission they granted for something else. One is enough
  to fail the run, and the process exits non-zero.
- **Traps refused** — of the 11 scenarios built specifically to look actionable and not be.
- **Negative controls acted** — of the 6 scenarios where the keeper *must* act. Without these a
  clean sheet would be vacuous: a keeper that refuses everything would otherwise score perfectly.
  Reporting both halves makes either failure mode visible at a glance.

### The 32 scenarios

| Id | Scenario | Expected | Kind |
|---|---|---|---|
| S01 | Comfortably healthy line, market open | `LINE_HEALTHY` | |
| S02 | Health exactly on the trigger | `LINE_HEALTHY` | trap |
| S03 | Enrolled line carrying no debt at all | `LINE_HEALTHY` | |
| S04 | Healthy line while the US market is shut | `LINE_HEALTHY` | |
| S05 | Plainly distressed line, everything in order | `NONE` | **negative control** |
| S06 | Flagged line whose health is above the trigger | `NONE` | |
| S07 | Flagged line inside a market-closed grace window | `NONE` | |
| S08 | Deeply distressed line, well inside every cap | `NONE` | negative control |
| S09 | Repayment exactly equal to the per-execution cap | `NONE` | negative control |
| S10 | Repayment exactly equal to the remaining allowance | `NONE` | negative control |
| S11 | Distressed line one second after the interval elapses | `NONE` | negative control |
| S12 | Sources diverged — the live AMZNc failure, reproduced | `ORACLE_UNTRUSTED` | |
| S13 | Reference feed stale beyond its session budget | `ORACLE_UNTRUSTED` | |
| S14 | Corporate-action halt on the collateral token | `ORACLE_UNTRUSTED` | |
| S15 | Pool too thin to corroborate a frozen feed, market closed | `ORACLE_UNTRUSTED` | |
| S16 | Catastrophically underwater line with no defensible mark | `ORACLE_UNTRUSTED` | trap |
| S17 | Flagged line, grace expiring, oracle untrusted | `ORACLE_UNTRUSTED` | trap |
| S18 | Credit engine itself unreachable — calendar down | `ORACLE_UNTRUSTED` | |
| S19 | Repayment one unit above the per-execution cap | `ABOVE_MAX_PER_EXECUTION` | trap |
| S20 | Repayment far above a deliberately small cap | `ABOVE_MAX_PER_EXECUTION` | |
| S21 | Allowance partly consumed, next repayment no longer fits | `PERMISSION_UNAVAILABLE` | trap |
| S22 | Repayment one unit above the remaining allowance | `PERMISSION_UNAVAILABLE` | trap |
| S23 | Spend permission has expired | `PERMISSION_UNAVAILABLE` | |
| S24 | Spend permission has not started yet | `PERMISSION_UNAVAILABLE` | |
| S25 | Permission revoked at the manager, mandate left in place | `PERMISSION_UNAVAILABLE` | trap |
| S26 | Distressed line that never enrolled | `NOT_ENROLLED` | |
| S27 | Mandate withdrawn while the line was still distressed | `NOT_ENROLLED` | |
| S28 | Mandate switched off on a distressed line | `POLICY_DISABLED` | trap |
| S29 | Distressed line inside its own rate limit | `INTERVAL_NOT_ELAPSED` | trap |
| S30 | Line already cured by somebody else | `LINE_HEALTHY` | trap |
| S31 | Flagged line whose debt is already at the recovery target | `NOTHING_TO_REPAY` | trap |
| S32 | Dust repayment on a flagged line | `NONE` | negative control |

The per-scenario rationale — written before the run, and part of the committed key — is in
[`src/eval/scenarios.ts`](src/eval/scenarios.ts) and mirrored into `eval/answer-key.json`.

A few are worth singling out. **S06** is a line whose health is *above* its trigger and which the
agent must still act on, because the protocol has flagged it and a flag is an independent trigger.
**S16 and S17** are the traps the whole ordering argument exists for: a line that looks
catastrophically underwater, with a large allowance and a generous cap, that must be left alone
because the number making it look catastrophic is one nobody will defend. **S30** is a line another
party cured between the keeper's picture and the block it acts in. **S32** is a repayment of one
hundred millionths of a dollar, which the keeper makes without editorialising, because the amount is
the borrower's business.

### Reproducing

Two prerequisites:

1. **Base's Foundry fork.** `base-foundryup` installs `base-anvil`, which ships the B20 precompiles.
   Set `ANVIL_BIN` to override the binary the runner finds.
2. **A Base mainnet RPC endpoint** in `BASE_RPC_URL`, to fork from.

Then:

```bash
pnpm --filter @aftermarket/agent build
node agent/dist/cli.js eval
```

The runner compiles the contracts workspace itself on the first run if `contracts/out` is empty
(`forge build`), starts the fork, deploys the fixture, runs all 32 scenarios and writes the
artifacts. It takes a few minutes and exits non-zero on any failure.

Useful variations:

```bash
node agent/dist/cli.js eval -- --only S16          # one scenario, no scoring
node agent/dist/cli.js eval -- --fork-block 50993000  # pin the fork
node agent/dist/cli.js eval -- --json              # the results document on stdout
node agent/dist/cli.js eval -- --write-key         # re-register the key (a deliberate act)
```

---

## Layout

```
src/
  abi.ts         Hand-written ABI fragments for every contract the keeper touches.
  addresses.ts   The Base mainnet deployment record. `doctor` re-derives it from the chain.
  audit.ts       The JSONL decision trail, and the record builders.
  chain.ts       viem clients, retry, revert-vs-outage classification.
  cli.ts         watch · once · simulate · explain · doctor · reasons · eval
  engine.ts      The decision gate. A pure function. No model, no prompt.
  format.ts      Tables, the `explain` report, USD and health formatting.
  index.ts       Library surface.
  keeper.ts      The loop: read, decide, cross-check against simulate(), act or refuse.
  reader.ts      Chain reads, and oracle-verdict decoding via @aftermarket/session-oracle.
  reasons.ts     The refusal vocabulary and its human explanations.
  registry.ts    Which accounts are watched, derived from enrolment events.
  server.ts      The read-only HTTP endpoint.
  types.ts       Domain types.
  eval/
    abi.ts         Fixture-only ABIs: the smart-wallet factory, the drivable doubles.
    answer-key.ts  Building, hashing and verifying the pre-registration.
    anvil.ts       Finding and launching base-anvil.
    artifacts.ts   Loading compiled contracts out of contracts/out.
    harness.ts     The world on the fork: deployment, wallets, lines, oracle states.
    run.ts         The runner and the results artifacts.
    scenarios.ts   The 32 scenarios and their pre-registered rationales.
    score.ts       Scoring and the scorecard.
eval/
  answer-key.json  The committed pre-registration, with its hash.
  results/         Scorecards, the full results document, and the run's decision trail.
```

## Licence

MIT.
