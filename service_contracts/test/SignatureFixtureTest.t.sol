// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * USAGE INSTRUCTIONS:
 *
 * 1. Generate signature fixtures + JSON:
 *    forge test --match-test testGenerateFixtures -vv
 *
 * 2. Update synapse-sdk fixtures (typed-data.test.ts FIXTURES const):
 *    Copy the "Copy to typed-data.test.ts FIXTURES:" section verbatim.
 *
 * 3. Update external_signatures.json:
 *    Copy the "JSON format for external_signatures.json:" section verbatim.
 *
 * 4. Verify external signatures still verify against the contract:
 *    forge test --match-test testExternalSignatures -vv
 *
 * 5. View EIP-712 type structures:
 *    forge test --match-test testEIP712TypeStructures -vv
 *
 * NOTE: Fixtures use the **calibration** chain domain (chainId 314159, FWSS
 * address 0x02925630df557F957f70E112bA06e50965417CA0) so they match what the
 * SDK produces by default for that chain. Do not change without updating the
 * SDK fixtures in lockstep.
 */
import {Test, console} from "forge-std/Test.sol";
import {Cids} from "@pdp/Cids.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureVerificationLib} from "../src/lib/SignatureVerificationLib.sol";

/**
 * @title EIP-712 Signature Fixture Generator
 * @dev Standalone contract for generating reference signatures.
 *
 * Computes the EIP-712 domain separator manually from a constructor-supplied
 * (chainId, verifyingContract) pair so we can mirror an arbitrary deployed
 * domain (e.g. calibration FWSS) without redeploying at that address.
 *
 * Typehashes for operations the FWSS contract implements come from
 * SignatureVerificationLib so any rename in the library will surface here as
 * a fixture mismatch (caught by external_signatures.json + the SDK fixtures).
 * DELETE_DATA_SET_TYPEHASH is declared locally because the FWSS contract
 * doesn't currently implement DeleteDataSet (handler removed in #255); move
 * it into the library when the impl returns.
 */
contract MetadataSignatureTestContract {
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant DELETE_DATA_SET_TYPEHASH = keccak256("DeleteDataSet(uint256 dataSetId)");

    bytes32 private immutable _domainSeparator;

    constructor(uint256 chainId, address verifyingContract) {
        _domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("FilecoinWarmStorageService")),
                keccak256(bytes("1")),
                chainId,
                verifyingContract
            )
        );
    }

    function getDomainSeparator() public view returns (bytes32) {
        return _domainSeparator;
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator, structHash));
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
        bytes32 digest = getCreateDataSetDigest(clientDataSetId, payee, metadataKeys, metadataValues);
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

    function verifySchedulePieceRemovalsSignature(
        address payer,
        uint256 clientDataSetId,
        uint256[] memory pieceIds,
        bytes memory signature
    ) public view returns (bool) {
        bytes32 digest = getSchedulePieceRemovalsDigest(clientDataSetId, pieceIds);
        address signer = ECDSA.recover(digest, signature);
        return signer == payer;
    }

    function verifyDeleteDataSetSignature(address payer, uint256 dataSetId, bytes memory signature)
        public
        view
        returns (bool)
    {
        bytes32 digest = getDeleteDataSetDigest(dataSetId);
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
        return _hashTypedData(
            SignatureVerificationLib.createDataSetStructHash(clientDataSetId, payee, metadataKeys, metadataValues)
        );
    }

    function getAddPiecesDigest(
        uint256 clientDataSetId,
        uint256 nonce,
        Cids.Cid[] memory pieceCidsArray,
        string[][] memory metadataKeys,
        string[][] memory metadataValues
    ) public view returns (bytes32) {
        return _hashTypedData(
            SignatureVerificationLib.addPiecesStructHash(
                clientDataSetId, nonce, pieceCidsArray, metadataKeys, metadataValues
            )
        );
    }

    // SchedulePieceRemovals struct hash isn't exposed by the library (FWSS computes
    // it inline at the call site); re-derived here from the shared typehash.
    function getSchedulePieceRemovalsDigest(uint256 clientDataSetId, uint256[] memory pieceIds)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                SignatureVerificationLib.SCHEDULE_PIECE_REMOVALS_TYPEHASH,
                clientDataSetId,
                keccak256(abi.encodePacked(pieceIds))
            )
        );
        return _hashTypedData(structHash);
    }

    function getDeleteDataSetDigest(uint256 dataSetId) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(DELETE_DATA_SET_TYPEHASH, dataSetId));
        return _hashTypedData(structHash);
    }
}

