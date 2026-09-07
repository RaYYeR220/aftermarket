// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The single, deliberately narrow seam between the credit engine and any DEX.
/// @dev Aftermarket only ever needs one shape of trade: "sell exactly this much of a collateral
///      token for USDC, and revert unless I get at least `minOut`". Keeping the seam this small is
///      a safety property, not an aesthetic one: the adapter is untrusted routing plumbing that can
///      be swapped by the owner, so it must never be in a position to decide *how much* slippage is
///      acceptable, *which* position is being unwound, or *who* gets the proceeds. Those are policy
///      and policy lives in `AftermarketCredit`.
///
///      An implementation MUST restrict `swapExactIn` to the credit engine. One side of every trade
///      an Aftermarket adapter can make is a Reg-S tokenized security, so a publicly callable
///      implementation is a swap endpoint into that security with no jurisdiction check on it - a
///      distribution channel the protocol does not intend to operate. See
///      `AerodromeSwapAdapter.onlyCredit`.
interface ISwapAdapter {
    /// @notice Sells `amountIn` of `tokenIn` for at least `minOut` of `tokenOut`.
    /// @dev The adapter pulls `amountIn` from `msg.sender`, so the caller MUST have approved the
    ///      adapter for at least `amountIn` beforehand. Pull-based (rather than "transfer to me
    ///      first, then call") means the adapter can never be made to trade tokens that a third
    ///      party donated to it, and the caller authorises an exact amount rather than a balance.
    ///      The caller is the credit engine: implementations MUST reject everybody else.
    /// @param tokenIn  Token being sold.
    /// @param tokenOut Token being bought.
    /// @param amountIn Exact amount of `tokenIn` to sell.
    /// @param minOut   Minimum acceptable output; the adapter MUST revert below it.
    /// @param to       Recipient of `tokenOut`.
    /// @return amountOut Amount of `tokenOut` actually delivered to `to`.
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut);
}
