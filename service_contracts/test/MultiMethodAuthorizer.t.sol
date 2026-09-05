// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MultiMethodAuthorizer} from "../src/examples/MultiMethodAuthorizer.sol";

contract MultiMethodAuthorizerTest is Test {
    using Clones for address;

    // Spec / FWSS operation typehashes.
    bytes32 internal constant ADD_PIECES = 0x954bdc254591a7eab1b73f03842464d9283a08352772737094d710a4428fd183;
    bytes32 internal constant SCHEDULE_REMOVALS = 0x5415701e313bb627e755b16924727217bb356574fe20e7061442c200b0822b22;
    bytes32 internal constant TERMINATE = 0x522bd88a11de1cdc6574394dde7a21ae488ff13e16e7408d0ea721dd8479dffc;

    uint256 internal constant PRIV = 0x2b6e033b015f3c86da0e6ecf6bd295fb19b45166d0ec219761d09c3d32225f6a;
    bytes32 internal constant DIGEST = bytes32(uint256(0x1111));
    bytes32 internal constant RP_ID = keccak256("example.com"); // not sha256; tests pin an arbitrary 32-byte value

    MultiMethodAuthorizer internal auth;
    uint256 internal px;
    uint256 internal py;
    address internal stranger;

    function setUp() public {
        auth = new MultiMethodAuthorizer();
        (px, py) = vm.publicKeyP256(PRIV);
        stranger = makeAddr("stranger");
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _ops(bytes32 a) internal pure returns (bytes32[] memory o) {
        o = new bytes32[](1);
        o[0] = a;
    }

    function _ops2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory o) {
        o = new bytes32[](2);
        o[0] = a;
        o[1] = b;
    }

    function _lowS(bytes32 s) internal pure returns (bytes32) {
        if (uint256(s) > P256.N / 2) return bytes32(P256.N - uint256(s));
        return s;
    }

    function _sign(bytes32 digest) internal pure returns (bytes32 r, bytes32 s) {
        (r, s) = vm.signP256(PRIV, digest);
        s = _lowS(s);
    }

    function _machineBlob(bytes32 digest) internal view returns (bytes memory) {
        (bytes32 r, bytes32 s) = _sign(digest);
        return abi.encode(uint8(0), abi.encode(px, py, r, s));
    }

    function _authData(bytes32 rpIdHash, uint8 flags) internal pure returns (bytes memory ad) {
        ad = new bytes(37);
        assembly {
            mstore(add(ad, 32), rpIdHash)
        }
        ad[32] = bytes1(flags);
    }

    function _clientData(bytes32 digest, bool compact) internal view returns (string memory) {
        string memory ch = auth.encodeChallenge(digest);
        if (compact) {
            return string.concat('{"type":"webauthn.get","challenge":"', ch, '","origin":"https://example.com"}');
        }
        return string.concat('{"type": "webauthn.get","challenge": "', ch, '","origin": "https://example.com"}');
    }

    function _passkeyBlob(bytes memory ad, string memory cd) internal view returns (bytes memory) {
        bytes32 message = sha256(abi.encodePacked(ad, sha256(bytes(cd))));
        (bytes32 r, bytes32 s) = _sign(message);
        return abi.encode(uint8(1), abi.encode(px, py, r, s, ad, cd));
    }

    function _goodPasskey(bytes32 digest, bytes32 rpIdHash) internal view returns (bytes memory) {
        bytes memory ad = _authData(rpIdHash, 0x05); // UP | UV
        return _passkeyBlob(ad, _clientData(digest, true));
    }

    function _addMachine(uint256 dataSetId, bytes32[] memory ops) internal returns (bytes32) {
        return auth.addCredential(MultiMethodAuthorizer.Method.MachineP256, px, py, dataSetId, bytes32(0), 0, ops);
    }

    function _addPasskey(uint256 dataSetId, bytes32 rpIdHash, bytes32[] memory ops) internal returns (bytes32) {
        return auth.addCredential(MultiMethodAuthorizer.Method.Passkey, px, py, dataSetId, rpIdHash, 0, ops);
    }

    function _check(uint256 dataSetId, bytes32 operation, bytes memory signature) internal returns (bool) {
        return auth.isAuthorized(dataSetId, address(0), operation, DIGEST, signature, "");
    }

    function _checkDigest(uint256 dataSetId, bytes32 operation, bytes32 digest, bytes memory signature)
        internal
        returns (bool)
    {
        return auth.isAuthorized(dataSetId, address(0), operation, digest, signature, "");
    }

    // ───────────────────────────── spec canaries ─────────────────────────────

    function test_specOperationTypehashesMatchFwss() public pure {
        assertEq(
            ADD_PIECES,
            keccak256(
                abi.encodePacked(
                    "AddPieces(uint256 clientDataSetId,uint256 nonce,Cid[] pieceData,PieceMetadata[] pieceMetadata)",
                    "Cid(bytes data)",
                    "MetadataEntry(string key,string value)",
                    "PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)"
                )
            )
        );
        assertEq(SCHEDULE_REMOVALS, keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)"));
        assertEq(TERMINATE, keccak256("TerminateService(uint256 dataSetId)"));
    }

    function test_encodeChallengeIsUnpaddedBase64UrlOf32Bytes() public view {
        string memory ch = auth.encodeChallenge(DIGEST);
        assertEq(bytes(ch).length, 43);
        bytes memory raw = bytes(ch);
        for (uint256 i; i < raw.length; i++) {
            bytes1 c = raw[i];
            bool ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-" || c == "_";
            assertTrue(ok, "non-base64url char");
        }
    }

    // ───────────────────────────── registry / clone ─────────────────────────────

    function test_constructorSetsDeployerAsOwner() public view {
        assertEq(auth.owner(), address(this));
    }

    function test_nonOwnerCannotMutateRegistry() public {
        bytes memory notOwner = abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(notOwner);
        _addMachine(1, _ops(ADD_PIECES));
        vm.expectRevert(notOwner);
        auth.setOperationAllowed(bytes32(0), ADD_PIECES, true);
        vm.expectRevert(notOwner);
        auth.setCredentialEnabled(bytes32(0), false);
        vm.expectRevert(notOwner);
        auth.setCredentialExpiry(bytes32(0), 1);
        vm.expectRevert(notOwner);
        auth.removeCredential(bytes32(0));
        vm.expectRevert(notOwner);
        auth.transferOwnership(stranger);
        vm.stopPrank();
    }

    function test_standaloneCannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        auth.initialize(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        auth.initialize(address(0));
    }

    function test_cloneInitializeIsOneShotAndFrontRunnable() public {
        MultiMethodAuthorizer clone = MultiMethodAuthorizer(address(auth).clone());
        assertEq(clone.owner(), address(0));

        vm.prank(stranger);
        clone.initialize(stranger);
        assertEq(clone.owner(), stranger);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(address(this));
    }

    function test_cloneInitializeRejectsZeroOwner() public {
        MultiMethodAuthorizer clone = MultiMethodAuthorizer(address(auth).clone());
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        clone.initialize(address(0));
    }

    function test_transferOwnershipRejectsZero() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        auth.transferOwnership(address(0));
        assertEq(auth.owner(), address(this));
    }

    function test_renounceOwnershipDisabled() public {
        vm.expectRevert(MultiMethodAuthorizer.RenounceDisabled.selector);
        auth.renounceOwnership();
        assertEq(auth.owner(), address(this));
    }

    function test_transferOwnershipMovesAdmin() public {
        auth.transferOwnership(stranger);
        assertEq(auth.owner(), stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        _addMachine(1, _ops(ADD_PIECES));
        vm.prank(stranger);
        _addMachine(1, _ops(ADD_PIECES));
    }

    function test_addCredentialOverwriteReplacesOps() public {
        bytes32 credId = _addMachine(7, _ops2(ADD_PIECES, TERMINATE));
        _addMachine(7, _ops(ADD_PIECES));
        assertTrue(auth.allowedOp(credId, ADD_PIECES));
        assertFalse(auth.allowedOp(credId, TERMINATE));
        assertFalse(_check(7, TERMINATE, _machineBlob(DIGEST)));
        bytes32[] memory ops = auth.credentialOps(credId);
        assertEq(ops.length, 1);
        assertEq(ops[0], ADD_PIECES);
    }

    function test_removeCredentialWipesAllOpsSoReaddDoesNotResurrect() public {
        bytes32 credId = _addMachine(7, _ops2(ADD_PIECES, TERMINATE));
        auth.removeCredential(credId);
        assertFalse(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
        assertFalse(_check(7, TERMINATE, _machineBlob(DIGEST)));

        _addMachine(7, _ops(TERMINATE));
        assertTrue(_check(7, TERMINATE, _machineBlob(DIGEST)));
        assertFalse(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
        assertEq(auth.credentialOps(credId).length, 1);
    }

    function test_setOperationAllowedFineTunesThenRemoveWipesThoseToo() public {
        bytes32 credId = _addMachine(7, _ops(ADD_PIECES));
        auth.setOperationAllowed(credId, TERMINATE, true);
        assertTrue(_check(7, TERMINATE, _machineBlob(DIGEST)));
        assertEq(auth.credentialOps(credId).length, 2);

        auth.setOperationAllowed(credId, ADD_PIECES, false);
        assertFalse(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
        assertTrue(_check(7, TERMINATE, _machineBlob(DIGEST)));
        assertEq(auth.credentialOps(credId).length, 1);
        assertEq(auth.credentialOps(credId)[0], TERMINATE);

        auth.removeCredential(credId);
        _addMachine(7, _ops(ADD_PIECES));
        assertTrue(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
        assertFalse(_check(7, TERMINATE, _machineBlob(DIGEST)));
    }

    function test_setOperationAllowedOnUnknownCredentialReverts() public {
        bytes32 missing = auth.credentialId(MultiMethodAuthorizer.Method.MachineP256, px, py, 7);
        vm.expectRevert(abi.encodeWithSelector(MultiMethodAuthorizer.UnknownCredential.selector, missing));
        auth.setOperationAllowed(missing, ADD_PIECES, true);
    }

    // ───────────────────────────── dataset isolation + wildcard ─────────────────────────────

    function test_specificCredentialDoesNotAuthorizeOtherDataSet() public {
        _addMachine(7, _ops(ADD_PIECES));
        assertTrue(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
        assertFalse(_check(8, ADD_PIECES, _machineBlob(DIGEST)));
    }

    function test_wildcardCredentialAuthorizesEveryDataSet() public {
        _addMachine(auth.WILDCARD_DATASET(), _ops(ADD_PIECES));
        assertTrue(_check(1, ADD_PIECES, _machineBlob(DIGEST)));
        assertTrue(_check(99, ADD_PIECES, _machineBlob(DIGEST)));
    }

    function test_specificAndWildcardAreUnion() public {
        _addMachine(7, _ops(TERMINATE));
        _addMachine(auth.WILDCARD_DATASET(), _ops(ADD_PIECES));
        assertTrue(_check(7, TERMINATE, _machineBlob(DIGEST)));
        assertTrue(_check(7, ADD_PIECES, _machineBlob(DIGEST)), "wildcard AddPieces still applies on ds 7");
        assertTrue(_check(8, ADD_PIECES, _machineBlob(DIGEST)));
        assertFalse(_check(8, TERMINATE, _machineBlob(DIGEST)));
    }

    function test_specificMatchPreferredInAuthorizedEvent() public {
        bytes32 specific = _addMachine(7, _ops(ADD_PIECES));
        _addMachine(auth.WILDCARD_DATASET(), _ops(ADD_PIECES));

        vm.expectEmit(true, true, false, true, address(auth));
        emit MultiMethodAuthorizer.Authorized(specific, ADD_PIECES, MultiMethodAuthorizer.Method.MachineP256);
        assertTrue(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
    }

    function test_wrongOperationReturnsFalse() public {
        _addMachine(7, _ops(ADD_PIECES));
        assertFalse(_check(7, TERMINATE, _machineBlob(DIGEST)));
        assertFalse(_check(7, SCHEDULE_REMOVALS, _machineBlob(DIGEST)));
    }

    function test_payerIsIgnored() public {
        _addMachine(7, _ops(ADD_PIECES));
        bytes memory blob = _machineBlob(DIGEST);
        assertTrue(auth.isAuthorized(7, address(0), ADD_PIECES, DIGEST, blob, ""));
        assertTrue(auth.isAuthorized(7, stranger, ADD_PIECES, DIGEST, blob, ""));
    }

    function test_machineAndPasskeyCredIdsAreDistinct() public {
        _addMachine(7, _ops(ADD_PIECES));
        assertFalse(_check(7, ADD_PIECES, _goodPasskey(DIGEST, bytes32(0))));
        _addPasskey(7, bytes32(0), _ops(ADD_PIECES));
        assertTrue(_check(7, ADD_PIECES, _goodPasskey(DIGEST, bytes32(0))));
    }

    // ───────────────────────────── machine path ─────────────────────────────

    function test_machineHappyPath() public {
        bytes32 credId = _addMachine(7, _ops(ADD_PIECES));
        vm.expectEmit(true, true, false, true, address(auth));
        emit MultiMethodAuthorizer.Authorized(credId, ADD_PIECES, MultiMethodAuthorizer.Method.MachineP256);
        assertTrue(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
    }

    function test_machineBadSignatureReturnsFalse() public {
        _addMachine(7, _ops(ADD_PIECES));
        (bytes32 r, bytes32 s) = _sign(DIGEST);
        s = bytes32(uint256(s) ^ 1);
        bytes memory blob = abi.encode(uint8(0), abi.encode(px, py, r, s));
        assertFalse(_check(7, ADD_PIECES, blob));
    }

    function test_machineHighSReturnsFalse() public {
        _addMachine(7, _ops(ADD_PIECES));
        (bytes32 r, bytes32 s) = vm.signP256(PRIV, DIGEST);
        s = _lowS(s);
        bytes32 highS = bytes32(P256.N - uint256(s));
        bytes memory blob = abi.encode(uint8(0), abi.encode(px, py, r, highS));
        assertFalse(_check(7, ADD_PIECES, blob));
    }

    function test_machineUnregisteredKeyReturnsFalse() public {
        (bytes32 r, bytes32 s) = _sign(DIGEST);
        bytes memory blob = abi.encode(uint8(0), abi.encode(px, py, r, s));
        assertFalse(_check(7, ADD_PIECES, blob));
    }

    function test_disabledCredentialReturnsFalse() public {
        bytes32 credId = _addMachine(7, _ops(ADD_PIECES));
        auth.setCredentialEnabled(credId, false);
        assertFalse(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
        auth.setCredentialEnabled(credId, true);
        assertTrue(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
    }

    function test_expiryInclusiveThenRejects() public {
        uint64 now_ = uint64(block.timestamp);
        auth.addCredential(MultiMethodAuthorizer.Method.MachineP256, px, py, 7, bytes32(0), now_, _ops(ADD_PIECES));
        assertTrue(_check(7, ADD_PIECES, _machineBlob(DIGEST)), "expiry == block.timestamp is still valid");
        vm.warp(uint256(now_) + 1);
        assertFalse(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
    }

    function test_zeroExpiryNeverExpires() public {
        _addMachine(7, _ops(ADD_PIECES));
        vm.warp(block.timestamp + 365 days);
        assertTrue(_check(7, ADD_PIECES, _machineBlob(DIGEST)));
    }

    function test_unknownMethodReverts() public {
        _addMachine(7, _ops(ADD_PIECES));
        bytes memory blob = abi.encode(uint8(2), abi.encode(px, py, bytes32(0), bytes32(0)));
        vm.expectRevert(abi.encodeWithSelector(MultiMethodAuthorizer.UnknownMethod.selector, uint8(2)));
        _check(7, ADD_PIECES, blob);
    }

    function test_malformedEnvelopeReverts() public {
        vm.expectRevert();
        _check(7, ADD_PIECES, hex"deadbeef");
    }

    // ───────────────────────────── passkey path ─────────────────────────────

    function test_passkeyHappyPath() public {
        bytes32 credId = _addPasskey(7, bytes32(0), _ops(ADD_PIECES));
        vm.expectEmit(true, true, false, true, address(auth));
        emit MultiMethodAuthorizer.Authorized(credId, ADD_PIECES, MultiMethodAuthorizer.Method.Passkey);
        assertTrue(_check(7, ADD_PIECES, _goodPasskey(DIGEST, RP_ID)));
    }

    function test_passkeyRequiresUserPresentAndVerified() public {
        _addPasskey(7, bytes32(0), _ops(ADD_PIECES));
        string memory cd = _clientData(DIGEST, true);

        assertFalse(_check(7, ADD_PIECES, _passkeyBlob(_authData(RP_ID, 0x01), cd))); // UP only
        assertFalse(_check(7, ADD_PIECES, _passkeyBlob(_authData(RP_ID, 0x04), cd))); // UV only
        assertTrue(_check(7, ADD_PIECES, _passkeyBlob(_authData(RP_ID, 0x05), cd))); // both
        assertTrue(_check(7, ADD_PIECES, _passkeyBlob(_authData(RP_ID, 0x07), cd))); // AT extra bit ok
    }

    function test_passkeyAuthDataTooShortReturnsFalse() public {
        _addPasskey(7, bytes32(0), _ops(ADD_PIECES));
        bytes memory ad = new bytes(36);
        assertFalse(_check(7, ADD_PIECES, _passkeyBlob(ad, _clientData(DIGEST, true))));
    }

    function test_passkeyRpIdHashPin() public {
        _addPasskey(7, RP_ID, _ops(ADD_PIECES));
        assertTrue(_check(7, ADD_PIECES, _goodPasskey(DIGEST, RP_ID)));
        assertFalse(_check(7, ADD_PIECES, _goodPasskey(DIGEST, keccak256("other.example"))));
    }

    function test_passkeyZeroRpIdHashAcceptsAnyOrigin() public {
        _addPasskey(7, bytes32(0), _ops(ADD_PIECES));
        assertTrue(_check(7, ADD_PIECES, _goodPasskey(DIGEST, keccak256("any.origin"))));
    }

    function test_passkeySpacedJsonReturnsFalse() public {
        _addPasskey(7, bytes32(0), _ops(ADD_PIECES));
        bytes memory ad = _authData(RP_ID, 0x05);
        assertFalse(_check(7, ADD_PIECES, _passkeyBlob(ad, _clientData(DIGEST, false))));
    }

    function test_passkeyWrongChallengeReturnsFalse() public {
        _addPasskey(7, bytes32(0), _ops(ADD_PIECES));
        bytes memory ad = _authData(RP_ID, 0x05);
        string memory cd = _clientData(bytes32(uint256(0x2222)), true);
        assertFalse(_checkDigest(7, ADD_PIECES, DIGEST, _passkeyBlob(ad, cd)));
    }

    function test_passkeyWrongTypeReturnsFalse() public {
        _addPasskey(7, bytes32(0), _ops(ADD_PIECES));
        bytes memory ad = _authData(RP_ID, 0x05);
        string memory ch = auth.encodeChallenge(DIGEST);
        string memory cd = string.concat('{"type":"webauthn.create","challenge":"', ch, '"}');
        assertFalse(_check(7, ADD_PIECES, _passkeyBlob(ad, cd)));
    }

    function test_passkeyWildcardUsesWildcardRpIdHash() public {
        _addPasskey(7, keccak256("specific.example"), _ops(TERMINATE));
        _addPasskey(auth.WILDCARD_DATASET(), RP_ID, _ops(ADD_PIECES));
        // AddPieces falls through to wildcard, so rpIdHash must match the wildcard pin.
        assertTrue(_check(7, ADD_PIECES, _goodPasskey(DIGEST, RP_ID)));
        assertFalse(_check(7, ADD_PIECES, _goodPasskey(DIGEST, keccak256("specific.example"))));
    }
}
