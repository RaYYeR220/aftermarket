# @aftermarket/session-oracle

The integrator SDK for **AftermarketOracle** — a market-session-aware price
oracle for Coinbase B20 tokenized equities on Base.

If you're about to list a tokenized stock as collateral, here's the problem
this package exists to solve: a B20 token trades onchain 24/7, but its
Chainlink total-return feed only tracks the underlying equity market, which
is open roughly 40% of the week. Outside those hours the feed's
`updatedAt` freezes at the last close and does not move — not "moves
slowly," *does not move at all* — through the night, the weekend, and every
exchange holiday. Right now, live, the Coinbase AMZN feed is **52 hours
stale at $257.69** while the Aerodrome pool it should be checked against is
printing $281.64 — a 9.29% divergence sitting on $62.5k of depth. A protocol
that reads that feed directly has no way to tell "quiet market" apart from
"broken feed," and will happily liquidate or over-lend against a number that
is two trading days old.

`AftermarketOracle` fuses four onchain sources — the Chainlink anchor, an
Aerodrome Slipstream TWAP, the B20 `multiplier()` corporate-action signal,
and an onchain NYSE/Nasdaq calendar — into a single verdict and two
deliberately asymmetric marks, and **reverts instead of quoting a mark it
cannot defend.** This package is the client for that oracle: decoded quotes,
decoded reverts, Morpho scale conversions, plain-English verdict text, and
React hooks — so your integration reads `if (result.ok)` instead of parsing
revert bytes.

## Quickstart

```ts
import { createPublicClient, http } from "viem";
import { base } from "viem/chains";
import { createOracleClient, morphoPriceToUsd } from "@aftermarket/session-oracle";

const publicClient = createPublicClient({ chain: base, transport: http() });
const oracle = createOracleClient({ publicClient, address: "0xYourOracleAddress" });

const quote = await oracle.peek(); // never reverts — full state for a UI or keeper
console.log(quote.verdict, quote.priceUsd, quote.isMarketOpen);

const result = await oracle.price(); // reverts onchain -> decoded error here instead
if (result.ok) {
  console.log("USD:", morphoPriceToUsd(result.price, 8, 6));
} else {
  console.log(result.error.name, result.error); // e.g. "StaleFeed", { session, age, budget }
}
```

## API

- **`createOracleClient({ publicClient, address })`** — build a client around a
  deployed oracle.
  - `peek()` → `Promise<DecodedQuote>`. Never rejects on a contract revert
    (`peek()` itself never reverts onchain). Every `Quote` field from the
    contract, plus `priceUsd`, `poolPriceUsd`, `feedAgeSeconds`, `isTrusted`,
    and `isMarketOpen`.
  - `price()`, `markBorrow()`, `markLiquidate()` → each resolves to
    `{ ok: true, price: bigint }` or `{ ok: false, error: OracleError }`. The
    error is one of the five typed contract errors below, already decoded —
    never a raw revert blob, and never a thrown exception for a revert the
    contract raised on purpose.
  - `watch(onQuote, { pollingInterval, onError })` → polls `peek()` and
    returns an `unsubscribe` function. Built for live UIs.
- **`explainVerdict(quote)`** → a plain-English sentence, ready to render:
  *"Reference feed and pool disagree by 9.29% with only $62.5k of depth —
  no mark can be defended until the market reopens Monday 09:30 ET."*
  Covers all six verdicts, open and closed sessions.
- **`morphoPriceToUsd(price, collateralDecimals, loanDecimals)`** and its
  inverse **`usdToMorphoPrice(usd, collateralDecimals, loanDecimals)`** —
  Morpho Blue's `1e36` price scale is a classic footgun (it's `1e36`
  *adjusted for both tokens' decimals*, not a flat `1e36`); these two
  helpers are the tested, documented version of that formula so you don't
  reimplement it.
- **`@aftermarket/session-oracle/react`** — optional `useQuote` / `usePrice`
  hooks built on wagmi. Not part of the main entry point, so a backend
  script or keeper never pulls in React.
- **`DEPLOYMENTS`**, `getDeployment(chainId, name?)`,
  `getDeploymentsForChain(chainId)` — a typed registry of deployed oracle
  addresses per chain, generated from `contracts/deployments/<chainId>.json`
  at build time. No deployments yet on a chain (or in this checkout) just
  means an empty array back, never a thrown error.

## Verdicts

Every `Quote` carries a `verdict`. Six values, six things to do:

| Verdict | Meaning | What to do |
|---|---|---|
| `TRUSTED` | Market open, feed fresh, sources agree. | Use the mark normally. |
| `TRUSTED_CLOSED` | Market closed as expected, sources agree, gap-risk haircut applied. | Use the mark normally — the haircut already prices in the closure. |
| `UNTRUSTED_STALE` | Feed older than this session's staleness budget. | `price()`/`markBorrow()`/`markLiquidate()` revert with `StaleFeed`. Wait for the feed to refresh. |
| `UNTRUSTED_DIVERGENT` | Reference feed and live pool disagree beyond the tolerated band. | Reverts with `SourcesDiverged`. Wait for sources to reconverge. |
| `UNTRUSTED_THIN` | Pool too shallow to corroborate a frozen feed. | Reverts with `PoolTooThin`. Wait for depth to recover or the market to reopen. |
| `UNTRUSTED_HALTED` | Corporate action in flight, or an issuer pause. | Reverts with `MarketHalted` (or `InvalidFeedAnswer` if the feed itself is broken). Wait for the halt to lift. |

Only the first two verdicts let `price()` / `markBorrow()` / `markLiquidate()`
succeed. That's not a bug to work around — see below.

