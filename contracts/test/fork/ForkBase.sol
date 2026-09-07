// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Predeploys} from "verifications/libraries/Predeploys.sol";

import {AftermarketCredit} from "../../src/AftermarketCredit.sol";
import {AftermarketOracle, OracleConfig} from "../../src/AftermarketOracle.sol";
import {AftermarketVault} from "../../src/AftermarketVault.sol";
import {AttesterRegistry} from "../../src/AttesterRegistry.sol";
import {RegSGate} from "../../src/RegSGate.sol";
import {SessionRateModel, ISessionRateModel} from "../../src/SessionRateModel.sol";
import {TradingCalendar} from "../../src/TradingCalendar.sol";
import {AerodromeSwapAdapter, ISlipstreamSwapRouter} from "../../src/adapters/AerodromeSwapAdapter.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketOracle} from "../../src/interfaces/IAftermarketOracle.sol";
import {IEligibility} from "../../src/interfaces/IEligibility.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {ITradingCalendar} from "../../src/interfaces/ITradingCalendar.sol";
import {Session, Verdict} from "../../src/libraries/Types.sol";

/// @notice The Aerodrome Slipstream concentrated-liquidity factory serving the B20 equity pools.
interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// @title  ForkBase
/// @notice Shared fixture for every Aftermarket fork test: real Base mainnet addresses, one place
///         that deploys the whole protocol against them, and the helpers that acquire genuine B20
///         collateral by trading through the live Aerodrome pools.
///
/// @dev ## Why these tests need `base-forge`
///
/// Coinbase's tokenized equities on Base are B20 tokens, and a B20 token is not an EVM contract.
/// It is a Rust precompile hosted inside Base's execution client: `eth_getCode` on
/// `0xb20000000000000000000078ee7ce2fE4908108C` returns the single byte `0xef`, which is a valid
/// account-code marker but not executable EVM bytecode. Stock `forge` and stock `anvil` know
/// nothing about the precompile set, so the moment a fork test calls `NVDAc.transfer(...)` the
/// interpreter tries to execute `0xef` and halts with `OpcodeNotFound`.
///
/// Base ships a fork of the toolchain - `base-forge`, `base-cast`, `base-anvil`, `base-chisel` -
/// that installs those precompiles into the EVM. Everything in `test/fork` therefore runs under
/// `base-forge test`, never under stock `forge test`. See `test/fork/README.md` for the commands
/// and `lib/base-std/LIVE_PRECOMPILE_TESTING.md` for the upstream description of the mechanism.
///
/// ## What is real here
///
/// The B20 tokens, the Chainlink aggregators, the Aerodrome Slipstream factory, pools and router,
/// USDC, the EAS predeploy and Coinbase's attestation indexer are all read live from Base mainnet.
/// The Aftermarket contracts themselves are deployed fresh into the fork, which is the point: the
/// production bytecode is exercised against production state.
///
/// Two inputs are seeded rather than observed, and both are called out at their use sites:
/// USDC starting balances (`vm.deal`-style storage seeding, standard for fork tests - the token
/// contract and all of its logic are the real ones) and, in exactly one test, a raised B20
/// `multiplier()`.
abstract contract ForkBase is Test {
    /*//////////////////////////////////////////////////////////////
                          BASE MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BASE_CHAIN_ID = 8453;

    /// @notice Circle USDC on Base, 6 decimals. The single loan asset.
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice The Slipstream CL factory the tokenized-equity pools were deployed from.
    address internal constant CL_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;

    /// @notice The Slipstream `SwapRouter` bound to `CL_FACTORY`.
    /// @dev Not the canonical Aerodrome router: that one is wired to a different factory and would
    ///      derive the wrong pool address for these pairs. See `AerodromeSwapAdapter` for the
    ///      onchain evidence behind this address.
    address internal constant SWAP_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;

    /// @notice Every live B20 equity pool is deployed at tick spacing 10.
    int24 internal constant TICK_SPACING = 10;

    address internal constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
    address internal constant AMZN = 0xb200000000000000000000d9192b6B456483C2E8;
    address internal constant AAPL = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    address internal constant META = 0xb2000000000000000000008bC8786B856E61707C;
    address internal constant GOOGL = 0xb2000000000000000000002D0BA3164cc74f58B7;
    address internal constant TSLA = 0xb2000000000000000000001e800a7f5189430cD0;

    /// @notice Coinbase's EAS attestation indexer on Base mainnet.
    /// @dev Mirrors `RegSGate.BASE_INDEXER`. Solidity will not read another contract's public
    ///      constant without an instance, and the gate has to be constructed with these values, so
    ///      they are repeated here and then checked against the deployed gate in `_deployCore`.
    address internal constant COINBASE_INDEXER = 0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C;

    /// @notice Mirrors `RegSGate.BASE_VERIFIED_COUNTRY_SCHEMA`: the "string verifiedCountry" schema.
    bytes32 internal constant VERIFIED_COUNTRY_SCHEMA =
        0x1801901fabd0e6189356b4fb52bb0ab855276d84f7ec140839fbd1f6801ca065;

    /// @notice Mirrors `RegSGate.BASE_VERIFIED_ACCOUNT_SCHEMA`: the "bool verifiedAccount" schema.
    bytes32 internal constant VERIFIED_ACCOUNT_SCHEMA =
        0xf8b05c79f090979bf4a80270aba232dff11a10d9ca55c4f88de95317970f0de9;

    address internal constant NVDA_FEED = 0x04689a41629776563E6822F76f2e57D148d28513;
    address internal constant AMZN_FEED = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;
    address internal constant AAPL_FEED = 0x787f13dEa48Db0897CbCDD985de77809D837F988;
    address internal constant META_FEED = 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D;
    address internal constant GOOGL_FEED = 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2;
    address internal constant TSLA_FEED = 0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4;

    /*//////////////////////////////////////////////////////////////
                              RISK POLICY
    //////////////////////////////////////////////////////////////*/

    /// @notice TWAP window used to corroborate the frozen Chainlink anchor, in seconds.
    /// @dev Thirty minutes is long enough that a single swap cannot move the mark and short enough
    ///      that every live equity pool still holds observations covering it over a weekend.
    uint32 internal constant TWAP_WINDOW = 1800;

    /// @notice Loan-side pool depth below which the pool stops being able to corroborate, 1e18 USD.
    /// @dev The thinnest live equity pool (AMZNc) carries tens of thousands of USDC, so this floor
    ///      keeps every configured market corroborated rather than quietly falling back to a
    ///      single unchecked source.
    uint128 internal constant MIN_POOL_LIQUIDITY_USD = 25_000e18;

    uint16 internal constant BASE_HAIRCUT_BPS = 100;
    uint16 internal constant HAIRCUT_SLOPE_BPS_PER_HOUR = 25;
    uint16 internal constant MAX_HAIRCUT_BPS = 1_500;

    /// @notice Divergence band tolerated while the US market is shut for the weekend, in bps.
    uint16 internal constant WEEKEND_BAND_BPS = 250;

    uint16 internal constant ADVANCE_OPEN_BPS = 5_000;
    uint16 internal constant ADVANCE_CLOSED_BPS = 3_500;
    uint16 internal constant LIQ_THRESHOLD_OPEN_BPS = 7_000;
    uint16 internal constant LIQ_THRESHOLD_CLOSED_BPS = 8_000;
    uint16 internal constant LIQ_BONUS_BPS = 700;

    /// @notice Slippage budget `sweepYield` is allowed to give up against the oracle mark.
    uint16 internal constant MAX_SLIPPAGE_BPS = 200;

    uint256 internal constant ORACLE_SCALE = 1e36;
    uint256 internal constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal owner = makeAddr("aftermarket.owner");
    address internal lender = makeAddr("aftermarket.lender");
    address internal borrower = makeAddr("aftermarket.borrower");
    address internal borrowerTwo = makeAddr("aftermarket.borrowerTwo");
    address internal liquidator = makeAddr("aftermarket.liquidator");
    /// @notice An account with no jurisdiction proven anywhere, deliberately never attested.
    address internal unattested = makeAddr("aftermarket.unattested");

    /*//////////////////////////////////////////////////////////////
                            DEPLOYED SYSTEM
    //////////////////////////////////////////////////////////////*/

    TradingCalendar internal calendar;
    AttesterRegistry internal attesters;
    RegSGate internal gate;
    SessionRateModel internal rateModel;
    AerodromeSwapAdapter internal adapter;
    AftermarketCredit internal credit;
    AftermarketVault internal vault;

    /// @notice One `AftermarketOracle` per configured collateral asset.
    mapping(address asset => AftermarketOracle) internal oracleOf;

    /// @notice The configured collateral assets, in listing order.
    address[] internal assets;

    /// @notice Human-readable ticker per configured asset, for logs.
    mapping(address asset => string) internal tickerOf;

    /*//////////////////////////////////////////////////////////////
                                FORKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Forks Base mainnet at its current head.
    function _forkLatest() internal {
        vm.createSelectFork(_rpcUrl());
        require(block.chainid == BASE_CHAIN_ID, "not Base mainnet");
    }

    /// @notice Forks Base mainnet pinned to a historical block.
    function _forkAt(uint256 blockNumber) internal {
        vm.createSelectFork(_rpcUrl(), blockNumber);
        require(block.chainid == BASE_CHAIN_ID, "not Base mainnet");
        require(block.number == blockNumber, "wrong pinned block");
    }

    function _rpcUrl() private view returns (string memory url) {
        url = vm.envOr("BASE_RPC_URL", string(""));
        require(bytes(url).length != 0, "BASE_RPC_URL is not set: fork tests need a Base mainnet RPC");
    }

    /*//////////////////////////////////////////////////////////////
                              DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the whole protocol into the current fork and lists every equity market.
    function _deployStack() internal {
        _deployCore();
        _listAsset("NVDAc", NVDA, NVDA_FEED);
        _listAsset("AMZNc", AMZN, AMZN_FEED);
        _listAsset("AAPLc", AAPL, AAPL_FEED);
        _listAsset("METAc", META, META_FEED);
        _listAsset("GOOGLc", GOOGL, GOOGL_FEED);
        _listAsset("TSLAc", TSLA, TSLA_FEED);
    }

    /// @notice Deploys the protocol and lists a single market. Used where a test only needs one
    ///         asset and every extra oracle deployment is a wasted archive round trip.
    function _deployStackWith(string memory ticker, address token, address feed) internal {
        _deployCore();
        _listAsset(ticker, token, feed);
    }

    function _deployCore() private {
        delete assets;

        calendar = new TradingCalendar();

        attesters = new AttesterRegistry(address(this));
        gate = new RegSGate(
            address(this),
            Predeploys.EAS,
            COINBASE_INDEXER,
            VERIFIED_COUNTRY_SCHEMA,
            VERIFIED_ACCOUNT_SCHEMA,
            address(attesters),
            new bytes2[](0)
        );
        // The gate carries the canonical Base mainnet values as its own constants. Checking them
        // here means the copies above can never drift away from the contract under test.
        require(gate.BASE_INDEXER() == COINBASE_INDEXER, "indexer drift");
        require(gate.BASE_VERIFIED_COUNTRY_SCHEMA() == VERIFIED_COUNTRY_SCHEMA, "country schema drift");
        require(gate.BASE_VERIFIED_ACCOUNT_SCHEMA() == VERIFIED_ACCOUNT_SCHEMA, "account schema drift");
        require(Predeploys.EAS.code.length != 0, "EAS predeploy missing from this fork");
        require(COINBASE_INDEXER.code.length != 0, "Coinbase indexer missing from this fork");

        // A kinked curve with a closed-market premium: 2% APR floor, +6% APR at the 80% kink,
        // +100% APR at full utilisation, and a session surcharge that pays suppliers for carrying
        // gap risk through the hours in which nothing can be liquidated.
        uint256[6] memory sessionMultipliers =
            [uint256(1e18), uint256(1e18), uint256(1e18), uint256(1.25e18), uint256(1.5e18), uint256(1.6e18)];
        rateModel = new SessionRateModel(
            ITradingCalendar(address(calendar)), 634_195_839, 1_902_587_519, 31_709_791_983, 0.8e18, sessionMultipliers
        );

        // Same three-CREATE unit the deploy script uses: the adapter only answers the engine, the
        // engine only settles into the vault, and both forward references are counterfactual.
        uint256 nonce = vm.getNonce(address(this));
        address predictedCredit = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 2);

        adapter =
            new AerodromeSwapAdapter(ISlipstreamSwapRouter(SWAP_ROUTER), TICK_SPACING, address(this), predictedCredit);

        credit = new AftermarketCredit(
            IERC20(USDC),
            predictedVault,
            ITradingCalendar(address(calendar)),
            IEligibility(address(gate)),
            ISessionRateModel(address(rateModel)),
            ISwapAdapter(address(adapter)),
            MAX_SLIPPAGE_BPS,
            owner
        );
        require(address(credit) == predictedCredit, "credit address prediction");
        vault = new AftermarketVault(IERC20(USDC), address(credit), "Aftermarket USDC", "amUSDC");
        require(address(vault) == predictedVault, "vault address prediction");
        require(adapter.credit() == address(credit), "adapter bound to the wrong engine");
    }

    /// @notice Deploys an oracle for `token` against its real feed and its real pool, then lists it.
    function _listAsset(string memory ticker, address token, address feed) internal {
        address pool = ICLFactory(CL_FACTORY).getPool(USDC, token, TICK_SPACING);
        require(pool != address(0), string.concat("no Slipstream pool for ", ticker));

        AftermarketOracle oracle = new AftermarketOracle(
            OracleConfig({
                collateralToken: token,
                loanToken: USDC,
                feed: feed,
                pool: pool,
                calendar: address(calendar),
                multiplierRegistry: address(0),
                twapWindow: TWAP_WINDOW,
                stalenessBudget: _stalenessBudgets(),
                divergenceBandBps: _divergenceBands(),
                baseHaircutBps: BASE_HAIRCUT_BPS,
                haircutSlopeBpsPerHour: HAIRCUT_SLOPE_BPS_PER_HOUR,
                maxHaircutBps: MAX_HAIRCUT_BPS,
                minPoolLiquidityUsd: MIN_POOL_LIQUIDITY_USD,
                minMultiplier: 0.5e18,
                maxMultiplier: 5e18
            })
        );

        oracleOf[token] = oracle;
        tickerOf[token] = ticker;
        assets.push(token);

        vm.prank(owner);
        credit.setAsset(
            token,
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(oracle)),
                advanceOpenBps: ADVANCE_OPEN_BPS,
                advanceClosedBps: ADVANCE_CLOSED_BPS,
                liqThresholdOpenBps: LIQ_THRESHOLD_OPEN_BPS,
                liqThresholdClosedBps: LIQ_THRESHOLD_CLOSED_BPS,
                liqBonusBps: LIQ_BONUS_BPS,
                cap: type(uint128).max,
                enabled: true
            })
        );
    }

    /// @notice Feed age tolerated per session, in seconds.
    /// @dev These are sized against how the Coinbase equity aggregators actually behave rather than
    ///      against a generic "1 hour heartbeat" assumption. `updatedAt` only moves while the
    ///      underlying equity market trades, so over a Friday-to-Tuesday Labor Day weekend a
    ///      perfectly healthy feed is roughly ninety hours old. Treating that as staleness would
    ///      make the oracle refuse to quote for three days straight; the protocol prices the gap
    ///      with a widening haircut instead, and reserves the staleness verdict for a feed that has
    ///      stopped moving when the market says it should be moving.
    function _stalenessBudgets() internal pure returns (uint32[6] memory budgets) {
        budgets[uint256(Session.REGULAR)] = 6 hours;
        budgets[uint256(Session.PRE)] = 8 hours;
        budgets[uint256(Session.POST)] = 8 hours;
        budgets[uint256(Session.CLOSED_OVERNIGHT)] = 24 hours;
        budgets[uint256(Session.CLOSED_WEEKEND)] = 76 hours;
        budgets[uint256(Session.CLOSED_HOLIDAY)] = 108 hours;
    }

    /// @notice Anchor/pool disagreement tolerated per session, in bps.
    function _divergenceBands() internal pure returns (uint16[6] memory bands) {
        bands[uint256(Session.REGULAR)] = 150;
        bands[uint256(Session.PRE)] = 200;
        bands[uint256(Session.POST)] = 200;
        bands[uint256(Session.CLOSED_OVERNIGHT)] = 250;
        bands[uint256(Session.CLOSED_WEEKEND)] = WEEKEND_BAND_BPS;
        bands[uint256(Session.CLOSED_HOLIDAY)] = 300;
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gives `who` a proven non-US jurisdiction through the fallback attester registry.
    /// @dev The Coinbase Verifications path is still exercised on every call: `RegSGate.check`
    ///      queries the real EAS predeploy and the real Coinbase indexer first, finds nothing for a
    ///      freshly generated address, and only then falls through to this registry.
    function _attest(address who) internal {
        attesters.attest(who, bytes2("PL"), 0);
    }

    /// @notice Seeds `who` with USDC and approves the protocol.
    /// @dev SIMULATED INPUT: the starting USDC balance is written into the real USDC contract's
    ///      balance slot rather than bridged in. Everything the token then does - transfers,
    ///      allowances, the vault's accounting - is the live Base deployment.
    function _seedUsdc(address who, uint256 amount) internal {
        deal(USDC, who, IERC20(USDC).balanceOf(who) + amount);
        _approveUsdc(who);
    }

    /// @notice Approves the credit engine and the vault to pull `who`'s USDC.
    function _approveUsdc(address who) internal {
        vm.startPrank(who);
        IERC20(USDC).approve(address(credit), type(uint256).max);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Buys `token` with `usdcIn` USDC through the live Slipstream router and delivers it
    ///         to `to`, then approves the credit engine to pull it.
    /// @dev Acquiring collateral by trading is deliberately preferred over impersonating a holder
    ///      discovered from `Transfer` logs: it needs no address that can go stale, it proves the
    ///      pool is genuinely tradable at the size the tests use, and it exercises a real B20
    ///      precompile transfer in both directions.
    /// @return bought Raw units of `token` received.
    function _buyCollateral(address token, uint256 usdcIn, address to) internal returns (uint256 bought) {
        _seedUsdc(address(this), usdcIn);

        IERC20(USDC).approve(SWAP_ROUTER, usdcIn);
        bought = ISlipstreamSwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                ISlipstreamSwapRouter.ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: token,
                tickSpacing: TICK_SPACING,
                recipient: to,
                deadline: block.timestamp,
                amountIn: usdcIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
        require(bought != 0, "swap returned nothing");

        vm.prank(to);
        IERC20(token).approve(address(credit), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                             SMALL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The advance rate that applies in `session`, in bps.
    function _advanceBps(Session session) internal pure returns (uint256) {
        return session == Session.REGULAR ? ADVANCE_OPEN_BPS : ADVANCE_CLOSED_BPS;
    }

    /// @notice `collateralRaw * mark / 1e36 * advance / 1e4`, i.e. exactly what the engine computes.
    function _expectedPower(uint256 amount, uint256 mark, Session session) internal pure returns (uint256) {
        return (((amount * mark) / ORACLE_SCALE) * _advanceBps(session)) / BPS;
    }

    /// @notice The posted balance the engine is tracking for `asset`.
    function _posted(address asset) internal view returns (uint128 posted) {
        (,,,,,,, posted,) = credit.assetConfig(asset);
    }

    function _verdictName(Verdict verdict) internal pure returns (string memory) {
        if (verdict == Verdict.TRUSTED) return "TRUSTED";
        if (verdict == Verdict.TRUSTED_CLOSED) return "TRUSTED_CLOSED";
        if (verdict == Verdict.UNTRUSTED_STALE) return "UNTRUSTED_STALE";
        if (verdict == Verdict.UNTRUSTED_DIVERGENT) return "UNTRUSTED_DIVERGENT";
        if (verdict == Verdict.UNTRUSTED_THIN) return "UNTRUSTED_THIN";
        return "UNTRUSTED_HALTED";
    }

    function _sessionName(Session session) internal pure returns (string memory) {
        if (session == Session.REGULAR) return "REGULAR";
        if (session == Session.PRE) return "PRE";
        if (session == Session.POST) return "POST";
        if (session == Session.CLOSED_OVERNIGHT) return "CLOSED_OVERNIGHT";
        if (session == Session.CLOSED_WEEKEND) return "CLOSED_WEEKEND";
        return "CLOSED_HOLIDAY";
    }

    /*//////////////////////////////////////////////////////////////
                              FORMATTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Renders a fixed-point `value` with `scaleDecimals` of scale, truncated to `places`.
    function _fixed(uint256 value, uint256 scaleDecimals, uint256 places) internal pure returns (string memory) {
        uint256 unit = 10 ** scaleDecimals;
        string memory whole = vm.toString(value / unit);
        if (places == 0) return whole;

        uint256 fraction = (value % unit) / (10 ** (scaleDecimals - places));
        string memory digits = vm.toString(fraction);
        // Left-pad the fractional part so 5 tenths of a cent never renders as "5".
        while (bytes(digits).length < places) {
            digits = string.concat("0", digits);
        }
        return string.concat(whole, ".", digits);
    }

    /// @notice Renders `value` seconds as `HHh MMm`.
    function _hoursMinutes(uint256 value) internal pure returns (string memory) {
        return string.concat(vm.toString(value / 1 hours), "h ", vm.toString((value % 1 hours) / 1 minutes), "m");
    }

    /// @notice Right-pads `text` with spaces to `width`, or returns it unchanged when already wider.
    function _pad(string memory text, uint256 width) internal pure returns (string memory) {
        while (bytes(text).length < width) {
            text = string.concat(text, " ");
        }
        return text;
    }

    /// @notice Left-pads `text` with spaces to `width`, so numeric columns line up on the decimal.
    function _padLeft(string memory text, uint256 width) internal pure returns (string memory) {
        while (bytes(text).length < width) {
            text = string.concat(" ", text);
        }
        return text;
    }
}