contract MetadataSignatureFixturesTest is Test {
    MetadataSignatureTestContract public testContract;

    // Test private key (well-known test key, never use in production)
    uint256 constant TEST_PRIVATE_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    address constant TEST_SIGNER = 0x2e988A386a799F506693793c6A5AF6B54dfAaBfB;

    // Mirror the SDK's calibration chain configuration so SDK fixtures
    // (synapse-core/test/typed-data.test.ts) can be regenerated by copy-paste.
    uint256 constant DOMAIN_CHAIN_ID = 314_159;
    address constant DOMAIN_VERIFYING_CONTRACT = 0x02925630df557F957f70E112bA06e50965417CA0;

    // Test data
    // CLIENT_DATA_SET_ID is the per-client nonce signed for create/add/schedule
    // operations (assigned by the client, opaque to the contract). DATA_SET_ID
    // is the canonical PDPVerifier-assigned id signed for delete. Distinct
    // values keep the conceptual separation visible in the fixtures.
    uint256 constant CLIENT_DATA_SET_ID = 12345;
    uint256 constant DATA_SET_ID = 67890;
    address constant PAYEE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant FIRST_ADDED = 1;

    function setUp() public {
        testContract = new MetadataSignatureTestContract(DOMAIN_CHAIN_ID, DOMAIN_VERIFYING_CONTRACT);
    }

    function testGenerateFixtures() public view {
        // Create test inputs
        (string[] memory dataSetKeys, string[] memory dataSetValues) = createTestDataSetMetadata();
        (string[][] memory pieceKeys, string[][] memory pieceValues) = createTestPieceMetadata();
        Cids.Cid[] memory pieceCidsArray = createTestPieceCids();

        uint256[] memory testPieceIds = new uint256[](3);
        testPieceIds[0] = 1;
        testPieceIds[1] = 3;
        testPieceIds[2] = 5;

        // Generate raw signatures
        bytes memory createDataSetSig = generateCreateDataSetSignature(dataSetKeys, dataSetValues);
        bytes memory addPiecesSig = generateAddPiecesSignature(pieceKeys, pieceValues);
        bytes memory scheduleRemovalsSig = generateSchedulePieceRemovalsSignature(testPieceIds);
        bytes memory deleteDataSetSig = generateDeleteDataSetSignature(DATA_SET_ID);

        // Compute SDK-format extraData (abi-encoded, matching synapse-core sign-* helpers)
        bytes memory createDataSetExtraData =
            encodeCreateDataSetExtraData(TEST_SIGNER, CLIENT_DATA_SET_ID, dataSetKeys, dataSetValues, createDataSetSig);
        bytes memory addPiecesExtraData = encodeAddPiecesExtraData(FIRST_ADDED, pieceKeys, pieceValues, addPiecesSig);
        bytes memory scheduleRemovalsExtraData = encodeSignatureBytes(scheduleRemovalsSig);
        bytes memory deleteDataSetExtraData = encodeSignatureBytes(deleteDataSetSig);

        // Output FIXTURES const for synapse-sdk (typed-data.test.ts)
        console.log("Copy to typed-data.test.ts FIXTURES:");
        console.log("const FIXTURES = {");
        console.log("  // Test private key from Solidity (never use in production!)");
        console.log("  privateKey: '%x' as Hex,", TEST_PRIVATE_KEY);
        console.log("");
        console.log("  // Expected EIP-712 signatures");
        console.log("  signatures: {");
        console.log("    createDataSet: {");
        console.log("      extraData:");
        console.log("        '%s' as Hex,", vm.toString(createDataSetExtraData));
        console.log("      clientDataSetId: %dn,", CLIENT_DATA_SET_ID);
        console.log("      payee: '%s' as Address,", PAYEE);
        console.log("      metadata: [{ key: '%s', value: '%s' }],", dataSetKeys[0], dataSetValues[0]);
        console.log("    },");
        console.log("    addPieces: {");
        console.log("      extraData:");
        console.log("        '%s' as Hex,", vm.toString(addPiecesExtraData));
        console.log("      clientDataSetId: %dn,", CLIENT_DATA_SET_ID);
        console.log("      nonce: %dn,", FIRST_ADDED);
        console.log("    },");
        console.log("    schedulePieceRemovals: {");
        console.log("      extraData:");
        console.log("        '%s' as Hex,", vm.toString(scheduleRemovalsExtraData));
        console.log("      clientDataSetId: %dn,", CLIENT_DATA_SET_ID);
        console.log("      pieceIds: [%dn, %dn, %dn],", testPieceIds[0], testPieceIds[1], testPieceIds[2]);
        console.log("    },");
        console.log("    deleteDataSet: {");
        console.log("      extraData:");
        console.log("        '%s' as Hex,", vm.toString(deleteDataSetExtraData));
        console.log("      dataSetId: %dn,", DATA_SET_ID);
        console.log("    },");
        console.log("  },");
        console.log("}");
        console.log("");

        // Output JSON for external_signatures.json (raw signatures, used by testExternalSignatures)
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
        console.log("  },");
        console.log("  \"deleteDataSet\": {");
        console.log("    \"signature\": \"%s\",", vm.toString(deleteDataSetSig));
        console.log("    \"dataSetId\": %d", DATA_SET_ID);
        console.log("  }");
        console.log("}");

        // Verify signatures recover correctly
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

        assertTrue(
            testContract.verifySchedulePieceRemovalsSignature(
                TEST_SIGNER, CLIENT_DATA_SET_ID, testPieceIds, scheduleRemovalsSig
            ),
            "SchedulePieceRemovals signature verification failed"
        );

        assertTrue(
            testContract.verifyDeleteDataSetSignature(TEST_SIGNER, DATA_SET_ID, deleteDataSetSig),
            "DeleteDataSet signature verification failed"
        );
    }

    /**
     * @dev Test external signatures (from external_signatures.json) verify against the contract.
     */
    function testExternalSignatures() public view {
        string memory json = vm.readFile("./test/external_signatures.json");
        address signer = vm.parseJsonAddress(json, ".signer");

        console.log("Testing external signatures for signer:", signer);

        testCreateDataSetSignature(json, signer);
        testAddPiecesSignature(json, signer);
        testSchedulePieceRemovalsSignature(json, signer);
        testDeleteDataSetSignature(json, signer);

        console.log("All external signature tests PASSED!");
    }

    /**
     * @dev Show EIP-712 type structures for external developers.
     */
    function testEIP712TypeStructures() public pure {
        console.log("=== EIP-712 TYPE STRUCTURES ===");
        console.log("");
        console.log("Domain:");
        console.log("  name: 'FilecoinWarmStorageService'");
        console.log("  version: '1'");
        console.log("  chainId: %d", DOMAIN_CHAIN_ID);
        console.log("  verifyingContract: %s", DOMAIN_VERIFYING_CONTRACT);
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
        console.log("  ],");
        console.log("  DeleteDataSet: [");
        console.log("    { name: 'dataSetId', type: 'uint256' }");
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

    function generateDeleteDataSetSignature(uint256 dataSetId) internal view returns (bytes memory) {
        bytes32 digest = testContract.getDeleteDataSetDigest(dataSetId);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    // SDK extraData encoders (must match synapse-core sign-* helpers exactly)

    function encodeCreateDataSetExtraData(
        address payer,
        uint256 clientDataSetId,
        string[] memory keys,
        string[] memory values,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        return abi.encode(payer, clientDataSetId, keys, values, signature);
    }

    function encodeAddPiecesExtraData(
        uint256 nonce,
        string[][] memory keys,
        string[][] memory values,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        return abi.encode(nonce, keys, values, signature);
    }

    function encodeSignatureBytes(bytes memory signature) internal pure returns (bytes memory) {
        return abi.encode(signature);
    }

    // External signature validators (verify external_signatures.json against the contract)

    function testCreateDataSetSignature(string memory json, address signer) internal view {
        string memory signature = vm.parseJsonString(json, ".createDataSet.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".createDataSet.clientDataSetId");
        address payee = vm.parseJsonAddress(json, ".createDataSet.payee");

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

        bytes[] memory pieceCidBytes = vm.parseJsonBytesArray(json, ".addPieces.pieceCidBytes");

        Cids.Cid[] memory pieceData = new Cids.Cid[](pieceCidBytes.length);
        for (uint256 i = 0; i < pieceCidBytes.length; i++) {
            pieceData[i] = Cids.Cid({data: pieceCidBytes[i]});
        }

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

    function testSchedulePieceRemovalsSignature(string memory json, address signer) internal view {
        string memory signature = vm.parseJsonString(json, ".schedulePieceRemovals.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".schedulePieceRemovals.clientDataSetId");
        uint256[] memory pieceIds = vm.parseJsonUintArray(json, ".schedulePieceRemovals.pieceIds");

        bool isValid = testContract.verifySchedulePieceRemovalsSignature(
            signer, clientDataSetId, pieceIds, vm.parseBytes(signature)
        );

        assertTrue(isValid, "SchedulePieceRemovals signature verification failed");
        console.log("  SchedulePieceRemovals: PASSED");
    }

    function testDeleteDataSetSignature(string memory json, address signer) internal view {
        string memory signature = vm.parseJsonString(json, ".deleteDataSet.signature");
        uint256 dataSetId = vm.parseJsonUint(json, ".deleteDataSet.dataSetId");

        bool isValid = testContract.verifyDeleteDataSetSignature(signer, dataSetId, vm.parseBytes(signature));

        assertTrue(isValid, "DeleteDataSet signature verification failed");
        console.log("  DeleteDataSet: PASSED");
    }
}
