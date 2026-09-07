// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AftermarketCredit} from "../src/AftermarketCredit.sol";
import {AftermarketLens} from "../src/AftermarketLens.sol";
import {AftermarketOracle, OracleConfig} from "../src/AftermarketOracle.sol";
import {AftermarketOracleFactory} from "../src/AftermarketOracleFactory.sol";
import {AftermarketVault} from "../src/AftermarketVault.sol";
import {AttesterRegistry} from "../src/AttesterRegistry.sol";
import {AutoRepayer} from "../src/AutoRepayer.sol";
import {RegSGate} from "../src/RegSGate.sol";
import {ISessionRateModel, SessionRateModel} from "../src/SessionRateModel.sol";
import {TradingCalendar} from "../src/TradingCalendar.sol";
import {AerodromeSwapAdapter, ISlipstreamSwapRouter} from "../src/adapters/AerodromeSwapAdapter.sol";
import {IAftermarketCredit} from "../src/interfaces/IAftermarketCredit.sol";
import {IAftermarketOracle} from "../src/interfaces/IAftermarketOracle.sol";
import {IEligibility} from "../src/interfaces/IEligibility.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {ITradingCalendar} from "../src/interfaces/ITradingCalendar.sol";
import {Session} from "../src/libraries/Types.sol";

import {AftermarketConfig} from "./AftermarketConfig.sol";

