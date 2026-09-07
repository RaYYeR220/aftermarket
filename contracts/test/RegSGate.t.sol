// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Predeploys} from "verifications/libraries/Predeploys.sol";

import {AttesterRegistry, Eligibility} from "../src/AttesterRegistry.sol";
import {RegSGate} from "../src/RegSGate.sol";
import {IEligibility} from "../src/interfaces/IEligibility.sol";
import {MockEAS} from "./mocks/MockEAS.sol";
import {MockIndexer} from "./mocks/MockIndexer.sol";

/// @dev An indexer that always reverts. Stands in for a broken or hostile Coinbase deployment.
contract RevertingIndexer {
    error Nope();

    fallback() external {
        revert Nope();
    }
}

/// @dev An indexer that answers with the wrong number of bytes.
contract GarbageIndexer {
    fallback() external {
        assembly {
            mstore(0x00, 0xdeadbeef)
            return(0x00, 0x08)
        }
    }
}

/// @dev An indexer that tries to make the caller pay for a huge return buffer.
contract ReturnBombIndexer {
    fallback() external {
        assembly {
            return(0x00, 100000)
        }
    }
}

/// @dev An indexer that burns every drop of gas it is given.
contract GasBurnerIndexer {
    fallback() external {
        assembly {
            for {} 1 {} { mstore(0x00, keccak256(0x00, 0x20)) }
        }
    }
}

/// @dev An EAS whose return data cannot be decoded as an `Attestation`.
contract GarbageEAS {
    fallback() external {
        assembly {
            mstore(0x00, not(0))
            return(0x00, 0x20)
        }
    }
}

/// @dev A registry that answers `eligibilityOf` with dirty, undecodable words.
contract GarbageRegistry {
    fallback() external {
        assembly {
            mstore(0x00, not(0))
            mstore(0x20, not(0))
            mstore(0x40, not(0))
            mstore(0x60, not(0))
            return(0x00, 0x80)
        }
    }
}

/// @dev Models the intended integration shape: entry gated, exit never. Used to pin down the safety
///      property that a lapsed attestation must not be able to trap a user's assets.
contract GatedConsumer {
    IEligibility public immutable gate;

    mapping(address borrower => uint256 amount) public debt;

    constructor(IEligibility gate_) {
        gate = gate_;
    }

    /// @dev Risk-increasing: gated.
    function borrow(uint256 amount) external {
        gate.requireEligible(msg.sender);
        debt[msg.sender] += amount;
    }

    /// @dev Risk-reducing: never gated, by design.
    function repay(uint256 amount) external {
        debt[msg.sender] -= amount;
    }
}

