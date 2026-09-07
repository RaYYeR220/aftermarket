# MOCKS

Where the line runs between what is real on Base mainnet and what is simulated. Everything on the
simulated side is here because we chose to simulate it, and every item says why, what is real
underneath it, and how you can check the real part yourself.

**Summary:** the ten protocol contracts, the six oracles, the negative control, the Chainlink feeds,
the Aerodrome pools, the B20 tokens, the EAS attestation reads, the calendar, the demo transactions
and every number in [PROOF.md](PROOF.md) are real. Four things are simulated, all of them inside
tests, all of them labelled `SIMULATED INPUT` in the source. Four project-level caveats sit at the
bottom.

---

## 1. Eligibility: the demo is attested by *our* registry, not by Coinbase

**This is the most important line in this file, so it is first.**

`RegSGate` admits an account from one of two sources, in order:

1. **Coinbase Verifications.** A live EAS read: the real EAS predeploy
   `0x4200000000000000000000000000000000000021`, the real Coinbase indexer
   `0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C`, the real `verifiedCountry`
   (`0x1801901f…ca065`) and `verifiedAccount` (`0xf8b05c79…0de9`) schemas, with the attester pinned to
   `verifications.coinbase.eth` (`0x357458739F90461b99789350868CD7CF330Dd7EE`) and a recipient,
   expiry and revocation check on the attestation record.
2. **`AttesterRegistry`**, our own fallback attester, for accounts with no Coinbase attestation.

**The Coinbase path is real and it is proven.** Not by a mock — against a genuinely attested
third-party address on Base mainnet, `0xc799DD327b5D6c6E4Ed5bbEC510b49A1ce4bB6d7`, which holds a live
Coinbase Verified Country attestation for `PL` (UID
`0xf0856c7f6702880efeb0afa9a85bf2b8c6e3cefb885d14f880a2cf3af8654187`) and a live Verified Account
attestation. We found it by filtering `AttestationIndexed` logs from the Coinbase indexer over Base
blocks 50,964,700–50,973,700. It has no relationship to this project.

Ask the **deployed** gate about it:

```bash
cast call 0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C "check(address)(bool,bytes2,uint8)" \
  0xc799DD327b5D6c6E4Ed5bbEC510b49A1ce4bB6d7 --rpc-url https://mainnet.base.org
# true  0x504c ("PL")  1     <- source 1 = SOURCE_COINBASE
```

and `test/RegSGate.t.sol::test_Fork_RealCoinbaseAttestationOnBaseMainnet` asserts the same thing plus
the negative (`0x…dEaD` → `false, 0x0000, 0`).

