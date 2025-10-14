// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Cids} from "@pdp/Cids.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {Errors} from "../Errors.sol";

/// @title SignatureVerificationLib
/// @notice Library for EIP-712 signature verification and metadata hashing
/// @dev This is an external library (deployed separately) to reduce main contract size.
///      Functions are marked public/external so they use DELEGATECALL rather than being inlined.
library SignatureVerificationLib {
    // ============================================================================
    // EIP-712 Type hashes
    // ============================================================================

    bytes32 private constant METADATA_ENTRY_TYPEHASH = keccak256("MetadataEntry(string key,string value)");

    bytes32 private constant CREATE_DATA_SET_TYPEHASH = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)MetadataEntry(string key,string value)"
    );

    bytes32 private constant CID_TYPEHASH = keccak256("Cid(bytes data)");

    bytes32 private constant PIECE_METADATA_TYPEHASH =
        keccak256("PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)MetadataEntry(string key,string value)");

    bytes32 private constant ADD_PIECES_TYPEHASH = keccak256(
        "AddPieces(uint256 clientDataSetId,uint256 firstAdded,Cid[] pieceData,PieceMetadata[] pieceMetadata)"
        "Cid(bytes data)" "MetadataEntry(string key,string value)"
        "PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)"
    );

    bytes32 internal constant SCHEDULE_PIECE_REMOVALS_TYPEHASH =
        keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)");

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
        return
            keccak256(abi.encode(CREATE_DATA_SET_TYPEHASH, clientDataSetId, payee, hashMetadataEntries(keys, values)));
    }

    function hashAllCids(Cids.Cid[] calldata pieceDataArray) internal pure returns (bytes32 cidHashesHash) {
        bytes32[] memory cidHashes = new bytes32[](pieceDataArray.length);
        for (uint256 i = 0; i < pieceDataArray.length; i++) {
            cidHashes[i] = keccak256(abi.encode(keccak256("Cid(bytes data)"), keccak256(pieceDataArray[i].data)));
        }
        return keccak256(abi.encodePacked(cidHashes));
    }

    function addPiecesStructHash(
        uint256 clientDataSetId,
        uint256 firstAdded,
        Cids.Cid[] calldata pieceDataArray,
        string[][] calldata allKeys,
        string[][] calldata allValues
    ) public pure returns (bytes32 structHash) {
        return keccak256(
            abi.encode(
                ADD_PIECES_TYPEHASH,
                clientDataSetId,
                firstAdded,
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

    /**
     * @notice Verifies a signature for the AddPieces operation
     * @dev The digest parameter already contains the EIP-712 wrapped struct hash computed by the caller
     * @param payer The address of the payer who should have signed the message
     * @param signature The signature bytes (v, r, s)
     * @param digest The EIP-712 digest to verify
     * @param sessionKeyRegistry The session key registry contract
     */
    function verifyAddPiecesSignature(
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
            sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, ADD_PIECES_TYPEHASH) >= block.timestamp,
            Errors.InvalidSignature(payer, recoveredSigner)
        );
    }

    /**
     * @notice Verifies a signature for the SchedulePieceRemovals operation
     * @dev The digest parameter already contains the EIP-712 wrapped struct hash computed by the caller
     * @param payer The address of the payer who should have signed the message
     * @param signature The signature bytes (v, r, s)
     * @param digest The EIP-712 digest to verify
     * @param sessionKeyRegistry The session key registry contract
     */
    function verifySchedulePieceRemovalsSignature(
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
            sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, SCHEDULE_PIECE_REMOVALS_TYPEHASH)
                >= block.timestamp,
            Errors.InvalidSignature(payer, recoveredSigner)
        );
    }
}
