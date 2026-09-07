// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The subset of the Aerodrome Slipstream concentrated-liquidity pool used as a corroborating venue.
/// @dev Slipstream is a Uniswap-v3 fork, so `observe` carries the same semantics: `tickCumulatives[i]`
///      is the running sum of ticks at `block.timestamp - secondsAgos[i]`, and the arithmetic-mean tick
///      over a window is the difference of two cumulatives divided by the window.
interface ICLPool {
    /// @return The pool's first token, ordered by address.
    function token0() external view returns (address);

    /// @return The pool's second token, ordered by address.
    function token1() external view returns (address);

    /// @return The pool's tick spacing. Slipstream keys pools on tick spacing rather than fee.
    function tickSpacing() external view returns (int24);

    /// @notice Returns cumulative values as of each `secondsAgos` entry.
    /// @dev Reverts when the requested window exceeds the oldest stored observation, i.e. when the
    ///      pool's observation cardinality is too small. Callers must tolerate that revert.
    /// @param secondsAgos Seconds before `block.timestamp` to sample, most-distant first.
    /// @return tickCumulatives                    Cumulative tick at each sample point.
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per unit of in-range liquidity.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
