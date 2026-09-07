// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AerodromeSwapAdapter, ISlipstreamSwapRouter} from "../src/adapters/AerodromeSwapAdapter.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice A Slipstream `SwapRouter` stand-in that fills at a fixed rate.
/// @dev Records the parameters it was handed so the adapter's routing decisions can be asserted
///      directly rather than inferred from a balance.
contract MockSlipstreamRouter {
    uint256 public constant RATE_SCALE = 1e18;

    address public immutable factory;
    uint256 public rate = 1e18;

    ISlipstreamSwapRouter.ExactInputSingleParams public lastParams;
    uint256 public callCount;

    constructor(address factory_) {
        factory = factory_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function exactInputSingle(ISlipstreamSwapRouter.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        lastParams = params;
        ++callCount;

        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        amountOut = params.amountIn * rate / RATE_SCALE;
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
    }
}

/// @notice Behavioural suite for the swap adapter.
///
/// @dev The adapter had no unit suite of its own before this file, which mattered more than it
///      looked: it is the one contract in the system that is deployed, source-verified, listed in
///      the public address table and reachable from outside the protocol, and it routes into a
///      Regulation-S tokenized security. Most of what is asserted here is therefore about *who may
///      call it* rather than about arithmetic.
contract AerodromeSwapAdapterTest is Test {
    AerodromeSwapAdapter internal adapter;
    MockSlipstreamRouter internal router;
    MockERC20 internal usdc;
    MockERC20 internal nvda;

    address internal owner = address(0xA11CE);
    address internal credit = address(0xC0FFEE);
    address internal stranger = address(0xBEEF);
    address internal factory = address(0xFAC7);

    int24 internal constant TICK_SPACING = 10;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvda = new MockERC20("NVDA xStock", "NVDAc", 8);
        router = new MockSlipstreamRouter(factory);

        adapter = new AerodromeSwapAdapter(ISlipstreamSwapRouter(address(router)), TICK_SPACING, owner, credit);

        usdc.mint(credit, 1_000e6);
        vm.prank(credit);
        usdc.approve(address(adapter), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_constructor_recordsItsWiring() public view {
        assertEq(address(adapter.router()), address(router));
        assertEq(adapter.credit(), credit, "the adapter names the one contract that may call it");
        assertEq(adapter.defaultTickSpacing(), TICK_SPACING);
        assertEq(adapter.owner(), owner);
    }

    function test_constructor_rejectsAZeroCredit() public {
        vm.expectRevert(AerodromeSwapAdapter.ZeroAddress.selector);
        new AerodromeSwapAdapter(ISlipstreamSwapRouter(address(router)), TICK_SPACING, owner, address(0));
    }

    function test_constructor_rejectsAZeroRouter() public {
        vm.expectRevert(AerodromeSwapAdapter.ZeroAddress.selector);
        new AerodromeSwapAdapter(ISlipstreamSwapRouter(address(0)), TICK_SPACING, owner, credit);
    }

    function test_constructor_rejectsANonPositiveTickSpacing() public {
        vm.expectRevert(abi.encodeWithSelector(AerodromeSwapAdapter.InvalidTickSpacing.selector, int24(0)));
        new AerodromeSwapAdapter(ISlipstreamSwapRouter(address(router)), 0, owner, credit);
    }

    /*//////////////////////////////////////////////////////////////
                             THE CALLER GATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The finding this gate closes: an arbitrary account swapping USDC into a Reg-S
    ///         tokenized equity through a contract this project deployed and advertised.
    function test_swapExactIn_rejectsEverybodyButTheCreditEngine() public {
        usdc.mint(stranger, 100e6);
        vm.startPrank(stranger);
        usdc.approve(address(adapter), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(AerodromeSwapAdapter.NotCredit.selector, stranger));
        adapter.swapExactIn(address(usdc), address(nvda), 100e6, 0, stranger);
        vm.stopPrank();

        assertEq(router.callCount(), 0, "nothing reached the router");
        assertEq(nvda.balanceOf(stranger), 0, "and no security was delivered");
    }

    /// @notice Owning the adapter is not a licence to trade through it. The routing table and the
    ///         swap gate are two different permissions on purpose: the first is configuration, the
    ///         second is who may hold the output.
    function test_swapExactIn_rejectsTheOwnerToo() public {
        usdc.mint(owner, 100e6);
        vm.startPrank(owner);
        usdc.approve(address(adapter), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(AerodromeSwapAdapter.NotCredit.selector, owner));
        adapter.swapExactIn(address(usdc), address(nvda), 100e6, 0, owner);
        vm.stopPrank();
    }

    /// @notice And it cannot be widened: there is no setter, so the caller set is fixed for the
    ///         life of the contract at whatever the constructor was given.
    function test_swapExactIn_theCallerSetHasNoSetter() public {
        bytes4[3] memory plausible = [
            bytes4(keccak256("setCredit(address)")),
            bytes4(keccak256("setCaller(address)")),
            bytes4(keccak256("setAuthorized(address,bool)"))
        ];

        for (uint256 i; i < plausible.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(adapter).call(abi.encodeWithSelector(plausible[i], credit));
            assertFalse(ok, "the adapter must expose no way to widen its caller set");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              THE HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_swapExactIn_routesTheCreditEnginesTrade() public {
        router.setRate(0.5e18);

        vm.prank(credit);
        uint256 out = adapter.swapExactIn(address(usdc), address(nvda), 100e6, 50e6, credit);

        assertEq(out, 50e6);
        assertEq(nvda.balanceOf(credit), 50e6);
        assertEq(usdc.balanceOf(address(adapter)), 0, "the adapter holds nothing between calls");
        assertEq(usdc.allowance(address(adapter), address(router)), 0, "and leaves the router no standing allowance");

        (address tokenIn, address tokenOut, int24 tickSpacing, address recipient,,, uint256 minOut,) =
            router.lastParams();
        assertEq(tokenIn, address(usdc));
        assertEq(tokenOut, address(nvda));
        assertEq(tickSpacing, TICK_SPACING, "the default tier is used when no route is configured");
        assertEq(recipient, credit, "the output goes where the engine said, not to the adapter");
        assertEq(minOut, 50e6, "the engine's floor is forwarded to the router verbatim");
    }

    function test_swapExactIn_revertsBelowTheCallersFloor() public {
        router.setRate(0.4e18);

        vm.prank(credit);
        vm.expectRevert(abi.encodeWithSelector(AerodromeSwapAdapter.InsufficientOutput.selector, 40e6, 50e6));
        adapter.swapExactIn(address(usdc), address(nvda), 100e6, 50e6, credit);
    }

    function test_swapExactIn_rejectsZeroArguments() public {
        vm.startPrank(credit);

        vm.expectRevert(AerodromeSwapAdapter.ZeroAddress.selector);
        adapter.swapExactIn(address(0), address(nvda), 1e6, 0, credit);

        vm.expectRevert(AerodromeSwapAdapter.ZeroAddress.selector);
        adapter.swapExactIn(address(usdc), address(nvda), 1e6, 0, address(0));

        vm.expectRevert(AerodromeSwapAdapter.ZeroAmount.selector);
        adapter.swapExactIn(address(usdc), address(nvda), 0, 0, credit);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 ROUTING
    //////////////////////////////////////////////////////////////*/

    function test_setRoute_isSymmetricAndOwnerOnly() public {
        assertEq(adapter.routeFor(address(usdc), address(nvda)), TICK_SPACING);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setRoute(address(usdc), address(nvda), 100);

        vm.prank(owner);
        adapter.setRoute(address(usdc), address(nvda), 100);

        assertEq(adapter.routeFor(address(usdc), address(nvda)), 100);
        assertEq(adapter.routeFor(address(nvda), address(usdc)), 100, "routes are stored for the unordered pair");
    }

    function test_setRoute_pinsTheTierTheSwapUses() public {
        vm.prank(owner);
        adapter.setRoute(address(usdc), address(nvda), 200);

        vm.prank(credit);
        adapter.swapExactIn(address(usdc), address(nvda), 100e6, 0, credit);

        (,, int24 tickSpacing,,,,,) = router.lastParams();
        assertEq(tickSpacing, 200);
    }
}
