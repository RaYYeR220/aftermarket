// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";

/// @notice A deterministic swap venue for tests.
/// @dev Prices the trade off a caller-supplied rate rather than a curve, so a test can express
///      "this fill is 3% worse than the oracle mark" directly and assert that the slippage guard in
///      the credit engine - not the venue - is what stops it.
contract MockSwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    /// @notice Output units delivered per 1e18 input units, scaled by `rateScale`.
    uint256 public rate;

    /// @notice Divisor applied after `rate`, used to bridge differing token decimals.
    uint256 public rateScale = 1e18;

    /// @notice Extra haircut applied to the computed output, in bps.
    uint256 public haircutBps;

    /// @notice Whether the venue enforces `minOut` itself.
    /// @dev Turning it off models a venue that is buggy or malicious about slippage, so a test can
    ///      prove that the credit engine catches a bad fill on its own rather than relying on the
    ///      adapter to be honest.
    bool public enforceMinOut = true;

    error InsufficientOutput(uint256 amountOut, uint256 minOut);

    function setRate(uint256 rate_, uint256 rateScale_) external {
        rate = rate_;
        rateScale = rateScale_;
    }

    function setHaircutBps(uint256 haircutBps_) external {
        haircutBps = haircutBps_;
    }

    function setEnforceMinOut(bool enforceMinOut_) external {
        enforceMinOut = enforceMinOut_;
    }

    function quote(uint256 amountIn) public view returns (uint256) {
        return amountIn * rate / rateScale * (10_000 - haircutBps) / 10_000;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = quote(amountIn);
        if (enforceMinOut && amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        IERC20(tokenOut).safeTransfer(to, amountOut);
    }
}