/// @title  DeployCore
/// @notice Deploys the whole Aftermarket stack from `script/config/<network>.json` and records the
///         result in `deployments/<chainId>.json`.
///
/// @dev ## Usage
///
///      Base mainnet, using a config copied into the one directory `foundry.toml` permits:
///
///          cp script/config/base.json deployments/base.json
///          CONFIG=deployments/base.json \
///            forge script script/DeployCore.s.sol:DeployCore \
///            --rpc-url https://mainnet.base.org --broadcast --verify
///
///      Drop `--broadcast` for a dry run: the script still writes `deployments/<chainId>.json`, so
///      a simulation produces a complete, inspectable record before anything is signed.
///
///      Environment: `OWNER` sets the protocol owner (default: the deployer). `FRESH=1` ignores an
///      existing deployment record and redeploys everything.
///
///      ## Ordering
///
///      The order is a dependency order, and it differs from the obvious reading order in one
///      place: `AerodromeSwapAdapter` is deployed *before* `AftermarketCredit`, because the engine
///      takes the adapter as a constructor argument. The alternative - construct the engine with a
///      zero adapter and set it afterwards - would leave a live protocol in which `sweepYield`
///      reverts for as long as it takes the second transaction to land, which is not a state worth
///      creating to preserve a listing order.
///
///      `AftermarketCredit` and `AftermarketVault` reference each other immutably, so the vault
///      address is predicted before the engine is deployed and the vault's own constructor checks
///      the reverse link. A wrong prediction can therefore only produce a failed deployment, never
///      a live mis-wired protocol. Because that pairing is atomic, the reuse logic treats the two as
///      one unit: if either is missing from the record, both are deployed again.
///
///      ## Idempotence
///
///      Re-running reuses every address already present in `deployments/<chainId>.json`. Oracles get
///      a stronger guarantee than the file: they are deployed through a CREATE2 factory, so the
///      script recomputes each oracle's counterfactual address from the config and reuses it if code
///      is already there. An oracle can therefore never be duplicated, and an oracle whose config
///      changed lands at a new address rather than silently shadowing the old one.
contract DeployCore is AftermarketConfig {
    /// @notice ERC-4626 metadata for the supply-side vault.
    string internal constant VAULT_NAME = "Aftermarket USDC";
    string internal constant VAULT_SYMBOL = "amUSDC";

    /// @dev 17:00 UTC is inside the regular session on any trading day, in both EST and EDT, so a
    ///      calendar that reports anything other than a holiday at that hour disagrees with the
    ///      config it was deployed alongside.
    uint256 internal constant HOLIDAY_PROBE_HOUR = 17 hours;

    /// @notice The deployed calendar disagrees with the holiday table in the config.
    error CalendarSeedMismatch(uint32 day, Session session);
    /// @notice The predicted vault address did not match the deployed one.
    error VaultPredictionFailed(address predicted, address actual);
    /// @notice The factory produced an oracle somewhere other than its counterfactual address.
    error OracleAddressMismatch(address predicted, address actual);

    struct Deployment {
        address calendar;
        address attesters;
        address gate;
        address rateModel;
        address oracleFactory;
        address swapAdapter;
        address credit;
        address vault;
        address autoRepayer;
        address lens;
    }

    Deployment internal d;
    address[] internal oracles;
    address internal deployer;
    address internal protocolOwner;

    function run() external {
        _loadConfig();
        _requireAssets();
        _shimPredeployAssets();

        deployer = msg.sender;
        protocolOwner = vm.envOr("OWNER", deployer);

        bool fresh = vm.envOr("FRESH", uint256(0)) == 1;
        string memory existing = fresh ? "" : _readDeployments();

        console2.log("network      ", networkName);
        console2.log("chain id     ", block.chainid);
        console2.log("config       ", configPath);
        console2.log("deployer     ", deployer);
        console2.log("owner        ", protocolOwner);
        console2.log("reusing      ", bytes(existing).length != 0);

        vm.startBroadcast();
        _deployBase(existing);
        _deployOracles(existing);
        _deployEngine(existing);
        _deployPeriphery(existing);
        _configureAssets();
        vm.stopBroadcast();

        _verifyCalendar();
        _writeDeployments(existing);
        _report();
    }

    /*//////////////////////////////////////////////////////////////
                              DEPLOY STEPS
    //////////////////////////////////////////////////////////////*/

    function _deployBase(string memory existing) private {
        d.calendar = _recorded(existing, "tradingCalendar");
        if (d.calendar == address(0)) d.calendar = address(new TradingCalendar());

        d.attesters = _recorded(existing, "attesterRegistry");
        if (d.attesters == address(0)) d.attesters = address(new AttesterRegistry(protocolOwner));

        d.gate = _recorded(existing, "regSGate");
        if (d.gate == address(0)) {
            d.gate = address(
                new RegSGate(
                    protocolOwner,
                    easAddress,
                    indexerAddress,
                    verifiedCountrySchema,
                    verifiedAccountSchema,
                    d.attesters,
                    // The gate already restricts the US and the sanctioned jurisdictions in its own
                    // constructor. Anything beyond that is a policy decision for the owner, made
                    // visibly with `restrict`, not folded silently into a deployment.
                    new bytes2[](0)
                )
            );
        }

        d.rateModel = _recorded(existing, "sessionRateModel");
        if (d.rateModel == address(0)) {
            d.rateModel = address(
                new SessionRateModel(
                    ITradingCalendar(d.calendar),
                    baseRatePerSecond,
                    slope1PerSecond,
                    slope2PerSecond,
                    kink,
                    sessionMultipliers
                )
            );
        }

        d.oracleFactory = _recorded(existing, "oracleFactory");
        if (d.oracleFactory == address(0)) d.oracleFactory = address(new AftermarketOracleFactory());
    }

    /// @dev One oracle per configured asset, at its deterministic CREATE2 address.
    function _deployOracles(string memory) private {
        AftermarketOracleFactory factory = AftermarketOracleFactory(d.oracleFactory);

        for (uint256 i; i < assets.length; ++i) {
            OracleConfig memory cfg = _oracleConfig(i, d.calendar, 0);
            address predicted = factory.predictAddress(cfg);

            if (predicted.code.length == 0) {
                address deployed = address(factory.deploy(cfg));
                if (deployed != predicted) revert OracleAddressMismatch(predicted, deployed);
            }
            oracles.push(predicted);
        }
    }

    function _deployEngine(string memory existing) private {
        d.swapAdapter = _recorded(existing, "swapAdapter");
        if (d.swapAdapter == address(0)) {
            d.swapAdapter = address(
                new AerodromeSwapAdapter(ISlipstreamSwapRouter(slipstreamRouter), slipstreamTickSpacing, protocolOwner)
            );
        }

        d.credit = _recorded(existing, "credit");
        d.vault = _recorded(existing, "vault");
        if (d.credit != address(0) && d.vault != address(0)) return;

        // The engine is deployed first and the vault immediately after, from the same account, so
        // the vault lands at the next CREATE address. The vault's constructor verifies the reverse
        // link, turning any mistake here into a failed deployment rather than a broken protocol.
        address predictedVault = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);

        d.credit = address(
            new AftermarketCredit(
                IERC20(usdc),
                predictedVault,
                ITradingCalendar(d.calendar),
                IEligibility(d.gate),
                ISessionRateModel(d.rateModel),
                ISwapAdapter(d.swapAdapter),
                maxSlippageBps,
                protocolOwner
            )
        );
        d.vault = address(new AftermarketVault(IERC20(usdc), d.credit, VAULT_NAME, VAULT_SYMBOL));
        if (d.vault != predictedVault) revert VaultPredictionFailed(predictedVault, d.vault);
    }

    function _deployPeriphery(string memory existing) private {
        d.autoRepayer = _recorded(existing, "autoRepayer");
        if (d.autoRepayer == address(0)) d.autoRepayer = address(new AutoRepayer(AftermarketCredit(d.credit)));

        d.lens = _recorded(existing, "lens");
        if (d.lens == address(0)) {
            d.lens = address(
                new AftermarketLens(AftermarketCredit(d.credit), AutoRepayer(d.autoRepayer), _assetAddresses())
            );
        }
    }

    /// @dev Listing is an owner action. When the protocol is being handed straight to a multisig the
    ///      deployer cannot perform it, so the script prints what the owner has to send instead of
    ///      reverting halfway through a deployment that is otherwise complete and correct.
    function _configureAssets() private {
        if (protocolOwner != deployer) {
            console2.log("owner is not the deployer: `setAsset` must be sent by the owner for each asset");
            return;
        }

        AftermarketCredit credit = AftermarketCredit(d.credit);
        for (uint256 i; i < assets.length; ++i) {
            credit.setAsset(assets[i].token, _assetParams(i));
        }
    }

    function _assetParams(uint256 i) private view returns (IAftermarketCredit.AssetParams memory) {
        // A cap is configured in whole tokens and scaled by the token's own decimals, so the config
        // never has to restate a decimal count that the token already publishes.
        uint256 unit = 10 ** uint256(_decimals(assets[i].token));

        return IAftermarketCredit.AssetParams({
            oracle: IAftermarketOracle(oracles[i]),
            advanceOpenBps: advanceOpenBps,
            advanceClosedBps: advanceClosedBps,
            liqThresholdOpenBps: liqThresholdOpenBps,
            liqThresholdClosedBps: liqThresholdClosedBps,
            liqBonusBps: liqBonusBps,
            // casting to 'uint128' is safe because a cap of a few hundred whole tokens at eighteen
            // decimals is roughly 1e20, twenty orders of magnitude below the ceiling
            // forge-lint: disable-next-line(unsafe-typecast)
            cap: uint128(assets[i].capWholeTokens * unit),
            enabled: true
        });
    }

    function _decimals(address token) private view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && ret.length == 32, "token has no decimals()");
        // casting to 'uint8' is safe because `decimals()` is a uint8 by ERC-20
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(abi.decode(ret, (uint256)));
    }

    /*//////////////////////////////////////////////////////////////
                              VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @dev The calendar seeds its holidays immutably in its own constructor, so the config's table
    ///      is a claim about deployed bytecode. Checking it here is what stops the two drifting: a
    ///      holiday that exists in the config and not in the contract would otherwise show up as an
    ///      unexplained liquidation on a day the market was shut.
    function _verifyCalendar() private view {
        ITradingCalendar calendar = ITradingCalendar(d.calendar);

        for (uint256 i; i < holidays.length; ++i) {
            uint256 probe = uint256(holidays[i]) * 1 days + HOLIDAY_PROBE_HOUR;
            (Session session,,) = calendar.sessionAt(probe);
            if (session != Session.CLOSED_HOLIDAY) revert CalendarSeedMismatch(holidays[i], session);
        }
        console2.log("calendar holidays verified", holidays.length);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT RECORD
    //////////////////////////////////////////////////////////////*/

    function _writeDeployments(string memory existing) private {
        vm.createDir("deployments", true);

        string memory root = "aftermarket";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "network", networkName);
        vm.serializeUint(root, "blockNumber", block.number);
        vm.serializeUint(root, "timestamp", block.timestamp);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "owner", protocolOwner);
        vm.serializeAddress(root, "usdc", usdc);
        vm.serializeAddress(root, "spendPermissionManager", spendPermissionManager);

        vm.serializeAddress(root, "tradingCalendar", d.calendar);
        vm.serializeAddress(root, "attesterRegistry", d.attesters);
        vm.serializeAddress(root, "regSGate", d.gate);
        vm.serializeAddress(root, "sessionRateModel", d.rateModel);
        vm.serializeAddress(root, "oracleFactory", d.oracleFactory);
        vm.serializeAddress(root, "swapAdapter", d.swapAdapter);
        vm.serializeAddress(root, "credit", d.credit);
        vm.serializeAddress(root, "vault", d.vault);
        vm.serializeAddress(root, "autoRepayer", d.autoRepayer);

        // Carried over rather than reset: these are written by `DeployNegativeControl` and
        // `CreateMorphoMarket`, and re-running the core deployment must not erase them.
        vm.serializeAddress(root, "negativeControl", _recorded(existing, "negativeControl"));
        vm.serializeString(root, "morphoMarkets", _preserveMorphoMarkets(existing));

        vm.serializeString(root, "oracles", _serializeOracles());
        vm.serializeString(root, "constructorArgs", _serializeConstructorArgs());

        string memory out = vm.serializeAddress(root, "lens", d.lens);
        vm.writeJson(out, _deploymentsPath());
    }

    function _serializeOracles() private returns (string memory json) {
        string memory key = "aftermarket.oracles";
        json = "{}";
        for (uint256 i; i < assets.length; ++i) {
            json = vm.serializeAddress(key, assets[i].symbol, oracles[i]);
        }
    }

    /// @dev ABI-encoded constructor arguments, so `forge verify-contract` needs nothing recomputed
    ///      by hand months later.
    function _serializeConstructorArgs() private returns (string memory json) {
        string memory key = "aftermarket.constructorArgs";

        vm.serializeBytes(key, "attesterRegistry", abi.encode(protocolOwner));
        vm.serializeBytes(
            key,
            "regSGate",
            abi.encode(
                protocolOwner,
                easAddress,
                indexerAddress,
                verifiedCountrySchema,
                verifiedAccountSchema,
                d.attesters,
                new bytes2[](0)
            )
        );
        vm.serializeBytes(
            key,
            "sessionRateModel",
            abi.encode(d.calendar, baseRatePerSecond, slope1PerSecond, slope2PerSecond, kink, sessionMultipliers)
        );
        vm.serializeBytes(key, "swapAdapter", abi.encode(slipstreamRouter, slipstreamTickSpacing, protocolOwner));
        vm.serializeBytes(
            key,
            "credit",
            abi.encode(usdc, d.vault, d.calendar, d.gate, d.rateModel, d.swapAdapter, maxSlippageBps, protocolOwner)
        );
        vm.serializeBytes(key, "vault", abi.encode(usdc, d.credit, VAULT_NAME, VAULT_SYMBOL));
        vm.serializeBytes(key, "autoRepayer", abi.encode(d.credit));
        vm.serializeBytes(key, "lens", abi.encode(d.credit, d.autoRepayer, _assetAddresses()));

        string memory oracleArgs = "aftermarket.constructorArgs.oracles";
        string memory oracleArgsJson = "{}";
        for (uint256 i; i < assets.length; ++i) {
            oracleArgsJson =
                vm.serializeBytes(oracleArgs, assets[i].symbol, abi.encode(_oracleConfig(i, d.calendar, 0)));
        }
        json = vm.serializeString(key, "oracles", oracleArgsJson);
    }

    function _preserveMorphoMarkets(string memory existing) private returns (string memory json) {
        string memory key = "aftermarket.morphoMarkets";
        json = "{}";

        if (bytes(existing).length == 0) return json;
        for (uint256 i; i < assets.length; ++i) {
            string memory path = string.concat(".morphoMarkets.", assets[i].symbol);
            if (!vm.keyExistsJson(existing, path)) continue;
            json = vm.serializeBytes32(key, assets[i].symbol, vm.parseJsonBytes32(existing, path));
        }
    }

    function _report() private view {
        console2.log("--- Aftermarket deployment ---");
        console2.log("TradingCalendar         ", d.calendar);
        console2.log("AttesterRegistry        ", d.attesters);
        console2.log("RegSGate                ", d.gate);
        console2.log("SessionRateModel        ", d.rateModel);
        console2.log("AftermarketOracleFactory", d.oracleFactory);
        console2.log("AerodromeSwapAdapter    ", d.swapAdapter);
        console2.log("AftermarketCredit       ", d.credit);
        console2.log("AftermarketVault        ", d.vault);
        console2.log("AutoRepayer             ", d.autoRepayer);
        console2.log("AftermarketLens         ", d.lens);
        for (uint256 i; i < assets.length; ++i) {
            console2.log(string.concat("oracle ", assets[i].symbol, "           "), oracles[i]);
        }
        console2.log("written to              ", _deploymentsPath());
    }
}
