// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Session} from "./Types.sol";

/// @notice An onchain NYSE/Nasdaq trading calendar: real US Eastern time with DST, real holidays,
///         real half-days. Everything downstream reasons about "is the market open" with this.
interface ITradingCalendar {
    /// @param timestamp Unix seconds (UTC).
    /// @return session   Where the market is in its cycle at `timestamp`.
    /// @return nextOpen  Unix ts of the next regular-session open at or after `timestamp`.
    /// @return lastClose Unix ts of the most recent regular-session close at or before `timestamp`.
    function sessionAt(uint256 timestamp)
        external
        view
        returns (Session session, uint64 nextOpen, uint64 lastClose);

    /// @notice Convenience wrapper over `sessionAt(block.timestamp)`.
    function session() external view returns (Session);

    /// @notice True while a regular session is running (excludes pre/post).
    function isOpen(uint256 timestamp) external view returns (bool);

    /// @notice Seconds the market has been out of its regular session at `timestamp`. Zero while open.
    function closedFor(uint256 timestamp) external view returns (uint256);

    /// @notice Unix ts of the next regular open at or after `timestamp`.
    function nextOpen(uint256 timestamp) external view returns (uint64);
}
