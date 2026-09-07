// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEligibility} from "../../src/interfaces/IEligibility.sol";

/// @notice An allow-list stand-in for the Reg-S gate.
/// @dev Defaults to permissive so that tests which are not about compliance stay short; the
///      eligibility tests flip individual addresses off and assert exactly which entry points
///      notice.
contract MockEligibility is IEligibility {
    mapping(address account => bool) public denied;
    // casting to 'bytes2' is safe because the literal is exactly two bytes long
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes2 public country = bytes2("DE");

    function setEligible(address account, bool ok) external {
        denied[account] = !ok;
    }

    function check(address account) external view returns (bool ok, bytes2 country_, uint8 source) {
        return (!denied[account], country, 1);
    }

    function requireEligible(address account) external view {
        if (denied[account]) revert NotEligible(account);
    }
}
