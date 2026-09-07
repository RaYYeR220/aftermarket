// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AftermarketCredit} from "../../src/AftermarketCredit.sol";
import {AftermarketOracle, OracleConfig} from "../../src/AftermarketOracle.sol";
import {AftermarketVault} from "../../src/AftermarketVault.sol";
import {SessionRateModel, ISessionRateModel} from "../../src/SessionRateModel.sol";
import {TradingCalendar} from "../../src/TradingCalendar.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketOracle} from "../../src/interfaces/IAftermarketOracle.sol";
import {IEligibility} from "../../src/interfaces/IEligibility.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {ITradingCalendar} from "../../src/interfaces/ITradingCalendar.sol";
import {Session} from "../../src/libraries/Types.sol";

import {MockAggregatorV3} from "../../test/mocks/MockAggregatorV3.sol";
import {MockCLPool} from "../../test/mocks/MockCLPool.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockEligibility} from "../../test/mocks/MockEligibility.sol";
import {MockSwapAdapter} from "../../test/mocks/MockSwapAdapter.sol";

/// @notice Full-fidelity audit harness.
///
/// @dev Deliberately mocks NOTHING that belongs to Aftermarket. The REAL `TradingCalendar`, the REAL
///      `AftermarketOracle`, the REAL `SessionRateModel`, the REAL `AftermarketCredit` and the REAL
///      `AftermarketVault` are deployed and wired to each other exactly as they would be on Base. Only
///      the two external venues the protocol integrates with - the Chainlink aggregator and the
///      Aerodrome Slipstream pool - are test doubles, because there is no way to run either locally.
///
///      All oracle parameters are the deployment defaults documented in
///      `script/config/base.json`, i.e. the parameters that will actually ship on Base mainnet:
///      staleness 1h/6h/6h/25h/73h/97h, divergence bands 200/400/400/800/1200/1500 bps, a
///      100bps + 10bps/h gap haircut capped at 1000bps, a 30-minute TWAP, a $25k pool-depth floor,
///      multiplier bounds [0.01e18, 1000e18], advance 6500/5000 open/closed, liquidation threshold
///      8000/8500 open/closed, a 700bps bonus and a 100bps sweep slippage budget.
abstract contract AuditHarness is Test {
    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT-DEFAULT ORACLE CONFIG
    //////////////////////////////////////////////////////////////*/

    uint32 internal constant TWAP_WINDOW = 1800;
    uint128 internal constant MIN_POOL_LIQUIDITY_USD = 25_000e18;
    uint16 internal constant BASE_HAIRCUT_BPS = 100;
    uint16 internal constant HAIRCUT_SLOPE_BPS_PER_HOUR = 10;
    uint16 internal constant MAX_HAIRCUT_BPS = 1_000;

    uint16 internal constant ADVANCE_OPEN_BPS = 6_500;
    uint16 internal constant ADVANCE_CLOSED_BPS = 5_000;
    uint16 internal constant LIQ_THRESHOLD_OPEN_BPS = 8_000;
    uint16 internal constant LIQ_THRESHOLD_CLOSED_BPS = 8_500;
    uint16 internal constant LIQ_BONUS_BPS = 700;

    /*//////////////////////////////////////////////////////////////
                                 CALENDAR
    //////////////////////////////////////////////////////////////*/

    /// @dev 2026-03-02 is a Monday. The whole week 2026-03-02..2026-03-06 is a normal trading week
    ///      and sits before the 2026-03-08 DST switch, so US Eastern is a flat UTC-5 throughout.
    uint256 internal constant MON_2026_03_02 = 20_514;
    uint256 internal constant EST = 5 hours;

    uint256 internal constant T_PRE_OPEN = 4 hours;
    uint256 internal constant T_OPEN = 9 hours + 30 minutes;
    uint256 internal constant T_CLOSE = 16 hours;
    uint256 internal constant T_POST_CLOSE = 20 hours;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    MockERC20 internal usdc;
    MockERC20 internal nvda;

    TradingCalendar internal calendar;
    MockAggregatorV3 internal feed;
    MockCLPool internal pool;
    AftermarketOracle internal oracle;

    MockEligibility internal eligibility;
    MockSwapAdapter internal adapter;
    SessionRateModel internal rateModel;
    AftermarketCredit internal credit;
    AftermarketVault internal vault;

    address internal owner = makeAddr("owner");
    address internal supplier = makeAddr("supplier");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    /// @dev Chainlink answer currently published, at 8 decimals.
    int256 internal feedAnswer;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function _deploy(int256 initialAnswer8dec) internal {
        int24 poolTick = 0;
        // Monday 2026-03-02, 11:00 ET, mid regular session.
        vm.warp(_et(MON_2026_03_02, T_OPEN));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        nvda = new MockERC20("Coinbase NVDA", "NVDAc", 8);

        calendar = new TradingCalendar();

        feedAnswer = initialAnswer8dec;
        feed = new MockAggregatorV3(8, initialAnswer8dec, block.timestamp);

        // Mirrors the live NVDAc/USDC Slipstream pool: USDC is token0, NVDAc is token1, spacing 10.
        pool = new MockCLPool(address(usdc), address(nvda), 10);
        pool.setMeanTick(poolTick, TWAP_WINDOW);
        _currentTick = poolTick;
        // Loan-side depth backing the TWAP. $100k, comfortably over the $25k floor.
        usdc.mint(address(pool), 100_000e6);

        oracle = new AftermarketOracle(_oracleConfig(address(nvda), address(usdc), address(pool)));
        _setPriceBoth(initialAnswer8dec);

        eligibility = new MockEligibility();
        adapter = new MockSwapAdapter();

        uint256[6] memory multipliers =
            [uint256(1e18), uint256(1e18), uint256(1e18), uint256(1.25e18), uint256(1.5e18), uint256(1.6e18)];
        rateModel = new SessionRateModel(
            ITradingCalendar(address(calendar)),
            634_195_839, // 2% APR floor
            1_902_587_519, // +6% APR at the kink
            31_709_791_983, // +100% APR at full utilisation
            0.8e18,
            multipliers
        );

        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        credit = new AftermarketCredit(
            IERC20(address(usdc)),
            predictedVault,
            ITradingCalendar(address(calendar)),
            IEligibility(address(eligibility)),
            ISessionRateModel(address(rateModel)),
            ISwapAdapter(address(adapter)),
            100,
            owner
        );
        vault = new AftermarketVault(IERC20(address(usdc)), address(credit), "Aftermarket USDC", "amUSDC");
        require(address(vault) == predictedVault, "vault prediction");

        vm.prank(owner);
        credit.setAsset(
            address(nvda),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(oracle)),
                advanceOpenBps: ADVANCE_OPEN_BPS,
                advanceClosedBps: ADVANCE_CLOSED_BPS,
                liqThresholdOpenBps: LIQ_THRESHOLD_OPEN_BPS,
                liqThresholdClosedBps: LIQ_THRESHOLD_CLOSED_BPS,
                liqBonusBps: LIQ_BONUS_BPS,
                cap: uint128(1_000_000e8),
                enabled: true
            })
        );

        _fund(supplier, 5_000_000e6, 0);
        _fund(alice, 1_000_000e6, 10_000e8);
        _fund(keeper, 1_000_000e6, 0);

        vm.prank(supplier);
        vault.deposit(1_000_000e6, supplier);
    }

    /// @dev The deployment defaults, lifted verbatim from `test/AftermarketOracle.t.sol::_config`.
    function _oracleConfig(address collateral_, address loan_, address pool_)
        internal
        view
        returns (OracleConfig memory)
    {
        return OracleConfig({
            collateralToken: collateral_,
            loanToken: loan_,
            feed: address(feed),
            pool: pool_,
            calendar: address(calendar),
            multiplierRegistry: address(0),
            twapWindow: TWAP_WINDOW,
            stalenessBudget: [
                uint32(3600), // REGULAR           1h
                uint32(21_600), // PRE              6h
                uint32(21_600), // POST             6h
                uint32(90_000), // CLOSED_OVERNIGHT 25h
                uint32(262_800), // CLOSED_WEEKEND  73h
                uint32(349_200) // CLOSED_HOLIDAY   97h
            ],
            divergenceBandBps: [uint16(200), uint16(400), uint16(400), uint16(800), uint16(1_200), uint16(1_500)],
            baseHaircutBps: BASE_HAIRCUT_BPS,
            haircutSlopeBpsPerHour: HAIRCUT_SLOPE_BPS_PER_HOUR,
            maxHaircutBps: MAX_HAIRCUT_BPS,
            minPoolLiquidityUsd: MIN_POOL_LIQUIDITY_USD,
            minMultiplier: 0.01e18,
            maxMultiplier: 1_000e18
        });
    }

    function _fund(address who, uint256 usdcAmount, uint256 nvdaAmount) internal {
        if (usdcAmount != 0) usdc.mint(who, usdcAmount);
        if (nvdaAmount != 0) nvda.mint(who, nvdaAmount);
        vm.startPrank(who);
        usdc.approve(address(credit), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        nvda.approve(address(credit), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  TIME
    //////////////////////////////////////////////////////////////*/

    /// @dev DST start/end for 2026, in unix seconds, mirroring `TradingCalendar._daylightWindow`.
    ///      2026-03-08 is the second Sunday of March (day 20520) and 2026-11-01 is the first Sunday
    ///      of November (day 20758).
    uint256 internal constant DST_START_2026 = 20_520 * 1 days + 7 hours;
    uint256 internal constant DST_END_2026 = 20_758 * 1 days + 6 hours;

    /// @dev Unix second of `secondOfDay` US Eastern on `dayNumber`, applying the same
    ///      assume-standard-time-then-correct rule the calendar itself uses.
    function _et(uint256 dayNumber, uint256 secondOfDay) internal pure returns (uint256) {
        uint256 asStandardTime = dayNumber * 1 days + secondOfDay + EST;
        if (asStandardTime >= DST_START_2026 && asStandardTime < DST_END_2026) {
            return dayNumber * 1 days + secondOfDay + 4 hours;
        }
        return asStandardTime;
    }

    /// @dev Warps to a wall-clock instant and refreshes the Chainlink answer if, and only if, the
    ///      market is in its regular session - which is exactly how a Coinbase equity feed behaves.
    function _warpTo(uint256 dayNumber, uint256 secondOfDay) internal {
        vm.warp(_et(dayNumber, secondOfDay));
        if (calendar.isOpen(block.timestamp)) feed.set(feedAnswer, block.timestamp);
    }

    /// @dev Publishes a new closing print. Only ever called while a regular session is running.
    function _setPrice(int256 answer8dec, int24 poolTick) internal {
        feedAnswer = answer8dec;
        feed.set(answer8dec, block.timestamp);
        pool.setMeanTick(poolTick, TWAP_WINDOW);
        _currentTick = poolTick;
    }

    /// @dev Moves both venues to `answer8dec`, deriving the pool tick from the oracle's own TWAP
    ///      decoder so the two sources agree to well inside every divergence band.
    function _setPriceBoth(int256 answer8dec) internal {
        _setPrice(answer8dec, _tickForPriceWad(uint256(answer8dec) * 1e10));
    }

    /// @dev Binary-searches the arithmetic-mean tick whose decoded pool price is closest to
    ///      `targetWad`, by driving the real `AftermarketOracle._readPoolPrice` through `peek()`.
    ///      Pool price is strictly decreasing in the tick for this token ordering.
    function _tickForPriceWad(uint256 targetWad) internal returns (int24) {
        int24 saved = _currentTick;
        int256 lo = -800_000;
        int256 hi = 800_000;
        while (lo < hi) {
            int256 mid = (lo + hi) / 2;
            if ((lo + hi) % 2 != 0 && (lo + hi) < 0) --mid; // floor division for negatives
            pool.setMeanTick(int24(mid), TWAP_WINDOW);
            uint256 p = oracle.peek().poolPrice;
            if (p == 0 || p > targetWad) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        pool.setMeanTick(saved, TWAP_WINDOW);
        return int24(lo);
    }

    int24 internal _currentTick;

    function _sessionName(Session s) internal pure returns (string memory) {
        if (s == Session.REGULAR) return "REGULAR";
        if (s == Session.PRE) return "PRE";
        if (s == Session.POST) return "POST";
        if (s == Session.CLOSED_OVERNIGHT) return "CLOSED_OVERNIGHT";
        if (s == Session.CLOSED_WEEKEND) return "CLOSED_WEEKEND";
        return "CLOSED_HOLIDAY";
    }
}
