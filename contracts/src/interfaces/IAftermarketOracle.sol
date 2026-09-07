// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Quote, Session, Verdict} from "../libraries/Types.sol";

/// @notice A market-session-aware price oracle for Coinbase B20 tokenized equities.
/// @dev Implements Morpho Blue's `IOracle` (`price()`), so it can be dropped into a permissionless
///      Morpho market unchanged. `price()` REVERTS whenever the mark cannot be trusted.
interface IAftermarketOracle {
    /// @notice Morpho Blue `IOracle`. Pessimistic mark, scaled to `1e36 * 10**(loanDec - collDec)`.
    /// @dev Reverts with a typed error when `peek().verdict` is untrusted.
    function price() external view returns (uint256);

    /// @notice Full oracle state. Never reverts. For UIs, keepers, and our own risk engine.
    function peek() external view returns (Quote memory);

    /// @notice Pessimistic mark used to size new borrowing power. Reverts when untrusted.
    function markBorrow() external view returns (uint256);

    /// @notice Optimistic mark used to test whether a position may be seized. Reverts when untrusted.
    /// @dev Deliberately asymmetric with `markBorrow`: it must be hard to over-borrow AND hard to
    ///      liquidate someone on a price nobody can verify.
    function markLiquidate() external view returns (uint256);

    function collateralToken() external view returns (address);
    function loanToken() external view returns (address);
    function calendar() external view returns (address);
    function feed() external view returns (address);
    function pool() external view returns (address);

    error StaleFeed(Session session, uint256 age, uint256 budget);
    error SourcesDiverged(Session session, uint256 divergenceBps, uint256 band);
    error PoolTooThin(uint256 liquidityUsd, uint256 minLiquidityUsd);
    error MarketHalted(uint256 multiplier);
    error InvalidFeedAnswer(int256 answer);
}
