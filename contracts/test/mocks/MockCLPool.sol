// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICLPool} from "../../src/interfaces/ICLPool.sol";

/// @notice Controllable stand-in for an Aerodrome Slipstream pool.
/// @dev Test double only. Token ordering is set explicitly rather than derived from address sort order,
///      so a test can put the collateral on either side of the pool on purpose. `observe` can be made
///      to revert, which is how a pool with insufficient observation cardinality behaves.
contract MockCLPool is ICLPool {
    error OLD();

    address public token0;
    address public token1;
    int24 public tickSpacing;

    int56 internal _cumulativeOld;
    int56 internal _cumulativeNow;
    bool public observeReverting;

    /// @notice Harmonic-mean in-range liquidity the synthesised `secondsPerLiquidityCumulativeX128`
    ///         pair will decode back to. Defaults high enough that a test which does not care about
    ///         depth is never accidentally judged thin.
    uint256 public liquidity = 1 << 100;

    constructor(address token0_, address token1_, int24 tickSpacing_) {
        token0 = token0_;
        token1 = token1_;
        tickSpacing = tickSpacing_;
    }

    /// @notice Sets the in-range liquidity the oracle will read back out of the TWAP window.
    function setLiquidity(uint256 liquidity_) external {
        liquidity = liquidity_;
    }

    /// @notice Sets the cumulatives so that the arithmetic-mean tick over `window` equals `tick`.
    function setMeanTick(int24 tick, uint32 window) external {
        _cumulativeOld = 0;
        _cumulativeNow = int56(tick) * int56(uint56(window));
    }

    /// @notice Sets the raw cumulatives, for tests that need degenerate values.
    function setCumulatives(int56 cumulativeOld, int56 cumulativeNow) external {
        _cumulativeOld = cumulativeOld;
        _cumulativeNow = cumulativeNow;
    }

    function setObserveReverting(bool reverting) external {
        observeReverting = reverting;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeReverting) revert OLD();
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        if (secondsAgos.length == 2) {
            tickCumulatives[0] = _cumulativeOld;
            tickCumulatives[1] = _cumulativeNow;
            // A real pool accumulates `elapsed / liquidity` in X128; the oracle inverts the
            // difference to recover the harmonic-mean liquidity over the window.
            if (liquidity != 0) {
                uint256 delta = (uint256(secondsAgos[0]) << 128) / liquidity;
                // casting to 'uint160' is safe because the real cumulative is a wrapping uint160
                // forge-lint: disable-next-line(unsafe-typecast)
                secondsPerLiquidityCumulativeX128s[1] = uint160(delta);
            }
        }
    }
}
