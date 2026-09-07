// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Attestation, IEAS} from "eas-contracts/IEAS.sol";
import {IAttestationIndexer} from "verifications/interfaces/IAttestationIndexer.sol";
import {Predeploys} from "verifications/libraries/Predeploys.sol";

import {RegSGate} from "../src/RegSGate.sol";

/// @title  ProveVerifications
/// @notice Reads an address's real Coinbase Verified Country attestation through the real indexer
///         and reports whether {RegSGate} would admit it.
///
/// @dev    This script exists to prove the source-1 read path is real rather than mocked. It only
///         reads: no broadcast, no deployment, no state change on the forked chain. The gate is
///         instantiated in the script's own EVM so the reported verdict is produced by the exact
///         bytecode that would run in production.
///
///         Base mainnet:
///           forge script script/ProveVerifications.s.sol:ProveVerifications \
///             --sig "run(address)" 0xc799DD327b5D6c6E4Ed5bbEC510b49A1ce4bB6d7 \
///             --rpc-url https://mainnet.base.org -vv
///
///         Or with the account in the environment:
///           ACCOUNT=0xc799DD327b5D6c6E4Ed5bbEC510b49A1ce4bB6d7 \
///             forge script script/ProveVerifications.s.sol:ProveVerifications \
///             --rpc-url https://mainnet.base.org -vv
contract ProveVerifications is Script {
    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal constant BASE_INDEXER = 0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C;
    bytes32 internal constant BASE_COUNTRY_SCHEMA = 0x1801901fabd0e6189356b4fb52bb0ab855276d84f7ec140839fbd1f6801ca065;
    bytes32 internal constant BASE_ACCOUNT_SCHEMA = 0xf8b05c79f090979bf4a80270aba232dff11a10d9ca55c4f88de95317970f0de9;

    address internal constant BASE_SEPOLIA_INDEXER = 0xd147a19c3B085Fb9B0c15D2EAAFC6CB086ea849B;
    bytes32 internal constant BASE_SEPOLIA_COUNTRY_SCHEMA =
        0xef54ae90f47a187acc050ce631c55584fd4273c0ca9456ab21750921c3a84028;
    bytes32 internal constant BASE_SEPOLIA_ACCOUNT_SCHEMA =
        0x2f34a2ffe5f87b2f45fbc7c784896b768d77261e2f24f77341ae43751c765a69;

    /// @dev Owner of the throwaway gate instantiated below. Nothing in this script is an owner
    ///      action, so the value only has to be non-zero.
    address internal constant PROBE_OWNER = 0x000000000000000000000000000000000000a11c;

    /// @notice Chain has no known Coinbase Verifications deployment.
    error UnsupportedChain(uint256 chainId);

    /// @notice Proves the account named by the `ACCOUNT` environment variable.
    function run() external {
        _prove(vm.envAddress("ACCOUNT"));
    }

    /// @notice Proves `account`.
    function run(address account) external {
        _prove(account);
    }

    function _prove(address account) internal {
        (address indexerAddress, bytes32 countrySchema, bytes32 accountSchema) = _config();

        console2.log("chain id            ", block.chainid);
        console2.log("account             ", account);
        console2.log("indexer             ", indexerAddress);
        console2.log("EAS                 ", Predeploys.EAS);
        console2.log("verified country schema");
        console2.logBytes32(countrySchema);
        console2.log("verified account schema");
        console2.logBytes32(accountSchema);

        IAttestationIndexer indexer = IAttestationIndexer(indexerAddress);

        bytes32 countryUid = indexer.getAttestationUid(account, countrySchema);
        bytes32 accountUid = indexer.getAttestationUid(account, accountSchema);
        console2.log("verified country uid");
        console2.logBytes32(countryUid);
        console2.log("verified account uid");
        console2.logBytes32(accountUid);

        if (countryUid == bytes32(0)) {
            console2.log("no Verified Country attestation indexed for this account");
        } else {
            Attestation memory attestation = IEAS(Predeploys.EAS).getAttestation(countryUid);
            console2.log("  recipient         ", attestation.recipient);
            console2.log("  attester          ", attestation.attester);
            console2.log("  attested at       ", attestation.time);
            console2.log("  expires at        ", attestation.expirationTime);
            console2.log("  revoked at        ", attestation.revocationTime);
            console2.log("  decoded country   ", abi.decode(attestation.data, (string)));
        }

        // The gate that would run in production, instantiated here so the verdict is real bytecode.
        RegSGate gate = new RegSGate(
            PROBE_OWNER, Predeploys.EAS, indexerAddress, countrySchema, accountSchema, address(0), new bytes2[](0)
        );

        (bool ok, bytes2 country, uint8 source) = gate.check(account);
        console2.log("--- RegSGate verdict ---");
        console2.log("  country           ", country == bytes2(0) ? "(none)" : string(abi.encodePacked(country)));
        console2.log("  source            ", _sourceName(source));
        console2.log("  eligible          ", ok);
        console2.log("  restricted set    ", _restrictedSet(gate));
    }

    function _config() internal view returns (address indexerAddress, bytes32 countrySchema, bytes32 accountSchema) {
        if (block.chainid == BASE_MAINNET) {
            return (BASE_INDEXER, BASE_COUNTRY_SCHEMA, BASE_ACCOUNT_SCHEMA);
        }
        if (block.chainid == BASE_SEPOLIA) {
            return (BASE_SEPOLIA_INDEXER, BASE_SEPOLIA_COUNTRY_SCHEMA, BASE_SEPOLIA_ACCOUNT_SCHEMA);
        }
        revert UnsupportedChain(block.chainid);
    }

    function _sourceName(uint8 source) internal pure returns (string memory) {
        if (source == 1) return "1 (Coinbase Verifications)";
        if (source == 2) return "2 (AttesterRegistry)";
        return "0 (nothing proven)";
    }

    function _restrictedSet(RegSGate gate) internal view returns (string memory list) {
        bytes2[] memory codes = gate.restrictedJurisdictions();
        for (uint256 i = 0; i < codes.length; ++i) {
            list = i == 0
                ? string(abi.encodePacked(codes[i]))
                : string(abi.encodePacked(list, " ", string(abi.encodePacked(codes[i]))));
        }
    }
}
