# @aftermarket/session-oracle-solidity

Three Solidity files, no dependencies: the frozen interfaces for Aftermarket's
session-aware price oracle. Import these into your own protocol to call a
deployed `AftermarketOracle` — or to build against its ABI in a mock — without
pulling in the rest of the Aftermarket codebase.

```
src/
├── Types.sol             Session, Verdict enums + the Quote struct
├── IAftermarketOracle.sol price(), peek(), markBorrow(), markLiquidate(), five typed errors
└── ITradingCalendar.sol   the onchain NYSE/Nasdaq session calendar the oracle reads
```

These are copied byte-for-byte (import paths aside) from
`contracts/src/interfaces/` and `contracts/src/libraries/Types.sol` in the
main Aftermarket repository, which remains the source of truth. If you need
the implementation, the deployment scripts, or the credit contract that
consumes `markBorrow()`/`markLiquidate()` asymmetrically, go there — this
package is deliberately just the interface surface.

## Why you'd want this

`AftermarketOracle` implements Morpho Blue's `IOracle`, so any Morpho market
can already use a deployed instance as its `oracle` address with zero
integration work. This package exists for everyone else: a protocol that
wants to read the same session-aware, staleness-checked, divergence-checked
price — or that wants to build a mock oracle for its own tests that reverts
the same way the real one does.

## Usage

Copy `src/` into your own `lib/` (or install as a git submodule / npm
package, whichever your build points at), then:

```solidity
import {IAftermarketOracle} from "@aftermarket/session-oracle-solidity/IAftermarketOracle.sol";
import {Quote, Verdict} from "@aftermarket/session-oracle-solidity/Types.sol";

contract MyVault {
    IAftermarketOracle public immutable oracle;

    constructor(IAftermarketOracle _oracle) {
        oracle = _oracle;
    }

    function currentMark() external view returns (uint256) {
        // Reverts with StaleFeed / SourcesDiverged / PoolTooThin / MarketHalted /
        // InvalidFeedAnswer when the mark cannot be defended. That revert is the
        // signal — do not catch it and substitute a stale price.
        return oracle.markBorrow();
    }

    function inspect() external view returns (Quote memory) {
        // peek() never reverts: safe for UIs, keepers, and off-chain risk engines.
        return oracle.peek();
    }
}
```

## What `price()` reverting buys you

Morpho Blue calls `IOracle.price()` in exactly three places — `borrow`,
`withdrawCollateral` and `liquidate` — and never in `supply`, `repay`,
`supplyCollateral` or `flashLoan`. Any protocol that gates the same three
actions behind `IAftermarketOracle.price()` (or `markBorrow()` /
`markLiquidate()`) inherits the same behavior for free: a revert freezes new
risk and freezes seizure, while repayment and collateral top-up stay open.
Design your integration around that revert rather than a try/catch that
falls back to a cached price — a cached price is exactly the stale-feed
problem this oracle exists to prevent.

See `@aftermarket/session-oracle`'s README for the off-chain half — decoding
these same five errors into structured objects, converting between the
Morpho `1e36` price scale and human USD, and a `peek()` client for UIs.