## Drop-in for Morpho Blue

`AftermarketOracle` implements Morpho Blue's `IOracle` as-is: pass its
address as the `oracle` field of `createMarket`, same as any other Morpho
oracle. No adapter, no wrapper contract.

What that buys you is specifically the revert behavior above. Morpho Blue
calls `IOracle.price()` in exactly three places:

- `borrow` — new debt is sized against `price()`.
- `withdrawCollateral` — checks the resulting health factor against `price()`.
- `liquidate` — checks whether a position is seizable against `price()`.

and **never** in `supply`, `repay`, `supplyCollateral`, or `flashLoan`. So
when the oracle reverts (an `UNTRUSTED_*` verdict), the effect on your
market is precise, not a blanket freeze:

- **New borrowing is frozen.** Nobody can open or increase debt against a
  price nobody can currently defend.
- **Collateral withdrawal is frozen.** Nobody can pull collateral out from
  under a health-factor check that has no reliable price to check against.
- **Liquidation is frozen.** Nobody can seize a position on a price that
  cannot be verified — including the exact scenario this oracle was built
  for: a Chainlink feed silently stale over a weekend while a thin pool
  wobbles.
- **Repayment stays open.** A borrower can always pay down debt.
- **Adding collateral stays open.** A borrower can always shore up their
  position.

In short: the borrower can always cure; nobody can take. That asymmetry is
inherited directly from Morpho Blue's own audited call sites — this oracle
only supplies the truth function, in the form of a revert.

If your protocol isn't Morpho Blue but gates similar actions (new debt,
collateral release, seizure) behind a price read, wire those same three
call sites to `price()` / `markBorrow()` / `markLiquidate()` and you inherit
the same guarantee.

## Why two marks?

`markBorrow()` is pessimistic (`min(anchor, pool)`, haircut applied
downward); `markLiquidate()` is optimistic (`max(anchor, pool)`, haircut
applied upward). `price()` — the single hook Morpho Blue actually reads —
returns the pessimistic `markBorrow()` value, because a Morpho market has
one immutable LLTV and one price hook, so all of the session-dependent risk
has to live in the mark. If your protocol controls both the borrow-power and
liquidation call sites independently (Aftermarket's own credit contract
does), read `markBorrow()` and `markLiquidate()` directly instead of
`price()` to get the full asymmetry: hard to over-borrow, equally hard to
get liquidated on a price nobody can verify.

## React

```tsx
import { useQuote, usePrice } from "@aftermarket/session-oracle/react";

function OracleBadge({ address }: { address: `0x${string}` }) {
  const { quote, isLoading } = useQuote({ address });
  if (isLoading || !quote) return <span>loading…</span>;
  return <span>{quote.isTrusted ? `$${quote.priceUsd.toFixed(2)}` : quote.verdict}</span>;
}

function BorrowLimit({ address }: { address: `0x${string}` }) {
  const { price, error } = usePrice({ address, functionName: "markBorrow" });
  if (error) return <span>Unavailable: {error.name}</span>;
  return <span>{price?.toString() ?? "…"}</span>;
}
```

Requires an app already wrapped in wagmi's `WagmiProvider` (and the
`QueryClientProvider` wagmi itself needs). `react` and `wagmi` are optional
peer dependencies of this package — install them yourself; the core entry
point (`@aftermarket/session-oracle`) never imports them.

## Morpho's `1e36` scale, worked example

Morpho's `IOracle.price()` returns "the price of 1 asset of collateral
token quoted in 1 asset of loan token, scaled by 1e36." For a USD
stablecoin loan token, that reduces to `usd = price / 10 ** (36 +
loanDecimals - collateralDecimals)` — the same exponent
`AftermarketOracle` itself uses to build `markBorrow()` / `markLiquidate()`
from a WAD USD price, so this is the *inverse* of the contract's own math,
not a separate convention.

Known-good vector, tested exhaustively in both directions in
`test/morpho.test.ts`: an 8-decimal Chainlink feed answering `22995730000`
for an 8-decimal collateral token against a 6-decimal loan token produces
`price === 2299573n * 10n ** 30n`, and `morphoPriceToUsd(price, 8, 6) ===
229.9573`.

## Deployments registry

```ts
import { getDeployment } from "@aftermarket/session-oracle";

const market = getDeployment(8453, "AMZNc-USDC");
if (market) {
  // market.oracle, market.collateralToken, market.loanToken, ...
}
```

Backed by `contracts/deployments/<chainId>.json` (one file per chain),
regenerated into `src/deployments.generated.ts` before every build. No file
for a chain — or no `contracts/deployments/` directory at all, as in a fresh
checkout before the first deployment — just means an empty registry; nothing
here throws or fails a build over a missing deployment.

## Package layout

```
src/
├── index.ts                 public entry point
├── abi.ts                   aftermarketOracleAbi, tradingCalendarAbi (as const)
├── types.ts                 Session, Verdict, Quote, DecodedQuote, OracleError, Morpho scale helpers
├── client.ts                createOracleClient
├── verdict.ts                explainVerdict, VERDICT_GUIDANCE
├── deployments.ts / .generated.ts   typed deployment registry
└── react.ts                 useQuote, usePrice (subpath export: "@aftermarket/session-oracle/react")
```

## Solidity side

Building a protocol that wants to call `AftermarketOracle` directly from
Solidity, rather than off-chain? See the sibling
`@aftermarket/session-oracle-solidity` package for the frozen
`IAftermarketOracle` / `ITradingCalendar` interfaces with zero dependency on
the rest of this codebase.
