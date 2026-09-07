// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice A jurisdiction record written by a trusted attester.
/// @param country   ISO 3166-1 alpha-2 code, uppercase, packed into two bytes (e.g. `0x504c` == "PL").
/// @param issuedAt  Unix timestamp the record was written. Zero means "no record".
/// @param expiresAt Unix timestamp the record stops being conclusive. Zero means "never expires".
/// @param revoked   Set once the record is withdrawn; a revoked record is never resurrected in place.
struct Eligibility {
    bytes2 country;
    uint64 issuedAt;
    uint64 expiresAt;
    bool revoked;
}

/// @notice The read surface {RegSGate} depends on. Kept separate so the gate can be repointed at any
///         contract with the same shape without touching the gate's own code.
interface IAttesterRegistry {
    function eligibilityOf(address subject) external view returns (Eligibility memory);
}

/// @title  AftermarketAttesterRegistry
/// @notice An owner-curated set of attesters who may record the proven jurisdiction of an address.
/// @dev    This is the *fallback* source behind Coinbase Verifications, not a replacement for it.
///         Coinbase attestations are the authority wherever they exist; this registry exists so the
///         Reg-S gate is demonstrable on networks and for accounts where Coinbase attestations cannot
///         be obtained. It is deliberately shaped so that switching a jurisdiction proof from here to
///         Coinbase requires no change in any consumer: {RegSGate} already prefers source 1.
///
///         Trust model: an attester is fully trusted for the addresses it writes. Adding one is an
///         owner action, so the owner should be a multisig or timelock in production. Attesters can
///         revoke (a risk-reducing action) but cannot manage each other.
contract AttesterRegistry is IAttesterRegistry, Ownable2Step {
    /// @notice Jurisdiction records, keyed by subject.
    mapping(address subject => Eligibility record) private _records;

    /// @notice Addresses currently permitted to write records.
    mapping(address account => bool trusted) public isAttester;

    /// @notice Emitted when an attester is added to or removed from the trusted set.
    event AttesterSet(address indexed attester, bool trusted);

    /// @notice Emitted on every successful {attest}.
    event Attested(
        address indexed subject, address indexed attester, bytes2 country, uint64 issuedAt, uint64 expiresAt
    );

    /// @notice Emitted on every successful {revoke}.
    event Revoked(address indexed subject, address indexed revoker, bytes2 country);

    /// @notice Caller is neither a trusted attester nor the owner.
    error NotAttester(address caller);
    /// @notice A zero address was supplied where a real account is required.
    error ZeroAddress();
    /// @notice The country code is not two uppercase ASCII letters.
    error InvalidCountryCode(bytes2 country);
    /// @notice The supplied expiry is already in the past.
    error ExpiryInThePast(uint64 expiresAt);
    /// @notice {revoke} was called for a subject that has no live record.
    error NoRecord(address subject);

    /// @dev Owner is set explicitly rather than to `msg.sender` so deploy scripts can hand the
    ///      registry straight to a multisig without a second transaction.
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    /// @dev The owner is implicitly an attester so a fresh deployment is usable, and so an emergency
    ///      revocation never depends on an attester key being available.
    modifier onlyAttester() {
        if (!isAttester[msg.sender] && msg.sender != owner()) revert NotAttester(msg.sender);
        _;
    }

    /// @notice Adds or removes an attester.
    function setAttester(address attester, bool trusted) external onlyOwner {
        if (attester == address(0)) revert ZeroAddress();
        isAttester[attester] = trusted;
        emit AttesterSet(attester, trusted);
    }

    /// @notice Records the proven jurisdiction of `subject`.
    /// @param subject   The account the record is about.
    /// @param country   ISO 3166-1 alpha-2 code, packed uppercase (e.g. `bytes2("PL")`).
    /// @param expiresAt Unix timestamp after which the record stops counting, or zero for no expiry.
    /// @dev Re-attesting overwrites in full, which is how a revoked subject is reinstated: the
    ///      `revoked` flag is cleared only by a fresh, deliberate attestation.
    function attest(address subject, bytes2 country, uint64 expiresAt) external onlyAttester {
        if (subject == address(0)) revert ZeroAddress();
        if (!_isCountryCode(country)) revert InvalidCountryCode(country);
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert ExpiryInThePast(expiresAt);

        uint64 issuedAt = uint64(block.timestamp);
        _records[subject] = Eligibility({country: country, issuedAt: issuedAt, expiresAt: expiresAt, revoked: false});

        emit Attested(subject, msg.sender, country, issuedAt, expiresAt);
    }

    /// @notice Withdraws the record for `subject`.
    /// @dev Revocation is risk-reducing, so any trusted attester may revoke any subject rather than
    ///      only the one that wrote the record. Losing an attester key must not strand a bad record.
    function revoke(address subject) external onlyAttester {
        Eligibility storage record = _records[subject];
        if (record.issuedAt == 0 || record.revoked) revert NoRecord(subject);

        record.revoked = true;
        emit Revoked(subject, msg.sender, record.country);
    }

    /// @notice Returns the raw record for `subject`. Callers must apply revocation and expiry
    ///         themselves; this getter reports state, it does not judge it.
    function eligibilityOf(address subject) external view returns (Eligibility memory) {
        return _records[subject];
    }

    /// @notice Convenience read: whether `subject` has a live, unexpired, unrevoked record.
    function isValid(address subject) external view returns (bool valid, bytes2 country) {
        Eligibility memory record = _records[subject];
        if (record.issuedAt == 0 || record.revoked) return (false, bytes2(0));
        if (record.expiresAt != 0 && record.expiresAt <= block.timestamp) return (false, record.country);
        return (true, record.country);
    }

    /// @dev Two uppercase ASCII letters. Rejects lowercase so that stored codes compare byte-for-byte
    ///      against the gate's restricted set without any runtime normalisation.
    function _isCountryCode(bytes2 country) private pure returns (bool) {
        uint8 first = uint8(country[0]);
        uint8 second = uint8(country[1]);
        return first >= 0x41 && first <= 0x5A && second >= 0x41 && second <= 0x5A;
    }
}
