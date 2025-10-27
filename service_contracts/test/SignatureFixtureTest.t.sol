// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * USAGE INSTRUCTIONS:
 *
 * 1. Generate new signature fixtures:
 *    forge test --match-test testGenerateFixtures -vv
 *
 * 2. Copy the JavaScript output from console to update synapse-sdk tests
 *    Look for the "Copy to synapse-sdk tests:" section in the output
 *
 * 3. Update external_signatures.json:
 *    - Run: forge test --match-test testGenerateFixtures -vv
 *    - Look for "JSON format for external_signatures.json:" section in output
 *    - Copy the complete JSON output to replace test/external_signatures.json
 *
 * 4. Verify external signatures work:
 *    forge test --match-test testExternalSignatures -vv
 *
 * 5. View EIP-712 type structures:
 *    forge test --match-test testEIP712TypeStructures -vv
 *
 * NOTE: This test generates deterministic signatures using a well-known test private key.
 * The signatures are compatible with FilecoinWarmStorageService but generated independently
 * to avoid heavy dependency compilation issues.
 */
import {Test, console} from "forge-std/Test.sol";
import {Cids} from "@pdp/Cids.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title EIP-712 Signature Fixture Generator
 * @dev Standalone contract for generating reference signatures
 *
 * This contract generates EIP-712 signatures that are compatible with FilecoinWarmStorageService
 * but doesn't import the full contract to avoid compilation stack depth issues in dependencies.
 */