**The write path in the demo is ours, and it is visible on chain.** We hold no Coinbase account, so we
cannot mint a Coinbase attestation for the demo wallet. Demo eligibility was granted by our own
`AttesterRegistry` in tx
[`0x35191d73…27422d`](https://base.blockscout.com/tx/0x35191d733f636ece63002a9f7ca086c9beedeef533afc976f33a88edae27422d),
and the gate reports the difference honestly rather than hiding it:

```bash
cast call 0xF87B4d3a2f50712d8442aa58Ca0F870E51ddD67C "check(address)(bool,bytes2,uint8)" \
  0x0AF7aFC75Db0CdEC3019CbAf4C67f311fEEC5c8f --rpc-url https://mainnet.base.org
# true  0x504c ("PL")  2     <- source 2 = SOURCE_REGISTRY
```

The `source` byte is in the return value, in the `UserView` the front end renders, and in the audit
trail. A judge, an integrator or a regulator can tell our attestation apart from Coinbase's without
asking us.

**What this does and does not mean.** It means the Reg-S read path is production code that works
against production data today. It does not mean the demo account is Coinbase-verified — it is not, and
the chain says so. In production `AttesterRegistry` would be set to the zero address, or restricted to
a real KYC provider under a timelock; today it is owned by the same un-timelocked EOA as everything
else (see [README, Honest limits](README.md#honest-limits)).

---

## 2. `sweepYield`: the multiplier increase is simulated, because no B20 has ever moved

`test/fork/LiveB20.t.sol::test_sweepYield_simulatedMultiplierIncrease` is the only simulated input in
that file, and the test says so in its own name.

A Coinbase B20 token exposes `multiplier()` — the corporate-action signal that a dividend or a split
has been applied. `sweepYield` sells exactly the `(m − m₀)/m` slice a distribution created and uses it
to burn debt, which is the "self-repaying collateral" behaviour. To exercise it, something has to have
happened.

**Nothing has.** Every live B20 equity on Base still reports a multiplier of exactly `1e18`, today, on
mainnet. The test asserts that as a live fact *before* it mocks anything:

```solidity
// The live fact this test is built on: no distribution has happened yet.
assertEq(_liveMultiplier(NVDA), 1e18, "a live B20 multiplier is expected to still be exactly 1e18");
...
// ---- SIMULATED INPUT: a 5% distribution on NVDAc -----------------------------
vm.mockCall(NVDA, abi.encodeWithSignature("multiplier()"), abi.encode(uint256(1.05e18)));
```

Check it yourself:

```bash
cast call 0xb20000000000000000000078ee7ce2fE4908108C "multiplier()(uint256)" --rpc-url https://mainnet.base.org
# 1000000000000000000
```

Everything else in that test is real: the real NVDAc token, the real Aerodrome pool the slice is sold
into, the real USDC that reaches the real vault, the real oracle-derived slippage floor. Only the
*trigger* is fabricated, and it is fabricated to a value (+5%) that a real dividend would plausibly
produce.

The same test also mocks the **timing** of one Chainlink round: a fork pinned outside US market hours
has no in-session print to read, so `_openTheMarket()` re-issues the live answer with a fresh
`updatedAt` at the next real opening bell. The *value* stays exactly the live one; only the timestamp
moves. This is needed because `sweepYield` deliberately refuses to run while the market is shut.

We do not know, and cannot know until the first real corporate action, whether the Coinbase feed
quotes pre- or post-multiplier units. That is finding **A-03 branch B** in the audit, it is recorded
as an unresolved live risk, and the oracle fails closed either way.

---

## 3. The flag/grace/liquidate replay applies a labelled 50% shock — because real weekend data *cannot* make a line flaggable

`test/fork/WeekendReplay.t.sol::test_weekendMechanismFlagGraceAndSeizure` walks a real position through
the real Labor Day weekend at real pinned blocks. The first two thirds of it use nothing but live tape:
a maxed-out line drawn on Friday afternoon, then the bell, then Saturday, then Sunday, then Labor Day —
and at every step it asserts the line is **still healthy** and the seizure threshold has gone **up**.

Then it does this, with the comment shipped in the source:

```solidity
// ---- SIMULATED INPUT: a 50% adverse move in NVDA, applied to both price sources -------
// Real weekend data cannot produce an unhealthy line here, by construction - that is the
// product. To exercise the rest of the mechanism the anchor and the pool are both marked
// down together, which is how a real gap behaves: the pool tracks the underlying, so the
// two sources stay in agreement while both fall.
```

The shock halves the Chainlink answer and moves the pool tick to match, so the two sources stay in
agreement (a divergent shock would just make the oracle refuse, which is a different test). It is
applied *after* every real-data assertion has already passed.

The point is worth stating plainly: **we could not make a healthy line become flaggable using real
weekend data, and that is the product working.** The test simulates the one thing the design is built
to prevent, in order to check the machinery on the other side of it — that grace lands 30 minutes
after Tuesday's bell rather than during the holiday, that seizure is refused at every point of the
weekend, and that the borrower can still repay while flagged.

---

## 4. Test-fixture balances

`ForkBase._seedUsdc` uses Foundry's `deal` to write a USDC balance into the real USDC contract's
storage on the fork. Labelled `SIMULATED INPUT` in the source. It is how a fork test gets funds; it
affects the fork only and touches nothing on chain. Collateral in the fork tests is then bought with
that USDC through the **real** Aerodrome pool, not dealt directly.

---

## Project-level caveats

These are not mocks. They are places where "it is deployed on mainnet" could be read as more than we
mean.

### The fork replay uses the fixture's risk parameters, not the deployed ones

`contracts/test/fork/ForkBase.sol` hardcodes its own parameter set, and it is **not** the mainnet
deploy configuration:

| parameter | fork fixture | deployed on mainnet |
|---|---|---|
| base gap haircut | 100 bps | 25 bps |
| haircut slope | 25 bps/hour | 15 bps/hour |
| max haircut | 1500 bps | 500 bps |
| advance rate, open / closed | 5000 / 3500 bps | 6500 / 5000 bps |
| liquidation threshold, open / closed | 7000 / 8000 bps | 8000 / 8500 bps |
| divergence bands (6 sessions) | 150 / 200 / 200 / 250 / 250 / 300 | 500 / 500 / 500 / 200 / 250 / 300 |
| staleness budgets (6 sessions) | 6h / 8h / 8h / 24h / 76h / 108h | 1h / 6h / 6h / 25h / 76h / 100h |

Every deployed value above is readable on chain — `baseHaircutBps()`, `maxHaircutBps()`,
`assetConfig(address)` — and the fixture values are constants at `ForkBase.sol:115-133`.

**Consequence:** the borrowing-power contraction printed in
[`contracts/deployments/weekend-timeline.txt`](contracts/deployments/weekend-timeline.txt) —
**11,557 → 6,921** USDC on 100 NVDAc across the weekend — is the fixture's number, not the deployed
protocol's. The *mechanism* (a haircut that widens with every closed hour, marks that move apart, a
seizure threshold that rises while the market is shut, a hard `UNTRUSTED_STALE` stop at the next bell)
is real and runs on real historical chain state at real pinned blocks. The magnitude is the fixture's.
On the deployed parameters the same weekend would contract borrowing power less, because the deployed
haircut caps at 500 bps rather than 1500.

Wherever that figure appears in this repository it is labelled. If you want a number that *is* the
deployed protocol, use the live reads in [PROOF.md §2 and §3](PROOF.md) instead.

### The demo swaps went through Aerodrome's router directly, not through our adapter

Steps 3 and 4 of the demo (`0xcbe1f83c…` and `0x608c9266…`) call the Aerodrome `SwapRouter`
`0x698cb2b6dd822994581fea6ea4fc755d1363a92f` straight from the wallet. That is how the demo account
acquired collateral — a user action, not a protocol code path.

`AerodromeSwapAdapter` (`0x71283dB3…A8465E`) is the protocol's own venue, used by
`AftermarketCredit.sweepYield` and by nothing else. It is deployed, verified, and covered by
`contracts/test/AerodromeSwapAdapter.t.sol` (12 tests, against a mock Slipstream router) plus the fork
suite, which builds and wires the real adapter into the live stack.

An earlier version of this section said the adapter was *"covered by the unit and fork suites"* at a
time when there was no `AerodromeSwapAdapter.t.sol` at all and every unit test used
`test/mocks/MockSwapAdapter.sol`. That was the one overstatement in this file and it is now true
rather than repaired by wording: the suite exists.

**The adapter's routing code has run on mainnet, and the transaction that proves it also records a
mistake.** Tx [`0xcf9150ed…1f9a37`](https://base.blockscout.com/tx/0xcf9150edf881cc45bb43df9a9ede54af3aedfd6230e338fd9f643dadd51f9a37)
at block 50,998,717 moved 0.400000 USDC into 0.00172031 NVDAc through the Slipstream router: the pull,
the approval, the router hop, the `minOut` assertion and the payout all executed for real. It was sent
by an ordinary externally-owned account, because `swapExactIn` was `external` with no caller
restriction — which made a contract this project deployed and advertised a swap endpoint into a
Regulation-S security with no jurisdiction check on it. That was a hole, not a feature, and the
adapter deployed since restricts `swapExactIn` to the credit engine through an immutable with no
setter. The transaction is kept in the record because it is the evidence for both halves.

What still has not happened is `sweepYield` itself, because it needs a multiplier increase that has
never occurred on any listed asset (see §2 above) — the routing code is exercised, the
corporate-action trigger that would drive it automatically is not.

### The Morpho Blue market is funded, but not with any volume

`0xfef5641f70e19a87e369304daa9ba823754f3db1e6481d757fcae0442cffe479` exists with the right loan token,
collateral token, oracle, IRM and LLTV, and now carries a real supply, a real collateral deposit and a
real borrow — `market(id)` returns totalSupplyAssets 500000, totalBorrowAssets 150000; `position(id,
deployer)` returns collateral 172031. Four direct Morpho Blue transactions did this, all from the
deployer, none through `AftermarketCredit`: see [PROOF §11](PROOF.md) for the hashes, including one
borrow attempt that reverted (an out-of-gas revert racing the collateral deposit, not an unhealthy
position) before the identical call succeeded two minutes later.

**What this proves and does not prove.** It proves the `IOracle` integration is wired correctly against
code we did not write, and that Morpho Blue's own `_isHealthy` — not ours — called our `price()` to
authorise a real borrow. It does not prove liquidity or adoption: one supplier, one borrower, both the
deployer, fifty cents total. The "Morpho reads `price()` in exactly three places" claim is still
verified independently from Morpho's source (`lib/morpho-blue/src/Morpho.sol:258`, `:337`, `:361`); the
borrow above is now a second, live confirmation of the same fact via the `borrow` call site.

### The audit text quotes an earlier configuration in places

`contracts/audit/AUDIT.md` was written against `script/config/base.json` as it stood during the review.
Some of its worked examples quote parameters that were subsequently changed before deploy — most
visibly a "100 bps + 10 bps/h haircut capped at 1000 bps" and multiplier bounds of `[0.5e18, 100e18]`,
where the deployed oracles carry 25 bps + 15 bps/h capped at 500 bps and bounds of `[0.01e18, 1e21]`.
The findings, the mechanisms and the PoCs are unaffected — the PoCs read the config file at run time,
so they test whatever is currently configured — but if you are cross-checking an arithmetic example in
the audit against a live `cast` read, that is why the numbers differ. The deployed values are the ones
in [`contracts/deployments/base.json`](contracts/deployments/base.json) and on chain.

---

## What is not mocked anywhere

For completeness, because the list of real things is longer than the list of fake ones:

- All 17 deployed contracts, source-verified — [docs/verification.md](docs/verification.md).
- Every Chainlink Coinbase-equity feed read, live and historical.
- Every Aerodrome Slipstream pool, TWAP and depth read.
- Every B20 token read (`decimals`, `balanceOf`, `transfer`, `multiplier`, `isPaused`) — these run
  against Base's real Rust precompiles under `base-forge`, which is why the fork suite needs it.
- The EAS predeploy, the Coinbase indexer, and both Coinbase Verifications schemas.
- `TradingCalendar` — no owner, no admin function, no upgrade path, seeded with the real 2026–2027
  NYSE/Nasdaq holidays and half days, differentially tested day-by-day over all 730 days.
- The seven demo transactions in [PROOF.md §4](PROOF.md), all real, all successful, all on mainnet.
- The keeper eval — real contract `simulate()` calls, no LLM anywhere in the decision path.
- The evidence snapshot in `docs/evidence/weekend-2026-09-06.json` — block-pinned, regenerable with
  `pnpm verify:onchain`.
