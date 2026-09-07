// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";

import {AftermarketOracle, OracleConfig} from "../src/AftermarketOracle.sol";
import {AftermarketOracleFactory} from "../src/AftermarketOracleFactory.sol";
import {IAftermarketOracle} from "../src/interfaces/IAftermarketOracle.sol";
import {Quote} from "../src/libraries/Types.sol";

import {AftermarketConfig} from "./AftermarketConfig.sol";

/// @title  DeployNegativeControl
/// @notice Deploys a deliberately over-strict twin of the demonstration asset's oracle, so that the
///         production oracle's success is falsifiable.
///
/// @dev A green check is worthless if nothing could have turned it red. Aftermarket's central claim
///      is that its oracle refuses to produce a mark it cannot defend - but on any given day, a
///      passing `price()` is equally consistent with "the checks work" and "the checks never fire".
///
///      This script settles that. It deploys a second `AftermarketOracle` for the same asset, the
///      same feed, the same pool and the same calendar, differing in exactly one number: the
///      divergence band, tightened to 25 bps in every session. Against live Base mainnet data the
///      Coinbase AMZN feed and the Aerodrome AMZNc/USDC pool disagree by several hundred bps, so the
///      production oracle - whose closed-session band is wide enough to tolerate a weekend gap -
///      returns a price, while this one reverts with `SourcesDiverged`.
///
///      Two oracles, one input, opposite answers, on the same block. That is the control.
///
///      ## Usage
///
///          cp script/config/base.json deployments/base.json
///          CONFIG=deployments/base.json \
///            forge script script/DeployNegativeControl.s.sol:DeployNegativeControl \
///            --rpc-url https://mainnet.base.org --broadcast
///
///      `DeployCore` must have run first: the factory and the calendar are read from
///      `deployments/<chainId>.json`, so the control shares the exact calendar the production
///      oracle uses and cannot accidentally differ in a second place.
contract DeployNegativeControl is AftermarketConfig {
    /// @notice `DeployCore` has not run on this chain yet.
    error CoreNotDeployed(string missing);
    /// @notice The band override would not actually differ from production.
    error BandNotStricter(uint16 control, uint16 production);

    function run() external {
        _loadConfig();
        _requireAssets();
        _shimPredeployAssets();

        string memory existing = _readDeployments();
        address calendarAddress = _recorded(existing, "tradingCalendar");
        address factoryAddress = _recorded(existing, "oracleFactory");
        if (calendarAddress == address(0)) revert CoreNotDeployed("tradingCalendar");
        if (factoryAddress == address(0)) revert CoreNotDeployed("oracleFactory");

        uint256 index = _negativeControlIndex();
        AssetSpec memory spec = assets[index];

        for (uint256 i; i < SESSION_COUNT; ++i) {
            if (negativeControlBandBps >= divergenceBandBps[i]) {
                revert BandNotStricter(negativeControlBandBps, divergenceBandBps[i]);
            }
        }

        OracleConfig memory cfg = _oracleConfig(index, calendarAddress, negativeControlBandBps);
        AftermarketOracleFactory factory = AftermarketOracleFactory(factoryAddress);
        address predicted = factory.predictAddress(cfg);

        if (predicted.code.length == 0) {
            vm.startBroadcast();
            factory.deploy(cfg);
            vm.stopBroadcast();
        }

        vm.writeJson(vm.toString(predicted), _deploymentsPath(), ".negativeControl");

        _report(spec, _recorded(existing, string.concat("oracles.", spec.symbol)), predicted);
    }

    function _report(AssetSpec memory spec, address production, address control) private view {
        console2.log("negative control asset  ", spec.symbol);
        console2.log("production oracle       ", production);
        console2.log("negative control oracle ", control);
        console2.log("production band (bps)   ", uint256(divergenceBandBps[0]));
        console2.log("control band (bps)      ", uint256(negativeControlBandBps));

        Quote memory q = AftermarketOracle(control).peek();
        console2.log("live divergence (bps)   ", q.divergenceBps);
        console2.log("control verdict         ", uint256(q.verdict));

        if (production != address(0)) {
            _reportPrice("production", production);
        }
        _reportPrice("control   ", control);
    }

    function _reportPrice(string memory label, address oracle) private view {
        try IAftermarketOracle(oracle).price() returns (uint256 price) {
            console2.log(string.concat(label, " price()  "), price);
        } catch (bytes memory err) {
            console2.log(string.concat(label, " price() reverted, selector below"));
            console2.logBytes4(_selector(err));
        }
    }
}
