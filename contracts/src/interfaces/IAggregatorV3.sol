// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal Chainlink `AggregatorV3Interface`, restricted to the reads this project performs.
/// @dev The Base deployment of the Coinbase equity feeds (e.g. "Coinbase NVDA" at
///      `0x04689a41629776563E6822F76f2e57D148d28513`) reports 8 decimals with a 24h heartbeat and a
///      0.5% deviation trigger. `updatedAt` only moves while the underlying equity market is open,
///      which is precisely the condition `AftermarketOracle` is built to reason about.
interface IAggregatorV3 {
    /// @return Number of decimals in the value returned by `latestRoundData`.
    function decimals() external view returns (uint8);

    /// @return Human readable feed name, e.g. "Coinbase NVDA / USD".
    function description() external view returns (string memory);

    /// @return roundId         Aggregator round identifier.
    /// @return answer          Price, scaled by `10 ** decimals()`.
    /// @return startedAt       Unix ts the round started.
    /// @return updatedAt       Unix ts the answer was last written. Frozen while the equity market is shut.
    /// @return answeredInRound Round in which `answer` was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
