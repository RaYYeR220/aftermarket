// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";

import {Id, IMorpho, Market, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/src/libraries/MarketParamsLib.sol";

import {AftermarketConfig} from "./AftermarketConfig.sol";

/// @title  CreateMorphoMarket
/// @notice Opens a permissionless Morpho Blue market that borrows USDC against a B20 equity token,
///         priced by an `AftermarketOracle`.
///
/// @dev This is the point of implementing Morpho's `IOracle` faithfully. `AftermarketOracle.price()`
///      is the whole integration surface: Morpho Blue reads it in `borrow`, `withdrawCollateral` and
///      `liquidate`, and nowhere else. A market created here therefore inherits Aftermarket's
///      central behaviour without a line of new code - when the feed goes stale over a weekend, or
///      the pool and the reference disagree beyond the session's band, the oracle reverts and
///      Morpho freezes new borrowing, collateral withdrawal and liquidation while leaving `repay`
///      and `supplyCollateral` open. Borrowers can always cure; nobody can seize.
///
///      ## The LLTV is not assumed
///
///      Morpho Blue only permits LLTVs the DAO has enabled. The configured value is checked with
///      `isLltvEnabled` before anything is sent, and if it is not enabled the script scans the
///      standard ladder and picks the closest enabled value rather than reverting on-chain with an
///      opaque error. Confirmed against `https://mainnet.base.org`: `isLltvEnabled(770000000000000000)`
///      returns true on Base mainnet and on Base Sepolia, so the configured 77% is used as-is.
///
///      ## Usage
///
///          cp script/config/base.json deployments/base.json
///          CONFIG=deployments/base.json ASSET=AMZNc \
///            forge script script/CreateMorphoMarket.s.sol:CreateMorphoMarket \
///            --rpc-url https://mainnet.base.org --broadcast
///
///      `ASSET` defaults to the demonstration asset named in the config's `negativeControl` block.
///      The resulting market id is written to `deployments/<chainId>.json` under
///      `morphoMarkets.<symbol>`.
contract CreateMorphoMarket is AftermarketConfig {
    using MarketParamsLib for MarketParams;

    /// @notice `DeployCore` has not run, or has not deployed an oracle for this asset.
    error OracleNotDeployed(string symbol);
    /// @notice Morpho Blue has no enabled LLTV at all on this chain.
    error NoEnabledLltv();

    /// @dev The LLTV ladder Morpho Blue ships with. Used only to find the nearest *enabled* value
    ///      when the configured one is not; the chain remains the authority through `isLltvEnabled`.
    function _ladder() private pure returns (uint256[9] memory) {
        return [uint256(0), 0.385e18, 0.625e18, 0.77e18, 0.86e18, 0.915e18, 0.945e18, 0.965e18, 0.98e18];
    }

    function run() external {
        _loadConfig();
        _requireAssets();
        _shimPredeployAssets();

        string memory symbol = vm.envOr("ASSET", negativeControlSymbol);
        uint256 index = _indexOf(symbol);
        AssetSpec memory spec = assets[index];

        string memory existing = _readDeployments();
        address oracle = _recorded(existing, string.concat("oracles.", spec.symbol));
        if (oracle == address(0)) revert OracleNotDeployed(spec.symbol);

        IMorpho morpho = IMorpho(morphoBlue);
        uint256 lltv = _enabledLltv(morpho, morphoLltv);

        MarketParams memory params =
            MarketParams({loanToken: usdc, collateralToken: spec.token, oracle: oracle, irm: morphoIrm, lltv: lltv});
        Id id = params.id();

        console2.log("loan token   ", params.loanToken);
        console2.log("collateral   ", params.collateralToken);
        console2.log("oracle       ", params.oracle);
        console2.log("irm          ", params.irm);
        console2.log("lltv         ", params.lltv);
        console2.log("market id    ");
        console2.logBytes32(Id.unwrap(id));

        Market memory market = morpho.market(id);
        if (market.lastUpdate == 0) {
            vm.startBroadcast();
            morpho.createMarket(params);
            vm.stopBroadcast();
            console2.log("market created");
        } else {
            console2.log("market already exists, last updated at", market.lastUpdate);
        }

        vm.writeJson(vm.toString(Id.unwrap(id)), _deploymentsPath(), string.concat(".morphoMarkets.", spec.symbol));
    }

    /// @dev The configured LLTV if Morpho has it enabled, otherwise the nearest enabled rung.
    function _enabledLltv(IMorpho morpho, uint256 wanted) private view returns (uint256) {
        if (morpho.isLltvEnabled(wanted)) {
            console2.log("configured lltv is enabled on this chain");
            return wanted;
        }

        uint256[9] memory ladder = _ladder();
        uint256 best;
        uint256 bestDistance = type(uint256).max;
        bool found;

        for (uint256 i; i < ladder.length; ++i) {
            if (!morpho.isLltvEnabled(ladder[i])) continue;

            uint256 distance = ladder[i] > wanted ? ladder[i] - wanted : wanted - ladder[i];
            if (distance < bestDistance) {
                bestDistance = distance;
                best = ladder[i];
                found = true;
            }
        }
        if (!found) revert NoEnabledLltv();

        console2.log("configured lltv is NOT enabled; using the nearest enabled value", wanted, best);
        return best;
    }

    function _indexOf(string memory symbol) private view returns (uint256) {
        bytes32 wanted = keccak256(bytes(symbol));
        for (uint256 i; i < assets.length; ++i) {
            if (keccak256(bytes(assets[i].symbol)) == wanted) return i;
        }
        revert IncompleteAsset(symbol);
    }
}
