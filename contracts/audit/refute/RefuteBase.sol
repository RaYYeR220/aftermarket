// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AuditHarness} from "../poc/Harness.sol";
import {AftermarketOracle, OracleConfig} from "../../src/AftermarketOracle.sol";
import {IAftermarketCredit} from "../../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketOracle} from "../../src/interfaces/IAftermarketOracle.sol";

/// @notice Shared base for the refutation suite.
///
/// @dev `audit/poc/Harness.sol` is being edited by someone else while this review runs, so its risk
///      parameters are not stable. Every test in `audit/refute` therefore PINS the parameter set the
///      review brief named - advance 5000/3500, liquidation threshold 7000/8000, bonus 800, gap
///      haircut 25bps + 15bps/h capped at 500, staleness 1h/6h/6h/20h/80h/104h, divergence
///      100/150/150/250/250/250, multiplier bounds [0.01e18, 1000e18] - by deploying its own oracle
///      and re-pointing the asset. Nothing in `src/`, `test/`, `script/` or `audit/poc/` is touched.
abstract contract RefuteBase is AuditHarness {
    uint16 internal constant PIN_BASE_HAIRCUT_BPS = 25;
    uint16 internal constant PIN_HAIRCUT_SLOPE_BPS_PER_HOUR = 15;
    uint16 internal constant PIN_MAX_HAIRCUT_BPS = 500;

    uint16 internal constant PIN_ADVANCE_OPEN_BPS = 5_000;
    uint16 internal constant PIN_ADVANCE_CLOSED_BPS = 3_500;
    uint16 internal constant PIN_LIQ_OPEN_BPS = 7_000;
    uint16 internal constant PIN_LIQ_CLOSED_BPS = 8_000;
    uint16 internal constant PIN_LIQ_BONUS_BPS = 800;

    /// @dev Deploys a fresh oracle carrying the brief's parameters and points the asset at it.
    function _pinBriefDefaults() internal {
        AftermarketOracle pinned = new AftermarketOracle(
            OracleConfig({
                collateralToken: address(nvda),
                loanToken: address(usdc),
                feed: address(feed),
                pool: address(pool),
                calendar: address(calendar),
                multiplierRegistry: address(0),
                twapWindow: TWAP_WINDOW,
                stalenessBudget: [
                    uint32(1 hours),
                    uint32(6 hours),
                    uint32(6 hours),
                    uint32(20 hours),
                    uint32(80 hours),
                    uint32(104 hours)
                ],
                divergenceBandBps: [uint16(100), uint16(150), uint16(150), uint16(250), uint16(250), uint16(250)],
                baseHaircutBps: PIN_BASE_HAIRCUT_BPS,
                haircutSlopeBpsPerHour: PIN_HAIRCUT_SLOPE_BPS_PER_HOUR,
                maxHaircutBps: PIN_MAX_HAIRCUT_BPS,
                minPoolLiquidityUsd: MIN_POOL_LIQUIDITY_USD,
                minMultiplier: 0.01e18,
                maxMultiplier: 1000e18
            })
        );

        vm.prank(owner);
        credit.setAsset(
            address(nvda),
            IAftermarketCredit.AssetParams({
                oracle: IAftermarketOracle(address(pinned)),
                advanceOpenBps: PIN_ADVANCE_OPEN_BPS,
                advanceClosedBps: PIN_ADVANCE_CLOSED_BPS,
                liqThresholdOpenBps: PIN_LIQ_OPEN_BPS,
                liqThresholdClosedBps: PIN_LIQ_CLOSED_BPS,
                liqBonusBps: PIN_LIQ_BONUS_BPS,
                cap: uint128(1_000_000e8),
                enabled: true
            })
        );

        oracle = pinned;
    }
}
