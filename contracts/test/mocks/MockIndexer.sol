// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAttestationIndexer} from "verifications/interfaces/IAttestationIndexer.sol";

/// @notice Minimal stand-in for Coinbase's attestation indexer.
/// @dev Backs a plain (recipient, schema) to UID map. Unknown pairs return `bytes32(0)`, matching the
///      documented behaviour of the real indexer.
contract MockIndexer is IAttestationIndexer {
    mapping(address recipient => mapping(bytes32 schema => bytes32 uid)) private _uids;

    /// @notice Files `uid` under `(recipient, schema)`.
    function setAttestationUid(address recipient, bytes32 schema, bytes32 uid) external {
        _uids[recipient][schema] = uid;
        emit AttestationIndexed(msg.sender, recipient, schema, uid);
    }

    /// @inheritdoc IAttestationIndexer
    /// @dev The real indexer resolves the attestation through EAS; tests wire the pair up directly.
    function index(bytes32 attestationUid) external {
        emit AttestationIndexed(msg.sender, address(0), bytes32(0), attestationUid);
    }

    /// @inheritdoc IAttestationIndexer
    function getAttestationUid(address recipient, bytes32 schemaUid) external view returns (bytes32) {
        return _uids[recipient][schemaUid];
    }
}
