// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Cids} from "@pdp/Cids.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {Errors} from "../Errors.sol";
import {IDataSetAuthorizer} from "../interfaces/IDataSetAuthorizer.sol";

/// @title SignatureVerificationLib
/// @notice Library for EIP-712 signature verification and metadata hashing
/// @dev This is an external library (deployed separately) to reduce main contract size.
///      Functions are marked public/external so they use DELEGATECALL rather than being inlined.
library SignatureVerificationLib {
    // ============================================================================
    // EIP-712 Type hashes
    // ============================================================================

    bytes32 internal constant METADATA_ENTRY_TYPEHASH = keccak256("MetadataEntry(string key,string value)");

    bytes32 internal constant CREATE_DATA_SET_TYPEHASH = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)MetadataEntry(string key,string value)"
    );

    bytes32 internal constant CID_TYPEHASH = keccak256("Cid(bytes data)");

    bytes32 internal constant PIECE_METADATA_TYPEHASH =
        keccak256("PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)MetadataEntry(string key,string value)");

    bytes32 internal constant ADD_PIECES_TYPEHASH = keccak256(
        "AddPieces(uint256 clientDataSetId,uint256 nonce,Cid[] pieceData,PieceMetadata[] pieceMetadata)"
        "Cid(bytes data)" "MetadataEntry(string key,string value)"
        "PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)"
    );

    bytes32 internal constant SCHEDULE_PIECE_REMOVALS_TYPEHASH =
        keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)");

    bytes32 internal constant TERMINATE_SERVICE_TYPEHASH = keccak256("TerminateService(uint256 dataSetId)");

    // ============================================================================
    // Metadata Hashing Functions
    // ============================================================================

    /**
     * @notice Hashes a single metadata entry for EIP-712 signing
     * @param key The metadata key
     * @param value The metadata value
     * @return Hash of the metadata entry struct
     */
    function hashMetadataEntry(string calldata key, string calldata value) internal pure returns (bytes32) {
        return keccak256(abi.encode(METADATA_ENTRY_TYPEHASH, keccak256(bytes(key)), keccak256(bytes(value))));
    }

    /**
     * @notice Hashes an array of metadata entries
     * @param keys Array of metadata keys
     * @param values Array of metadata values
     * @return Hash of all metadata entries
     */
    function hashMetadataEntries(string[] calldata keys, string[] calldata values) internal pure returns (bytes32) {
        require(keys.length == values.length, Errors.MetadataKeyAndValueLengthMismatch(keys.length, values.length));

        bytes32[] memory entryHashes = new bytes32[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            entryHashes[i] = hashMetadataEntry(keys[i], values[i]);
        }
        return keccak256(abi.encodePacked(entryHashes));
    }

    function createDataSetStructHash(
        uint256 clientDataSetId,
        address payee,
        string[] calldata keys,
        string[] calldata values
    ) public pure returns (bytes32 structHash) {
        return keccak256(
            abi.encode(CREATE_DATA_SET_TYPEHASH, clientDataSetId, payee, hashMetadataEntries(keys, values))
        );
    }

    function hashAllCids(Cids.Cid[] calldata pieceDataArray) internal pure returns (bytes32 cidHashesHash) {
        bytes32[] memory cidHashes = new bytes32[](pieceDataArray.length);
        for (uint256 i = 0; i < pieceDataArray.length; i++) {
            cidHashes[i] = keccak256(abi.encode(CID_TYPEHASH, keccak256(pieceDataArray[i].data)));
        }
        return keccak256(abi.encodePacked(cidHashes));
    }

    function addPiecesStructHash(
        uint256 clientDataSetId,
        uint256 nonce,
        Cids.Cid[] calldata pieceDataArray,
        string[][] calldata allKeys,
        string[][] calldata allValues
    ) public pure returns (bytes32 structHash) {
        return keccak256(
            abi.encode(
                ADD_PIECES_TYPEHASH,
                clientDataSetId,
                nonce,
                hashAllCids(pieceDataArray),
                hashAllPieceMetadata(allKeys, allValues)
            )
        );
    }

    /**
     * @notice Hashes piece metadata for a specific piece index
     * @param pieceIndex The index of the piece
     * @param keys Array of metadata keys for this piece
     * @param values Array of metadata values for this piece
     * @return Hash of the piece metadata struct
     */
    function hashPieceMetadata(uint256 pieceIndex, string[] calldata keys, string[] calldata values)
        internal
        pure
        returns (bytes32)
    {
        bytes32 metadataHash = hashMetadataEntries(keys, values);
        return keccak256(abi.encode(PIECE_METADATA_TYPEHASH, pieceIndex, metadataHash));
    }

    /**
     * @notice Hashes all piece metadata for multiple pieces
     * @param allKeys 2D array where allKeys[i] contains keys for piece i
     * @param allValues 2D array where allValues[i] contains values for piece i
     * @return Hash of all piece metadata
     */
    function hashAllPieceMetadata(string[][] calldata allKeys, string[][] calldata allValues)
        public
        pure
        returns (bytes32)
    {
        require(allKeys.length == allValues.length, "Keys/values array length mismatch");

        bytes32[] memory pieceHashes = new bytes32[](allKeys.length);
        for (uint256 i = 0; i < allKeys.length; i++) {
            pieceHashes[i] = hashPieceMetadata(i, allKeys[i], allValues[i]);
        }
        return keccak256(abi.encodePacked(pieceHashes));
    }

    // ============================================================================
    // Signature Recovery
    // ============================================================================

    /**
     * @notice Recover the signer address from a signature
     * @param messageHash The signed message hash
     * @param signature The signature bytes (v, r, s)
     * @return The address that signed the message
     */
    function recoverSigner(bytes32 messageHash, bytes calldata signature) public pure returns (address) {
        require(signature.length == 65, Errors.InvalidSignatureLength(65, signature.length));

        bytes32 r;
        bytes32 s;
        uint8 v;

        // Extract r, s, v from the signature
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        uint8 originalV = v;

        // If v is not 27 or 28, adjust it (for some wallets)
        if (v < 27) {
            v += 27;
        }

        require(v == 27 || v == 28, Errors.UnsupportedSignatureV(originalV));

        // Recover and return the address
        return ecrecover(messageHash, v, r, s);
    }

    // ============================================================================
    // Signature Verification Functions
    // ============================================================================

    /**
     * @notice Verifies a signature for the CreateDataSet operation
     * @dev The digest parameter already contains the EIP-712 wrapped struct hash computed by the caller
     * @param payer The address of the payer who should have signed
     * @param signature The signature bytes
     * @param digest The EIP-712 digest to verify
     * @param sessionKeyRegistry The session key registry contract
     */
    function verifyCreateDataSetSignature(
        address payer,
        bytes calldata signature,
        bytes32 digest,
        SessionKeyRegistry sessionKeyRegistry
    ) public view {
        // The digest is already computed by the calling contract
        // Just use it directly for signature verification

        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);

        if (payer == recoveredSigner) {
            return;
        }
        require(
            sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, CREATE_DATA_SET_TYPEHASH) >= block.timestamp,
            Errors.InvalidSignature(payer, recoveredSigner)
        );
    }

    /// @notice Verifies and authorizes an AddPieces operation.
    function verifyAddPiecesAuthorization(
        address payer,
        uint256 dataSetId,
        address authorizer,
        uint256 clientDataSetId,
        Cids.Cid[] calldata pieceDataArray,
        uint256 nonce,
        string[][] calldata allKeys,
        string[][] calldata allValues,
        bytes calldata signature,
        bytes32 domainSeparator,
        SessionKeyRegistry sessionKeyRegistry
    ) public {
        bytes32 digest = _toTypedDataHash(
            domainSeparator, addPiecesStructHash(clientDataSetId, nonce, pieceDataArray, allKeys, allValues)
        );

        if (authorizer == address(0)) {
            _verifySignature(payer, signature, digest, ADD_PIECES_TYPEHASH, sessionKeyRegistry);
            return;
        }

        _verifyAuthorizer(
            payer,
            signature,
            digest,
            ADD_PIECES_TYPEHASH,
            dataSetId,
            authorizer,
            abi.encode(clientDataSetId, nonce, pieceDataArray, allKeys, allValues)
        );
    }

    /// @notice Verifies and authorizes a SchedulePieceRemovals operation.
    function verifySchedulePieceRemovalsAuthorization(
        address payer,
        uint256 dataSetId,
        address authorizer,
        uint256 clientDataSetId,
        uint256[] calldata pieceIds,
        bytes calldata signature,
        bytes32 domainSeparator,
        SessionKeyRegistry sessionKeyRegistry
    ) public {
        bytes32 digest = _toTypedDataHash(
            domainSeparator,
            keccak256(
                abi.encode(SCHEDULE_PIECE_REMOVALS_TYPEHASH, clientDataSetId, keccak256(abi.encodePacked(pieceIds)))
            )
        );

        if (authorizer == address(0)) {
            _verifySignature(payer, signature, digest, SCHEDULE_PIECE_REMOVALS_TYPEHASH, sessionKeyRegistry);
            return;
        }

        _verifyAuthorizer(
            payer,
            signature,
            digest,
            SCHEDULE_PIECE_REMOVALS_TYPEHASH,
            dataSetId,
            authorizer,
            abi.encode(clientDataSetId, pieceIds)
        );
    }

    /// @notice Verifies and authorizes a TerminateService operation.
    function verifyTerminateServiceAuthorization(
        address payer,
        uint256 dataSetId,
        address authorizer,
        bytes calldata signature,
        bytes32 domainSeparator,
        SessionKeyRegistry sessionKeyRegistry
    ) public returns (address) {
        bytes32 digest = _toTypedDataHash(domainSeparator, keccak256(abi.encode(TERMINATE_SERVICE_TYPEHASH, dataSetId)));

        if (authorizer == address(0)) {
            return _verifySignature(payer, signature, digest, TERMINATE_SERVICE_TYPEHASH, sessionKeyRegistry);
        }

        return _verifyAuthorizer(payer, signature, digest, TERMINATE_SERVICE_TYPEHASH, dataSetId, authorizer, bytes(""));
    }

    /// @notice Gas ceiling for the authorizer subcall.
    /// @dev Bounds what an untrusted authorizer can burn on the caller's behalf. EIP-150 forwards at
    ///      most 63/64 of the remaining gas, so this only binds when the caller supplies more.
    uint256 internal constant AUTHORIZER_GAS_LIMIT = 150_000_000;

    /// @dev Transient-storage slot for the authorizer reentrancy latch. This library is DELEGATECALL'd,
    ///      so the slot lives in the calling contract's (FWSS's) transient storage and the latch therefore
    ///      spans the whole FWSS call frame, not just this library invocation.
    bytes32 internal constant AUTHORIZER_REENTRANCY_SLOT =
        keccak256("filecoin-warm-storage-service.authorizer.reentrancy.guard");

    /// @dev Reentrancy latch for the authorizer subcall. `_lockAuthorizer` takes the latch before the body;
    ///      it clears after `_;` (a `return` in the body still runs post-`_;` code) and, on any revert, via
    ///      transient-storage rollback — so a second legitimate authorization in the same transaction is not
    ///      blocked. The pre-`_;` check-and-set is hoisted so the modifier body stays call-only
    ///      (forge-lint `unwrapped-modifier-logic`).
    modifier nonReentrantAuthorizer() {
        _lockAuthorizer();
        _;
        _setAuthorizerLock(false);
    }

    function _verifyAuthorizer(
        address payer,
        bytes calldata signature,
        bytes32 digest,
        bytes32 operation,
        uint256 dataSetId,
        address authorizer,
        bytes memory operationData
    ) private nonReentrantAuthorizer returns (address) {
        require(
            IDataSetAuthorizer(authorizer).isAuthorized{gas: AUTHORIZER_GAS_LIMIT}(
                dataSetId, payer, operation, digest, signature, operationData
            ),
            Errors.Unauthorized(payer, operation, digest, signature)
        );
        return payer;
    }

    function _verifySignature(
        address payer,
        bytes calldata signature,
        bytes32 digest,
        bytes32 operation,
        SessionKeyRegistry sessionKeyRegistry
    ) private view returns (address recoveredSigner) {
        recoveredSigner = recoverSigner(digest, signature);
        if (payer != recoveredSigner) {
            require(
                sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, operation) >= block.timestamp,
                Errors.InvalidSignature(payer, recoveredSigner)
            );
        }
    }

    function _toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _authorizerLocked() private view returns (bool locked) {
        bytes32 slot = AUTHORIZER_REENTRANCY_SLOT;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
    }

    function _setAuthorizerLock(bool value) private {
        bytes32 slot = AUTHORIZER_REENTRANCY_SLOT;
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /// @dev Pre-`_;` half of `nonReentrantAuthorizer`, split out to keep the modifier body call-only.
    function _lockAuthorizer() private {
        require(!_authorizerLocked(), Errors.AuthorizerReentrancy());
        _setAuthorizerLock(true);
    }
}
