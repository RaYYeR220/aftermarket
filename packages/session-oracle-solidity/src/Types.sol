// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Where the US equity market is in its daily cycle, as seen from the chain.
enum Session {
    REGULAR,          // 09:30-16:00 ET (13:00 ET on early-close days)
    PRE,              // 04:00-09:30 ET
    POST,             // 16:00-20:00 ET
    CLOSED_OVERNIGHT, // weeknight, market reopens tomorrow
    CLOSED_WEEKEND,   // Saturday / Sunday
    CLOSED_HOLIDAY    // exchange holiday
}

/// @notice How much the oracle trusts its own mark right now.
/// @dev Anything above `TRUSTED_CLOSED` makes `price()` revert, which is the entire point:
///      Morpho Blue reads the oracle in `borrow`, `withdrawCollateral` and `liquidate` only, so a
///      reverting oracle freezes new risk and freezes seizure while leaving `repay` and
///      `supplyCollateral` open. The borrower can always cure; nobody can take.
enum Verdict {
    TRUSTED,             // open session, feed fresh, sources agree
    TRUSTED_CLOSED,      // market closed as expected, sources agree, gap haircut applied
    UNTRUSTED_STALE,     // feed older than this session's staleness budget
    UNTRUSTED_DIVERGENT, // reference feed and the live pool disagree beyond the band
    UNTRUSTED_THIN,      // pool too shallow to corroborate the frozen feed
    UNTRUSTED_HALTED     // corporate action in flight: multiplier announcement / issuer pause
}

/// @notice Everything the oracle knows, in one non-reverting read. Powers the UI and our own risk engine.
struct Quote {
    Verdict verdict;
    Session session;
    uint256 anchorPrice;     // Chainlink total-return feed, 1e18 USD per whole token
    uint256 poolPrice;       // Aerodrome Slipstream TWAP, 1e18 USD per whole token
    uint256 markBorrow;      // pessimistic mark, Morpho 1e36 scale
    uint256 markLiquidate;   // optimistic mark, Morpho 1e36 scale
    uint256 feedAge;         // seconds since the feed last moved
    uint256 stalenessBudget; // seconds tolerated in this session
    uint256 divergenceBps;   // |anchor - pool| / anchor
    uint256 divergenceBand;  // bps tolerated in this session
    uint256 haircutBps;      // gap-risk haircut currently applied
    uint256 multiplier;      // B20 dividend/split multiplier, WAD
    uint256 poolLiquidityUsd;// 1e18 USD of quote-side depth backing the TWAP
    uint64 nextOpen;         // unix ts of the next regular open
    uint64 lastClose;        // unix ts of the previous regular close
}
