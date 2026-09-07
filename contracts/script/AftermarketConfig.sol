// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {OracleConfig} from "../src/AftermarketOracle.sol";

/// @title  AftermarketConfig
/// @notice Loads `script/config/<network>.json` and turns it into constructor arguments.
///
/// @dev Every script in this directory shares one loader so that the deployment, the negative
///      control, the Morpho market and the proof run all read exactly the same numbers. A second
///      copy of these values anywhere would eventually disagree with the first, and the whole point
///      of the config file is that there is one place to look.
///
///      ## Units
///
///      The JSON deliberately holds no scaled integers. Rates are annual percentages in bps,
///      thresholds are bps, liquidity floors are whole dollars, caps are whole tokens. Everything is
///      scaled here, once, next to the contract it is scaled for. A config file full of eighteen-zero
///      literals is a config file nobody proof-reads.
///
///      ## Reading the file
///
///      `foundry.toml` is frozen in this repository and its `fs_permissions` grant read-write on
///      `./deployments` only, so `vm.readFile("script/config/base.json")` is refused. The loader
///      therefore reports that precisely rather than dying on an opaque cheatcode revert, and the
///      `CONFIG` environment variable lets an operator point it at a copy inside `./deployments`,
///      which needs no change to any frozen file:
///
///          cp script/config/base.json deployments/base.json
///          CONFIG=deployments/base.json forge script script/DeployCore.s.sol --rpc-url base
///
///      The alternative, for anyone able to edit `foundry.toml`, is one line:
///      `{ access = "read", path = "./script/config" }`.
abstract contract AftermarketConfig is Script {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant SESSION_COUNT = 6;

    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84532;

    /// @notice Attempts made to read one B20 predeploy value from the node before giving up.
    uint256 internal constant SHIM_ATTEMPTS = 5;
    /// @notice Pause between those attempts, in milliseconds.
    uint256 internal constant SHIM_RETRY_DELAY_MS = 400;

    /// @notice One collateral asset as the config file describes it.
    struct AssetSpec {
        string symbol;
        address token;
        address feed;
        address pool;
        uint256 capWholeTokens;
    }

    /*//////////////////////////////////////////////////////////////
                             LOADED CONFIG
    //////////////////////////////////////////////////////////////*/

    string internal configPath;
    string internal configJson;
    string internal networkName;

    address internal usdc;
    address internal spendPermissionManager;
    address internal publicERC6492Validator;

    address internal slipstreamFactory;
    address internal slipstreamRouter;
    int24 internal slipstreamTickSpacing;

    address internal morphoBlue;
    address internal morphoIrm;
    uint256 internal morphoLltv;

    address internal easAddress;
    address internal indexerAddress;
    bytes32 internal verifiedCountrySchema;
    bytes32 internal verifiedAccountSchema;

    uint256 internal baseRatePerSecond;
    uint256 internal slope1PerSecond;
    uint256 internal slope2PerSecond;
    uint256 internal kink;
    uint256[SESSION_COUNT] internal sessionMultipliers;

    uint16 internal maxSlippageBps;

    uint32 internal twapWindow;
    uint32[SESSION_COUNT] internal stalenessBudget;
    uint16[SESSION_COUNT] internal divergenceBandBps;
    uint16 internal baseHaircutBps;
    uint16 internal haircutSlopeBpsPerHour;
    uint16 internal maxHaircutBps;
    uint128 internal minPoolLiquidityUsd;
    uint128 internal minMultiplier;
    uint128 internal maxMultiplier;

    uint16 internal advanceOpenBps;
    uint16 internal advanceClosedBps;
    uint16 internal liqThresholdOpenBps;
    uint16 internal liqThresholdClosedBps;
    uint16 internal liqBonusBps;

    string internal negativeControlSymbol;
    uint16 internal negativeControlBandBps;

    AssetSpec[] internal assets;
    uint32[] internal holidays;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The config file could not be read, almost always an `fs_permissions` refusal.
    error ConfigUnreadable(string path);
    /// @notice The chain the script is pointed at is not the one the config describes.
    error ChainMismatch(uint256 configChainId, uint256 actualChainId);
    /// @notice This chain has no known config file.
    error UnsupportedChain(uint256 chainId);
    /// @notice The config lists no collateral, so there would be nothing to lend against.
    error NoAssetsConfigured(uint256 chainId, string network);
    /// @notice A configured asset is missing a token, a feed or a pool.
    error IncompleteAsset(string symbol);
    /// @notice A B20 predeploy read could not be fetched from the node, so nothing can be simulated.
    error PredeployShimFailed(address token, bytes4 selector);

    /*//////////////////////////////////////////////////////////////
                                LOADING
    //////////////////////////////////////////////////////////////*/

    /// @dev Populates every field above. Call once, first thing, in every script's `run`.
    function _loadConfig() internal {
        configPath = vm.envOr("CONFIG", _defaultConfigPath());

        try vm.readFile(configPath) returns (string memory contents) {
            configJson = contents;
        } catch {
            console2.log("Could not read", configPath);
            console2.log("foundry.toml grants fs read-write on ./deployments only. Either add");
            console2.log('  { access = "read", path = "./script/config" }');
            console2.log("to fs_permissions, or copy the file somewhere already permitted:");
            console2.log("  cp script/config/base.json deployments/base.json");
            console2.log("  CONFIG=deployments/base.json forge script ...");
            revert ConfigUnreadable(configPath);
        }

        networkName = vm.parseJsonString(configJson, ".network");
        uint256 configChainId = vm.parseJsonUint(configJson, ".chainId");
        if (configChainId != block.chainid) revert ChainMismatch(configChainId, block.chainid);

        _loadAddresses();
        _loadRateModel();
        _loadOracleDefaults();
        _loadRisk();
        _loadAssets();
        _loadHolidays();
    }

    function _loadAddresses() private {
        usdc = vm.parseJsonAddress(configJson, ".usdc");
        spendPermissionManager = vm.parseJsonAddress(configJson, ".spendPermissionManager");
        publicERC6492Validator = vm.parseJsonAddress(configJson, ".publicERC6492Validator");

        slipstreamFactory = vm.parseJsonAddress(configJson, ".aerodrome.slipstreamFactory");
        slipstreamRouter = vm.parseJsonAddress(configJson, ".aerodrome.swapRouter");
        // casting to 'int24' is safe because a Slipstream tick spacing is a small positive integer
        // forge-lint: disable-next-line(unsafe-typecast)
        slipstreamTickSpacing = int24(int256(vm.parseJsonUint(configJson, ".aerodrome.tickSpacing")));

        morphoBlue = vm.parseJsonAddress(configJson, ".morpho.blue");
        morphoIrm = vm.parseJsonAddress(configJson, ".morpho.adaptiveCurveIrm");
        morphoLltv = vm.parseJsonUint(configJson, ".morpho.lltvBps") * WAD / BPS;

        easAddress = vm.parseJsonAddress(configJson, ".regS.eas");
        indexerAddress = vm.parseJsonAddress(configJson, ".regS.indexer");
        verifiedCountrySchema = vm.parseJsonBytes32(configJson, ".regS.verifiedCountrySchema");
        verifiedAccountSchema = vm.parseJsonBytes32(configJson, ".regS.verifiedAccountSchema");
    }

    function _loadRateModel() private {
        baseRatePerSecond = _perSecondFromAprBps(vm.parseJsonUint(configJson, ".rateModel.baseRateAprBps"));
        slope1PerSecond = _perSecondFromAprBps(vm.parseJsonUint(configJson, ".rateModel.slope1AprBps"));
        slope2PerSecond = _perSecondFromAprBps(vm.parseJsonUint(configJson, ".rateModel.slope2AprBps"));
        kink = vm.parseJsonUint(configJson, ".rateModel.kinkBps") * WAD / BPS;

        uint256[] memory multipliers = vm.parseJsonUintArray(configJson, ".rateModel.sessionMultiplierBps");
        require(multipliers.length == SESSION_COUNT, "sessionMultiplierBps: expected 6 entries");
        for (uint256 i; i < SESSION_COUNT; ++i) {
            sessionMultipliers[i] = multipliers[i] * WAD / BPS;
        }

        // casting to 'uint16' is safe because the model itself rejects anything above 10_000 bps
        // forge-lint: disable-next-line(unsafe-typecast)
        maxSlippageBps = uint16(vm.parseJsonUint(configJson, ".credit.maxSlippageBps"));
    }

    function _loadOracleDefaults() private {
        // casting to 'uint32' is safe because a TWAP window is bounded at 7 days by the oracle
        // forge-lint: disable-next-line(unsafe-typecast)
        twapWindow = uint32(vm.parseJsonUint(configJson, ".oracle.twapWindowSeconds"));

        uint256[] memory budgets = vm.parseJsonUintArray(configJson, ".oracle.stalenessBudgetSeconds");
        uint256[] memory bands = vm.parseJsonUintArray(configJson, ".oracle.divergenceBandBps");
        require(budgets.length == SESSION_COUNT, "stalenessBudgetSeconds: expected 6 entries");
        require(bands.length == SESSION_COUNT, "divergenceBandBps: expected 6 entries");
        for (uint256 i; i < SESSION_COUNT; ++i) {
            // casting is safe because both tables are validated by the oracle constructor
            // forge-lint: disable-next-line(unsafe-typecast)
            stalenessBudget[i] = uint32(budgets[i]);
            // forge-lint: disable-next-line(unsafe-typecast)
            divergenceBandBps[i] = uint16(bands[i]);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        baseHaircutBps = uint16(vm.parseJsonUint(configJson, ".oracle.baseHaircutBps"));
        // forge-lint: disable-next-line(unsafe-typecast)
        haircutSlopeBpsPerHour = uint16(vm.parseJsonUint(configJson, ".oracle.haircutSlopeBpsPerHour"));
        // forge-lint: disable-next-line(unsafe-typecast)
        maxHaircutBps = uint16(vm.parseJsonUint(configJson, ".oracle.maxHaircutBps"));
        // forge-lint: disable-next-line(unsafe-typecast)
        minPoolLiquidityUsd = uint128(vm.parseJsonUint(configJson, ".oracle.minPoolLiquidityUsd") * WAD);
        // forge-lint: disable-next-line(unsafe-typecast)
        minMultiplier = uint128(vm.parseJsonUint(configJson, ".oracle.minMultiplierBps") * WAD / BPS);
        // forge-lint: disable-next-line(unsafe-typecast)
        maxMultiplier = uint128(vm.parseJsonUint(configJson, ".oracle.maxMultiplierBps") * WAD / BPS);

        negativeControlSymbol = vm.parseJsonString(configJson, ".negativeControl.symbol");
        // forge-lint: disable-next-line(unsafe-typecast)
        negativeControlBandBps = uint16(vm.parseJsonUint(configJson, ".negativeControl.divergenceBandBps"));
    }

    function _loadRisk() private {
        // casting is safe because every one of these is validated against 9_500 bps by the engine
        // forge-lint: disable-next-line(unsafe-typecast)
        advanceOpenBps = uint16(vm.parseJsonUint(configJson, ".risk.advanceOpenBps"));
        // forge-lint: disable-next-line(unsafe-typecast)
        advanceClosedBps = uint16(vm.parseJsonUint(configJson, ".risk.advanceClosedBps"));
        // forge-lint: disable-next-line(unsafe-typecast)
        liqThresholdOpenBps = uint16(vm.parseJsonUint(configJson, ".risk.liqThresholdOpenBps"));
        // forge-lint: disable-next-line(unsafe-typecast)
        liqThresholdClosedBps = uint16(vm.parseJsonUint(configJson, ".risk.liqThresholdClosedBps"));
        // forge-lint: disable-next-line(unsafe-typecast)
        liqBonusBps = uint16(vm.parseJsonUint(configJson, ".risk.liqBonusBps"));
    }

    /// @dev Walked by index rather than decoded as an array of structs: foundry's struct decoding
    ///      depends on the JSON keys being in alphabetical order, which is a silent trap for anyone
    ///      later editing the file by hand.
    function _loadAssets() private {
        for (uint256 i;; ++i) {
            string memory base = string.concat(".assets[", vm.toString(i), "]");
            if (!vm.keyExistsJson(configJson, string.concat(base, ".token"))) break;

            AssetSpec memory spec = AssetSpec({
                symbol: vm.parseJsonString(configJson, string.concat(base, ".symbol")),
                token: vm.parseJsonAddress(configJson, string.concat(base, ".token")),
                feed: vm.parseJsonAddress(configJson, string.concat(base, ".feed")),
                pool: vm.parseJsonAddress(configJson, string.concat(base, ".pool")),
                capWholeTokens: vm.parseJsonUint(configJson, string.concat(base, ".capWholeTokens"))
            });
            if (spec.token == address(0) || spec.feed == address(0) || spec.pool == address(0)) {
                revert IncompleteAsset(spec.symbol);
            }
            assets.push(spec);
        }
    }

    function _loadHolidays() private {
        for (uint256 i;; ++i) {
            string memory key = string.concat(".calendar.holidays[", vm.toString(i), "].day");
            if (!vm.keyExistsJson(configJson, key)) break;
            // casting to 'uint32' is safe because a day number is bounded by the year 11,000
            // forge-lint: disable-next-line(unsafe-typecast)
            holidays.push(uint32(vm.parseJsonUint(configJson, key)));
        }
    }

    /// @dev Reverts unless the config lists at least one fully specified collateral asset.
    function _requireAssets() internal view {
        if (assets.length == 0) revert NoAssetsConfigured(block.chainid, networkName);
    }

    /*//////////////////////////////////////////////////////////////
                           B20 PREDEPLOY SHIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Makes Base's B20 tokenized equities readable inside a local EVM.
    ///
    /// @dev `eth_getCode` on a B20 asset such as `0xb20000000000000000000078ee7ce2fE4908108C`
    ///      returns the single byte `0xEF`. The behaviour lives in the node, not in bytecode, so
    ///      `decimals()`, `symbol()`, `multiplier()` and `isPaused()` all answer correctly over JSON-RPC
    ///      and all fail with `OpcodeNotFound` the moment a local EVM tries to execute them. Every
    ///      script here runs locally first - that is how `forge script` learns what to broadcast - so
    ///      without this shim nothing involving a B20 asset can be simulated at all.
    ///
    ///      The shim does not invent values. Each read is performed against the live node with
    ///      `vm.rpc` and the node's own answer is installed as the local mock, so a simulation sees
    ///      exactly what the chain would return. Mocks affect local execution only: the calldata of
    ///      every broadcast transaction is built from the config and from these same live values, and
    ///      is identical to what an unmocked run against a node-side EVM would produce.
    function _shimPredeployAssets() internal {
        for (uint256 i; i < assets.length; ++i) {
            _shimPredeploy(assets[i].token);
        }
    }

    function _shimPredeploy(address token) private {
        // A normal contract executes locally and must not be mocked; the marker is exactly one byte.
        if (token.code.length != 1) return;

        _mockFromNode(token, abi.encodeWithSignature("decimals()"));
        _mockFromNode(token, abi.encodeWithSignature("symbol()"));
        _mockFromNode(token, abi.encodeWithSignature("multiplier()"));
        // `PausableFeature.TRANSFER` is ordinal 0, the only one the oracle asks about.
        _mockFromNode(token, abi.encodeWithSignature("isPaused(uint8)", uint8(0)));
    }

    /// @dev Reads one value from the node and installs it as a local mock, retrying because the
    ///      public Base endpoint rate-limits a burst of `eth_call`s and a dropped read here would
    ///      otherwise resurface much later as an unexplained `OpcodeNotFound`. When every attempt
    ///      fails the script stops: a missing shim must not be papered over with a default value,
    ///      because the deployment would then be configured from a number nobody read.
    function _mockFromNode(address target, bytes memory data) private {
        string memory params =
            string.concat('[{"to":"', vm.toString(target), '","data":"', vm.toString(data), '"},"latest"]');

        for (uint256 attempt; attempt < SHIM_ATTEMPTS; ++attempt) {
            if (attempt != 0) vm.sleep(SHIM_RETRY_DELAY_MS);

            try vm.rpc("eth_call", params) returns (bytes memory result) {
                if (result.length == 0) continue;
                vm.mockCall(target, data, result);
                return;
            } catch {}
        }
        revert PredeployShimFailed(target, _selector(data));
    }

    /*//////////////////////////////////////////////////////////////
                            DERIVED VALUES
    //////////////////////////////////////////////////////////////*/

    /// @dev The oracle configuration for asset `index`, optionally with an overridden divergence
    ///      band. The override is what `DeployNegativeControl` uses to build an oracle that differs
    ///      from production in exactly one number.
    function _oracleConfig(uint256 index, address calendarAddress, uint16 bandOverrideBps)
        internal
        view
        returns (OracleConfig memory cfg)
    {
        AssetSpec memory spec = assets[index];

        uint16[SESSION_COUNT] memory bands = divergenceBandBps;
        if (bandOverrideBps != 0) {
            for (uint256 i; i < SESSION_COUNT; ++i) {
                bands[i] = bandOverrideBps;
            }
        }

        cfg = OracleConfig({
            collateralToken: spec.token,
            loanToken: usdc,
            feed: spec.feed,
            pool: spec.pool,
            calendar: calendarAddress,
            // The B20 token is its own corporate-action registry: it exposes `multiplier()` itself,
            // so no separate registry address is needed and the oracle probes the token directly.
            multiplierRegistry: address(0),
            twapWindow: twapWindow,
            stalenessBudget: stalenessBudget,
            divergenceBandBps: bands,
            baseHaircutBps: baseHaircutBps,
            haircutSlopeBpsPerHour: haircutSlopeBpsPerHour,
            maxHaircutBps: maxHaircutBps,
            minPoolLiquidityUsd: minPoolLiquidityUsd,
            minMultiplier: minMultiplier,
            maxMultiplier: maxMultiplier
        });
    }

    /// @dev Index of the asset the negative control is built against.
    function _negativeControlIndex() internal view returns (uint256) {
        bytes32 wanted = keccak256(bytes(negativeControlSymbol));
        for (uint256 i; i < assets.length; ++i) {
            if (keccak256(bytes(assets[i].symbol)) == wanted) return i;
        }
        revert IncompleteAsset(negativeControlSymbol);
    }

    function _assetAddresses() internal view returns (address[] memory list) {
        list = new address[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            list[i] = assets[i].token;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Simple (non-compounded) annual rate in bps to the WAD-per-second the model expects. The
    ///      engine compounds it itself, which is why the config talks about the linear rate.
    function _perSecondFromAprBps(uint256 aprBps) internal pure returns (uint256) {
        return aprBps * WAD / BPS / SECONDS_PER_YEAR;
    }

    /// @dev The four-byte selector of a caught revert, or zero when the payload is too short. Used
    ///      by the proof scripts to name the exact error an oracle refused with, rather than merely
    ///      reporting that something failed.
    function _selector(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(err, 0x20))
        }
    }

    function _defaultConfigPath() private view returns (string memory) {
        if (block.chainid == BASE_MAINNET) return "script/config/base.json";
        if (block.chainid == BASE_SEPOLIA) return "script/config/base-sepolia.json";
        revert UnsupportedChain(block.chainid);
    }

    /// @dev Path of this chain's deployment record. Inside `./deployments`, which is the one
    ///      directory the frozen `foundry.toml` grants read-write on.
    function _deploymentsPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function _readDeployments() internal view returns (string memory) {
        string memory path = _deploymentsPath();
        if (!vm.isFile(path)) return "";
        return vm.readFile(path);
    }

    /// @dev One address out of an existing deployment record, or zero when absent.
    ///
    ///      A recorded address only counts if there is code at it on the chain being addressed. That
    ///      guard matters more than it looks: `forge script` without `--broadcast` still runs the
    ///      script and still writes the record, so a simulation leaves behind a file full of
    ///      addresses that were never deployed. Checking for code means a later real run redeploys
    ///      them instead of wiring the protocol to empty accounts, and it makes a record copied
    ///      between chains harmlessly wrong rather than dangerously wrong.
    function _recorded(string memory deployments, string memory key) internal view returns (address) {
        if (bytes(deployments).length == 0) return address(0);

        string memory path = string.concat(".", key);
        if (!vm.keyExistsJson(deployments, path)) return address(0);

        address recorded = vm.parseJsonAddress(deployments, path);
        return recorded.code.length == 0 ? address(0) : recorded;
    }
}