/// @notice Behavioural suite for the Reg-S eligibility gate and its fallback registry.
contract RegSGateTest is Test {
    bytes2 internal constant US = 0x5553;
    bytes2 internal constant PL = 0x504C;
    bytes2 internal constant GB = 0x4742;
    bytes2 internal constant KP = 0x4B50;
    bytes2 internal constant IR = 0x4952;
    bytes2 internal constant SY = 0x5359;
    bytes2 internal constant CU = 0x4355;

    bytes32 internal constant COUNTRY_SCHEMA = keccak256("string verifiedCountry");
    bytes32 internal constant ACCOUNT_SCHEMA = keccak256("bool verifiedAccount");
    bytes32 internal constant OTHER_SCHEMA = keccak256("bool verifiedCoinbaseOne");

    // Real Base mainnet deployment, cross-checked against lib/verifications and live `cast` reads.
    address internal constant COINBASE_ATTESTER = 0x357458739F90461b99789350868CD7CF330Dd7EE;
    address internal constant REAL_INDEXER = 0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C;
    bytes32 internal constant REAL_COUNTRY_SCHEMA = 0x1801901fabd0e6189356b4fb52bb0ab855276d84f7ec140839fbd1f6801ca065;
    bytes32 internal constant REAL_ACCOUNT_SCHEMA = 0xf8b05c79f090979bf4a80270aba232dff11a10d9ca55c4f88de95317970f0de9;

    /// @dev Found by filtering `AttestationIndexed(address,address,bytes32,bytes32)` logs emitted by
    ///      the Coinbase indexer 0x2c7e...619C for topic2 == the Verified Country schema, over Base
    ///      mainnet blocks 50,964,700-50,973,700. The hit resolves to attestation UID
    ///      0xf0856c7f6702880efeb0afa9a85bf2b8c6e3cefb885d14f880a2cf3af8654187, whose EAS record has
    ///      recipient == this address, attester == verifications.coinbase.eth, no expiry, no
    ///      revocation, and data that ABI-decodes to the string "PL". The same address also holds a
    ///      live Verified Account attestation, UID 0xfcb37b5f...4084cb.
    address internal constant ATTESTED_ON_BASE = 0xc799DD327b5D6c6E4Ed5bbEC510b49A1ce4bB6d7;

    /// @dev Burn address. Confirmed to have no Coinbase attestation of either schema on Base mainnet.
    address internal constant UNATTESTED_ON_BASE = 0x000000000000000000000000000000000000dEaD;

    address internal owner = makeAddr("owner");
    address internal attester = makeAddr("attester");
    address internal alice = makeAddr("alice");
    address internal mallory = makeAddr("mallory");

    MockEAS internal eas;
    MockIndexer internal indexer;
    AttesterRegistry internal registry;
    RegSGate internal gate;

    function setUp() public {
        eas = new MockEAS();
        indexer = new MockIndexer();
        registry = new AttesterRegistry(owner);
        gate = _deployGate(address(eas), address(indexer), address(registry));

        vm.prank(owner);
        registry.setAttester(attester, true);
    }

    /*//////////////////////////////////////////////////////////////
                        SOURCE 1: COINBASE VERIFICATIONS
    //////////////////////////////////////////////////////////////*/

    function test_Coinbase_EligibleNonUsAccount() public {
        _grantCountry(alice, "PL");
        _grantAccount(alice);

        (bool ok, bytes2 country, uint8 source) = gate.check(alice);
        assertTrue(ok, "non-US Coinbase account must be admitted");
        assertEq(country, PL);
        assertEq(source, gate.SOURCE_COINBASE());

        gate.requireEligible(alice);
        assertTrue(gate.checkNonBlocking(alice));
    }

    function test_Coinbase_LowercaseCountryIsNormalised() public {
        _grantCountry(alice, "pl");
        _grantAccount(alice);

        (bool ok, bytes2 country,) = gate.check(alice);
        assertTrue(ok);
        assertEq(country, PL, "lowercase attestation must normalise to the uppercase code");
    }

    function test_Coinbase_UnitedStatesIsRejected() public {
        _grantCountry(alice, "US");
        _grantAccount(alice);

        (bool ok, bytes2 country, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(country, US);
        assertEq(source, gate.SOURCE_COINBASE());

        vm.expectRevert(abi.encodeWithSelector(IEligibility.RestrictedJurisdiction.selector, alice, US));
        gate.requireEligible(alice);

        assertFalse(gate.checkNonBlocking(alice));
    }

    function test_Coinbase_LowercaseUnitedStatesIsRejected() public {
        _grantCountry(alice, "us");
        _grantAccount(alice);

        vm.expectRevert(abi.encodeWithSelector(IEligibility.RestrictedJurisdiction.selector, alice, US));
        gate.requireEligible(alice);
    }

    function test_Coinbase_SanctionedJurisdictionsAreRejected() public {
        bytes2[4] memory sanctioned = [KP, IR, SY, CU];

        for (uint256 i = 0; i < sanctioned.length; ++i) {
            string memory code = _codeString(sanctioned[i]);
            address subject = makeAddr(code);
            _grantCountry(subject, code);
            _grantAccount(subject);

            (bool ok, bytes2 country, uint8 source) = gate.check(subject);
            assertFalse(ok, code);
            assertEq(country, sanctioned[i]);
            assertEq(source, gate.SOURCE_COINBASE());

            vm.expectRevert(
                abi.encodeWithSelector(IEligibility.RestrictedJurisdiction.selector, subject, sanctioned[i])
            );
            gate.requireEligible(subject);
        }
    }

    function test_Coinbase_ExpiredCountryAttestationIsNotProven() public {
        bytes32 uid = _grantCountry(alice, "PL");
        _grantAccount(alice);

        vm.warp(1_800_000_000);
        // Re-file the same UID with an expiry that has already passed.
        eas.attest(
            uid, COUNTRY_SCHEMA, alice, COINBASE_ATTESTER, uint64(block.timestamp - 1), 0, abi.encode(string("PL"))
        );

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(source, gate.SOURCE_NONE());
        assertFalse(gate.checkNonBlocking(alice));
    }

    function test_Coinbase_RevokedCountryAttestationIsNotProven() public {
        bytes32 uid = _grantCountry(alice, "PL");
        _grantAccount(alice);

        eas.revoke(uid, uint64(block.timestamp));

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(source, gate.SOURCE_NONE());
    }

    function test_Coinbase_WrongSchemaIsNotProven() public {
        bytes32 uid = keccak256("wrong-schema");
        // Indexed under the country schema, but the attestation itself carries a different one.
        eas.attest(uid, OTHER_SCHEMA, alice, COINBASE_ATTESTER, 0, 0, abi.encode(string("PL")));
        indexer.setAttestationUid(alice, COUNTRY_SCHEMA, uid);
        _grantAccount(alice);

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(source, gate.SOURCE_NONE());
    }

    function test_Coinbase_AttestationForAnotherRecipientIsNotProven() public {
        // Alice holds a genuine PL attestation; Mallory points the indexer at it.
        bytes32 uid = _grantCountry(alice, "PL");
        indexer.setAttestationUid(mallory, COUNTRY_SCHEMA, uid);
        _grantAccount(mallory);

        (bool ok,, uint8 source) = gate.check(mallory);
        assertFalse(ok, "AttestationVerifier must reject a recipient mismatch");
        assertEq(source, gate.SOURCE_NONE());

        vm.expectRevert(abi.encodeWithSelector(IEligibility.AttestationMissing.selector, mallory));
        gate.requireEligible(mallory);
    }

    function test_Coinbase_MissingAccountAttestationIsNotEligible() public {
        _grantCountry(alice, "PL");

        (bool ok, bytes2 country, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(country, PL, "the country is still reported, it just is not sufficient");
        assertEq(source, gate.SOURCE_COINBASE());

        vm.expectRevert(abi.encodeWithSelector(IEligibility.NotEligible.selector, alice));
        gate.requireEligible(alice);
    }

    function test_Coinbase_RevokedAccountAttestationIsNotEligible() public {
        _grantCountry(alice, "PL");
        bytes32 uid = _grantAccount(alice);
        eas.revoke(uid, uint64(block.timestamp));

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(source, gate.SOURCE_COINBASE());
    }

    function test_Coinbase_MalformedCountryStringIsNotProven() public {
        bytes32 uid = keccak256("malformed");
        eas.attest(uid, COUNTRY_SCHEMA, alice, COINBASE_ATTESTER, 0, 0, abi.encode(string("POL")));
        indexer.setAttestationUid(alice, COUNTRY_SCHEMA, uid);
        _grantAccount(alice);

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(source, gate.SOURCE_NONE());
    }

    function test_Coinbase_UndecodableAttestationDataIsNotProven() public {
        bytes32 uid = keccak256("undecodable");
        eas.attest(uid, COUNTRY_SCHEMA, alice, COINBASE_ATTESTER, 0, 0, hex"c0ffee");
        indexer.setAttestationUid(alice, COUNTRY_SCHEMA, uid);
        _grantAccount(alice);

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(source, gate.SOURCE_NONE());
    }

    function test_Coinbase_ZeroUidFallsThroughToRegistry() public {
        // Nothing indexed at all: the indexer answers bytes32(0) for both schemas.
        assertEq(indexer.getAttestationUid(alice, COUNTRY_SCHEMA), bytes32(0));

        vm.prank(attester);
        registry.attest(alice, GB, 0);

        (bool ok, bytes2 country, uint8 source) = gate.check(alice);
        assertTrue(ok);
        assertEq(country, GB);
        assertEq(source, gate.SOURCE_REGISTRY());
    }

    /*//////////////////////////////////////////////////////////////
                          HOSTILE EXTERNAL SOURCES
    //////////////////////////////////////////////////////////////*/

    function test_Hostile_RevertingIndexerDegradesCleanly() public {
        _expectCleanDegradation(address(new RevertingIndexer()));
    }

    function test_Hostile_GarbageIndexerDegradesCleanly() public {
        _expectCleanDegradation(address(new GarbageIndexer()));
    }

    function test_Hostile_ReturnBombIndexerDegradesCleanly() public {
        _expectCleanDegradation(address(new ReturnBombIndexer()));
    }

    function test_Hostile_GasBurningIndexerDegradesCleanly() public {
        _expectCleanDegradation(address(new GasBurnerIndexer()));
    }

    function test_Hostile_IndexerWithNoCodeDegradesCleanly() public {
        _expectCleanDegradation(makeAddr("not-a-contract"));
    }

    function test_Hostile_GarbageEasDegradesCleanly() public {
        RegSGate hostile = _deployGate(address(new GarbageEAS()), address(indexer), address(registry));
        indexer.setAttestationUid(alice, COUNTRY_SCHEMA, keccak256("anything"));

        (bool ok,, uint8 source) = hostile.check(alice);
        assertFalse(ok);
        assertEq(source, hostile.SOURCE_NONE());
        assertFalse(hostile.checkNonBlocking(alice));
    }

    function test_Hostile_GarbageRegistryDegradesCleanly() public {
        address hostileRegistry = address(new GarbageRegistry());
        vm.prank(owner);
        gate.setRegistry(hostileRegistry);

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok, "dirty registry words must not decode into an admission");
        assertEq(source, gate.SOURCE_NONE());
        assertFalse(gate.checkNonBlocking(alice));
    }

    function test_Hostile_RevertingRegistryDegradesCleanly() public {
        address hostileRegistry = address(new RevertingIndexer());
        vm.prank(owner);
        gate.setRegistry(hostileRegistry);

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(source, gate.SOURCE_NONE());
    }

    /// @dev A Coinbase-proven restricted country must not be overridable by the fallback registry.
    function test_Hostile_RegistryCannotLaunderARestrictedCoinbaseCountry() public {
        _grantCountry(alice, "US");
        _grantAccount(alice);

        vm.prank(attester);
        registry.attest(alice, PL, 0);

        (bool ok, bytes2 country, uint8 source) = gate.check(alice);
        assertFalse(ok, "source 1 is conclusive; the registry must not be consulted");
        assertEq(country, US);
        assertEq(source, gate.SOURCE_COINBASE());
    }

    /*//////////////////////////////////////////////////////////////
                         SOURCE 2: ATTESTER REGISTRY
    //////////////////////////////////////////////////////////////*/

    function test_Registry_AttestMakesEligible() public {
        vm.prank(attester);
        registry.attest(alice, GB, 0);

        (bool ok, bytes2 country, uint8 source) = gate.check(alice);
        assertTrue(ok);
        assertEq(country, GB);
        assertEq(source, gate.SOURCE_REGISTRY());
        gate.requireEligible(alice);

        Eligibility memory record = registry.eligibilityOf(alice);
        assertEq(record.country, GB);
        assertEq(record.issuedAt, uint64(block.timestamp));
        assertEq(record.expiresAt, 0);
        assertFalse(record.revoked);
    }

    function test_Registry_RevokeMakesIneligible() public {
        vm.prank(attester);
        registry.attest(alice, GB, 0);

        vm.prank(attester);
        registry.revoke(alice);

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(source, gate.SOURCE_NONE());

        vm.expectRevert(abi.encodeWithSelector(IEligibility.AttestationMissing.selector, alice));
        gate.requireEligible(alice);
    }

    function test_Registry_ExpiryMakesIneligible() public {
        uint64 expiresAt = uint64(block.timestamp + 30 days);
        vm.prank(attester);
        registry.attest(alice, GB, expiresAt);

        (bool ok,, uint8 source) = gate.check(alice);
        assertTrue(ok);

        vm.warp(expiresAt);
        (ok,, source) = gate.check(alice);
        assertFalse(ok, "an expiry is inclusive: at expiresAt the record is already stale");
        assertEq(source, gate.SOURCE_NONE());
        assertFalse(gate.checkNonBlocking(alice));
    }

    function test_Registry_RestrictedCountryIsRejected() public {
        vm.prank(attester);
        registry.attest(alice, US, 0);

        (bool ok, bytes2 country, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(country, US);
        assertEq(source, gate.SOURCE_REGISTRY());

        vm.expectRevert(abi.encodeWithSelector(IEligibility.RestrictedJurisdiction.selector, alice, US));
        gate.requireEligible(alice);
    }

    function test_Registry_ReattestationReinstatesARevokedSubject() public {
        vm.prank(attester);
        registry.attest(alice, GB, 0);
        vm.prank(attester);
        registry.revoke(alice);
        vm.prank(attester);
        registry.attest(alice, GB, 0);

        (bool ok,, uint8 source) = gate.check(alice);
        assertTrue(ok);
        assertEq(source, gate.SOURCE_REGISTRY());
    }

    function test_Registry_NonAttesterCannotAttest() public {
        vm.expectRevert(abi.encodeWithSelector(AttesterRegistry.NotAttester.selector, mallory));
        vm.prank(mallory);
        registry.attest(alice, GB, 0);
    }

    function test_Registry_NonAttesterCannotRevoke() public {
        vm.prank(attester);
        registry.attest(alice, GB, 0);

        vm.expectRevert(abi.encodeWithSelector(AttesterRegistry.NotAttester.selector, mallory));
        vm.prank(mallory);
        registry.revoke(alice);
    }

    function test_Registry_RemovedAttesterCannotAttest() public {
        vm.prank(owner);
        registry.setAttester(attester, false);

        vm.expectRevert(abi.encodeWithSelector(AttesterRegistry.NotAttester.selector, attester));
        vm.prank(attester);
        registry.attest(alice, GB, 0);
    }

    function test_Registry_OwnerIsImplicitlyAnAttester() public {
        vm.prank(owner);
        registry.attest(alice, GB, 0);

        (bool valid, bytes2 country) = registry.isValid(alice);
        assertTrue(valid);
        assertEq(country, GB);
    }

    function test_Registry_RejectsBadInput() public {
        vm.startPrank(attester);

        vm.expectRevert(AttesterRegistry.ZeroAddress.selector);
        registry.attest(address(0), GB, 0);

        vm.expectRevert(abi.encodeWithSelector(AttesterRegistry.InvalidCountryCode.selector, bytes2(0)));
        registry.attest(alice, bytes2(0), 0);

        vm.expectRevert(abi.encodeWithSelector(AttesterRegistry.InvalidCountryCode.selector, bytes2("gb")));
        registry.attest(alice, bytes2("gb"), 0);

        uint64 past = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(AttesterRegistry.ExpiryInThePast.selector, past));
        registry.attest(alice, GB, past);

        vm.expectRevert(abi.encodeWithSelector(AttesterRegistry.NoRecord.selector, alice));
        registry.revoke(alice);

        vm.stopPrank();
    }

    function test_Registry_OnlyOwnerManagesAttesters() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        vm.prank(mallory);
        registry.setAttester(mallory, true);
    }

    function test_Registry_EmitsEvents() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit AttesterRegistry.AttesterSet(mallory, true);
        vm.prank(owner);
        registry.setAttester(mallory, true);

        vm.expectEmit(true, true, false, true, address(registry));
        emit AttesterRegistry.Attested(alice, attester, GB, uint64(block.timestamp), 0);
        vm.prank(attester);
        registry.attest(alice, GB, 0);

        vm.expectEmit(true, true, false, true, address(registry));
        emit AttesterRegistry.Revoked(alice, attester, GB);
        vm.prank(attester);
        registry.revoke(alice);
    }

    function test_Registry_DisablingSource2LeavesTheGateWorking() public {
        vm.prank(attester);
        registry.attest(alice, GB, 0);

        vm.prank(owner);
        gate.setRegistry(address(0));

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(source, gate.SOURCE_NONE());
    }

    /*//////////////////////////////////////////////////////////////
                                  CONFIG
    //////////////////////////////////////////////////////////////*/

    function test_Config_DefaultRestrictedSet() public view {
        assertTrue(gate.isRestricted(US));
        assertTrue(gate.isRestricted(KP));
        assertTrue(gate.isRestricted(IR));
        assertTrue(gate.isRestricted(SY));
        assertTrue(gate.isRestricted(CU));
        assertFalse(gate.isRestricted(GB));
        assertEq(gate.restrictedJurisdictions().length, 5);
    }

    function test_Config_ExtraRestrictedCodesAreSeeded() public {
        bytes2[] memory extra = new bytes2[](2);
        extra[0] = GB;
        extra[1] = US; // duplicate of a default; must not be double-counted
        RegSGate custom = new RegSGate(
            owner, address(eas), address(indexer), COUNTRY_SCHEMA, ACCOUNT_SCHEMA, address(registry), extra
        );

        assertTrue(custom.isRestricted(GB));
        assertEq(custom.restrictedJurisdictions().length, 6);
    }

    function test_Config_OwnerCanRestrictAndUnrestrict() public {
        vm.startPrank(owner);

        vm.expectEmit(true, false, false, true, address(gate));
        emit RegSGate.RestrictedJurisdictionSet(GB, true);
        gate.setRestricted(GB, true);
        assertTrue(gate.isRestricted(GB));
        assertEq(gate.restrictedJurisdictions().length, 6);

        vm.expectEmit(true, false, false, true, address(gate));
        emit RegSGate.RestrictedJurisdictionSet(GB, false);
        gate.setRestricted(GB, false);
        assertFalse(gate.isRestricted(GB));
        assertEq(gate.restrictedJurisdictions().length, 5);

        vm.stopPrank();

        // The remaining five must survive the swap-and-pop intact.
        assertTrue(gate.isRestricted(US));
        assertTrue(gate.isRestricted(KP));
        assertTrue(gate.isRestricted(IR));
        assertTrue(gate.isRestricted(SY));
        assertTrue(gate.isRestricted(CU));
    }

    function test_Config_UnitedStatesCannotBeUnrestricted() public {
        vm.expectRevert(RegSGate.UnitedStatesIsPermanentlyRestricted.selector);
        vm.prank(owner);
        gate.setRestricted(US, false);
    }

    function test_Config_RejectsMalformedCountryCodes() public {
        vm.expectRevert(abi.encodeWithSelector(RegSGate.InvalidCountryCode.selector, bytes2("u5")));
        vm.prank(owner);
        gate.setRestricted(bytes2("u5"), true);
    }

    function test_Config_OnlyOwnerConfigures() public {
        vm.startPrank(mallory);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        gate.setRestricted(GB, true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        gate.setIndexer(address(1));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        gate.setRegistry(address(1));

        vm.stopPrank();
    }

    function test_Config_SetIndexerRepointsSource1() public {
        MockIndexer replacement = new MockIndexer();
        bytes32 countryUid = keccak256("replacement-country");
        bytes32 accountUid = keccak256("replacement-account");
        eas.attest(countryUid, COUNTRY_SCHEMA, alice, COINBASE_ATTESTER, 0, 0, abi.encode(string("PL")));
        eas.attest(accountUid, ACCOUNT_SCHEMA, alice, COINBASE_ATTESTER, 0, 0, abi.encode(true));
        replacement.setAttestationUid(alice, COUNTRY_SCHEMA, countryUid);
        replacement.setAttestationUid(alice, ACCOUNT_SCHEMA, accountUid);

        (bool ok,, uint8 source) = gate.check(alice);
        assertFalse(ok);

        vm.expectEmit(true, true, false, false, address(gate));
        emit RegSGate.IndexerSet(address(indexer), address(replacement));
        vm.prank(owner);
        gate.setIndexer(address(replacement));

        (ok,, source) = gate.check(alice);
        assertTrue(ok);
        assertEq(source, gate.SOURCE_COINBASE());
    }

    function test_Config_ConstructorRejectsZeroArguments() public {
        bytes2[] memory none = new bytes2[](0);

        vm.expectRevert(RegSGate.ZeroAddress.selector);
        new RegSGate(owner, address(0), address(indexer), COUNTRY_SCHEMA, ACCOUNT_SCHEMA, address(registry), none);

        vm.expectRevert(RegSGate.ZeroAddress.selector);
        new RegSGate(owner, address(eas), address(0), COUNTRY_SCHEMA, ACCOUNT_SCHEMA, address(registry), none);

        vm.expectRevert(RegSGate.ZeroSchema.selector);
        new RegSGate(owner, address(eas), address(indexer), bytes32(0), ACCOUNT_SCHEMA, address(registry), none);

        vm.expectRevert(RegSGate.ZeroSchema.selector);
        new RegSGate(owner, address(eas), address(indexer), COUNTRY_SCHEMA, bytes32(0), address(registry), none);
    }

    function test_Config_BaseMainnetConfigMatchesConfirmedAddresses() public view {
        (address easAddress, address indexerAddress, bytes32 countrySchema, bytes32 accountSchema) =
            gate.baseMainnetConfig();
        assertEq(easAddress, Predeploys.EAS);
        assertEq(indexerAddress, REAL_INDEXER);
        assertEq(countrySchema, REAL_COUNTRY_SCHEMA);
        assertEq(accountSchema, REAL_ACCOUNT_SCHEMA);
    }

    /*//////////////////////////////////////////////////////////////
                            TOTALITY AND FUZZING
    //////////////////////////////////////////////////////////////*/

    /// @dev `check` must return, never revert, whatever the indexer and EAS happen to hold.
    function testFuzz_CheckNeverReverts(address account, bytes32 countryUid, bytes32 accountUid, bytes memory payload)
        public
    {
        vm.assume(account != address(0));

        indexer.setAttestationUid(account, COUNTRY_SCHEMA, countryUid);
        indexer.setAttestationUid(account, ACCOUNT_SCHEMA, accountUid);
        if (countryUid != bytes32(0)) {
            eas.attest(countryUid, COUNTRY_SCHEMA, account, COINBASE_ATTESTER, 0, 0, payload);
        }
        if (accountUid != bytes32(0)) {
            eas.attest(accountUid, ACCOUNT_SCHEMA, account, COINBASE_ATTESTER, 0, 0, payload);
        }

        (bool ok, bytes2 country, uint8 source) = gate.check(account);
        assertEq(gate.checkNonBlocking(account), ok);
        assertLe(source, gate.SOURCE_REGISTRY());
        if (ok) {
            assertFalse(gate.isRestricted(country));
            assertGt(source, gate.SOURCE_NONE());
        }
    }

    /// @dev Whatever the registry holds, the gate stays total and never admits a restricted code.
    /// @param first  First letter of the code, bounded into A-Z rather than assumed, so the fuzzer
    ///               never has to reject its way to a valid ISO code.
    /// @param second Second letter of the code, bounded the same way.
    function testFuzz_RegistryFallbackNeverReverts(address account, uint8 first, uint8 second, uint64 expiresAt)
        public
    {
        vm.assume(account != address(0));
        bytes2 country =
            bytes2((uint16(uint8(_bound(first, 0x41, 0x5A))) << 8) | uint16(uint8(_bound(second, 0x41, 0x5A))));
        expiresAt = uint64(_bound(expiresAt, block.timestamp + 1, type(uint64).max));

        vm.prank(attester);
        registry.attest(account, country, expiresAt);

        (bool ok, bytes2 reported, uint8 source) = gate.check(account);
        assertEq(source, gate.SOURCE_REGISTRY());
        assertEq(reported, country);
        assertEq(ok, !gate.isRestricted(country));
        assertEq(gate.checkNonBlocking(account), ok);
    }

    /// @dev `checkNonBlocking` is the UI read: it must be false-not-revert in every failure mode.
    function test_NonBlocking_NeverRevertsAcrossFailureModes() public {
        assertFalse(gate.checkNonBlocking(alice));

        address reverting = address(new RevertingIndexer());
        address gasBurner = address(new GasBurnerIndexer());
        address garbageRegistry = address(new GarbageRegistry());

        vm.prank(owner);
        gate.setIndexer(reverting);
        assertFalse(gate.checkNonBlocking(alice));

        vm.prank(owner);
        gate.setIndexer(gasBurner);
        assertFalse(gate.checkNonBlocking(alice));

        vm.prank(owner);
        gate.setRegistry(garbageRegistry);
        assertFalse(gate.checkNonBlocking(alice));

        vm.prank(owner);
        gate.setRegistry(address(0));
        assertFalse(gate.checkNonBlocking(alice));
    }

    /// @dev The property the whole module is designed around: an attestation lapsing must close the
    ///      door in, never the door out.
    function test_Safety_LapsedAttestationBlocksEntryButNotExit() public {
        GatedConsumer consumer = new GatedConsumer(gate);
        uint64 expiresAt = uint64(block.timestamp + 30 days);

        vm.prank(attester);
        registry.attest(alice, GB, expiresAt);

        vm.prank(alice);
        consumer.borrow(100 ether);
        assertEq(consumer.debt(alice), 100 ether);

        vm.warp(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(IEligibility.AttestationMissing.selector, alice));
        vm.prank(alice);
        consumer.borrow(1 ether);

        // The exit path never touches the gate, so the borrower can always cure.
        vm.prank(alice);
        consumer.repay(100 ether);
        assertEq(consumer.debt(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        BASE MAINNET FORK: PROOF OF REALITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Runs the gate against the real Coinbase Verifications deployment on Base mainnet.
    /// @dev This is the evidence that source 1 is a real read path and not a mock. Set BASE_RPC_URL
    ///      to run it; optionally pin with BASE_FORK_BLOCK. It is skipped, not failed, without an RPC.
    function test_Fork_RealCoinbaseAttestationOnBaseMainnet() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set");
            return;
        }

        uint256 pinnedBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (pinnedBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pinnedBlock);
        }
        assertEq(block.chainid, 8453, "BASE_RPC_URL must point at Base mainnet");

        RegSGate live = new RegSGate(
            owner,
            Predeploys.EAS,
            REAL_INDEXER,
            REAL_COUNTRY_SCHEMA,
            REAL_ACCOUNT_SCHEMA,
            address(0), // Coinbase only: no fallback, so this proves source 1 in isolation.
            new bytes2[](0)
        );

        (bool ok, bytes2 country, uint8 source) = live.check(ATTESTED_ON_BASE);
        console2.log("attested account", ATTESTED_ON_BASE);
        console2.log("country", string(abi.encodePacked(country)));
        console2.log("source", source);
        assertEq(source, live.SOURCE_COINBASE(), "answer must come from Coinbase Verifications");
        assertEq(country, PL, "live Verified Country attestation decodes to PL");
        assertTrue(ok, "a non-US Coinbase-verified account must be admitted");
        assertTrue(live.checkNonBlocking(ATTESTED_ON_BASE));
        live.requireEligible(ATTESTED_ON_BASE);

        // The same read path through the standalone helpers.
        assertEq(live.verifiedCountryOf(ATTESTED_ON_BASE), PL);
        assertTrue(live.verifiedAccountOf(ATTESTED_ON_BASE));

        // And an address the indexer knows nothing about.
        (ok, country, source) = live.check(UNATTESTED_ON_BASE);
        assertFalse(ok);
        assertEq(country, bytes2(0));
        assertEq(source, live.SOURCE_NONE());
        assertFalse(live.checkNonBlocking(UNATTESTED_ON_BASE));
        vm.expectRevert(abi.encodeWithSelector(IEligibility.AttestationMissing.selector, UNATTESTED_ON_BASE));
        live.requireEligible(UNATTESTED_ON_BASE);

        // A US-restricted gate would reject the same account, proving the restricted set bites on
        // real data rather than only on fixtures.
        vm.prank(owner);
        live.setRestricted(PL, true);
        vm.expectRevert(abi.encodeWithSelector(IEligibility.RestrictedJurisdiction.selector, ATTESTED_ON_BASE, PL));
        live.requireEligible(ATTESTED_ON_BASE);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Unpacks a country code back into the two-character string an attestation carries.
    function _codeString(bytes2 code) internal pure returns (string memory) {
        return string(abi.encodePacked(code));
    }

    function _deployGate(address easAddress, address indexerAddress, address registryAddress)
        internal
        returns (RegSGate)
    {
        return new RegSGate(
            owner, easAddress, indexerAddress, COUNTRY_SCHEMA, ACCOUNT_SCHEMA, registryAddress, new bytes2[](0)
        );
    }

    function _grantCountry(address subject, string memory code) internal returns (bytes32 uid) {
        uid = keccak256(abi.encode("country", subject, code));
        eas.attest(uid, COUNTRY_SCHEMA, subject, COINBASE_ATTESTER, 0, 0, abi.encode(code));
        indexer.setAttestationUid(subject, COUNTRY_SCHEMA, uid);
    }

    function _grantAccount(address subject) internal returns (bytes32 uid) {
        uid = keccak256(abi.encode("account", subject));
        eas.attest(uid, ACCOUNT_SCHEMA, subject, COINBASE_ATTESTER, 0, 0, abi.encode(true));
        indexer.setAttestationUid(subject, ACCOUNT_SCHEMA, uid);
    }

    /// @dev Points the gate at a broken indexer and asserts the whole surface stays total, with the
    ///      registry fallback still reachable behind it.
    function _expectCleanDegradation(address brokenIndexer) internal {
        vm.prank(owner);
        gate.setIndexer(brokenIndexer);

        (bool ok, bytes2 country, uint8 source) = gate.check(alice);
        assertFalse(ok);
        assertEq(country, bytes2(0));
        assertEq(source, gate.SOURCE_NONE());
        assertFalse(gate.checkNonBlocking(alice));

        vm.expectRevert(abi.encodeWithSelector(IEligibility.AttestationMissing.selector, alice));
        gate.requireEligible(alice);

        // Source 2 must still work behind a broken source 1.
        vm.prank(attester);
        registry.attest(alice, GB, 0);
        (ok, country, source) = gate.check(alice);
        assertTrue(ok, "a broken indexer must not disable the fallback");
        assertEq(country, GB);
        assertEq(source, gate.SOURCE_REGISTRY());
    }
}
