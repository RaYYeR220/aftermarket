// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Attestation, IEAS} from "eas-contracts/IEAS.sol";
import {IAttestationIndexer} from "verifications/interfaces/IAttestationIndexer.sol";
import {AttestationVerifier} from "verifications/libraries/AttestationVerifier.sol";
import {Predeploys} from "verifications/libraries/Predeploys.sol";

import {IEligibility} from "./interfaces/IEligibility.sol";
import {IAttesterRegistry} from "./AttesterRegistry.sol";

/// @title  RegSGate
/// @notice Multi-source Regulation-S eligibility oracle for Aftermarket.
///
/// @dev    Coinbase's tokenized equities on Base are offered under Regulation S, i.e. to non-US
///         persons only. The B20 token itself checks identity at mint and redeem and keeps a
///         sanctions blocklist, but performs no per-transaction jurisdiction check; anything built
///         on top of it inherits that gap. This contract closes it for Aftermarket by answering one
///         question in bytecode: may this address take a risk-increasing action?
///
///         Sources are consulted in priority order and the first conclusive one wins:
///           1. Coinbase Verifications (live EAS attestations on Base, the authority),
///           2. AttesterRegistry (our own trusted-attester fallback, for networks and accounts
///              where Coinbase attestations cannot be obtained).
///         A valid Coinbase Verified Country attestation is conclusive on its own: it can neither
///         be overridden nor supplemented by the registry. That ordering is the point, because
///         otherwise a compromised or careless attester could whitelist a US person that Coinbase
///         has already identified as one.
///
/// @dev    SAFETY PROPERTY - READ BEFORE INTEGRATING.
///         This gate is only ever to be placed in front of risk-INCREASING actions: opening a line,
///         supplying collateral, drawing credit, increasing leverage. It must NEVER guard repay,
///         nor a collateral withdrawal that leaves no debt behind, nor any other exit path. A
///         compliance rule that can trap someone's assets is a bug, not a feature: an attestation
///         can expire or be revoked at any moment, entirely outside the user's control, and if that
///         event could freeze a repayment it would turn a jurisdiction check into an unbounded loss
///         for a user who did nothing wrong. Consumers that need a read for UI purposes must use
///         {checkNonBlocking}, which cannot revert. Consumers gating a state change must use
///         {requireEligible}, and only on the way in.
///
/// @dev    Every external read is defensive. A missing attestation, a hostile or broken indexer, a
///         garbage return value and a return bomb all degrade to "this source proves nothing"
///         rather than reverting the caller. {check} is total: it returns for every input.
///
/// @dev    Onchain facts confirmed against Base mainnet (chain id 8453) around block 50,973,712 via
///         cast on https://mainnet.base.org, and cross-checked against lib/verifications:
///           - EAS predeploy 0x4200...0021 answers version() == "1.0.1" and has code.
///           - SchemaRegistry predeploy 0x4200...0020 has code.
///           - Coinbase indexer 0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C has code.
///           - Schema 0x1801901f...ca065 resolves to "string verifiedCountry", revocable, resolver
///             0xD867CbEd445c37b0F95Cc956fe6B539BdEf7F32f.
///           - Schema 0xf8b05c79...f0de9 resolves to "bool verifiedAccount", revocable, same resolver.
///           - A live Verified Country attestation carries attester
///             0x357458739F90461b99789350868CD7CF330Dd7EE (verifications.coinbase.eth).
///         Note that the lib/verifications README lists 0x31c04B28E0Dc9909616357bD713De179408F48B0
///         as the Base Sepolia schema resolver, not as an indexer; the Base Sepolia indexer is
///         0xd147a19c3B085Fb9B0c15D2EAAFC6CB086ea849B.
contract RegSGate is IEligibility, Ownable2Step {
    /// @notice No source could prove anything about the account.
    uint8 public constant SOURCE_NONE = 0;
    /// @notice Answer came from a Coinbase Verifications attestation.
    uint8 public constant SOURCE_COINBASE = 1;
    /// @notice Answer came from the AttesterRegistry fallback.
    uint8 public constant SOURCE_REGISTRY = 2;

    /// @notice Coinbase's attester on Base mainnet, verifications.coinbase.eth.
    /// @dev Informational. The gate does not filter on it: Coinbase's schemas are resolver-protected
    ///      so only permitted attesters can write them, which makes the schema check sufficient and
    ///      leaves Coinbase free to rotate the attester key without bricking this contract.
    address public constant COINBASE_ATTESTER = 0x357458739F90461b99789350868CD7CF330Dd7EE;
    /// @notice Coinbase's attestation indexer on Base mainnet.
    address public constant BASE_INDEXER = 0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C;
    /// @notice Coinbase's attestation indexer on Base Sepolia.
    address public constant BASE_SEPOLIA_INDEXER = 0xd147a19c3B085Fb9B0c15D2EAAFC6CB086ea849B;
    /// @notice The "string verifiedCountry" schema on Base mainnet.
    bytes32 public constant BASE_VERIFIED_COUNTRY_SCHEMA =
        0x1801901fabd0e6189356b4fb52bb0ab855276d84f7ec140839fbd1f6801ca065;
    /// @notice The "bool verifiedAccount" schema on Base mainnet.
    bytes32 public constant BASE_VERIFIED_ACCOUNT_SCHEMA =
        0xf8b05c79f090979bf4a80270aba232dff11a10d9ca55c4f88de95317970f0de9;

    /// @notice ISO 3166-1 alpha-2 code for the United States, permanently restricted.
    bytes2 public constant US = 0x5553;

    /// @dev Gas ceiling for a single call into the owner-configured indexer or registry. Both are one
    ///      storage read behind a proxy; the ceiling exists so a hostile implementation can neither
    ///      burn the caller's whole budget nor grief the fallback path.
    uint256 private constant _EXTERNAL_READ_GAS = 200_000;
    /// @dev Gas ceiling for the self-call that reads and verifies one attestation end to end.
    uint256 private constant _ATTESTATION_READ_GAS = 600_000;
    /// @dev Gas ceiling for the self-call behind {checkNonBlocking}.
    uint256 private constant _CHECK_GAS = 2_000_000;

    /// @notice EAS instance holding the attestations. The OP Stack predeploy in production.
    IEAS public immutable eas;
    /// @notice Schema UID of the "string verifiedCountry" attestation.
    bytes32 public immutable verifiedCountrySchema;
    /// @notice Schema UID of the "bool verifiedAccount" attestation.
    bytes32 public immutable verifiedAccountSchema;

    /// @notice Coinbase's attestation indexer. Settable because Coinbase may redeploy it.
    IAttestationIndexer public indexer;
    /// @notice Fallback jurisdiction registry. Settable, and may be zero to disable source 2.
    IAttesterRegistry public registry;

    /// @notice Whether a country code is barred from risk-increasing actions.
    mapping(bytes2 country => bool restricted) public isRestricted;

    /// @dev Enumeration of the restricted set for UIs and audits. Index is one-based; zero means absent.
    bytes2[] private _restrictedList;
    mapping(bytes2 country => uint256 oneBasedIndex) private _restrictedIndex;

    /// @notice Emitted when the indexer address changes.
    event IndexerSet(address indexed previousIndexer, address indexed newIndexer);
    /// @notice Emitted when the fallback registry changes.
    event RegistrySet(address indexed previousRegistry, address indexed newRegistry);
    /// @notice Emitted whenever a country enters or leaves the restricted set.
    event RestrictedJurisdictionSet(bytes2 indexed country, bool restricted);

    /// @notice A zero address was supplied where a real contract is required.
    error ZeroAddress();
    /// @notice A schema UID of zero was supplied.
    error ZeroSchema();
    /// @notice The code is not two uppercase ASCII letters.
    error InvalidCountryCode(bytes2 country);
    /// @notice Regulation S is defined by the exclusion of US persons; US cannot be un-restricted.
    error UnitedStatesIsPermanentlyRestricted();
    /// @notice An attestation decoded to something that is not an ISO 3166-1 alpha-2 code.
    error MalformedCountryCode(string raw);

    /// @param initialOwner    Owner of the gate; a multisig or timelock in production.
    /// @param easAddress      EAS instance; Predeploys.EAS on any OP Stack chain.
    /// @param indexerAddress  Coinbase attestation indexer for this chain.
    /// @param countrySchema   Schema UID of "string verifiedCountry" for this chain.
    /// @param accountSchema   Schema UID of "bool verifiedAccount" for this chain.
    /// @param registryAddress Fallback AttesterRegistry, or zero to run on Coinbase alone.
    /// @param extraRestricted Additional restricted codes on top of the mandatory defaults.
    /// @dev The default restricted set (US plus KP, IR, SY, CU) is always seeded, so no deployment of
    ///      this contract can ever start out admitting a US person.
    constructor(
        address initialOwner,
        address easAddress,
        address indexerAddress,
        bytes32 countrySchema,
        bytes32 accountSchema,
        address registryAddress,
        bytes2[] memory extraRestricted
    ) Ownable(initialOwner) {
        if (initialOwner == address(0) || easAddress == address(0) || indexerAddress == address(0)) {
            revert ZeroAddress();
        }
        if (countrySchema == bytes32(0) || accountSchema == bytes32(0)) revert ZeroSchema();

        eas = IEAS(easAddress);
        verifiedCountrySchema = countrySchema;
        verifiedAccountSchema = accountSchema;
        indexer = IAttestationIndexer(indexerAddress);
        registry = IAttesterRegistry(registryAddress);

        emit IndexerSet(address(0), indexerAddress);
        emit RegistrySet(address(0), registryAddress);

        _restrict(US); // United States: the jurisdiction Regulation S is defined against.
        _restrict(0x4B50); // KP, North Korea
        _restrict(0x4952); // IR, Iran
        _restrict(0x5359); // SY, Syria
        _restrict(0x4355); // CU, Cuba

        for (uint256 i = 0; i < extraRestricted.length; ++i) {
            if (!_isCountryCode(extraRestricted[i])) revert InvalidCountryCode(extraRestricted[i]);
            _restrict(extraRestricted[i]);
        }
    }

    /// @notice The confirmed Base mainnet constructor arguments, so deploy scripts and integrators do
    ///         not have to re-type them.
    function baseMainnetConfig()
        external
        pure
        returns (address easAddress, address indexerAddress, bytes32 countrySchema, bytes32 accountSchema)
    {
        return (Predeploys.EAS, BASE_INDEXER, BASE_VERIFIED_COUNTRY_SCHEMA, BASE_VERIFIED_ACCOUNT_SCHEMA);
    }

    /// @inheritdoc IEligibility
    /// @dev Total function: it never reverts, for any input, against any behaviour of the configured
    ///      indexer, EAS or registry. Callers that want a revert use {requireEligible}.
    function check(address account) public view returns (bool ok, bytes2 country, uint8 source) {
        (bool countryProven, bytes2 coinbaseCountry) = _coinbaseCountry(account);
        if (countryProven) {
            // A valid Coinbase country attestation is conclusive. The registry is not consulted
            // afterwards, so a trusted attester cannot launder a restricted jurisdiction.
            bool admitted = !isRestricted[coinbaseCountry] && _coinbaseAccountVerified(account);
            return (admitted, coinbaseCountry, SOURCE_COINBASE);
        }

        (bool registryProven, bytes2 registryCountry) = _registryCountry(account);
        if (registryProven) {
            return (!isRestricted[registryCountry], registryCountry, SOURCE_REGISTRY);
        }

        return (false, bytes2(0), SOURCE_NONE);
    }

    /// @inheritdoc IEligibility
    /// @dev Reverts with the most specific error that applies:
    ///      - {RestrictedJurisdiction} when a source proved a barred country,
    ///      - {NotEligible} when a permitted country was proven but the account itself is not
    ///        verified, and
    ///      - {AttestationMissing} when nothing at all could be proven.
    ///      Only ever call this on the way into a risk-increasing action. See the contract notice.
    function requireEligible(address account) external view {
        (bool ok, bytes2 country, uint8 source) = check(account);
        if (ok) return;
        if (source != SOURCE_NONE && isRestricted[country]) revert RestrictedJurisdiction(account, country);
        if (source == SOURCE_NONE) revert AttestationMissing(account);
        revert NotEligible(account);
    }

    /// @notice Non-reverting eligibility read for UIs and for callers that must not be able to fail.
    /// @dev Belt and braces around {check}, which is already total. Deliberately not usable to gate a
    ///      state change: it answers "would the gate admit this account right now", nothing more.
    function checkNonBlocking(address account) external view returns (bool) {
        try this.check{gas: _CHECK_GAS}(account) returns (bool ok, bytes2, uint8) {
            return ok;
        } catch {
            return false;
        }
    }

    /// @notice Reads and verifies the Coinbase Verified Country attestation for `account`.
    /// @dev External so {check} can wrap it in try/catch, and directly useful to off-chain tooling
    ///      that wants the failure reason. Reverts when no valid attestation exists.
    function verifiedCountryOf(address account) external view returns (bytes2) {
        bytes32 uid = _attestationUid(account, verifiedCountrySchema);
        if (uid == bytes32(0)) revert AttestationMissing(account);

        Attestation memory attestation = eas.getAttestation(uid);
        // Checks existence, recipient (the impersonation guard), schema, expiry and revocation.
        AttestationVerifier.verifyAttestation(attestation, account, verifiedCountrySchema);

        return _toCountryCode(abi.decode(attestation.data, (string)));
    }

    /// @notice Reads and verifies the Coinbase Verified Account attestation for `account`.
    /// @dev See {verifiedCountryOf} for why this is external. Reverts when no valid attestation exists.
    function verifiedAccountOf(address account) external view returns (bool) {
        bytes32 uid = _attestationUid(account, verifiedAccountSchema);
        if (uid == bytes32(0)) revert AttestationMissing(account);

        Attestation memory attestation = eas.getAttestation(uid);
        AttestationVerifier.verifyAttestation(attestation, account, verifiedAccountSchema);

        return abi.decode(attestation.data, (bool));
    }

    /// @notice The full restricted set, for UIs and audits.
    function restrictedJurisdictions() external view returns (bytes2[] memory) {
        return _restrictedList;
    }

    /// @notice Points the gate at a different Coinbase attestation indexer.
    function setIndexer(address newIndexer) external onlyOwner {
        if (newIndexer == address(0)) revert ZeroAddress();
        emit IndexerSet(address(indexer), newIndexer);
        indexer = IAttestationIndexer(newIndexer);
    }

    /// @notice Points the gate at a different fallback registry, or at zero to disable source 2.
    /// @dev Setting this to zero only ever removes a way to be admitted, so it cannot trap anyone.
    function setRegistry(address newRegistry) external onlyOwner {
        emit RegistrySet(address(registry), newRegistry);
        registry = IAttesterRegistry(newRegistry);
    }

    /// @notice Adds or removes a country code from the restricted set.
    /// @dev US cannot be removed: this contract exists to enforce a Reg-S offering, and an owner key
    ///      that could admit US persons would make the enforcement decorative.
    function setRestricted(bytes2 country, bool restricted) external onlyOwner {
        if (!_isCountryCode(country)) revert InvalidCountryCode(country);
        if (restricted) {
            _restrict(country);
        } else {
            if (country == US) revert UnitedStatesIsPermanentlyRestricted();
            _unrestrict(country);
        }
    }

    /// @dev Resolves the Coinbase country attestation, turning every possible failure into
    ///      "unproven". `proven` is false whenever anything at all went wrong.
    function _coinbaseCountry(address account) private view returns (bool proven, bytes2 country) {
        try this.verifiedCountryOf{gas: _ATTESTATION_READ_GAS}(account) returns (bytes2 code) {
            return (code != bytes2(0), code);
        } catch {
            return (false, bytes2(0));
        }
    }

    /// @dev Resolves the Coinbase account attestation, turning every failure into false.
    function _coinbaseAccountVerified(address account) private view returns (bool) {
        try this.verifiedAccountOf{gas: _ATTESTATION_READ_GAS}(account) returns (bool verified) {
            return verified;
        } catch {
            return false;
        }
    }

    /// @dev Reads the fallback registry and applies revocation and expiry. Never reverts: the return
    ///      data is consumed word by word rather than through abi.decode, so a registry answering
    ///      with dirty or short data degrades to "unproven" instead of reverting the whole check.
    function _registryCountry(address account) private view returns (bool proven, bytes2 country) {
        address target = address(registry);
        if (target == address(0)) return (false, bytes2(0));

        (bool ok, bytes memory raw) =
            _boundedStaticcall(target, abi.encodeCall(IAttesterRegistry.eligibilityOf, (account)), 0x80);
        if (!ok) return (false, bytes2(0));

        bytes2 code = bytes2(_word(raw, 0));
        uint64 issuedAt = uint64(uint256(_word(raw, 1)));
        uint64 expiresAt = uint64(uint256(_word(raw, 2)));
        bool revoked = uint256(_word(raw, 3)) != 0;

        if (issuedAt == 0 || revoked || !_isCountryCode(code)) return (false, bytes2(0));
        if (expiresAt != 0 && expiresAt <= block.timestamp) return (false, bytes2(0));

        return (true, code);
    }

    /// @dev Asks the indexer for an attestation UID. Returns zero on any failure, including a
    ///      reverting indexer, an indexer with no code, and one that answers with the wrong length.
    function _attestationUid(address account, bytes32 schemaUid) private view returns (bytes32) {
        (bool ok, bytes memory raw) = _boundedStaticcall(
            address(indexer), abi.encodeCall(IAttestationIndexer.getAttestationUid, (account, schemaUid)), 0x20
        );
        if (!ok) return bytes32(0);
        return _word(raw, 0);
    }

    /// @dev Gas-capped staticcall that copies exactly `outLength` bytes and demands the callee
    ///      returned exactly that much. Bounding the copy is what makes a return bomb harmless: the
    ///      caller never pays to expand memory for data it did not ask for.
    function _boundedStaticcall(address target, bytes memory payload, uint256 outLength)
        private
        view
        returns (bool ok, bytes memory out)
    {
        out = new bytes(outLength);
        uint256 gasLimit = _EXTERNAL_READ_GAS;
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(payload, 0x20), mload(payload), add(out, 0x20), outLength)
            ok := and(ok, eq(returndatasize(), outLength))
        }
    }

    /// @dev Reads the `index`-th 32-byte word of `data`. The caller guarantees the word exists.
    function _word(bytes memory data, uint256 index) private pure returns (bytes32 result) {
        assembly ("memory-safe") {
            result := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }

    /// @dev Packs a decoded attestation string into a bytes2 code, uppercasing ASCII letters so a
    ///      lowercase attestation cannot slip past the restricted set. Reverts on anything that is
    ///      not two letters, which the caller turns into "unproven".
    function _toCountryCode(string memory raw) private pure returns (bytes2) {
        bytes memory buffer = bytes(raw);
        if (buffer.length != 2) revert MalformedCountryCode(raw);

        uint8 first = _toUpper(uint8(buffer[0]));
        uint8 second = _toUpper(uint8(buffer[1]));
        bytes2 code = bytes2((uint16(first) << 8) | uint16(second));
        if (!_isCountryCode(code)) revert MalformedCountryCode(raw);

        return code;
    }

    /// @dev ASCII uppercase; leaves every other byte alone for {_isCountryCode} to reject.
    function _toUpper(uint8 character) private pure returns (uint8) {
        return (character >= 0x61 && character <= 0x7A) ? character - 0x20 : character;
    }

    /// @dev Two uppercase ASCII letters.
    function _isCountryCode(bytes2 country) private pure returns (bool) {
        uint8 first = uint8(country[0]);
        uint8 second = uint8(country[1]);
        return first >= 0x41 && first <= 0x5A && second >= 0x41 && second <= 0x5A;
    }

    function _restrict(bytes2 country) private {
        if (isRestricted[country]) return;
        isRestricted[country] = true;
        _restrictedList.push(country);
        _restrictedIndex[country] = _restrictedList.length;
        emit RestrictedJurisdictionSet(country, true);
    }

    function _unrestrict(bytes2 country) private {
        uint256 oneBasedIndex = _restrictedIndex[country];
        if (oneBasedIndex == 0) return;

        uint256 lastIndex = _restrictedList.length - 1;
        if (oneBasedIndex - 1 != lastIndex) {
            bytes2 moved = _restrictedList[lastIndex];
            _restrictedList[oneBasedIndex - 1] = moved;
            _restrictedIndex[moved] = oneBasedIndex;
        }
        _restrictedList.pop();

        delete _restrictedIndex[country];
        delete isRestricted[country];
        emit RestrictedJurisdictionSet(country, false);
    }
}
