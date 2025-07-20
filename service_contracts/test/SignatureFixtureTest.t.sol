// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {PandoraService} from "../src/PandoraService.sol";
import {PDPVerifier} from "@pdp/PDPVerifier.sol";
import {IPDPTypes} from "@pdp/interfaces/IPDPTypes.sol";
import {Cids} from "@pdp/Cids.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title EIP-712 Signature Fixture Test
 * @dev Generate and test EIP-712 signatures for PandoraService compatibility
 *
 * This contract serves two purposes:
 * 1. Generate reference EIP-712 signatures from Solidity (for testing external applications)
 * 2. Test external signatures against contract verification
 *
 * Usage:
 * - Run testGenerateFixtures to create reference signatures
 * - Run testExternalSignatures to verify your application's signatures
 */

// Simple standalone contract just for EIP-712 testing
contract TestablePandoraServiceEIP712 is EIP712 {
    constructor() EIP712("PandoraService", "1") {}

    // Re-declare the type hashes from parent contract (they're private)
    bytes32 private constant CREATE_PROOFSET_TYPEHASH = keccak256(
        "CreateProofSet(uint256 clientDataSetId,bool withCDN,address payee)"
    );

    bytes32 private constant CID_TYPEHASH = keccak256(
        "Cid(bytes data)"
    );

    bytes32 private constant ROOTDATA_TYPEHASH = keccak256(
        "PieceData(Cid piece,uint256 rawSize)Cid(bytes data)"
    );

    bytes32 private constant ADD_ROOTS_TYPEHASH = keccak256(
        "AddRoots(uint256 clientDataSetId,uint256 firstAdded,PieceData[] rootData)Cid(bytes data)PieceData(Cid piece,uint256 rawSize)"
    );

    bytes32 private constant SCHEDULE_REMOVALS_TYPEHASH = keccak256(
        "ScheduleRemovals(uint256 clientDataSetId,uint256[] rootIds)"
    );

    bytes32 private constant DELETE_PROOFSET_TYPEHASH = keccak256(
        "DeleteProofSet(uint256 clientDataSetId)"
    );

    function verifyCreateProofSetSignatureTest(
        address payer,
        uint256 clientDataSetId,
        address payee,
        bool withCDN,
        bytes memory signature
    ) public view returns (bool) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_PROOFSET_TYPEHASH,
                clientDataSetId,
                withCDN,
                payee
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        return signer == payer;
    }

    function verifyAddRootsSignatureTest(
        address payer,
        uint256 clientDataSetId,
        IPDPTypes.PieceData[] memory rootDataArray,
        uint256 firstAdded,
        bytes memory signature
    ) public view returns (bool) {
        bytes32 digest = getAddRootsDigest(clientDataSetId, firstAdded, rootDataArray);
        address signer = ECDSA.recover(digest, signature);
        return signer == payer;
    }

    function verifyScheduleRemovalsSignatureTest(
        address payer,
        uint256 clientDataSetId,
        uint256[] memory rootIds,
        bytes memory signature
    ) public view returns (bool) {
        bytes32 digest = getScheduleRemovalsDigest(clientDataSetId, rootIds);
        address signer = ECDSA.recover(digest, signature);
        return signer == payer;
    }

    function verifyDeleteProofSetSignatureTest(
        address payer,
        uint256 clientDataSetId,
        bytes memory signature
    ) public view returns (bool) {
        bytes32 digest = getDeleteProofSetDigest(clientDataSetId);
        address signer = ECDSA.recover(digest, signature);
        return signer == payer;
    }

    // Expose EIP-712 digest creation for testing
    function getCreateProofSetDigest(
        uint256 clientDataSetId,
        bool withCDN,
        address payee
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_PROOFSET_TYPEHASH,
                clientDataSetId,
                withCDN,
                payee
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getAddRootsDigest(
        uint256 clientDataSetId,
        uint256 firstAdded,
        IPDPTypes.PieceData[] memory rootDataArray
    ) public view returns (bytes32) {
        // Hash each PieceData struct
        bytes32[] memory rootDataHashes = new bytes32[](rootDataArray.length);
        for (uint256 i = 0; i < rootDataArray.length; i++) {
            // Hash the Cid struct
            bytes32 cidHash = keccak256(
                abi.encode(
                    CID_TYPEHASH,
                    keccak256(rootDataArray[i].piece.data)
                )
            );
            // Hash the PieceData struct
            rootDataHashes[i] = keccak256(
                abi.encode(
                    ROOTDATA_TYPEHASH,
                    cidHash,
                    rootDataArray[i].rawSize
                )
            );
        }

        bytes32 structHash = keccak256(abi.encode(
            ADD_ROOTS_TYPEHASH,
            clientDataSetId,
            firstAdded,
            keccak256(abi.encodePacked(rootDataHashes))
        ));
        return _hashTypedDataV4(structHash);
    }

    function getScheduleRemovalsDigest(
        uint256 clientDataSetId,
        uint256[] memory rootIds
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SCHEDULE_REMOVALS_TYPEHASH,
                clientDataSetId,
                keccak256(abi.encodePacked(rootIds))
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getDeleteProofSetDigest(
        uint256 clientDataSetId
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                DELETE_PROOFSET_TYPEHASH,
                clientDataSetId
            )
        );
        return _hashTypedDataV4(structHash);
    }

    // Get domain separator for external verification
    function getDomainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }
}

