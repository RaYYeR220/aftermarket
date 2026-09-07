// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @notice The subset of the Aerodrome Slipstream `SwapRouter` this adapter uses.
/// @dev Slipstream is Aerodrome's concentrated-liquidity stack. Its router is a fork of the
///      Uniswap v3 `SwapRouter` in which the fee tier is replaced by the pool's `tickSpacing`.
interface ISlipstreamSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    /// @notice The CL pool factory this router validates swap callbacks against.
    function factory() external view returns (address);
}

/// @title  AerodromeSwapAdapter
/// @notice Routes a single-hop exact-input swap through the Aerodrome Slipstream router.
///
/// @dev Deliberately dumb. It holds no policy, no price opinion and no funds between calls: it
///      pulls exactly what it was told to sell, approves exactly that much to the router for the
///      duration of one call, and forwards the output to a recipient the caller chose. Every risk
///      decision - which position is being unwound, how much slippage is tolerable, where the
///      proceeds go - is made in `AftermarketCredit`, which is why this contract can be replaced
///      with a different venue without touching the credit engine.
///
///      ## Router address verification
///
///      Base mainnet has two live Slipstream CL factories, and the tokenized-equity pools sit on
///      the second one. The canonical Slipstream `SwapRouter` at
///      `0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5` is hard-wired to factory
///      `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` and therefore cannot trade the B20 pools at
///      all: it would derive the wrong pool address and reject its own callback.
///
///      The router that serves the B20 pools is `0x698cb2b6dd822994581fea6ea4fc755d1363a92f`. That
///      was established against `https://mainnet.base.org` with `cast`, as follows.
///
///      1. The NVDAc/USDC Slipstream pool `0x853f5f1b92b16714fe6cda67caad0856b83c7ab9` reports
///         `token0() = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (USDC),
///         `token1() = 0xb20000000000000000000078ee7ce2fE4908108C` (NVDAc), `tickSpacing() = 10`
///         and `factory() = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef`.
///      2. That pool address is reproducible as an ERC-1167 clone: `cast code` on the pool returns
///         the minimal-proxy runtime pointing at `0xc770898522D2A9c8Da7A10D63989b6b58305B665`, and
///         `keccak256(0xff ++ 0xf8f2eB49... ++ keccak256(abi.encode(token0, token1, tickSpacing))
///         ++ keccak256(cloneInitCode))` reproduces `0x853f5f1b...` exactly. The same computation
///         against the canonical factory yields `0xe90123cd...`, which is not the pool.
///      3. Scanning the pool's `Swap` events over the most recent ~9,500 blocks returned 1,244
///         swaps. The single most frequent `sender` (the address the pool calls back) was
///         `0x698cb2b6dd822994581fea6ea4fc755d1363a92f`, and `factory()` on it returns
///         `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` - the B20 pool factory.
///      4. `cast code` on that router and on the canonical Slipstream router return byte strings of
///         identical length (9,908 bytes) that differ in exactly 92 bytes: three copies of the
///         immutable factory address and the trailing metadata hash. `WETH9()` matches
///         (`0x4200000000000000000000000000000000000006`), and the `exactInputSingle`,
///         `exactOutputSingle`, `exactInput` and `uniswapV3SwapCallback` selectors are all present
///         in the runtime code. It is the same SwapRouter contract, redeployed against the
///         tokenized-equity factory.
///
///      The router is nevertheless a constructor argument rather than a constant, so a redeployment
///      by Aerodrome does not require a new adapter to be written.
contract AerodromeSwapAdapter is ISwapAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice The Aerodrome Slipstream router every swap is routed through.
    ISlipstreamSwapRouter public immutable router;

    /// @notice Tick spacing used when a pair has no explicit route configured.
    /// @dev The B20 equity pools are deployed at tick spacing 10, which is the sensible default for
    ///      a USD-quoted equity pair.
    int24 public immutable defaultTickSpacing;

    /// @notice Tick spacing to route a given unordered pair through; zero means "use the default".
    mapping(address tokenA => mapping(address tokenB => int24)) public tickSpacingFor;

    /// @notice Emitted when the owner points a pair at a specific Slipstream pool tier.
    event RouteSet(address indexed tokenA, address indexed tokenB, int24 tickSpacing);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidTickSpacing(int24 tickSpacing);
    error InsufficientOutput(uint256 amountOut, uint256 minOut);

    /// @param router_             Aerodrome Slipstream `SwapRouter`.
    /// @param defaultTickSpacing_ Fallback tick spacing for unconfigured pairs.
    /// @param owner_              Initial owner, able to add explicit routes.
    constructor(ISlipstreamSwapRouter router_, int24 defaultTickSpacing_, address owner_) Ownable(owner_) {
        if (address(router_) == address(0)) revert ZeroAddress();
        if (defaultTickSpacing_ <= 0) revert InvalidTickSpacing(defaultTickSpacing_);

        router = router_;
        defaultTickSpacing = defaultTickSpacing_;
    }

    /// @notice Pins a pair to a specific Slipstream tick spacing.
    /// @dev Routing is configuration, not policy: it decides *where* a trade goes, never *whether*
    ///      it is allowed or at what price. The caller still supplies `minOut`, so a badly chosen
    ///      route can only cause a revert, never a bad fill.
    /// @param tokenA      One side of the pair.
    /// @param tokenB      The other side.
    /// @param tickSpacing Slipstream tick spacing of the pool to use.
    function setRoute(address tokenA, address tokenB, int24 tickSpacing) external onlyOwner {
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (tickSpacing <= 0) revert InvalidTickSpacing(tickSpacing);

        tickSpacingFor[tokenA][tokenB] = tickSpacing;
        tickSpacingFor[tokenB][tokenA] = tickSpacing;

        emit RouteSet(tokenA, tokenB, tickSpacing);
    }

    /// @notice The tick spacing this adapter would route `tokenIn`/`tokenOut` through.
    function routeFor(address tokenIn, address tokenOut) public view returns (int24) {
        int24 configured = tickSpacingFor[tokenIn][tokenOut];
        return configured == 0 ? defaultTickSpacing : configured;
    }

    /// @inheritdoc ISwapAdapter
    /// @dev The allowance granted to the router is exactly `amountIn` and is consumed by the swap,
    ///      so the adapter never leaves standing permission over anything. `sqrtPriceLimitX96` is
    ///      left at zero: the price bound that matters is `minOut`, which the credit engine derives
    ///      from an oracle mark it is willing to defend, and adding a second, weaker bound here
    ///      would only create a way for a swap to half-execute.
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0) || to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            ISlipstreamSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: routeFor(tokenIn, tokenOut),
                recipient: to,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        // The router enforces `amountOutMinimum` itself; this is a second, local assertion so that a
        // future router with different semantics cannot quietly weaken the caller's guarantee.
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }
}
