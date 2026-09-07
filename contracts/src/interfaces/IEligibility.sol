// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Regulation-S eligibility, enforced in bytecode rather than in a disclaimer.
/// @dev Coinbase's tokenized stocks are offered only to non-US persons. Aftermarket therefore gates
///      every risk-increasing action (opening a line, posting collateral, drawing credit) on an
///      onchain attestation. Risk-REDUCING actions (repay, and withdrawing collateral once the debt
///      is cleared) are never gated: a compliance rule must not be able to trap someone's assets.
interface IEligibility {
    /// @return ok      Whether `account` may take risk-increasing actions.
    /// @return country ISO 3166-1 alpha-2 code proven for `account`, or empty when unproven.
    /// @return source  Which attestation satisfied the check.
    function check(address account) external view returns (bool ok, bytes2 country, uint8 source);

    /// @notice Reverts with a typed error when `account` is not eligible.
    function requireEligible(address account) external view;

    error NotEligible(address account);
    error RestrictedJurisdiction(address account, bytes2 country);
    error AttestationMissing(address account);
}