contract SignatureFixtureTest is Test {
    TestablePandoraServiceEIP712 public testContract;

    // Test private key (well-known test key, never use in production)
    uint256 constant TEST_PRIVATE_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    address constant TEST_SIGNER = 0x2e988A386a799F506693793c6A5AF6B54dfAaBfB;

    // Test data
    uint256 constant CLIENT_DATASET_ID = 12345;
    address constant PAYEE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    bool constant WITH_CDN = true;
    uint256 constant FIRST_ADDED = 1;

    function setUp() public {
        // Deploy the contract with proper EIP712 domain initialization
        testContract = new TestablePandoraServiceEIP712();
    }

    /**
     * @dev Generate reference EIP-712 signatures and output JSON fixture
     */
    function testGenerateFixtures() public view {
        console.log("=== EIP-712 SIGNATURE FIXTURE GENERATION ===");
        console.log("Contract Address:", address(testContract));
        console.log("Test Signer:", TEST_SIGNER);
        console.log("Chain ID:", block.chainid);
        console.log("Domain Separator:", vm.toString(testContract.getDomainSeparator()));
        console.log("");

        // Generate all signatures
        bytes memory createProofSetSig = generateCreateProofSetSignature();
        bytes memory addRootsSig = generateAddRootsSignature();
        bytes memory scheduleRemovalsSig = generateScheduleRemovalsSignature();
        bytes memory deleteProofSetSig = generateDeleteProofSetSignature();

        // Get the message digests for verification
        bytes32 createProofSetDigest = testContract.getCreateProofSetDigest(CLIENT_DATASET_ID, WITH_CDN, PAYEE);

        // Create PieceData for AddRoots digest
        IPDPTypes.PieceData[] memory rootDataArray = createTestRootData();
        bytes32 addRootsDigest = testContract.getAddRootsDigest(CLIENT_DATASET_ID, FIRST_ADDED, rootDataArray);

        uint256[] memory testRootIds = new uint256[](3);
        testRootIds[0] = 1;
        testRootIds[1] = 3;
        testRootIds[2] = 5;
        bytes32 scheduleRemovalsDigest = testContract.getScheduleRemovalsDigest(CLIENT_DATASET_ID, testRootIds);

        bytes32 deleteProofSetDigest = testContract.getDeleteProofSetDigest(CLIENT_DATASET_ID);

        // Output JSON format for copying to synapse-sdk tests
        console.log("Copy this JSON to synapse-sdk src/test/pdp-auth.test.ts:");
        console.log("{");
        console.log('  "privateKey": "0x%s",', vm.toString(TEST_PRIVATE_KEY));
        console.log('  "signerAddress": "%s",', TEST_SIGNER);
        console.log('  "contractAddress": "%s",', address(testContract));
        console.log('  "chainId": %d,', block.chainid);
        console.log('  "domainSeparator": "%s",', vm.toString(testContract.getDomainSeparator()));
        console.log('  "signatures": {');
        console.log('    "createProofSet": {');
        console.log('      "signature": "%s",', vm.toString(createProofSetSig));
        console.log('      "digest": "%s",', vm.toString(createProofSetDigest));
        console.log('      "clientDataSetId": %d,', CLIENT_DATASET_ID);
        console.log('      "payee": "%s",', PAYEE);
        console.log('      "withCDN": %s', WITH_CDN ? "true" : "false");
        console.log('    },');
        console.log('    "addRoots": {');
        console.log('      "signature": "%s",', vm.toString(addRootsSig));
        console.log('      "digest": "%s",', vm.toString(addRootsDigest));
        console.log('      "clientDataSetId": %d,', CLIENT_DATASET_ID);
        console.log('      "firstAdded": %d,', FIRST_ADDED);
        console.log('      "rootCidBytes": [');
        console.log('        "0x0181e203922020fc7e928296e516faade986b28f92d44a4f24b935485223376a799027bc18f833",');
        console.log('        "0x0181e203922020a9eb89e9825d609ab500be99bf0770bd4e01eeaba92b8dad23c08f1f59bfe10f"');
        console.log('      ],');
        console.log('      "rootSizes": [2048, 4096]');
        console.log('    },');
        console.log('    "scheduleRemovals": {');
        console.log('      "signature": "%s",', vm.toString(scheduleRemovalsSig));
        console.log('      "digest": "%s",', vm.toString(scheduleRemovalsDigest));
        console.log('      "clientDataSetId": %d,', CLIENT_DATASET_ID);
        console.log('      "rootIds": [1, 3, 5]');
        console.log('    },');
        console.log('    "deleteProofSet": {');
        console.log('      "signature": "%s",', vm.toString(deleteProofSetSig));
        console.log('      "digest": "%s",', vm.toString(deleteProofSetDigest));
        console.log('      "clientDataSetId": %d', CLIENT_DATASET_ID);
        console.log('    }');
        console.log('  }');
        console.log('}');

        // Verify all signatures work
        assertTrue(
            testContract.verifyCreateProofSetSignatureTest(
                TEST_SIGNER,
                CLIENT_DATASET_ID,
                PAYEE,
                WITH_CDN,
                createProofSetSig
            ),
            "CreateProofSet signature verification failed"
        );

        assertTrue(
            testContract.verifyAddRootsSignatureTest(
                TEST_SIGNER,
                CLIENT_DATASET_ID,
                rootDataArray,
                FIRST_ADDED,
                addRootsSig
            ),
            "AddRoots signature verification failed"
        );

        assertTrue(
            testContract.verifyScheduleRemovalsSignatureTest(
                TEST_SIGNER,
                CLIENT_DATASET_ID,
                testRootIds,
                scheduleRemovalsSig
            ),
            "ScheduleRemovals signature verification failed"
        );

        assertTrue(
            testContract.verifyDeleteProofSetSignatureTest(
                TEST_SIGNER,
                CLIENT_DATASET_ID,
                deleteProofSetSig
            ),
            "DeleteProofSet signature verification failed"
        );
    }

    /**
     * @dev Test external signatures against contract verification
     */
    function testExternalSignatures() public view {
        string memory json = vm.readFile("./test/external_signatures.json");
        address signer = vm.parseJsonAddress(json, ".signer");

        console.log("Testing external signatures for signer:", signer);

        // Test all signature types
        testCreateProofSetSignature(json, signer);
        testAddRootsSignature(json, signer);
        testScheduleRemovalsSignature(json, signer);
        testDeleteProofSetSignature(json, signer);

        console.log("All external signature tests PASSED!");
    }

    /**
     * @dev Show EIP-712 type structures for external developers
     */
    function testEIP712TypeStructures() public view {
        console.log("=== EIP-712 TYPE STRUCTURES ===");
        console.log("");
        console.log("Domain:");
        console.log('  name: "PandoraService"');
        console.log('  version: "1"');
        console.log('  chainId: %d', block.chainid);
        console.log('  verifyingContract: %s', address(testContract));
        console.log("");
        console.log("Types:");
        console.log("  CreateProofSet: [");
        console.log('    { name: "clientDataSetId", type: "uint256" },');
        console.log('    { name: "withCDN", type: "bool" },');
        console.log('    { name: "payee", type: "address" }');
        console.log("  ]");
        console.log("");
        console.log("  Cid: [");
        console.log('    { name: "data", type: "bytes" }');
        console.log("  ]");
        console.log("");
        console.log("  PieceData: [");
        console.log('    { name: "piece", type: "Cid" },');
        console.log('    { name: "rawSize", type: "uint256" }');
        console.log("  ]");
        console.log("");
        console.log("  AddRoots: [");
        console.log('    { name: "clientDataSetId", type: "uint256" },');
        console.log('    { name: "firstAdded", type: "uint256" },');
        console.log('    { name: "rootData", type: "PieceData[]" }');
        console.log("  ]");
        console.log("");
        console.log("  ScheduleRemovals: [");
        console.log('    { name: "clientDataSetId", type: "uint256" },');
        console.log('    { name: "rootIds", type: "uint256[]" }');
        console.log("  ]");
        console.log("");
        console.log("  DeleteProofSet: [");
        console.log('    { name: "clientDataSetId", type: "uint256" }');
        console.log("  ]");
    }

    // ============= SIGNATURE GENERATION FUNCTIONS =============

    function generateCreateProofSetSignature() internal view returns (bytes memory) {
        bytes32 digest = testContract.getCreateProofSetDigest(CLIENT_DATASET_ID, WITH_CDN, PAYEE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function generateAddRootsSignature() internal view returns (bytes memory) {
        IPDPTypes.PieceData[] memory rootDataArray = createTestRootData();
        bytes32 digest = testContract.getAddRootsDigest(CLIENT_DATASET_ID, FIRST_ADDED, rootDataArray);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function generateScheduleRemovalsSignature() internal view returns (bytes memory) {
        uint256[] memory testRootIds = new uint256[](3);
        testRootIds[0] = 1;
        testRootIds[1] = 3;
        testRootIds[2] = 5;

        bytes32 digest = testContract.getScheduleRemovalsDigest(CLIENT_DATASET_ID, testRootIds);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function generateDeleteProofSetSignature() internal view returns (bytes memory) {
        bytes32 digest = testContract.getDeleteProofSetDigest(CLIENT_DATASET_ID);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    // ============= HELPER FUNCTIONS =============

    function createTestRootData() internal pure returns (IPDPTypes.PieceData[] memory) {
        IPDPTypes.PieceData[] memory rootDataArray = new IPDPTypes.PieceData[](2);

        // Create Cid with full CID bytes (not just digest)
        // CID baga6ea4seaqpy7usqklokfx2vxuynmupslkeutzexe2uqurdg5vhtebhxqmpqmy
        rootDataArray[0] = IPDPTypes.PieceData({
            piece: Cids.Cid({
                data: abi.encodePacked(hex"0181e203922020fc7e928296e516faade986b28f92d44a4f24b935485223376a799027bc18f833")
            }),
            rawSize: 2048 // Piece size of 1024
        });

        // CID baga6ea4seaqkt24j5gbf2ye2wual5gn7a5yl2tqb52v2sk4nvur4bdy7lg76cdy
        rootDataArray[1] = IPDPTypes.PieceData({
            piece: Cids.Cid({
                data: abi.encodePacked(hex"0181e203922020a9eb89e9825d609ab500be99bf0770bd4e01eeaba92b8dad23c08f1f59bfe10f")
            }),
            rawSize: 4096 // Piece size of 2048
        });

        return rootDataArray;
    }

    // ============= SIGNATURE VERIFICATION FUNCTIONS =============

    function testCreateProofSetSignature(string memory json, address signer) internal view {
        string memory signature = vm.parseJsonString(json, ".createProofSet.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".createProofSet.clientDataSetId");
        address payee = vm.parseJsonAddress(json, ".createProofSet.payee");
        bool withCDN = vm.parseJsonBool(json, ".createProofSet.withCDN");

        bool isValid = testContract.verifyCreateProofSetSignatureTest(
            signer,
            clientDataSetId,
            payee,
            withCDN,
            vm.parseBytes(signature)
        );

        assertTrue(isValid, "CreateProofSet signature verification failed");
        console.log("  CreateProofSet: PASSED");
    }

    function testAddRootsSignature(string memory json, address signer) internal view {
        string memory signature = vm.parseJsonString(json, ".addRoots.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".addRoots.clientDataSetId");
        uint256 firstAdded = vm.parseJsonUint(json, ".addRoots.firstAdded");

        // Parse root data arrays
        bytes[] memory rootCidBytes = vm.parseJsonBytesArray(json, ".addRoots.rootCidBytes");
        uint256[] memory sizes = vm.parseJsonUintArray(json, ".addRoots.rootSizes");

        require(rootCidBytes.length == sizes.length, "CID bytes and size arrays must be same length");

        // Create PieceData array
        IPDPTypes.PieceData[] memory rootData = new IPDPTypes.PieceData[](rootCidBytes.length);
        for (uint256 i = 0; i < rootCidBytes.length; i++) {
            rootData[i] = IPDPTypes.PieceData({
                piece: Cids.Cid({
                    data: rootCidBytes[i]
                }),
                rawSize: sizes[i]
            });
        }

        bool isValid = testContract.verifyAddRootsSignatureTest(
            signer,
            clientDataSetId,
            rootData,
            firstAdded,
            vm.parseBytes(signature)
        );

        assertTrue(isValid, "AddRoots signature verification failed");
        console.log("  AddRoots: PASSED");
    }

    function testScheduleRemovalsSignature(string memory json, address signer) internal view {
        string memory signature = vm.parseJsonString(json, ".scheduleRemovals.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".scheduleRemovals.clientDataSetId");
        uint256[] memory testRootIds = vm.parseJsonUintArray(json, ".scheduleRemovals.rootIds");

        bool isValid = testContract.verifyScheduleRemovalsSignatureTest(
            signer,
            clientDataSetId,
            testRootIds,
            vm.parseBytes(signature)
        );

        assertTrue(isValid, "ScheduleRemovals signature verification failed");
        console.log("  ScheduleRemovals: PASSED");
    }

    function testDeleteProofSetSignature(string memory json, address signer) internal view {
        string memory signature = vm.parseJsonString(json, ".deleteProofSet.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".deleteProofSet.clientDataSetId");

        bool isValid = testContract.verifyDeleteProofSetSignatureTest(
            signer,
            clientDataSetId,
            vm.parseBytes(signature)
        );

        assertTrue(isValid, "DeleteProofSet signature verification failed");
        console.log("  DeleteProofSet: PASSED");
    }
}
