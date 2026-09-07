// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITradingCalendar} from "../../src/interfaces/ITradingCalendar.sol";
import {Session} from "../../src/libraries/Types.sol";

/// @notice Controllable stand-in for `TradingCalendar`.
/// @dev Test double only. The real calendar derives everything from `timestamp`; this one is told what
///      to say, so oracle tests can pin a session without reimplementing US market hours.
contract MockCalendar is ITradingCalendar {
    error Down();

    Session internal _session;
    uint64 internal _nextOpen;
    uint64 internal _lastClose;
    uint256 internal _closedFor;
    bool public reverting;

    constructor(Session session_, uint256 closedFor_) {
        _session = session_;
        _closedFor = closedFor_;
    }

    function set(Session session_, uint256 closedFor_, uint64 nextOpen_, uint64 lastClose_) external {
        _session = session_;
        _closedFor = closedFor_;
        _nextOpen = nextOpen_;
        _lastClose = lastClose_;
    }

    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }

    function sessionAt(uint256) external view returns (Session, uint64, uint64) {
        if (reverting) revert Down();
        return (_session, _nextOpen, _lastClose);
    }

    function session() external view returns (Session) {
        if (reverting) revert Down();
        return _session;
    }

    function isOpen(uint256) external view returns (bool) {
        if (reverting) revert Down();
        return _session == Session.REGULAR;
    }

    function closedFor(uint256) external view returns (uint256) {
        if (reverting) revert Down();
        return _closedFor;
    }

    function nextOpen(uint256) external view returns (uint64) {
        if (reverting) revert Down();
        return _nextOpen;
    }
}