contract MetadataSignatureTestContract is EIP712 {
    constructor() EIP712("FilecoinWarmStorageService", "1") {}

    // EIP-712 type hashes - must match FilecoinWarmStorageService exactly
    bytes32 private constant METADATA_ENTRY_TYPEHASH = keccak256("MetadataEntry(string key,string value)");

    bytes32 private constant CREATE_DATA_SET_TYPEHASH = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)MetadataEntry(string key,string value)"
    );

    bytes32 private constant CID_TYPEHASH = keccak256("Cid(bytes data)");

    bytes32 private constant PIECE_METADATA_TYPEHASH =
        keccak256("PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)MetadataEntry(string key,string value)");

    bytes32 private constant ADD_PIECES_TYPEHASH = keccak256(
        "AddPieces(uint256 clientDataSetId,uint256 nonce,Cid[] pieceData,PieceMetadata[] pieceMetadata)"
        "Cid(bytes data)" "MetadataEntry(string key,string value)"
        "PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)"
    );

    bytes32 private constant SCHEDULE_PIECE_REMOVALS_TYPEHASH =
        keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)");

    // Metadata hashing functions
    function hashMetadataEntry(string memory key, string memory value) internal pure returns (bytes32) {
        return keccak256(abi.encode(METADATA_ENTRY_TYPEHASH, keccak256(bytes(key)), keccak256(bytes(value))));
    }

    function hashMetadataEntries(string[] memory keys, string[] memory values) internal pure returns (bytes32) {
        if (keys.length == 0) return keccak256("");

        bytes32[] memory hashes = new bytes32[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            hashes[i] = hashMetadataEntry(keys[i], values[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function hashPieceMetadata(uint256 pieceIndex, string[] memory keys, string[] memory values)
        internal
        pure
        returns (bytes32)
    {
        bytes32 metadataHash = hashMetadataEntries(keys, values);
        return keccak256(abi.encode(PIECE_METADATA_TYPEHASH, pieceIndex, metadataHash));
    }

    function hashAllPieceMetadata(string[][] memory allKeys, string[][] memory allValues)
        internal
        pure
        returns (bytes32)
    {
        if (allKeys.length == 0) return keccak256("");

        bytes32[] memory pieceHashes = new bytes32[](allKeys.length);
        for (uint256 i = 0; i < allKeys.length; i++) {
            pieceHashes[i] = hashPieceMetadata(i, allKeys[i], allValues[i]);
        }
        return keccak256(abi.encodePacked(pieceHashes));
    }

    // Signature verification functions
    function verifyCreateDataSetSignature(
        address payer,
        uint256 clientDataSetId,
        address payee,
        string[] memory metadataKeys,
        string[] memory metadataValues,
        bytes memory signature
    ) public view returns (bool) {
        bytes32 metadataHash = hashMetadataEntries(metadataKeys, metadataValues);
        bytes32 structHash = keccak256(abi.encode(CREATE_DATA_SET_TYPEHASH, clientDataSetId, payee, metadataHash));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        return signer == payer;
    }

    function verifyAddPiecesSignature(
        address payer,
        uint256 clientDataSetId,
        Cids.Cid[] memory pieceCidsArray,
        uint256 nonce,
        string[][] memory metadataKeys,
        string[][] memory metadataValues,
        bytes memory signature
    ) public view returns (bool) {
        bytes32 digest = getAddPiecesDigest(clientDataSetId, nonce, pieceCidsArray, metadataKeys, metadataValues);
        address signer = ECDSA.recover(digest, signature);
        return signer == payer;
    }

    // Digest creation functions
    function getCreateDataSetDigest(
        uint256 clientDataSetId,
        address payee,
        string[] memory metadataKeys,
        string[] memory metadataValues
    ) public view returns (bytes32) {
        bytes32 metadataHash = hashMetadataEntries(metadataKeys, metadataValues);
        bytes32 structHash = keccak256(abi.encode(CREATE_DATA_SET_TYPEHASH, clientDataSetId, payee, metadataHash));
        return _hashTypedDataV4(structHash);
    }

    function getAddPiecesDigest(
        uint256 clientDataSetId,
        uint256 nonce,
        Cids.Cid[] memory pieceCidsArray,
        string[][] memory metadataKeys,
        string[][] memory metadataValues
    ) public view returns (bytes32) {
        // Hash each PieceCid struct
        bytes32[] memory pieceCidsHashes = new bytes32[](pieceCidsArray.length);
        for (uint256 i = 0; i < pieceCidsArray.length; i++) {
            pieceCidsHashes[i] = keccak256(abi.encode(CID_TYPEHASH, keccak256(pieceCidsArray[i].data)));
        }

        bytes32 pieceMetadataHash = hashAllPieceMetadata(metadataKeys, metadataValues);
        bytes32 structHash = keccak256(
            abi.encode(
                ADD_PIECES_TYPEHASH,
                clientDataSetId,
                nonce,
                keccak256(abi.encodePacked(pieceCidsHashes)),
                pieceMetadataHash
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getSchedulePieceRemovalsDigest(uint256 clientDataSetId, uint256[] memory pieceIds)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(SCHEDULE_PIECE_REMOVALS_TYPEHASH, clientDataSetId, keccak256(abi.encodePacked(pieceIds)))
        );
        return _hashTypedDataV4(structHash);
    }

    function getDomainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }
}

contract MetadataSignatureFixturesTest is Test {
    MetadataSignatureTestContract public testContract;

    // Test private key (well-known test key, never use in production)
    uint256 constant TEST_PRIVATE_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    address constant TEST_SIGNER = 0x2e988A386a799F506693793c6A5AF6B54dfAaBfB;

    // Test data
    uint256 constant CLIENT_DATA_SET_ID = 12345;
    address constant PAYEE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant FIRST_ADDED = 1;

    function setUp() public {
        testContract = new MetadataSignatureTestContract();
    }

    function testGenerateFixtures() public view {
        console.log("=== EIP-712 SIGNATURE FIXTURES ===");
        console.log("Contract Address:", address(testContract));
        console.log("Test Signer:", TEST_SIGNER);
        console.log("Chain ID:", block.chainid);
        console.log("Domain Separator:", vm.toString(testContract.getDomainSeparator()));
        console.log("");

        // Create test metadata
        (string[] memory dataSetKeys, string[] memory dataSetValues) = createTestDataSetMetadata();
        (string[][] memory pieceKeys, string[][] memory pieceValues) = createTestPieceMetadata();

        // Generate all signatures
        bytes memory createDataSetSig = generateCreateDataSetSignature(dataSetKeys, dataSetValues);
        bytes memory addPiecesSig = generateAddPiecesSignature(pieceKeys, pieceValues);

        // Generate additional signatures for JSON compatibility
        uint256[] memory testPieceIds = new uint256[](3);
        testPieceIds[0] = 1;
        testPieceIds[1] = 3;
        testPieceIds[2] = 5;
        bytes memory scheduleRemovalsSig = generateSchedulePieceRemovalsSignature(testPieceIds);

        // Get all digests
        bytes32 createDataSetDigest =
            testContract.getCreateDataSetDigest(CLIENT_DATA_SET_ID, PAYEE, dataSetKeys, dataSetValues);
        Cids.Cid[] memory pieceCidsArray = createTestPieceCids();
        bytes32 addPiecesDigest =
            testContract.getAddPiecesDigest(CLIENT_DATA_SET_ID, FIRST_ADDED, pieceCidsArray, pieceKeys, pieceValues);
        bytes32 scheduleRemovalsDigest = testContract.getSchedulePieceRemovalsDigest(CLIENT_DATA_SET_ID, testPieceIds);

        // Output JavaScript format for copying to synapse-sdk tests
        console.log("Copy this JavaScript const to synapse-sdk src/test/pdp-auth.test.ts:");
        console.log("const FIXTURES = {");
        console.log("  // Test private key from Solidity (never use in production!)");
        console.log("  privateKey: '%x',", TEST_PRIVATE_KEY);
        console.log("  signerAddress: '%s',", TEST_SIGNER);
        console.log("  contractAddress: '%s',", address(testContract));
        console.log("  chainId: %d,", block.chainid);
        console.log("  domainSeparator: '%s',", vm.toString(testContract.getDomainSeparator()));
        console.log("");
        console.log("  // EIP-712 domain separator components");
        console.log("  domain: {");
        console.log("    name: 'FilecoinWarmStorageService',");
        console.log("    version: '1',");
        console.log("    chainId: %d,", block.chainid);
        console.log("    verifyingContract: '%s'", address(testContract));
        console.log("  },");
        console.log("");
        console.log("  // Expected EIP-712 signatures");
        console.log("  signatures: {");
        console.log("    createDataSet: {");
        console.log("      signature: '%s',", vm.toString(createDataSetSig));
        console.log("      digest: '%s',", vm.toString(createDataSetDigest));
        console.log("      clientDataSetId: %d,", CLIENT_DATA_SET_ID);
        console.log("      payee: '%s',", PAYEE);
        console.log("      metadata: [{ key: '%s', value: '%s' }]", dataSetKeys[0], dataSetValues[0]);
        console.log("    },");
        console.log("    addPieces: {");
        console.log("      signature: '%s',", vm.toString(addPiecesSig));
        console.log("      digest: '%s',", vm.toString(addPiecesDigest));
        console.log("      clientDataSetId: %d,", CLIENT_DATA_SET_ID);
        console.log("      nonce: %d,", FIRST_ADDED);
        console.log(
            "      pieceCidBytes: ['%s', '%s'],",
            vm.toString(pieceCidsArray[0].data),
            vm.toString(pieceCidsArray[1].data)
        );
        console.log("      metadata: [[], []]");
        console.log("    },");
        console.log("    schedulePieceRemovals: {");
        console.log("      signature: '%s',", vm.toString(scheduleRemovalsSig));
        console.log("      digest: '%s',", vm.toString(scheduleRemovalsDigest));
        console.log("      clientDataSetId: %d,", CLIENT_DATA_SET_ID);
        console.log("      pieceIds: [%d, %d, %d]", testPieceIds[0], testPieceIds[1], testPieceIds[2]);
        console.log("    }");
        console.log("  }");
        console.log("}");
        console.log("");

        // Output JSON format for easy copy to external_signatures.json
        console.log("JSON format for external_signatures.json:");
        console.log("{");
        console.log("  \"signer\": \"%s\",", TEST_SIGNER);
        console.log("  \"createDataSet\": {");
        console.log("    \"signature\": \"%s\",", vm.toString(createDataSetSig));
        console.log("    \"clientDataSetId\": %d,", CLIENT_DATA_SET_ID);
        console.log("    \"payee\": \"%s\",", PAYEE);
        console.log("    \"metadata\": [");
        console.log("      {");
        console.log("        \"key\": \"%s\",", dataSetKeys[0]);
        console.log("        \"value\": \"%s\"", dataSetValues[0]);
        console.log("      }");
        console.log("    ]");
        console.log("  },");
        console.log("  \"addPieces\": {");
        console.log("    \"signature\": \"%s\",", vm.toString(addPiecesSig));
        console.log("    \"clientDataSetId\": %d,", CLIENT_DATA_SET_ID);
        console.log("    \"nonce\": %d,", FIRST_ADDED);
        console.log("    \"pieceCidBytes\": [");
        console.log("      \"%s\",", vm.toString(pieceCidsArray[0].data));
        console.log("      \"%s\"", vm.toString(pieceCidsArray[1].data));
        console.log("    ],");
        console.log("    \"metadata\": [");
        console.log("      [],");
        console.log("      []");
        console.log("    ]");
        console.log("  },");
        console.log("  \"schedulePieceRemovals\": {");
        console.log("    \"signature\": \"%s\",", vm.toString(scheduleRemovalsSig));
        console.log("    \"clientDataSetId\": %d,", CLIENT_DATA_SET_ID);
        console.log("    \"pieceIds\": [");
        console.log("      %d,", testPieceIds[0]);
        console.log("      %d,", testPieceIds[1]);
        console.log("      %d", testPieceIds[2]);
        console.log("    ]");
        console.log("  }");
        console.log("}");

        // Verify signatures work
        assertTrue(
            testContract.verifyCreateDataSetSignature(
                TEST_SIGNER, CLIENT_DATA_SET_ID, PAYEE, dataSetKeys, dataSetValues, createDataSetSig
            ),
            "CreateDataSet signature verification failed"
        );

        assertTrue(
            testContract.verifyAddPiecesSignature(
                TEST_SIGNER, CLIENT_DATA_SET_ID, pieceCidsArray, FIRST_ADDED, pieceKeys, pieceValues, addPiecesSig
            ),
            "AddPieces signature verification failed"
        );

        console.log("All signature verifications passed!");
    }

    /**
     * @dev Test external signatures against contract verification
     */
    function testExternalSignatures() public view {
        string memory json = vm.readFile("./test/external_signatures.json");
        address signer = vm.parseJsonAddress(json, ".signer");

        console.log("Testing external signatures for signer:", signer);

        // Test CreateDataSet signature
        testCreateDataSetSignature(json, signer);

        // Test AddPieces signature
        testAddPiecesSignature(json, signer);

        console.log("All external signature tests PASSED!");
    }

    /**
     * @dev Show EIP-712 type structures for external developers
     */
    function testEIP712TypeStructures() public view {
        console.log("=== EIP-712 TYPE STRUCTURES ===");
        console.log("");
        console.log("Domain:");
        console.log("  name: 'FilecoinWarmStorageService'");
        console.log("  version: '1'");
        console.log("  chainId: %d", block.chainid);
        console.log("  verifyingContract: %s", address(testContract));
        console.log("");
        console.log("Types:");
        console.log("  MetadataEntry: [");
        console.log("    { name: 'key', type: 'string' },");
        console.log("    { name: 'value', type: 'string' }");
        console.log("  ],");
        console.log("  CreateDataSet: [");
        console.log("    { name: 'clientDataSetId', type: 'uint256' },");
        console.log("    { name: 'payee', type: 'address' },");
        console.log("    { name: 'metadata', type: 'MetadataEntry[]' }");
        console.log("  ],");
        console.log("  Cid: [");
        console.log("    { name: 'data', type: 'bytes' }");
        console.log("  ],");
        console.log("  PieceMetadata: [");
        console.log("    { name: 'pieceIndex', type: 'uint256' },");
        console.log("    { name: 'metadata', type: 'MetadataEntry[]' }");
        console.log("  ],");
        console.log("  AddPieces: [");
        console.log("    { name: 'clientDataSetId', type: 'uint256' },");
        console.log("    { name: 'nonce', type: 'uint256' },");
        console.log("    { name: 'pieceData', type: 'Cid[]' },");
        console.log("    { name: 'pieceMetadata', type: 'PieceMetadata[]' }");
        console.log("  ],");
        console.log("  SchedulePieceRemovals: [");
        console.log("    { name: 'clientDataSetId', type: 'uint256' },");
        console.log("    { name: 'pieceIds', type: 'uint256[]' }");
        console.log("  ]");
    }

    // Helper functions
    function createTestDataSetMetadata() internal pure returns (string[] memory keys, string[] memory values) {
        keys = new string[](1);
        values = new string[](1);
        keys[0] = "title";
        values[0] = "TestDataSet";
    }

    function createTestPieceMetadata() internal pure returns (string[][] memory keys, string[][] memory values) {
        keys = new string[][](2);
        values = new string[][](2);

        // Empty metadata for both pieces to keep it simple
        keys[0] = new string[](0);
        values[0] = new string[](0);
        keys[1] = new string[](0);
        values[1] = new string[](0);
    }

    function createTestPieceCids() internal pure returns (Cids.Cid[] memory) {
        Cids.Cid[] memory pieceCidsArray = new Cids.Cid[](2);

        pieceCidsArray[0] = Cids.Cid({
            data: abi.encodePacked(hex"01559120220500de6815dcb348843215a94de532954b60be550a4bec6e74555665e9a5ec4e0f3c")
        });
        pieceCidsArray[1] = Cids.Cid({
            data: abi.encodePacked(hex"01559120227e03642a607ef886b004bf2c1978463ae1d4693ac0f410eb2d1b7a47fe205e5e750f")
        });
        return pieceCidsArray;
    }

    function generateCreateDataSetSignature(string[] memory keys, string[] memory values)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = testContract.getCreateDataSetDigest(CLIENT_DATA_SET_ID, PAYEE, keys, values);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function generateAddPiecesSignature(string[][] memory keys, string[][] memory values)
        internal
        view
        returns (bytes memory)
    {
        Cids.Cid[] memory pieceCidsArray = createTestPieceCids();
        bytes32 digest = testContract.getAddPiecesDigest(CLIENT_DATA_SET_ID, FIRST_ADDED, pieceCidsArray, keys, values);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function generateSchedulePieceRemovalsSignature(uint256[] memory pieceIds) internal view returns (bytes memory) {
        bytes32 digest = testContract.getSchedulePieceRemovalsDigest(CLIENT_DATA_SET_ID, pieceIds);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    // External signature validation functions
    function testCreateDataSetSignature(string memory json, address signer) internal view {
        string memory signature = vm.parseJsonString(json, ".createDataSet.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".createDataSet.clientDataSetId");
        address payee = vm.parseJsonAddress(json, ".createDataSet.payee");

        // Parse metadata from JSON - simplified for single entry
        string[] memory keys = new string[](1);
        string[] memory values = new string[](1);
        keys[0] = vm.parseJsonString(json, ".createDataSet.metadata[0].key");
        values[0] = vm.parseJsonString(json, ".createDataSet.metadata[0].value");

        bool isValid = testContract.verifyCreateDataSetSignature(
            signer, clientDataSetId, payee, keys, values, vm.parseBytes(signature)
        );

        assertTrue(isValid, "CreateDataSet signature verification failed");
        console.log("  CreateDataSet: PASSED");
    }

    function testAddPiecesSignature(string memory json, address signer) internal view {
        string memory signature = vm.parseJsonString(json, ".addPieces.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".addPieces.clientDataSetId");
        uint256 nonce = vm.parseJsonUint(json, ".addPieces.nonce");

        // Parse piece data arrays
        bytes[] memory pieceCidBytes = vm.parseJsonBytesArray(json, ".addPieces.pieceCidBytes");

        // Create Cids array
        Cids.Cid[] memory pieceData = new Cids.Cid[](pieceCidBytes.length);
        for (uint256 i = 0; i < pieceCidBytes.length; i++) {
            pieceData[i] = Cids.Cid({data: pieceCidBytes[i]});
        }

        // For now, use empty metadata (as per the JSON)
        string[][] memory keys = new string[][](pieceData.length);
        string[][] memory values = new string[][](pieceData.length);
        for (uint256 i = 0; i < pieceData.length; i++) {
            keys[i] = new string[](0);
            values[i] = new string[](0);
        }

        bool isValid = testContract.verifyAddPiecesSignature(
            signer, clientDataSetId, pieceData, nonce, keys, values, vm.parseBytes(signature)
        );

        assertTrue(isValid, "AddPieces signature verification failed");
        console.log("  AddPieces: PASSED");
    }
}
