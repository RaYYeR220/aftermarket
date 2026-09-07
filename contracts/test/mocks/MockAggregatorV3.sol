// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Controllable stand-in for a Chainlink aggregator.
/// @dev Test double only. Lets a test freeze `updatedAt` in the past, push a negative or zero answer,
///      or make the aggregator revert outright.
contract MockAggregatorV3 is IAggregatorV3 {
    error Down();

    uint8 internal _decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    bool public reverting;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        _decimals = decimals_;
        answer = answer_;
        updatedAt = updatedAt_;
        roundId = 1;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Feed / USD";
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        ++roundId;
    }

    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverting) revert Down();
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
