// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";

import {AftermarketOracle} from "../src/AftermarketOracle.sol";
import {IAftermarketOracle} from "../src/interfaces/IAftermarketOracle.sol";
import {Quote, Session, Verdict} from "../src/libraries/Types.sol";

import {AftermarketConfig} from "./AftermarketConfig.sol";

/// @title  Prove
/// @notice The judge-facing run: every deployed oracle's live verdict, and the negative control
///         reverting on the same block that production succeeds.
///
/// @dev Reads only. No broadcast, no state change, no fork trickery - the numbers below come from
///      the deployed oracle bytecode reading the real Coinbase feeds, the real Aerodrome pools and
///      the real onchain trading calendar at the head of Base mainnet.
///
///      The table is worth reading in one specific way. For each asset it prints the age of the
///      Chainlink reference next to the staleness budget for the *current session*, and the
///      feed-versus-pool divergence next to the band for that same session. Those four numbers are
///      the entire argument: a feed that is two days old is not a fault to be papered over, it is
///      the normal state of a tokenized equity outside market hours, and what makes a mark
///      defensible is that a live pool still agrees with it.
///
///      The last two lines are the control. `price()` is called on the production oracle and on the
///      negative-control oracle - identical in every parameter but the divergence band - and the
///      script reports that one returns a number and the other reverts with `SourcesDiverged`. A
///      green check that could not have been red proves nothing; this one could.
///
///      ## Usage
///
///          cp script/config/base.json deployments/base.json
///          CONFIG=deployments/base.json \
///            forge script script/Prove.s.sol:Prove --rpc-url https://mainnet.base.org -vv
contract Prove is AftermarketConfig {
    /// @notice `DeployCore` has not run on this chain yet.
    error NothingDeployed(uint256 chainId);

    function run() external {
        _loadConfig();
        _requireAssets();
        _shimPredeployAssets();

        string memory existing = _readDeployments();
        if (bytes(existing).length == 0) revert NothingDeployed(block.chainid);

        console2.log("=== Aftermarket live oracle verdicts ===");
        console2.log("chain      ", block.chainid);
        console2.log("block      ", block.number);
        console2.log("timestamp  ", block.timestamp);

        for (uint256 i; i < assets.length; ++i) {
            address oracle = _recorded(existing, string.concat("oracles.", assets[i].symbol));
            if (oracle == address(0)) {
                console2.log(string.concat("-- ", assets[i].symbol, ": not deployed"));
                continue;
            }
            _reportAsset(assets[i].symbol, oracle);
        }

        _reportControl(existing);
    }

    /*//////////////////////////////////////////////////////////////
                              THE VERDICT TABLE
    //////////////////////////////////////////////////////////////*/

    function _reportAsset(string memory symbol, address oracle) private view {
        Quote memory q;
        // `peek` is total in the deployed oracle, but the address comes out of a JSON file that a
        // human edits. A proof script that dies on a mistyped address proves nothing.
        try AftermarketOracle(oracle).peek() returns (Quote memory got) {
            q = got;
        } catch {
            console2.log(string.concat("-- ", symbol, ": address does not answer peek()"), oracle);
            return;
        }

        console2.log(string.concat("-- ", symbol, " ", _verdictName(q.verdict)));
        console2.log("   oracle             ", oracle);
        console2.log("   session            ", _sessionName(q.session));
        console2.log("   anchor (1e18 USD)  ", q.anchorPrice);
        console2.log("   pool   (1e18 USD)  ", q.poolPrice);
        console2.log("   feed age / budget  ", q.feedAge, q.stalenessBudget);
        console2.log("   divergence / band  ", q.divergenceBps, q.divergenceBand);
        console2.log("   pool depth (1e18)  ", q.poolLiquidityUsd);
        console2.log("   haircut (bps)      ", q.haircutBps);
        console2.log("   multiplier (WAD)   ", q.multiplier);
        console2.log("   markBorrow         ", q.markBorrow);
        console2.log("   markLiquidate      ", q.markLiquidate);
        _reportPrice("   price()            ", oracle);
    }

    /*//////////////////////////////////////////////////////////////
                             THE NEGATIVE CONTROL
    //////////////////////////////////////////////////////////////*/

    function _reportControl(string memory existing) private view {
        address control = _recorded(existing, "negativeControl");
        if (control == address(0)) {
            console2.log("=== no negative control deployed; run DeployNegativeControl ===");
            return;
        }

        uint256 index = _negativeControlIndex();
        address production = _recorded(existing, string.concat("oracles.", assets[index].symbol));

        console2.log("=== negative control ===");
        console2.log("asset                 ", assets[index].symbol);
        console2.log("production oracle     ", production);
        console2.log("control oracle        ", control);
        console2.log("production band (bps) ", uint256(divergenceBandBps[0]));
        console2.log("control band (bps)    ", uint256(negativeControlBandBps));

        bool productionOk = _reportPrice("production price()    ", production);
        bool controlOk = _reportPrice("control    price()    ", control);

        if (productionOk && !controlOk) {
            console2.log("VERDICT: production priced, control refused. The checks are live.");
        } else if (productionOk && controlOk) {
            console2.log("VERDICT: both priced. The sources agree inside 25 bps right now.");
        } else {
            console2.log("VERDICT: production refused to price. New risk and seizure are frozen.");
        }
    }

    /// @dev Calls `price()` and reports the answer, or the exact typed error it refused with.
    function _reportPrice(string memory label, address oracle) private view returns (bool ok) {
        if (oracle == address(0)) {
            console2.log(string.concat(label, " not deployed"));
            return false;
        }

        try IAftermarketOracle(oracle).price() returns (uint256 price) {
            console2.log(label, price);
            return true;
        } catch (bytes memory err) {
            console2.log(string.concat(label, " REVERTED ", _errorName(_selector(err))));
            return false;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  LABELS
    //////////////////////////////////////////////////////////////*/

    function _errorName(bytes4 selector) private pure returns (string memory) {
        if (selector == IAftermarketOracle.StaleFeed.selector) return "StaleFeed";
        if (selector == IAftermarketOracle.SourcesDiverged.selector) return "SourcesDiverged";
        if (selector == IAftermarketOracle.PoolTooThin.selector) return "PoolTooThin";
        if (selector == IAftermarketOracle.MarketHalted.selector) return "MarketHalted";
        if (selector == IAftermarketOracle.InvalidFeedAnswer.selector) return "InvalidFeedAnswer";
        return "unknown error";
    }

    function _verdictName(Verdict verdict) private pure returns (string memory) {
        if (verdict == Verdict.TRUSTED) return "TRUSTED";
        if (verdict == Verdict.TRUSTED_CLOSED) return "TRUSTED_CLOSED";
        if (verdict == Verdict.UNTRUSTED_STALE) return "UNTRUSTED_STALE";
        if (verdict == Verdict.UNTRUSTED_DIVERGENT) return "UNTRUSTED_DIVERGENT";
        if (verdict == Verdict.UNTRUSTED_THIN) return "UNTRUSTED_THIN";
        return "UNTRUSTED_HALTED";
    }

    function _sessionName(Session session) private pure returns (string memory) {
        if (session == Session.REGULAR) return "REGULAR";
        if (session == Session.PRE) return "PRE";
        if (session == Session.POST) return "POST";
        if (session == Session.CLOSED_OVERNIGHT) return "CLOSED_OVERNIGHT";
        if (session == Session.CLOSED_WEEKEND) return "CLOSED_WEEKEND";
        return "CLOSED_HOLIDAY";
    }
}
