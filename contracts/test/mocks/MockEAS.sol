// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Attestation} from "eas-contracts/IEAS.sol";

/// @notice Minimal stand-in for the EAS predeploy: a UID to attestation map plus a setter.
/// @dev Only the read surface that consumers actually call is implemented, so this deliberately does
///      not inherit `IEAS`. Real EAS returns a zeroed struct for an unknown UID, and so does this.
contract MockEAS {
    mapping(bytes32 uid => Attestation attestation) private _attestations;

    /// @notice Stores `attestation` under its own `uid`.
    function set(Attestation memory attestation) external {
        _attestations[attestation.uid] = attestation;
    }

    /// @notice Builds and stores an attestation, returning its UID.
    /// @param uid            Identifier to file it under.
    /// @param schema         Schema UID.
    /// @param recipient      Subject of the attestation.
    /// @param attester       Issuer of the attestation.
    /// @param expirationTime Expiry, or zero for none.
    /// @param revocationTime Revocation timestamp, or zero if live.
    /// @param data           ABI-encoded schema payload.
    function attest(
        bytes32 uid,
        bytes32 schema,
        address recipient,
        address attester,
        uint64 expirationTime,
        uint64 revocationTime,
        bytes memory data
    ) external returns (bytes32) {
        _attestations[uid] = Attestation({
            uid: uid,
            schema: schema,
            time: uint64(block.timestamp),
            expirationTime: expirationTime,
            revocationTime: revocationTime,
            refUID: bytes32(0),
            recipient: recipient,
            attester: attester,
            revocable: true,
            data: data
        });
        return uid;
    }

    /// @notice Marks a stored attestation revoked as of `revocationTime`.
    function revoke(bytes32 uid, uint64 revocationTime) external {
        _attestations[uid].revocationTime = revocationTime;
    }

    /// @notice Mirrors `IEAS.getAttestation`.
    function getAttestation(bytes32 uid) external view returns (Attestation memory) {
        return _attestations[uid];
    }
}
