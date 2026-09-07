// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAftermarketOracle} from "../../src/interfaces/IAftermarketOracle.sol";
import {Quote, Session, Verdict} from "../../src/libraries/Types.sol";

/// @notice A drivable `IAftermarketOracle` for tests.
/// @dev The important capability is not setting a price, it is being able to make `markBorrow` and
///      `markLiquidate` revert independently. The whole safety argument of the credit engine rests
///      on those reverts propagating, so the mock has to be able to produce them on demand.
contract MockOracle is IAftermarketOracle {
    uint256 public borrowMark;
    uint256 public liquidateMark;

    bool public borrowReverts;
    bool public liquidateReverts;

    Verdict public verdict = Verdict.TRUSTED;
    Session public session = Session.REGULAR;
    uint256 public multiplier = 1e18;

    address public collateralToken;
    address public loanToken;
    address public calendar;
    address public feed;
    address public pool;

    constructor(uint256 borrowMark_, uint256 liquidateMark_) {
        borrowMark = borrowMark_;
        liquidateMark = liquidateMark_;
    }

    /// @notice Declares which pair this oracle prices, which `AftermarketCredit.setAsset` asserts.
    function setTokens(address collateralToken_, address loanToken_) external {
        collateralToken = collateralToken_;
        loanToken = loanToken_;
    }

    function setMarks(uint256 borrowMark_, uint256 liquidateMark_) external {
        borrowMark = borrowMark_;
        liquidateMark = liquidateMark_;
    }

    /// @notice Drives the oracle into an untrusted verdict for one or both marks.
    function setReverting(bool borrowReverts_, bool liquidateReverts_) external {
        borrowReverts = borrowReverts_;
        liquidateReverts = liquidateReverts_;
        verdict = (borrowReverts_ || liquidateReverts_) ? Verdict.UNTRUSTED_STALE : Verdict.TRUSTED;
    }

    function setSession(Session session_) external {
        session = session_;
    }

    function setMultiplier(uint256 multiplier_) external {
        multiplier = multiplier_;
    }

    function markBorrow() external view returns (uint256) {
        if (borrowReverts) revert StaleFeed(session, 52 hours, 1 hours);
        return borrowMark;
    }

    function markLiquidate() external view returns (uint256) {
        if (liquidateReverts) revert StaleFeed(session, 52 hours, 1 hours);
        return liquidateMark;
    }

    function price() external view returns (uint256) {
        if (borrowReverts) revert StaleFeed(session, 52 hours, 1 hours);
        return borrowMark;
    }

    function peek() external view returns (Quote memory q) {
        q.verdict = verdict;
        q.session = session;
        q.markBorrow = borrowMark;
        q.markLiquidate = liquidateMark;
        q.multiplier = multiplier;
    }
}
