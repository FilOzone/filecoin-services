// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {FWSSDataSetModule} from "../../src/modules/FWSSDataSetModule.sol";
import {console, Vm} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Cids} from "@pdp/Cids.sol";

import {CHALLENGES_PER_PROOF, FilecoinWarmStorageService} from "../../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";
import {FWSSProvingModule} from "../../src/modules/FWSSProvingModule.sol";
import {FWSSEIP712Module} from "../../src/modules/FWSSEIP712Module.sol";
import {FWSSConfigModule} from "../../src/modules/FWSSConfigModule.sol";
import {AbiCheats} from "@erc8167/lib/AbiCheats.sol";
import {ProxyStorage} from "@erc8167/lib/ProxyStorage.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {LibSignatureVerification} from "../../src/lib/LibSignatureVerification.sol";
import {FilecoinWarmStorageServiceStateLibrary} from "../../src/lib/FilecoinWarmStorageServiceStateLibrary.sol";
import {SCHEDULED_PIECE_METADATA_REMOVALS_SLOT} from "../../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {CDNPaymentRailsToppedUp} from "../../src/lib/LibRails.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {MockERC20} from "../mocks/SharedMocks.sol";
import {Errors} from "../../src/Errors.sol";
import {
    calculateStorageSizeBasedRatePerEpoch,
    DATASET_FEE_PER_EPOCH,
    DATASET_FEE_PER_MONTH,
    DEFAULT_LOCKUP_PERIOD,
    LIFECYCLE_RESERVE_TARGET
} from "../../src/lib/PriceListUSDFC.sol";

import {PDPOffering} from "../PDPOffering.sol";

import {
    TestDataSetAuthorizer,
    RevertingDataSetAuthorizer,
    OperationDataCheckingAuthorizer,
    StatefulDataSetAuthorizer
} from "../FilecoinWarmStorageService.t.sol";

contract FWSSDataSetModuleTest is FilecoinWarmStorageServiceFixture {
    using SafeERC20 for MockERC20;
    using PDPOffering for PDPOffering.Schema;
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;

    function setUp() public override {
        super.setUp();

        address proxy = address(pdpServiceWithPayments);
        address legacyImplementation = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        FWSSConfigModule configModule = new FWSSConfigModule(
            pdpServiceWithPayments.paymentsContractAddress(), pdpServiceWithPayments.pdpVerifierAddress(), mockUSDFC
        );
        FWSSDataSetModule module =
            new FWSSDataSetModule(mockUSDFC, filBeamBeneficiary, serviceProviderRegistry, sessionKeyRegistry);
        FWSSEIP712Module eip712Module = new FWSSEIP712Module();
        address dispatcher = deployCode("lib/erc8167/out/Proxy.evm/Proxy.json");

        // Preserve legacy routes and route dataset operations and configuration to their modules.
        bytes4[] memory selectors = AbiCheats.getSelectors(
            vm, "out/FilecoinWarmStorageServiceFixture.sol/FilecoinWarmStorageServiceHarness.json"
        );
        for (uint256 i; i < selectors.length; ++i) {
            _route(proxy, selectors[i], legacyImplementation);
        }
        selectors = AbiCheats.getSelectors(vm, "out/FWSSDataSetModule.sol/FWSSDataSetModule.json");
        for (uint256 i; i < selectors.length; ++i) {
            _route(proxy, selectors[i], address(module));
        }
        selectors = AbiCheats.getSelectors(vm, "out/FWSSConfigModule.sol/FWSSConfigModule.json");
        for (uint256 i; i < selectors.length; ++i) {
            _route(proxy, selectors[i], address(configModule));
        }

        selectors = AbiCheats.getSelectors(vm, "out/FWSSEIP712Module.sol/FWSSEIP712Module.json");
        for (uint256 i; i < selectors.length; ++i) {
            _route(proxy, selectors[i], address(eip712Module));
        }

        vm.store(proxy, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(dispatcher))));
    }

    function _route(address proxy, bytes4 selector, address implementation) internal {
        vm.store(proxy, ProxyStorage.delegateStorageKey(selector), bytes32(uint256(uint160(implementation))));
    }

    function createDataSetForServiceProviderTest(address provider, address clientAddress, string memory label)
        internal
        returns (uint256)
    {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", label);
        return createDataSetForClient(provider, clientAddress, keys, values);
    }

    function _scheduledPieceMetadataRemovalsLength(uint256 dataSetId) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(dataSetId, SCHEDULED_PIECE_METADATA_REMOVALS_SLOT));
        return uint256(vm.load(address(pdpServiceWithPayments), slot));
    }

    function _scheduledPieceMetadataRemovalAt(uint256 dataSetId, uint256 index) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(dataSetId, SCHEDULED_PIECE_METADATA_REMOVALS_SLOT));
        bytes32 elementSlot = bytes32(uint256(keccak256(abi.encode(slot))) + index);
        return uint256(vm.load(address(pdpServiceWithPayments), elementSlot));
    }

    function testCreateDataSetCreatesRail() public {
        // Prepare ExtraData - withCDN key presence means CDN is enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");

        // Prepare ExtraData
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: client,
            clientDataSetId: 0,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        // Encode the extra data
        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Client needs to approve the PDP Service to create a payment rail
        vm.startPrank(client);
        // Set operator approval for the PDP service in the FilecoinPayV1 contract
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            1000e18, // rate allowance (1000 USDFC)
            1000e18, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );

        // Client deposits funds to the FilecoinPayV1 contract for future payments
        uint256 depositAmount = 10e18; // Sufficient funds for initial lockup and future operations
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Expect CDNPaymentRailsToppedUp event when creating the data set with CDN enabled
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            1, defaultCDNLockup, defaultCDNLockup, defaultCacheMissLockup, defaultCacheMissLockup
        );

        // Expect DataSetCreated event when creating the data set (with CDN rails)
        // Rail IDs: pdp=1, cacheMiss=2, cdn=3
        vm.expectEmit(true, true, true, true);
        emit FWSSDataSetModule.DataSetCreated(
            1, 1, 1, 2, 3, client, serviceProvider, serviceProvider, createData.metadataKeys, createData.metadataValues
        );

        // Create a data set as the service provider
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);
        vm.stopPrank();

        // Get data set info
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        uint256 pdpRailId = dataSet.pdpRailId;
        uint256 cacheMissRailId = dataSet.cacheMissRailId;
        uint256 cdnRailId = dataSet.cdnRailId;

        // Verify valid rail IDs were created
        assertTrue(pdpRailId > 0, "PDP Rail ID should be non-zero");
        assertTrue(cacheMissRailId > 0, "Cache Miss Rail ID should be non-zero");
        assertTrue(cdnRailId > 0, "CDN Rail ID should be non-zero");

        // Verify data set info was stored correctly
        assertEq(dataSet.payer, client, "Payer should be set to client");
        assertEq(dataSet.payee, serviceProvider, "Payee should be set to service provider");

        // Verify metadata was stored correctly
        (bool exists, string memory metadata) = viewContract.getDataSetMetadata(newDataSetId, metadataKeys[0]);
        assertTrue(exists, "Metadata key should exist");
        assertEq(metadata, "true", "Metadata should be stored correctly");

        // Verify client data set ids
        uint256[] memory clientDataSetIds = viewContract.clientDataSets(client);
        assertEq(clientDataSetIds.length, 1);
        assertEq(clientDataSetIds[0], newDataSetId);

        assertEq(viewContract.railToDataSet(pdpRailId), newDataSetId);

        // Verify data set info
        FilecoinWarmStorageService.DataSetInfoView memory dataSetInfo = viewContract.getDataSet(newDataSetId);
        assertEq(dataSetInfo.pdpRailId, pdpRailId, "PDP rail ID should match");
        assertNotEq(dataSetInfo.cacheMissRailId, 0, "Cache miss rail ID should be set");
        assertNotEq(dataSetInfo.cdnRailId, 0, "CDN rail ID should be set");
        assertEq(dataSetInfo.payer, client, "Payer should match");
        assertEq(dataSetInfo.payee, serviceProvider, "Payee should match");

        // Verify the rails in the actual FilecoinPayV1 contract
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(pdpRailId);
        assertEq(address(pdpRail.token), address(mockUSDFC), "Token should be USDFC");
        assertEq(pdpRail.from, client, "From address should be client");
        assertEq(pdpRail.to, serviceProvider, "To address should be service provider");
        assertEq(pdpRail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(pdpRail.validator, address(pdpServiceWithPayments), "Validator should be the PDP service");
        assertEq(pdpRail.commissionRateBps, 0, "No commission");
        assertEq(pdpRail.lockupFixed, LIFECYCLE_RESERVE_TARGET, "Lockup fixed should be lifecycle reserve target");
        assertEq(pdpRail.paymentRate, 0, "Initial payment rate should be 0");

        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(cacheMissRailId);
        assertEq(address(cacheMissRail.token), address(mockUSDFC), "Token should be USDFC");
        assertEq(cacheMissRail.from, client, "From address should be client");
        assertEq(cacheMissRail.to, serviceProvider, "To address should be service provider");
        assertEq(cacheMissRail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(cacheMissRail.validator, address(0), "Validator should be empty");
        assertEq(cacheMissRail.commissionRateBps, 0, "No commission");
        assertEq(cacheMissRail.lockupFixed, defaultCacheMissLockup, "Cache miss lockup should be 0.3 USDFC");
        assertEq(cacheMissRail.paymentRate, 0, "Initial payment rate should be 0");

        FilecoinPayV1.RailView memory cdnRail = payments.getRail(cdnRailId);
        assertEq(address(cdnRail.token), address(mockUSDFC), "Token should be USDFC");
        assertEq(cdnRail.from, client, "From address should be client");
        assertEq(cdnRail.to, filBeamBeneficiary, "To address should be FilBeamBeneficiary");
        assertEq(cdnRail.operator, address(pdpServiceWithPayments), "Operator should be the PDP service");
        assertEq(cdnRail.validator, address(0), "Validator should be empty");
        assertEq(cdnRail.commissionRateBps, 0, "No commission");
        assertEq(cdnRail.lockupFixed, defaultCDNLockup, "CDN lockup should be 0.7 USDFC");
        assertEq(cdnRail.paymentRate, 0, "Initial payment rate should be 0");
    }

    function testCreateDataSetNoCDN() public {
        // Prepare ExtraData - no withCDN key means CDN is disabled
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);

        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: client,
            clientDataSetId: 0,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        // Encode the extra data
        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Client needs to approve the PDP Service to create a payment rail
        vm.startPrank(client);
        // Set operator approval for the PDP service in the FilecoinPayV1 contract
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            1000e18, // rate allowance (1000 USDFC)
            1000e18, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );

        // Client deposits funds to the FilecoinPayV1 contract for future payments
        uint256 depositAmount = 10e18; // Sufficient funds for initial lockup and future operations
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Expect DataSetCreated event when creating the data set (no CDN rails)
        vm.expectEmit(true, true, true, true);
        emit FWSSDataSetModule.DataSetCreated(
            1, 1, 1, 0, 0, client, serviceProvider, serviceProvider, createData.metadataKeys, createData.metadataValues
        );

        // Create a data set as the service provider
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);
        vm.stopPrank();

        // Get data set info
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        assertEq(dataSet.payer, client);
        assertEq(dataSet.payee, serviceProvider);
        // Verify the commission rate was set correctly for basic service (no CDN)
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(dataSet.pdpRailId);
        assertEq(pdpRail.commissionRateBps, 0, "Commission rate should be 0% for basic service (no CDN)");

        assertEq(dataSet.cacheMissRailId, 0, "Cache miss rail ID should be 0 for basic service (no CDN)");
        assertEq(dataSet.cdnRailId, 0, "CDN rail ID should be 0 for basic service (no CDN)");

        // now with session key
        vm.prank(client);
        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = CREATE_DATA_SET_TYPEHASH;
        sessionKeyRegistry.login(sessionKey1, block.timestamp, permissions, "FilecoinWarmStorageServiceTest");
        makeSignaturePass(sessionKey1);

        extraData =
            abi.encode(createData.payer, 1, createData.metadataKeys, createData.metadataValues, createData.signature);
        vm.prank(serviceProvider);
        uint256 newDataSetId2 = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);

        FilecoinWarmStorageService.DataSetInfoView memory dataSet2 = viewContract.getDataSet(newDataSetId2);
        assertEq(dataSet2.payer, client);
        assertEq(dataSet2.payee, serviceProvider);

        extraData =
            abi.encode(createData.payer, 2, createData.metadataKeys, createData.metadataValues, createData.signature);
        // ensure another session key would be denied
        makeSignaturePass(sessionKey2);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey2));
        mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);

        // session key expires
        vm.warp(block.timestamp + 1);
        makeSignaturePass(sessionKey1);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey1));
        mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);

        // cannot recreate dataset
        extraData =
            abi.encode(createData.payer, 1, createData.metadataKeys, createData.metadataValues, createData.signature);
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, 1));
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(newDataSetId2);
        FilecoinWarmStorageService.DataSetInfoView memory terminatedInfo = viewContract.getDataSet(newDataSetId2);
        assertTrue(terminatedInfo.pdpEndEpoch > 0, "Dataset 2 should be terminated");
        // Advance block number past end epoch to allow settlement and deletion
        vm.roll(terminatedInfo.pdpEndEpoch + 1);
        // Settle the rail before deletion
        FilecoinPayV1.RailView memory rail = payments.getRail(terminatedInfo.pdpRailId);
        payments.settleRail(terminatedInfo.pdpRailId, rail.endEpoch);
        vm.prank(serviceProvider);
        mockPDPVerifier.deleteDataSet(PDPListener(address(pdpServiceWithPayments)), newDataSetId2, "");

        // cannot recreate deleted dataset
        extraData =
            abi.encode(createData.payer, 1, createData.metadataKeys, createData.metadataValues, createData.signature);
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, 1));
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);
    }

    function testCreateDataSetAddPieces() public {
        // Create dataset with metadataKeys/metadataValues
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Test Data Set");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: client, clientDataSetId: 0, metadataKeys: dsKeys, metadataValues: dsValues, signature: FAKE_SIGNATURE
        });
        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Approvals and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            1000e18, // rate allowance (1000 USDFC)
            1000e18, // lockup allowance (1000 USDFC)
            365 days // max lockup period
        );
        uint256 depositAmount = 10e18; // Sufficient funds for initial lockup and future operations
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Create dataset
        makeSignaturePass(client);
        vm.prank(serviceProvider); // Create dataset as service provider
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);

        // Prepare piece batches
        uint256 firstAdded = 0;
        string memory metadataShort = "metadata";
        string memory metadataLong = "metadatAmetadaTametadAtametaDatametAdatameTadatamEtadataMetadata";

        // First batch (3 pieces) with key "meta" => metadataShort
        Cids.Cid[] memory pieceData1 = new Cids.Cid[](3);
        pieceData1[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("1_0:1111")));
        pieceData1[1] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("1_1:111100000")));
        pieceData1[2] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("1_2:11110000000000")));
        string[] memory keys1 = new string[](1);
        string[] memory values1 = new string[](1);
        keys1[0] = "meta";
        values1[0] = metadataShort;
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            firstAdded,
            pieceData1,
            1,
            FAKE_SIGNATURE,
            keys1,
            values1
        );
        firstAdded += pieceData1.length;

        // Second batch (2 pieces) with key "meta" => metadataLong
        Cids.Cid[] memory pieceData2 = new Cids.Cid[](2);
        pieceData2[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("2_0:22222222222222222222")));
        pieceData2[1] = Cids.CommPv2FromDigest(
            0, 4, keccak256(abi.encodePacked("2_1:222222222222222222220000000000000000000000000000000000000000000"))
        );
        string[] memory keys2 = new string[](1);
        string[] memory values2 = new string[](1);
        keys2[0] = "meta";
        values2[0] = metadataLong;
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            firstAdded,
            pieceData2,
            2,
            FAKE_SIGNATURE,
            keys2,
            values2
        );
        firstAdded += pieceData2.length;

        // now with session keys
        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = ADD_PIECES_TYPEHASH;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp, permissions, "FilecoinWarmStorageServiceTest");

        makeSignaturePass(sessionKey1);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            firstAdded,
            pieceData2,
            3,
            FAKE_SIGNATURE,
            keys2,
            values2
        );
        firstAdded += pieceData2.length;

        // unauthorized session key reverts
        makeSignaturePass(sessionKey2);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey2));
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            firstAdded,
            pieceData2,
            4,
            FAKE_SIGNATURE,
            keys2,
            values2
        );

        // expired session key reverts
        vm.warp(block.timestamp + 1);
        makeSignaturePass(sessionKey1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey1));
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            firstAdded,
            pieceData2,
            5,
            FAKE_SIGNATURE,
            keys2,
            values2
        );
    }

    // Minimum Funds Validation Tests
    function testInsufficientFunds_BelowMinimum() public {
        // Setup: Client with insufficient funds (below 0.62 USDFC minimum = 0.12 dataset fee + 0.50 lifecycle reserve)
        address insufficientClient = makeAddr("insufficientClient");
        uint256 insufficientAmount = 12e16; // 0.12 USDFC (below 0.62 minimum)

        // Transfer tokens from test contract to the test client
        mockUSDFC.safeTransfer(insufficientClient, insufficientAmount);

        vm.startPrank(insufficientClient);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), insufficientAmount);
        payments.deposit(mockUSDFC, insufficientClient, insufficientAmount);
        vm.stopPrank();

        // Prepare dataset creation data
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Insufficient Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: insufficientClient,
            clientDataSetId: 999,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        uint256 required = DATASET_FEE_PER_MONTH + LIFECYCLE_RESERVE_TARGET;

        // Expect revert with InsufficientLockupFunds error
        makeSignaturePass(insufficientClient);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientLockupFunds.selector, insufficientClient, required, insufficientAmount
            )
        );
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);
    }

    function testInsufficientFunds_ExactMinimum() public {
        // Setup: Client with exactly the minimum funds (0.62 USDFC = 0.12 dataset fee + 0.50 lifecycle reserve)
        address exactClient = makeAddr("exactClient");
        uint256 exactAmount = DATASET_FEE_PER_MONTH + LIFECYCLE_RESERVE_TARGET; // Exactly 0.62 USDFC

        // Transfer tokens from test contract to the test client
        mockUSDFC.safeTransfer(exactClient, exactAmount);

        vm.startPrank(exactClient);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), exactAmount);
        payments.deposit(mockUSDFC, exactClient, exactAmount);
        vm.stopPrank();

        // Prepare dataset creation data
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Exact Minimum Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: exactClient,
            clientDataSetId: 1000,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Should succeed with exact minimum
        makeSignaturePass(exactClient);
        vm.prank(serviceProvider);
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);

        // Verify dataset was created
        assertEq(dataSetId, 1, "Dataset should be created with exact minimum funds");
    }

    function testInsufficientFunds_JustAboveMinimum() public {
        // Setup: Client with slightly more than minimum (0.621 USDFC)
        address aboveMinClient = makeAddr("aboveMinClient");
        uint256 aboveMinAmount = DATASET_FEE_PER_MONTH + LIFECYCLE_RESERVE_TARGET + 1e15; // 0.621 USDFC

        // Transfer tokens from test contract to the test client
        mockUSDFC.safeTransfer(aboveMinClient, aboveMinAmount);

        vm.startPrank(aboveMinClient);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), aboveMinAmount);
        payments.deposit(mockUSDFC, aboveMinClient, aboveMinAmount);
        vm.stopPrank();

        // Prepare dataset creation data
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Above Minimum Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: aboveMinClient,
            clientDataSetId: 1001,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Should succeed with funds above minimum
        makeSignaturePass(aboveMinClient);
        vm.prank(serviceProvider);
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);

        // Verify dataset was created
        assertEq(dataSetId, 1, "Dataset should be created with above-minimum funds");
    }

    function testInsufficientFunds_AddPiecesFailsImmediately() public {
        // Test that adding pieces fails immediately when client has insufficient funds
        // for the new lockup amount. This validates that updatePaymentRates is called
        // in piecesAdded rather than waiting until nextProvingPeriod.

        // Setup: Client with minimal funds - just enough to create an empty dataset
        address limitedClient = makeAddr("limitedClient");
        uint256 limitedAmount = DATASET_FEE_PER_MONTH + LIFECYCLE_RESERVE_TARGET + 1e15; // 0.621 USDFC

        mockUSDFC.safeTransfer(limitedClient, limitedAmount);

        vm.startPrank(limitedClient);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), limitedAmount);
        payments.deposit(mockUSDFC, limitedClient, limitedAmount);
        vm.stopPrank();

        // Create dataset - should succeed with minimal funds
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Limited Funds Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: limitedClient,
            clientDataSetId: 1001,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        makeSignaturePass(limitedClient);
        vm.prank(serviceProvider);
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);
        assertEq(dataSetId, 1, "Dataset should be created successfully");

        // Prepare a large piece - 1 TiB would cost 2.5 USDFC/month, way more than client has
        // height=35 means 2^35 leaves × 32 bytes = 1 TiB
        Cids.Cid[] memory largePieceData = new Cids.Cid[](1);
        largePieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256(abi.encodePacked("large_piece")));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);

        // Attempt to add piece should fail immediately due to insufficient funds
        // The error comes from FilecoinPayV1's modifyRailPayment when lockup check fails
        makeSignaturePass(limitedClient);
        vm.expectRevert(); // Reverts with "invariant failure: insufficient funds to cover lockup after function execution"
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, largePieceData, 1, FAKE_SIGNATURE, keys, values
        );
    }

    function testAddPieces_RateUpdatedImmediately() public {
        // Test that payment rates are updated immediately when pieces are added,
        // not deferred to nextProvingPeriod.

        // Setup: Client with sufficient funds
        address testClient = makeAddr("rateUpdateClient");
        uint256 depositAmount = 100e18; // 100 USDFC - plenty of funds

        mockUSDFC.safeTransfer(testClient, depositAmount);

        vm.startPrank(testClient);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, testClient, depositAmount);
        vm.stopPrank();

        // Create dataset
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Rate Update Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: testClient,
            clientDataSetId: 1002,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        makeSignaturePass(testClient);
        vm.prank(serviceProvider);
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);

        // Get initial rail info (should be at minimum rate for empty dataset)
        FilecoinWarmStorageService.DataSetInfoView memory dataSetInfo = viewContract.getDataSet(dataSetId);
        uint256 railId = dataSetInfo.pdpRailId;

        // Get initial rate
        FilecoinPayV1.RailView memory initialRail = payments.getRail(railId);
        uint256 initialRate = initialRail.paymentRate;

        // Add a large piece (1 TiB = height 35)
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256(abi.encodePacked("1tib_piece")));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);

        makeSignaturePass(testClient);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, pieceData, 1, FAKE_SIGNATURE, keys, values
        );

        // Get rate after adding piece - should be updated immediately, not waiting for nextProvingPeriod
        FilecoinPayV1.RailView memory railAfterAdd = payments.getRail(railId);
        uint256 rateAfterAdd = railAfterAdd.paymentRate;

        // Rate should have increased (1 TiB costs ~2.5 USDFC/month, much more than minimum 0.06)
        assertGt(rateAfterAdd, initialRate, "Rate should increase immediately after adding piece");
    }

    function testUpdatePaymentRates_PiecesAddedUsesRawSize() public {
        address payer = makeAddr("rawSizeClient");
        mockUSDFC.safeTransfer(payer, 100e18);
        vm.startPrank(payer);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), 100e18);
        payments.deposit(mockUSDFC, payer, 100e18);
        vm.stopPrank();

        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Raw Size Test");
        bytes memory createData = abi.encode(payer, uint256(7001), dsKeys, dsValues, FAKE_SIGNATURE);
        makeSignaturePass(payer);
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), createData);

        // height=35, padding=0: 1<<30 leaves, well above the floor crossover.
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256("raw_size_piece"));
        uint256 leafCount = Cids.leafCount(0, 35);

        makeSignaturePass(payer);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            1,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        uint256 actualRate = payments.getRail(viewContract.getDataSet(dataSetId).pdpRailId).paymentRate;
        uint256 expectedRate = calculateStorageSizeBasedRatePerEpoch(Cids.leafCountToRawSize(leafCount));
        uint256 buggyRate = calculateStorageSizeBasedRatePerEpoch(leafCount * 32);

        assertEq(actualRate, expectedRate, "rail rate should price on raw bytes");
        assertLt(actualRate, buggyRate, "raw-size rate must be lower than the Fr32-size rate");
        // 127/128 ratio applies only to the size-proportional component; strip the additive dataset fee before checking.
        // Tolerance of 1 covers integer-division truncation differences between the two paths.
        assertApproxEqAbs(
            actualRate - DATASET_FEE_PER_EPOCH,
            ((buggyRate - DATASET_FEE_PER_EPOCH) * 127) / 128,
            1,
            "ratio between raw and Fr32 rates is 127/128"
        );
    }

    // Operator Approval Validation Tests
    function testOperatorApproval_NotApproved() public {
        // Setup: Client with sufficient funds but no operator approval
        address testClient = makeAddr("testClient");
        uint256 depositAmount = 10e18; // 10 USDFC (plenty of funds)

        // Transfer tokens and deposit
        mockUSDFC.safeTransfer(testClient, depositAmount);

        vm.startPrank(testClient);
        // Don't set operator approval (or explicitly set to false)
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), false, 0, 0, 0);
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, testClient, depositAmount);
        vm.stopPrank();

        // Prepare dataset creation data
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Not Approved Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: testClient,
            clientDataSetId: 2000,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Expect revert with OperatorNotApproved error
        makeSignaturePass(testClient);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OperatorNotApproved.selector, testClient, address(pdpServiceWithPayments))
        );
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);
    }

    function testOperatorApproval_InsufficientRateAllowance() public {
        // Setup: Client with sufficient funds but insufficient rate allowance
        address testClient = makeAddr("testClient2");
        uint256 depositAmount = 10e18; // 10 USDFC (plenty of funds)

        uint256 minimumRatePerEpoch = DATASET_FEE_PER_EPOCH;
        uint256 insufficientRateAllowance = minimumRatePerEpoch - 1; // Just below minimum

        // Transfer tokens and set up approvals
        mockUSDFC.safeTransfer(testClient, depositAmount);

        vm.startPrank(testClient);
        // Set operator approval with insufficient rate allowance
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            insufficientRateAllowance, // rate allowance too low
            1000e18, // lockup allowance sufficient
            365 days // max lockup period sufficient
        );
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, testClient, depositAmount);
        vm.stopPrank();

        // Prepare dataset creation data
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Insufficient Rate Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: testClient,
            clientDataSetId: 2001,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Expect revert with InsufficientRateAllowance error
        makeSignaturePass(testClient);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientRateAllowance.selector,
                testClient,
                address(pdpServiceWithPayments),
                insufficientRateAllowance,
                0, // rateUsage is 0 initially
                minimumRatePerEpoch
            )
        );
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);
    }

    function testOperatorApproval_InsufficientLockupAllowance() public {
        // Setup: Client with sufficient funds but insufficient lockup allowance
        address testClient = makeAddr("testClient3");
        uint256 depositAmount = 10e18; // 10 USDFC (plenty of funds)

        uint256 lockupRequired = DATASET_FEE_PER_MONTH + LIFECYCLE_RESERVE_TARGET;
        uint256 insufficientLockupAllowance = lockupRequired - 1; // Just below required

        // Transfer tokens and set up approvals
        mockUSDFC.safeTransfer(testClient, depositAmount);

        vm.startPrank(testClient);
        // Set operator approval with insufficient lockup allowance
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            1000e18, // rate allowance sufficient
            insufficientLockupAllowance, // lockup allowance too low
            365 days // max lockup period sufficient
        );
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, testClient, depositAmount);
        vm.stopPrank();

        // Prepare dataset creation data
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Insufficient Lockup Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: testClient,
            clientDataSetId: 2002,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Expect revert with InsufficientLockupAllowance error
        makeSignaturePass(testClient);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientLockupAllowance.selector,
                testClient,
                address(pdpServiceWithPayments),
                insufficientLockupAllowance,
                0, // lockupUsage is 0 initially
                lockupRequired
            )
        );
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);
    }

    function testOperatorApproval_InsufficientMaxLockupPeriod() public {
        // Setup: Client with sufficient funds but insufficient max lockup period
        address testClient = makeAddr("testClient4");
        uint256 depositAmount = 10e18; // 10 USDFC (plenty of funds)

        uint256 defaultLockupPeriod = DEFAULT_LOCKUP_PERIOD;
        uint256 insufficientMaxLockupPeriod = defaultLockupPeriod - 1; // Just below required

        // Transfer tokens and set up approvals
        mockUSDFC.safeTransfer(testClient, depositAmount);

        vm.startPrank(testClient);
        // Set operator approval with insufficient max lockup period
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            1000e18, // rate allowance sufficient
            1000e18, // lockup allowance sufficient
            insufficientMaxLockupPeriod // max lockup period too low
        );
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, testClient, depositAmount);
        vm.stopPrank();

        // Prepare dataset creation data
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Insufficient Period Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: testClient,
            clientDataSetId: 2003,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Expect revert with InsufficientMaxLockupPeriod error
        makeSignaturePass(testClient);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientMaxLockupPeriod.selector,
                testClient,
                address(pdpServiceWithPayments),
                insufficientMaxLockupPeriod,
                defaultLockupPeriod
            )
        );
        vm.prank(serviceProvider);
        mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);
    }

    function testOperatorApproval_AllSufficient() public {
        // Setup: Client with all approvals sufficient
        address testClient = makeAddr("testClient5");
        uint256 depositAmount = 10e18; // 10 USDFC (plenty of funds)

        // Transfer tokens and set up sufficient approvals
        mockUSDFC.safeTransfer(testClient, depositAmount);

        vm.startPrank(testClient);
        // Set operator approval with all sufficient values
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true, // approved
            1000e18, // rate allowance more than sufficient
            1000e18, // lockup allowance more than sufficient
            365 days // max lockup period more than sufficient
        );
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, testClient, depositAmount);
        vm.stopPrank();

        // Prepare dataset creation data
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "All Sufficient Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: testClient,
            clientDataSetId: 2004,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Should succeed with all approvals sufficient
        makeSignaturePass(testClient);
        vm.prank(serviceProvider);
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);

        // Verify dataset was created
        assertEq(dataSetId, 1, "Dataset should be created with sufficient approvals");
    }

    /**
     * @notice Test successful service provider change between two approved providers
     * @dev Verifies only the data set's payee is updated, event is emitted, and serviceProviderRegistry state is unchanged.
     */
    // NOTE: Disabled for GA - Storage provider changes are not permitted
    // See: https://github.com/FilOzone/filecoin-services/issues/203
    function testServiceProviderChangedSuccessDecoupled() public {
        // Create a data set with sp1 as the service provider
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");

        // Change service provider from sp1 to sp2 should revert
        bytes memory testExtraData = new bytes(0);
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(Errors.StorageProviderChangesNotSupported.selector));
        mockPDPVerifier.changeDataSetServiceProvider(testDataSetId, sp2, address(pdpServiceWithPayments), testExtraData);
    }

    /**
     * @notice Test service provider change reverts if new service provider is zero address
     */
    // NOTE: The mock PDPVerifier checks for zero address before calling the listener
    function testServiceProviderChangedRevertsIfNewServiceProviderZeroAddress() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        vm.prank(sp1);
        vm.expectRevert("New service provider cannot be zero address");
        mockPDPVerifier.changeDataSetServiceProvider(
            testDataSetId, address(0), address(pdpServiceWithPayments), testExtraData
        );
    }

    /**
     * @notice Test service provider change reverts (feature not yet supported)
     */
    // NOTE: Disabled for GA - Storage provider changes are not permitted
    // See: https://github.com/FilOzone/filecoin-services/issues/203
    function testServiceProviderChangedRevertsIfOldServiceProviderMismatch() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        // Call directly as PDPVerifier - should now revert before validation
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.StorageProviderChangesNotSupported.selector));
        FWSSDataSetModule(address(pdpServiceWithPayments))
            .storageProviderChanged(testDataSetId, sp2, sp2, testExtraData);
    }

    /**
     * @notice Test service provider change reverts if called by unauthorized address
     */
    // NOTE: This test for the onlyPDPVerifier modifier validation remains important
    function testServiceProviderChangedRevertsIfUnauthorizedCaller() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        bytes memory testExtraData = new bytes(0);
        // Call directly as sp2 (not PDPVerifier) - should fail on modifier before main revert
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyPDPVerifierAllowed.selector, address(mockPDPVerifier), sp2));
        FWSSDataSetModule(address(pdpServiceWithPayments))
            .storageProviderChanged(testDataSetId, sp1, sp2, testExtraData);
    }

    /**
     * @notice Test service provider change works with arbitrary extra data
     */
    // NOTE: Disabled for GA - Storage provider changes are not permitted
    // See: https://github.com/FilOzone/filecoin-services/issues/203
    function testServiceProviderChangedWithArbitraryExtraData() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        // Use arbitrary extra data
        bytes memory testExtraData = abi.encode("arbitrary", 123, address(this));
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(Errors.StorageProviderChangesNotSupported.selector));
        mockPDPVerifier.changeDataSetServiceProvider(testDataSetId, sp2, address(pdpServiceWithPayments), testExtraData);
    }

    // Data Set Metadata Storage Tests
    function testDataSetMetadataStorage() public {
        // Create a data set with metadata
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("label", "Test Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // read metadata key and value from contract
        (bool exists, string memory storedMetadata) = viewContract.getDataSetMetadata(dataSetId, metadataKeys[0]);
        (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);

        // Verify the stored metadata matches what we set
        assertTrue(exists, "Metadata key should exist");
        assertEq(storedMetadata, string(metadataValues[0]), "Stored metadata value should match");
        assertEq(storedKeys.length, 1, "Should have one metadata key");
        assertEq(storedKeys[0], metadataKeys[0], "Stored metadata key should match");
    }

    function testDataSetMetadataEmpty() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Verify no metadata is stored
        (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
        assertEq(storedKeys.length, 0, "Should have no metadata keys");
    }

    function testDataSetMetadataStorageMultipleKeys() public {
        // Create a data set with multiple metadata entries
        string[] memory metadataKeys = new string[](3);
        string[] memory metadataValues = new string[](3);

        metadataKeys[0] = "label";
        metadataValues[0] = "Test Metadata 1";

        metadataKeys[1] = "description";
        metadataValues[1] = "Test Description";

        metadataKeys[2] = "version";
        metadataValues[2] = "1.0.0";

        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Verify all metadata keys and values
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            (bool exists, string memory storedMetadata) = viewContract.getDataSetMetadata(dataSetId, metadataKeys[i]);
            assertTrue(exists, "Metadata key should exist");
            assertEq(
                storedMetadata,
                metadataValues[i],
                string(abi.encodePacked("Stored metadata for ", metadataKeys[i], " should match"))
            );
        }
        (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
        assertEq(storedKeys.length, metadataKeys.length, "Should have correct number of metadata keys");
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < storedKeys.length; j++) {
                if (keccak256(abi.encodePacked(storedKeys[j])) == keccak256(abi.encodePacked(metadataKeys[i]))) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string(abi.encodePacked("Metadata key ", metadataKeys[i], " should be stored")));
        }
    }

    function testDataSetMetadataStorageMultipleDataSets() public {
        // Create multiple proof sets with metadata
        (string[] memory metadataKeys1, string[] memory metadataValues1) = _getSingleMetadataKV("label", "Data Set 1");
        (string[] memory metadataKeys2, string[] memory metadataValues2) = _getSingleMetadataKV("label", "Data Set 2");

        uint256 dataSetId1 = createDataSetForClient(sp1, client, metadataKeys1, metadataValues1);
        uint256 dataSetId2 = createDataSetForClient(sp2, client, metadataKeys2, metadataValues2);

        // Verify metadata for first data set
        (bool exists1, string memory storedMetadata1) = viewContract.getDataSetMetadata(dataSetId1, metadataKeys1[0]);
        assertTrue(exists1, "First dataset metadata key should exist");
        assertEq(storedMetadata1, string(metadataValues1[0]), "Stored metadata for first data set should match");

        // Verify metadata for second data set
        (bool exists2, string memory storedMetadata2) = viewContract.getDataSetMetadata(dataSetId2, metadataKeys2[0]);
        assertTrue(exists2, "Second dataset metadata key should exist");
        assertEq(storedMetadata2, string(metadataValues2[0]), "Stored metadata for second data set should match");
    }

    function testDataSetMetadataKeyLengthBoundaries() public {
        // Test key lengths: just below max (31), at max (32), and exceeding max (33)
        uint256[] memory keyLengths = new uint256[](3);
        keyLengths[0] = 31; // Just below max
        keyLengths[1] = 32; // At max
        keyLengths[2] = 33; // Exceeds max

        for (uint256 i = 0; i < keyLengths.length; i++) {
            uint256 keyLength = keyLengths[i];
            (string[] memory metadataKeys, string[] memory metadataValues) =
                _getSingleMetadataKV(_makeStringOfLength(keyLength), "Test Metadata");

            if (keyLength <= 32) {
                // Should succeed for valid lengths
                uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

                // Verify the metadata is stored correctly
                (bool exists, string memory storedMetadata) =
                    viewContract.getDataSetMetadata(dataSetId, metadataKeys[0]);
                assertTrue(exists, "Metadata key should exist");
                assertEq(
                    storedMetadata,
                    string(metadataValues[0]),
                    string.concat("Stored metadata value should match for key length ", Strings.toString(keyLength))
                );

                // Verify the metadata key is stored
                (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
                assertEq(storedKeys.length, 1, "Should have one metadata key");
                assertEq(
                    storedKeys[0],
                    metadataKeys[0],
                    string.concat("Stored metadata key should match for key length ", Strings.toString(keyLength))
                );
            } else {
                // Should fail for exceeding max
                bytes memory encodedData = prepareDataSetForClient(sp1, client, metadataKeys, metadataValues);
                vm.prank(sp1);
                vm.expectRevert(abi.encodeWithSelector(Errors.MetadataKeyExceedsMaxLength.selector, 0, 32, keyLength));
                mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedData);
            }
        }
    }

    function testDataSetMetadataValueLengthBoundaries() public {
        // Test value lengths: just below max, at max, and exceeding max
        uint256[] memory valueLengths = new uint256[](3);
        valueLengths[0] = MAX_VALUE_LENGTH - 1; // Just below max
        valueLengths[1] = MAX_VALUE_LENGTH; // At max
        valueLengths[2] = MAX_VALUE_LENGTH + 1; // Exceeds max

        for (uint256 i = 0; i < valueLengths.length; i++) {
            uint256 valueLength = valueLengths[i];
            string[] memory metadataKeys = new string[](1);
            string[] memory metadataValues = new string[](1);
            metadataKeys[0] = "key";
            metadataValues[0] = _makeStringOfLength(valueLength);

            if (valueLength <= MAX_VALUE_LENGTH) {
                // Should succeed for valid lengths
                uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

                // Verify the metadata is stored correctly
                (bool exists, string memory storedMetadata) =
                    viewContract.getDataSetMetadata(dataSetId, metadataKeys[0]);
                assertTrue(exists, "Metadata key should exist");
                assertEq(
                    storedMetadata,
                    metadataValues[0],
                    string.concat("Stored metadata value should match for value length ", Strings.toString(valueLength))
                );

                // Verify the metadata key is stored
                (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
                assertEq(storedKeys.length, 1, "Should have one metadata key");
                assertEq(
                    storedKeys[0],
                    metadataKeys[0],
                    string.concat("Stored metadata key should match for value length ", Strings.toString(valueLength))
                );
            } else {
                // Should fail for exceeding max
                bytes memory encodedData = prepareDataSetForClient(sp1, client, metadataKeys, metadataValues);
                vm.prank(sp1);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        Errors.MetadataValueExceedsMaxLength.selector, 0, MAX_VALUE_LENGTH, valueLength
                    )
                );
                mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedData);
            }
        }
    }

    function testDataSetMetadataKeyCountBoundaries() public {
        // Test key counts: just below max (MAX_KEYS_PER_DATASET - 1), at max, and exceeding max
        uint256[] memory keyCounts = new uint256[](3);
        keyCounts[0] = MAX_KEYS_PER_DATASET - 1; // Just below max
        keyCounts[1] = MAX_KEYS_PER_DATASET; // At max
        keyCounts[2] = MAX_KEYS_PER_DATASET + 1; // Exceeds max

        for (uint256 testIdx = 0; testIdx < keyCounts.length; testIdx++) {
            uint256 keyCount = keyCounts[testIdx];
            string[] memory metadataKeys = new string[](keyCount);
            string[] memory metadataValues = new string[](keyCount);

            for (uint256 i = 0; i < keyCount; i++) {
                metadataKeys[i] = string.concat("key", Strings.toString(i));
                metadataValues[i] = _makeStringOfLength(32);
            }

            if (keyCount <= MAX_KEYS_PER_DATASET) {
                // Should succeed for valid counts
                uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

                // Verify all metadata keys and values
                for (uint256 i = 0; i < metadataKeys.length; i++) {
                    (bool exists, string memory storedMetadata) =
                        viewContract.getDataSetMetadata(dataSetId, metadataKeys[i]);
                    assertTrue(exists, string.concat("Key ", metadataKeys[i], " should exist"));
                    assertEq(
                        storedMetadata,
                        metadataValues[i],
                        string.concat("Stored metadata for ", metadataKeys[i], " should match")
                    );
                }

                (string[] memory storedKeys,) = viewContract.getAllDataSetMetadata(dataSetId);
                assertEq(
                    storedKeys.length,
                    metadataKeys.length,
                    string.concat("Should have ", Strings.toString(keyCount), " metadata keys")
                );

                // Verify all keys are stored
                for (uint256 i = 0; i < metadataKeys.length; i++) {
                    bool found = false;
                    for (uint256 j = 0; j < storedKeys.length; j++) {
                        if (keccak256(bytes(storedKeys[j])) == keccak256(bytes(metadataKeys[i]))) {
                            found = true;
                            break;
                        }
                    }
                    assertTrue(found, string.concat("Metadata key ", metadataKeys[i], " should be stored"));
                }
            } else {
                // Should fail for exceeding max
                bytes memory encodedData = prepareDataSetForClient(sp1, client, metadataKeys, metadataValues);
                vm.prank(sp1);
                vm.expectRevert(
                    abi.encodeWithSelector(Errors.TooManyMetadataKeys.selector, MAX_KEYS_PER_DATASET, keyCount)
                );
                mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedData);
            }
        }
    }

    function testDataSetMetaDataWithAllBoundaries() public {
        // Create metadata with max keys, each with max key and value lengths
        uint256[] memory keyCounts = new uint256[](3);
        keyCounts[0] = MAX_KEYS_PER_DATASET - 1; // Just below max
        keyCounts[1] = MAX_KEYS_PER_DATASET; // At max
        keyCounts[2] = MAX_KEYS_PER_DATASET + 4; // Exceeds max

        for (uint256 testIdx = 0; testIdx < keyCounts.length; testIdx++) {
            uint256 keyCount = keyCounts[testIdx];
            string[] memory metadataKeys = new string[](keyCount);
            string[] memory metadataValues = new string[](keyCount);

            for (uint256 i = 0; i < keyCount; i++) {
                //key must be unique with length 32 bytes
                metadataKeys[i] = _generateKey(i);
                assertEq(bytes(metadataKeys[i]).length, 32, "Key length should be 32 bytes");
                // Max key and value lengths
                metadataValues[i] = _makeStringOfLength(MAX_VALUE_LENGTH);
            }

            if (keyCount <= MAX_KEYS_PER_DATASET) {
                // Should succeed for valid counts
                uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

                // Verify all metadata keys and values
                for (uint256 i = 0; i < metadataKeys.length; i++) {
                    (bool exists, string memory storedMetadata) =
                        viewContract.getDataSetMetadata(dataSetId, metadataKeys[i]);
                    assertTrue(exists, string.concat("Key ", metadataKeys[i], " should exist"));
                    assertEq(
                        storedMetadata,
                        metadataValues[i],
                        string.concat("Stored metadata for ", metadataKeys[i], " should match")
                    );
                }
            } else {
                // Should fail for exceeding max
                bytes memory encodedData = prepareDataSetForClient(sp1, client, metadataKeys, metadataValues);
                vm.prank(sp1);
                vm.expectRevert(
                    abi.encodeWithSelector(Errors.TooManyMetadataKeys.selector, MAX_KEYS_PER_DATASET, keyCount)
                );
                mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedData);
            }
        }
    }

    function testPieceMetadataKeyLengthBoundaries() public {
        uint256 pieceId = 42;

        // Test key lengths: just below max (31), at max (32), and exceeding max (33)
        uint256[] memory keyLengths = new uint256[](3);
        keyLengths[0] = 31; // Just below max
        keyLengths[1] = 32; // At max
        keyLengths[2] = 33; // Exceeds max

        for (uint256 i = 0; i < keyLengths.length; i++) {
            uint256 keyLength = keyLengths[i];
            string[] memory keys = new string[](1);
            string[] memory values = new string[](1);
            keys[0] = _makeStringOfLength(keyLength);
            values[0] = "dog.jpg";

            // Create dataset
            (string[] memory metadataKeys, string[] memory metadataValues) =
                _getSingleMetadataKV("label", "Test Root Metadata");
            uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

            Cids.Cid[] memory pieceData = new Cids.Cid[](1);
            pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

            // Convert to per-piece format
            string[][] memory allKeys = new string[][](1);
            string[][] memory allValues = new string[][](1);
            allKeys[0] = keys;
            allValues[0] = values;
            bytes memory encodedData = abi.encode(pieceId + i + 3000, allKeys, allValues, FAKE_SIGNATURE);

            if (keyLength <= 32) {
                // Should succeed for valid lengths
                vm.expectEmit(true, false, false, true);
                emit FWSSDataSetModule.PieceAdded(dataSetId, pieceId + i, pieceData[0], keys, values);

                vm.prank(address(mockPDPVerifier));
                FWSSDataSetModule(address(pdpServiceWithPayments))
                    .piecesAdded(dataSetId, pieceId + i, pieceData, encodedData);
            } else {
                // Should fail for exceeding max
                vm.expectRevert(abi.encodeWithSelector(Errors.MetadataKeyExceedsMaxLength.selector, 0, 32, keyLength));
                vm.prank(address(mockPDPVerifier));
                FWSSDataSetModule(address(pdpServiceWithPayments))
                    .piecesAdded(dataSetId, pieceId + i, pieceData, encodedData);
            }
        }
    }

    function testPieceMetadataValueLengthBoundaries() public {
        uint256 pieceId = 42;

        // Test value lengths: just below max, at max, and exceeding max
        uint256[] memory valueLengths = new uint256[](3);
        valueLengths[0] = MAX_VALUE_LENGTH - 1; // Just below max
        valueLengths[1] = MAX_VALUE_LENGTH; // At max
        valueLengths[2] = MAX_VALUE_LENGTH + 1; // Exceeds max

        for (uint256 i = 0; i < valueLengths.length; i++) {
            uint256 valueLength = valueLengths[i];
            string[] memory keys = new string[](1);
            string[] memory values = new string[](1);
            keys[0] = "filename";
            values[0] = _makeStringOfLength(valueLength);

            // Create dataset
            (string[] memory metadataKeys, string[] memory metadataValues) =
                _getSingleMetadataKV("label", "Test Root Metadata");
            uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

            Cids.Cid[] memory pieceData = new Cids.Cid[](1);
            pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

            // Convert to per-piece format
            string[][] memory allKeys = new string[][](1);
            string[][] memory allValues = new string[][](1);
            allKeys[0] = keys;
            allValues[0] = values;
            bytes memory encodedData = abi.encode(pieceId + i + 4000, allKeys, allValues, FAKE_SIGNATURE);

            if (valueLength <= MAX_VALUE_LENGTH) {
                // Should succeed for valid lengths
                vm.expectEmit(true, false, false, true);
                emit FWSSDataSetModule.PieceAdded(dataSetId, pieceId + i, pieceData[0], keys, values);

                vm.prank(address(mockPDPVerifier));
                FWSSDataSetModule(address(pdpServiceWithPayments))
                    .piecesAdded(dataSetId, pieceId + i, pieceData, encodedData);
            } else {
                // Should fail for exceeding max
                vm.expectRevert(
                    abi.encodeWithSelector(
                        Errors.MetadataValueExceedsMaxLength.selector, 0, MAX_VALUE_LENGTH, valueLength
                    )
                );
                vm.prank(address(mockPDPVerifier));
                FWSSDataSetModule(address(pdpServiceWithPayments))
                    .piecesAdded(dataSetId, pieceId + i, pieceData, encodedData);
            }
        }
    }

    function testPieceMetadataKeyCountBoundaries() public {
        uint256 pieceId = 42;

        // Test key counts: just below max, at max, and exceeding max
        uint256[] memory keyCounts = new uint256[](3);
        keyCounts[0] = MAX_KEYS_PER_PIECE - 1; // Just below max
        keyCounts[1] = MAX_KEYS_PER_PIECE; // At max
        keyCounts[2] = MAX_KEYS_PER_PIECE + 1; // Exceeds max

        for (uint256 testIdx = 0; testIdx < keyCounts.length; testIdx++) {
            uint256 keyCount = keyCounts[testIdx];
            string[] memory keys = new string[](keyCount);
            string[] memory values = new string[](keyCount);

            for (uint256 i = 0; i < keyCount; i++) {
                keys[i] = string.concat("key", Strings.toString(i));
                values[i] = string.concat("value", Strings.toString(i));
            }

            // Create dataset
            (string[] memory metadataKeys, string[] memory metadataValues) =
                _getSingleMetadataKV("label", "Test Root Metadata");
            uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

            Cids.Cid[] memory pieceData = new Cids.Cid[](1);
            pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

            // Convert to per-piece format
            string[][] memory allKeys = new string[][](1);
            string[][] memory allValues = new string[][](1);
            allKeys[0] = keys;
            allValues[0] = values;
            bytes memory encodedData = abi.encode(pieceId + testIdx + 5000, allKeys, allValues, FAKE_SIGNATURE);

            if (keyCount <= MAX_KEYS_PER_PIECE) {
                // Should succeed for valid counts
                vm.expectEmit(true, false, false, true);
                emit FWSSDataSetModule.PieceAdded(dataSetId, pieceId + testIdx, pieceData[0], keys, values);

                vm.prank(address(mockPDPVerifier));
                FWSSDataSetModule(address(pdpServiceWithPayments))
                    .piecesAdded(dataSetId, pieceId + testIdx, pieceData, encodedData);
            } else {
                // Should fail for exceeding max
                vm.expectRevert(
                    abi.encodeWithSelector(Errors.TooManyMetadataKeys.selector, MAX_KEYS_PER_PIECE, keyCount)
                );
                vm.prank(address(mockPDPVerifier));
                FWSSDataSetModule(address(pdpServiceWithPayments))
                    .piecesAdded(dataSetId, pieceId + testIdx, pieceData, encodedData);
            }
        }
    }

    function testPieceMetadataAllBoundaries() public {
        uint256 pieceId = 42;

        // Helper to create a dataset
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Parameters
        uint256 totalPieces = 5;

        // --- Phase 1: all pieces within limits ---
        {
            Cids.Cid[] memory pieceData = new Cids.Cid[](totalPieces);
            string[][] memory allKeys = new string[][](totalPieces);
            string[][] memory allValues = new string[][](totalPieces);

            for (uint256 p = 0; p < totalPieces; p++) {
                pieceData[p] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file", Strings.toString(p))));

                uint256 keyCount = MAX_KEYS_PER_PIECE; // at the limit
                string[] memory keys = new string[](keyCount);
                string[] memory values = new string[](keyCount);

                for (uint256 k = 0; k < keyCount; k++) {
                    // Generate globally unique keys by combining piece index and key index
                    keys[k] = _generateKey(p * 1000 + k);
                    assertEq(bytes(keys[k]).length, 32, "Key length should be 32 bytes");
                    values[k] = _makeStringOfLength(MAX_VALUE_LENGTH);
                }

                allKeys[p] = keys;
                allValues[p] = values;
            }

            uint256 nonce = pieceId + 1000;
            bytes memory encodedData = abi.encode(nonce, allKeys, allValues, FAKE_SIGNATURE);
            // Expect success
            vm.expectEmit(true, false, false, true);
            emit FWSSDataSetModule.PieceAdded(dataSetId, pieceId, pieceData[0], allKeys[0], allValues[0]);

            vm.prank(address(mockPDPVerifier));
            FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, pieceId, pieceData, encodedData);
            console.log("encodedData length (within limits):", encodedData.length);
        }

        // --- Phase 2: one piece exceeds key limit and must revert ---
        {
            Cids.Cid[] memory pieceData = new Cids.Cid[](totalPieces);
            string[][] memory allKeys = new string[][](totalPieces);
            string[][] memory allValues = new string[][](totalPieces);

            for (uint256 p = 0; p < totalPieces; p++) {
                pieceData[p] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file-ex", Strings.toString(p))));

                // Make the last piece exceed the per-piece key limit
                uint256 keyCount = (p == totalPieces - 1) ? (MAX_KEYS_PER_PIECE + 1) : MAX_KEYS_PER_PIECE;
                string[] memory keys = new string[](keyCount);
                string[] memory values = new string[](keyCount);

                for (uint256 k = 0; k < keyCount; k++) {
                    // Ensure uniqueness across all pieces
                    keys[k] = _generateKey(p * 1000 + k + 1);
                    values[k] = _makeStringOfLength(MAX_VALUE_LENGTH);
                }

                allKeys[p] = keys;
                allValues[p] = values;
            }

            uint256 nonce = pieceId + 2000;
            bytes memory encodedData = abi.encode(nonce, allKeys, allValues, FAKE_SIGNATURE);

            // Expect revert when at least one piece has too many keys
            vm.prank(address(mockPDPVerifier));
            vm.expectRevert(
                abi.encodeWithSelector(Errors.TooManyMetadataKeys.selector, MAX_KEYS_PER_PIECE, MAX_KEYS_PER_PIECE + 1)
            );
            FWSSDataSetModule(address(pdpServiceWithPayments))
                .piecesAdded(dataSetId, pieceId + totalPieces, pieceData, encodedData);
            console.log("encodedData length (exceeding limits):", encodedData.length);
        }
    }

    function testPieceMetadataCannotBeAddedByNonPDPVerifier() public {
        uint256 pieceId = 42;

        // Set metadata for the piece
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";

        setupDataSetWithPieceMetadata(pieceId, keys, values, FAKE_SIGNATURE, address(this));
    }

    function testPieceMetadataRejectsDuplicateKeys() public {
        uint256 pieceId = 42;
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "filename";
        values[1] = "cat.jpg";

        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

        string[][] memory allKeys = new string[][](1);
        string[][] memory allValues = new string[][](1);
        allKeys[0] = keys;
        allValues[0] = values;
        bytes memory encodedData = abi.encode(pieceId + 6000, allKeys, allValues, FAKE_SIGNATURE);

        vm.expectRevert(abi.encodeWithSelector(Errors.DuplicateMetadataKey.selector, dataSetId, keys[1]));
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, pieceId, pieceData, encodedData);
    }

    function testPieceMetadataCannotBeCalledWithMoreValues() public {
        uint256 pieceId = 42;

        // Set metadata for the piece with more values than keys
        string[] memory keys = new string[](2);
        string[] memory values = new string[](3); // One extra value

        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";
        values[2] = "extraValue"; // Extra value

        // Create dataset first
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

        // Convert to per-piece format with mismatched arrays
        string[][] memory allKeys = new string[][](1);
        string[][] memory allValues = new string[][](1);
        allKeys[0] = keys;
        allValues[0] = values;

        // Encode extraData with mismatched keys/values
        bytes memory encodedData = abi.encode(pieceId + 6000, allKeys, allValues, FAKE_SIGNATURE);

        // Expect revert due to key/value mismatch
        vm.expectRevert(
            abi.encodeWithSelector(Errors.MetadataKeyAndValueLengthMismatch.selector, keys.length, values.length)
        );
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, pieceId, pieceData, encodedData);
    }

    function testPieceMetadataCannotBeCalledWithMoreKeys() public {
        uint256 pieceId = 42;

        // Set metadata for the piece with more keys than values
        string[] memory keys = new string[](3); // One extra key
        string[] memory values = new string[](2);

        keys[0] = "filename";
        values[0] = "dog.jpg";
        keys[1] = "contentType";
        values[1] = "image/jpeg";
        keys[2] = "extraKey"; // Extra key

        // Create dataset first
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

        // Convert to per-piece format with mismatched arrays
        string[][] memory allKeys = new string[][](1);
        string[][] memory allValues = new string[][](1);
        allKeys[0] = keys;
        allValues[0] = values;

        // Encode extraData with mismatched keys/values
        bytes memory encodedData = abi.encode(pieceId + 7000, allKeys, allValues, FAKE_SIGNATURE);

        // Expect revert due to key/value mismatch
        vm.expectRevert(
            abi.encodeWithSelector(Errors.MetadataKeyAndValueLengthMismatch.selector, keys.length, values.length)
        );
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, pieceId, pieceData, encodedData);
    }

    function testPieceMetadataPerPieceDifferentMetadata() public {
        // Test different metadata for multiple pieces
        uint256 firstPieceId = 100;
        uint256 numPieces = 3;

        // Create dataset
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Create multiple pieces with different metadata
        Cids.Cid[] memory pieceData = new Cids.Cid[](numPieces);
        for (uint256 i = 0; i < numPieces; i++) {
            pieceData[i] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file", i)));
        }

        // Prepare different metadata for each piece
        string[][] memory allKeys = new string[][](numPieces);
        string[][] memory allValues = new string[][](numPieces);

        // Piece 0: filename and contentType
        allKeys[0] = new string[](2);
        allValues[0] = new string[](2);
        allKeys[0][0] = "filename";
        allValues[0][0] = "document.pdf";
        allKeys[0][1] = "contentType";
        allValues[0][1] = "application/pdf";

        // Piece 1: filename, size, and compression
        allKeys[1] = new string[](3);
        allValues[1] = new string[](3);
        allKeys[1][0] = "filename";
        allValues[1][0] = "image.jpg";
        allKeys[1][1] = "size";
        allValues[1][1] = "1024000";
        allKeys[1][2] = "compression";
        allValues[1][2] = "jpeg";

        // Piece 2: just filename
        allKeys[2] = new string[](1);
        allValues[2] = new string[](1);
        allKeys[2][0] = "filename";
        allValues[2][0] = "data.json";

        bytes memory encodedData = abi.encode(firstPieceId + 2000, allKeys, allValues, FAKE_SIGNATURE);

        // Expect events for each piece with their specific metadata
        vm.expectEmit(true, false, false, true);
        emit FWSSDataSetModule.PieceAdded(dataSetId, firstPieceId, pieceData[0], allKeys[0], allValues[0]);
        vm.expectEmit(true, false, false, true);
        emit FWSSDataSetModule.PieceAdded(dataSetId, firstPieceId + 1, pieceData[1], allKeys[1], allValues[1]);
        vm.expectEmit(true, false, false, true);
        emit FWSSDataSetModule.PieceAdded(dataSetId, firstPieceId + 2, pieceData[2], allKeys[2], allValues[2]);

        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, firstPieceId, pieceData, encodedData);

        for (uint256 i = 0; i < numPieces; i++) {
            assertEq(
                _legacyPieceMetadataKeysLength(dataSetId, firstPieceId + i),
                0,
                "New piece metadata must not be stored on-chain"
            );
            for (uint256 j = 0; j < allKeys[i].length; j++) {
                assertEq(
                    _legacyPieceMetadataValue(dataSetId, firstPieceId + i, allKeys[i][j]),
                    "",
                    "New piece metadata values must not be stored on-chain"
                );
            }
        }
    }

    function testEmptyStringMetadata() public {
        // Create data set with empty string metadata
        string[] memory metadataKeys = new string[](2);
        metadataKeys[0] = "withCDN";
        metadataKeys[1] = "description";

        string[] memory metadataValues = new string[](2);
        metadataValues[0] = ""; // Empty string for withCDN
        metadataValues[1] = "Test dataset"; // Non-empty for description

        // Create dataset using the helper function
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Test that empty string is stored and retrievable
        (bool existsCDN, string memory withCDN) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertTrue(existsCDN, "withCDN key should exist");
        assertEq(withCDN, "", "Empty string should be stored and retrievable");

        // Test that non-existent key returns false
        (bool existsNonExistent, string memory nonExistent) =
            viewContract.getDataSetMetadata(dataSetId, "nonExistentKey");
        assertFalse(existsNonExistent, "Non-existent key should not exist");
        assertEq(nonExistent, "", "Non-existent key returns empty string");

        // Distinguish between these two cases:
        // - Empty value: exists=true, value=""
        // - Non-existent: exists=false, value=""

        // Also test for piece metadata with empty strings
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("test_piece_1")));

        string[] memory pieceKeys = new string[](2);
        pieceKeys[0] = "filename";
        pieceKeys[1] = "contentType";

        string[] memory pieceValues = new string[](2);
        pieceValues[0] = ""; // Empty filename
        pieceValues[1] = "application/octet-stream";

        makeSignaturePass(client);
        uint256 pieceId = 0; // First piece in this dataset
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            pieceId,
            pieces,
            1,
            FAKE_SIGNATURE,
            pieceKeys,
            pieceValues
        );
    }

    function testPieceMetadataArrayMismatchErrors() public {
        uint256 pieceId = 42;

        // Create dataset
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Create 2 pieces
        Cids.Cid[] memory pieceData = new Cids.Cid[](2);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file1")));
        pieceData[1] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file2")));

        // Test case 1: Wrong number of key arrays (only 1 for 2 pieces)
        string[][] memory wrongKeys = new string[][](1);
        string[][] memory correctValues = new string[][](2);
        wrongKeys[0] = new string[](1);
        wrongKeys[0][0] = "filename";
        correctValues[0] = new string[](1);
        correctValues[0][0] = "file1.txt";
        correctValues[1] = new string[](1);
        correctValues[1][0] = "file2.txt";

        bytes memory encodedData1 = abi.encode(pieceId + 9000, wrongKeys, correctValues, FAKE_SIGNATURE);

        vm.expectRevert(abi.encodeWithSelector(Errors.MetadataArrayCountMismatch.selector, 1, 2));
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, pieceId, pieceData, encodedData1);

        // Test case 2: Wrong number of value arrays (only 1 for 2 pieces)
        string[][] memory correctKeys = new string[][](2);
        string[][] memory wrongValues = new string[][](1);
        correctKeys[0] = new string[](1);
        correctKeys[0][0] = "filename";
        correctKeys[1] = new string[](1);
        correctKeys[1][0] = "filename";
        wrongValues[0] = new string[](1);
        wrongValues[0][0] = "file1.txt";

        bytes memory encodedData2 = abi.encode(pieceId + 9001, correctKeys, wrongValues, FAKE_SIGNATURE);

        vm.expectRevert(abi.encodeWithSelector(Errors.MetadataArrayCountMismatch.selector, 1, 2));
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, pieceId, pieceData, encodedData2);
    }

    function testPieceMetadataEmptyMetadataForAllPieces() public {
        uint256 firstPieceId = 200;
        uint256 numPieces = 2;

        // Create dataset
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Create multiple pieces with no metadata
        Cids.Cid[] memory pieceData = new Cids.Cid[](numPieces);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file1")));
        pieceData[1] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file2")));

        // Create empty metadata arrays for each piece
        string[][] memory allKeys = new string[][](numPieces); // Empty arrays
        string[][] memory allValues = new string[][](numPieces); // Empty arrays

        bytes memory encodedData = abi.encode(firstPieceId + 8000, allKeys, allValues, FAKE_SIGNATURE);

        // Expect events with empty metadata arrays
        vm.expectEmit(true, false, false, true);
        emit FWSSDataSetModule.PieceAdded(dataSetId, firstPieceId, pieceData[0], allKeys[0], allValues[0]);
        vm.expectEmit(true, false, false, true);
        emit FWSSDataSetModule.PieceAdded(dataSetId, firstPieceId + 1, pieceData[1], allKeys[1], allValues[1]);

        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, firstPieceId, pieceData, encodedData);
    }

    function testPieceMetadataCompactEmptyMetadataForAllPieces() public {
        uint256 firstPieceId = 300;
        uint256 numPieces = 2;

        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        Cids.Cid[] memory pieceData = new Cids.Cid[](numPieces);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("compact-file1")));
        pieceData[1] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("compact-file2")));

        string[][] memory allKeys = new string[][](0);
        string[][] memory allValues = new string[][](0);
        string[] memory emptyMetadata = new string[](0);
        bytes memory encodedData = abi.encode(firstPieceId + 8000, allKeys, allValues, FAKE_SIGNATURE);

        vm.expectEmit(true, false, false, true);
        emit FWSSDataSetModule.PieceAdded(dataSetId, firstPieceId, pieceData[0], emptyMetadata, emptyMetadata);
        vm.expectEmit(true, false, false, true);
        emit FWSSDataSetModule.PieceAdded(dataSetId, firstPieceId + 1, pieceData[1], emptyMetadata, emptyMetadata);

        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, firstPieceId, pieceData, encodedData);

        assertEq(
            _legacyPieceMetadataKeysLength(dataSetId, firstPieceId), 0, "Piece 0 metadata must not be stored on-chain"
        );
        assertEq(
            _legacyPieceMetadataKeysLength(dataSetId, firstPieceId + 1),
            0,
            "Piece 1 metadata must not be stored on-chain"
        );
    }

    function testPieceMetadataCompactEmptyMetadataRequiresBothArraysEmpty() public {
        uint256 firstPieceId = 400;
        uint256 numPieces = 2;

        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        Cids.Cid[] memory pieceData = new Cids.Cid[](numPieces);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("asymmetric-file1")));
        pieceData[1] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("asymmetric-file2")));

        string[][] memory emptyMetadata = new string[][](0);
        string[][] memory perPieceMetadata = new string[][](numPieces);

        bytes memory encodedData = abi.encode(firstPieceId + 8000, emptyMetadata, perPieceMetadata, FAKE_SIGNATURE);
        vm.expectRevert(abi.encodeWithSelector(Errors.MetadataArrayCountMismatch.selector, 0, numPieces));
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, firstPieceId, pieceData, encodedData);

        encodedData = abi.encode(firstPieceId + 8001, perPieceMetadata, emptyMetadata, FAKE_SIGNATURE);
        vm.expectRevert(abi.encodeWithSelector(Errors.MetadataArrayCountMismatch.selector, 0, numPieces));
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, firstPieceId, pieceData, encodedData);
    }

    function testCreateDataSetWithCDN_VerifyDefaultBehavior() public {
        // Test that CDN datasets now have lockup values: 0.7 USDFC for CDN, 0.3 USDFC for cache-miss
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");

        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            clientDataSetId: 0,
            payer: client,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        uint256 depositAmount = LIFECYCLE_RESERVE_TARGET + 1e18 + defaultTotalCDNLockup;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Expect CDNPaymentRailsToppedUp event when creating the data set with CDN enabled
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            1, defaultCDNLockup, defaultCDNLockup, defaultCacheMissLockup, defaultCacheMissLockup
        );

        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);
        vm.stopPrank();

        // Verify CDN rails were created with default zero lockup
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        assertTrue(dataSet.cacheMissRailId > 0, "Cache Miss Rail ID should be non-zero");
        assertTrue(dataSet.cdnRailId > 0, "CDN Rail ID should be non-zero");

        // Verify lockup amounts are set to the expected values
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(dataSet.cacheMissRailId);
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(dataSet.cdnRailId);
        assertEq(cacheMissRail.lockupFixed, defaultCacheMissLockup, "Cache miss lockup should be 0.3 USDFC");
        assertEq(cdnRail.lockupFixed, defaultCDNLockup, "CDN lockup should be 0.7 USDFC");
        // Verify that CDN rails have no validator
        assertEq(cacheMissRail.validator, address(0), "Cache miss rail should have no validator");
        assertEq(cdnRail.validator, address(0), "CDN rail should have no validator");
    }

    function testCreateDataSetWithCDN_EmitsCDNPaymentRailsToppedUp() public {
        // Test that creating a dataset with CDN enabled emits CDNPaymentRailsToppedUp event
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");

        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            clientDataSetId: 0,
            payer: client,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        uint256 depositAmount = LIFECYCLE_RESERVE_TARGET + 1e18 + defaultTotalCDNLockup;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Expect the CDNPaymentRailsToppedUp event with correct parameters
        // Event signature: CDNPaymentRailsToppedUp(uint256 indexed dataSetId, uint256 cdnAmountAdded, uint256 totalCdnLockup, uint256 cacheMissAmountAdded, uint256 totalCacheMissLockup)
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            1, // dataSetId will be 1 (first dataset created)
            defaultCDNLockup, // CDN amount added (0.7 USDFC)
            defaultCDNLockup, // Total CDN lockup (0.7 USDFC)
            defaultCacheMissLockup, // Cache miss amount added (0.3 USDFC)
            defaultCacheMissLockup // Total cache miss lockup (0.3 USDFC)
        );

        // Create the dataset
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);
        vm.stopPrank();

        // Verify the dataset was created with CDN rails
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        assertTrue(dataSet.cacheMissRailId > 0, "Cache Miss Rail ID should be non-zero");
        assertTrue(dataSet.cdnRailId > 0, "CDN Rail ID should be non-zero");
    }

    function testCreateDataSetWithoutCDN_NoCDNPaymentRailsToppedUpEvent() public {
        // Test that creating a dataset without CDN does not emit CDNPaymentRailsToppedUp event
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);

        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            clientDataSetId: 0,
            payer: client,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            signature: FAKE_SIGNATURE
        });

        extraData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        uint256 depositAmount = 10e18;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Record logs to verify CDNPaymentRailsToppedUp event is NOT emitted
        vm.recordLogs();

        // Create the dataset
        makeSignaturePass(client);
        vm.startPrank(serviceProvider);
        uint256 newDataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), extraData);
        vm.stopPrank();

        // Check that CDNPaymentRailsToppedUp event was NOT emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 cdnEventSignature = keccak256("CDNPaymentRailsToppedUp(uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(
                logs[i].topics[0], cdnEventSignature, "CDNPaymentRailsToppedUp should not be emitted without CDN"
            );
        }

        // Verify the dataset was created without CDN rails
        FilecoinWarmStorageService.DataSetInfoView memory dataSet = viewContract.getDataSet(newDataSetId);
        assertEq(dataSet.cacheMissRailId, 0, "Cache Miss Rail ID should be zero");
        assertEq(dataSet.cdnRailId, 0, "CDN Rail ID should be zero");
    }

    function _makeStringOfLength(uint256 len) internal pure returns (string memory s) {
        s = string(_makeBytesOfLength(len));
    }

    function _makeBytesOfLength(uint256 len) internal pure returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = "a";
        }
    }

    /**
     * @notice Regression test for: CDN data set clean up
     * @dev Tests that railToDataSet mappings are properly cleaned up when dataSetDeleted is called
     * This test ensures that the fix prevents rail mapping leaks after dataset deletion
     */
    function testRegression_CDNDataSetCleanup() public {
        console.log("=== Regression Test: CDN Data Set Clean Up Fix ===");

        // Test 1: CDN dataset cleanup
        console.log("1. Testing CDN dataset rail mapping cleanup");
        _testCDNDatasetRailMappingCleanup();

        // Test 2: Non-CDN dataset cleanup
        console.log("2. Testing non-CDN dataset rail mapping cleanup");
        _testNonCDNDatasetRailMappingCleanup();

        // Test 3: Complete dataSetDeleted cleanup verification
        console.log("3. Testing complete dataSetDeleted cleanup verification");
        _testCompleteDataSetDeletedCleanup();

        console.log("=== Regression test completed successfully! ===");
    }

    function _testCDNDatasetRailMappingCleanup() internal {
        // Create a dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, metadataKeys, metadataValues);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Verify CDN rails were created
        assertTrue(info.cacheMissRailId != 0, "Cache miss rail should be created for CDN dataset");
        assertTrue(info.cdnRailId != 0, "CDN rail should be created for CDN dataset");

        // Verify rail mappings exist before deletion
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == dataSetId, "PDP rail mapping should exist");

        // Terminate the service
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Get updated info after termination to get pdpEndEpoch
        info = viewContract.getDataSet(dataSetId);

        // Wait for payment end epoch to elapse
        vm.roll(info.pdpEndEpoch + 1);

        // Settle the rail before deletion
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        payments.settleRail(info.pdpRailId, pdpRail.endEpoch);

        // Call dataSetDeleted to trigger cleanup
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).dataSetDeleted(dataSetId, 10, bytes(""));

        // Verify all rail mappings are cleaned up (this is the fix from issue #269)
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == 0, "PDP rail mapping should be cleaned up");
        assertTrue(
            viewContract.railToDataSet(info.cacheMissRailId) == 0, "Cache miss rail mapping should be cleaned up"
        );
        assertTrue(viewContract.railToDataSet(info.cdnRailId) == 0, "CDN rail mapping should be cleaned up");
    }

    function _testNonCDNDatasetRailMappingCleanup() internal {
        // Create a dataset without CDN
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("label", "test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, metadataKeys, metadataValues);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Verify CDN rails were NOT created
        assertTrue(info.cacheMissRailId == 0, "Cache miss rail should NOT be created for non-CDN dataset");
        assertTrue(info.cdnRailId == 0, "CDN rail should NOT be created for non-CDN dataset");

        // Verify only PDP rail mapping exists before deletion
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == dataSetId, "PDP rail mapping should exist");

        // Terminate the service to set pdpEndEpoch
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Get updated info after termination to get pdpEndEpoch
        info = viewContract.getDataSet(dataSetId);

        // Wait for payment end epoch to elapse
        vm.roll(info.pdpEndEpoch + 1);

        // Settle the rail before deletion
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        payments.settleRail(info.pdpRailId, pdpRail.endEpoch);

        // Call dataSetDeleted to trigger cleanup
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).dataSetDeleted(dataSetId, 10, bytes(""));

        // Verify PDP rail mapping is cleaned up
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == 0, "PDP rail mapping should be cleaned up");
    }

    function _testCompleteDataSetDeletedCleanup() internal {
        // Create a dataset with CDN and multiple metadata keys
        string[] memory metadataKeys = new string[](3);
        string[] memory metadataValues = new string[](3);
        metadataKeys[0] = "withCDN";
        metadataValues[0] = "";
        metadataKeys[1] = "label";
        metadataValues[1] = "test-dataset";
        metadataKeys[2] = "description";
        metadataValues[2] = "A test dataset for cleanup verification";

        uint256 dataSetId = createDataSetForClient(serviceProvider, client, metadataKeys, metadataValues);

        // Get initial dataset info
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Verify initial state exists
        assertTrue(info.pdpRailId != 0, "PDP rail should exist");

        // Verify rail mappings exist
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == dataSetId, "PDP rail mapping should exist");

        // Verify metadata exists
        (bool withCDNExists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        (bool labelExists,) = viewContract.getDataSetMetadata(dataSetId, "label");
        (bool descriptionExists,) = viewContract.getDataSetMetadata(dataSetId, "description");
        assertTrue(withCDNExists, "withCDN metadata should exist");
        assertTrue(labelExists, "label metadata should exist");
        assertTrue(descriptionExists, "description metadata should exist");

        // Verify dataset info exists
        assertTrue(viewContract.getDataSet(dataSetId).pdpRailId != 0, "Dataset info should exist");

        // Set up proving state to test cleanup by calling nextProvingPeriod via mock PDP verifier
        // From setUp(): maxProvingPeriod = 2880, challengeWindowSize = 60
        uint256 currentBlock = block.number;
        uint256 firstDeadline = currentBlock + 2880; // maxProvingPeriod
        uint256 validChallengeEpoch = firstDeadline - 60 + 1;

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, validChallengeEpoch, 10, bytes("")
        );

        // Verify proving-related fields have non-zero values before deletion
        uint256 provingDeadlineBefore = viewContract.provingDeadline(dataSetId);
        bool provenThisPeriodBefore = viewContract.provenThisPeriod(dataSetId);
        uint256 provingActivationEpochBefore = viewContract.provingActivationEpoch(dataSetId);

        assertTrue(provingDeadlineBefore != 0, "provingDeadline should be non-zero after nextProvingPeriod");
        assertFalse(provenThisPeriodBefore, "provenThisPeriod should be false after nextProvingPeriod");
        assertTrue(
            provingActivationEpochBefore != 0, "provingActivationEpoch should be non-zero after nextProvingPeriod"
        );

        // Verify client dataset list includes this dataset
        FilecoinWarmStorageService.DataSetInfoView[] memory clientDataSets = viewContract.getClientDataSets(client);
        bool foundInList = false;
        for (uint256 i = 0; i < clientDataSets.length; i++) {
            if (clientDataSets[i].dataSetId == dataSetId) {
                foundInList = true;
                break;
            }
        }
        assertTrue(foundInList, "Dataset should be in client dataset list");

        // Terminate the service
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Get updated info after termination
        info = viewContract.getDataSet(dataSetId);

        // Wait for payment end epoch to elapse plus extra for proving deadline
        (uint64 maxProvingPeriod,,,) = viewContract.getPDPConfig();
        vm.roll(info.pdpEndEpoch + maxProvingPeriod + 1);

        // Settle the rail before deletion
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        payments.settleRail(info.pdpRailId, pdpRail.endEpoch);

        // Call dataSetDeleted to trigger complete cleanup
        vm.prank(address(mockPDPVerifier));
        FWSSDataSetModule(address(pdpServiceWithPayments)).dataSetDeleted(dataSetId, 10, bytes(""));

        // Verify ALL mappings are cleaned up

        // Rail mappings should be cleaned up
        assertTrue(viewContract.railToDataSet(info.pdpRailId) == 0, "PDP rail mapping should be cleaned up");

        // Metadata mappings should be cleaned up
        (bool withCDNExistsAfter,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        (bool labelExistsAfter,) = viewContract.getDataSetMetadata(dataSetId, "label");
        (bool descriptionExistsAfter,) = viewContract.getDataSetMetadata(dataSetId, "description");
        assertFalse(withCDNExistsAfter, "withCDN metadata key should be cleaned up");
        assertFalse(labelExistsAfter, "label metadata key should be cleaned up");
        assertFalse(descriptionExistsAfter, "description metadata key should be cleaned up");

        // Check that metadata values are also cleaned up from storage using internal function
        string memory withCDNValueAfter = pdpServiceWithPayments._getDataSetMetadataValue(dataSetId, "withCDN");
        string memory labelValueAfter = pdpServiceWithPayments._getDataSetMetadataValue(dataSetId, "label");
        string memory descriptionValueAfter = pdpServiceWithPayments._getDataSetMetadataValue(dataSetId, "description");
        assertEq(withCDNValueAfter, "", "withCDN metadata value should be cleaned up from storage");
        assertEq(labelValueAfter, "", "label metadata value should be cleaned up from storage");
        assertEq(descriptionValueAfter, "", "description metadata value should be cleaned up from storage");

        // Proving-related fields should be cleaned up
        assertTrue(viewContract.provingDeadline(dataSetId) == 0, "provingDeadline should be cleaned up");
        assertFalse(viewContract.provenThisPeriod(dataSetId), "provenThisPeriod should be cleaned up");
        assertTrue(viewContract.provingActivationEpoch(dataSetId) == 0, "provingActivationEpoch should be cleaned up");

        // Dataset info should be cleaned up
        FilecoinWarmStorageService.DataSetInfoView memory dataSetInfo = viewContract.getDataSet(dataSetId);
        assertTrue(dataSetInfo.pdpRailId == 0, "pdpRailId should be cleaned up");
        assertTrue(dataSetInfo.cacheMissRailId == 0, "cacheMissRailId should be cleaned up in DataSetInfoView");
        assertTrue(dataSetInfo.cdnRailId == 0, "cdnRailId should be cleaned up in DataSetInfoView");
        assertTrue(dataSetInfo.payer == address(0), "payer should be cleaned up");
        assertTrue(dataSetInfo.payee == address(0), "payee should be cleaned up");
        assertTrue(dataSetInfo.serviceProvider == address(0), "serviceProvider should be cleaned up");
        assertTrue(dataSetInfo.commissionBps == 0, "commissionBps should be cleaned up");
        assertTrue(dataSetInfo.clientDataSetId == 0, "clientDataSetId should be cleaned up");
        assertTrue(dataSetInfo.pdpEndEpoch == 0, "pdpEndEpoch should be cleaned up");
        assertTrue(dataSetInfo.providerId == 0, "providerId should be cleaned up");
        assertTrue(dataSetInfo.dataSetId == dataSetId, "dataSetId should remain unchanged");

        // Client dataset list should not include this dataset
        clientDataSets = viewContract.getClientDataSets(client);
        foundInList = false;
        for (uint256 i = 0; i < clientDataSets.length; i++) {
            if (clientDataSets[i].dataSetId == dataSetId) {
                foundInList = true;
                break;
            }
        }
        assertTrue(!foundInList, "Dataset should be removed from client dataset list");
    }

    function testAddPiecesNonceReplayProtection() public {
        // Setup: Create a dataset
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Nonce Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: client,
            clientDataSetId: 100,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });
        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup approvals and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), 10e18);
        payments.deposit(mockUSDFC, client, 10e18);
        vm.stopPrank();

        // Create dataset
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);

        // Prepare piece data
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("test_piece_1")));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);

        // First add with nonce 1 should succeed
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, pieceData, 1, FAKE_SIGNATURE, keys, values
        );

        // Attempt to reuse nonce 1 should fail
        makeSignaturePass(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, 1));
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, 1, pieceData, 1, FAKE_SIGNATURE, keys, values
        );
    }

    function testAddPiecesNonceIndependentFromFirstAdded() public {
        // Setup: Create a dataset
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Nonce Independence");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: client,
            clientDataSetId: 200,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });
        bytes memory encodedCreateData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup approvals and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), 10e18);
        payments.deposit(mockUSDFC, client, 10e18);
        vm.stopPrank();

        // Create dataset
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId =
            mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedCreateData);

        // Prepare piece data
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("test_piece_1")));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);

        // Use nonce 999 with firstAdded 0 - should succeed
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, pieceData, 999, FAKE_SIGNATURE, keys, values
        );

        // Use nonce 1 with firstAdded 1 - should succeed (nonce != firstAdded is fine)
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, 1, pieceData, 1, FAKE_SIGNATURE, keys, values
        );
    }

    function testAddPiecesNonceUniquePerPayer() public {
        // Setup approvals and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), 20e18);
        payments.deposit(mockUSDFC, client, 20e18);
        vm.stopPrank();

        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Dataset 1");
        FWSSDataSetModule.DataSetCreateData memory createData1 = FWSSDataSetModule.DataSetCreateData({
            payer: client,
            clientDataSetId: 300,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        FWSSDataSetModule.DataSetCreateData memory createData2 = FWSSDataSetModule.DataSetCreateData({
            payer: client,
            clientDataSetId: 301,
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        // Create first dataset
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId1 = mockPDPVerifier.createDataSet(
            PDPListener(address(pdpServiceWithPayments)),
            abi.encode(
                createData1.payer,
                createData1.clientDataSetId,
                createData1.metadataKeys,
                createData1.metadataValues,
                createData1.signature
            )
        );

        // Create second dataset
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId2 = mockPDPVerifier.createDataSet(
            PDPListener(address(pdpServiceWithPayments)),
            abi.encode(
                createData2.payer,
                createData2.clientDataSetId,
                createData2.metadataKeys,
                createData2.metadataValues,
                createData2.signature
            )
        );

        // Prepare piece data
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("test_piece_1")));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);

        // Use nonce 42 on first dataset
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId1, 0, pieceData, 42, FAKE_SIGNATURE, keys, values
        );

        // Attempt to reuse nonce 42 on second dataset (same client) - should fail
        makeSignaturePass(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, 42));
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId2, 0, pieceData, 42, FAKE_SIGNATURE, keys, values
        );
    }

    function testNonceCannotBeReusedAcrossOperations() public {
        // Setup: Approvals and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), 10e18);
        payments.deposit(mockUSDFC, client, 10e18);
        vm.stopPrank();

        // Use nonce 777 to create a dataset
        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Nonce Isolation Test");
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            payer: client,
            clientDataSetId: 777, // This uses nonce 777 in the clientNonces mapping
            metadataKeys: dsKeys,
            metadataValues: dsValues,
            signature: FAKE_SIGNATURE
        });

        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(
            PDPListener(address(pdpServiceWithPayments)),
            abi.encode(
                createData.payer,
                createData.clientDataSetId,
                createData.metadataKeys,
                createData.metadataValues,
                createData.signature
            )
        );

        // Prepare piece data
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("test_piece_1")));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);

        // Attempt to use same nonce (777) for AddPieces - should fail
        makeSignaturePass(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, 777));
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, pieceData, 777, FAKE_SIGNATURE, keys, values
        );

        // Different nonce should work
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, pieceData, 888, FAKE_SIGNATURE, keys, values
        );
    }

    function testDataSetAuthorizerCanBeSetClearedAndRead() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "acl");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        TestDataSetAuthorizer authorizer = new TestDataSetAuthorizer(sessionKeyRegistry);

        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyDataSetPayer.selector, dataSetId, serviceProvider));
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(authorizer));

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDataSetAuthorizer.selector, sessionKey1));
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, sessionKey1);

        vm.expectEmit(true, true, false, true);
        emit FWSSDataSetModule.DataSetAuthorizerSet(dataSetId, address(authorizer));
        vm.prank(client);
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(authorizer));
        assertEq(viewContract.getDataSetAuthorizer(dataSetId), address(authorizer));

        vm.prank(client);
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(0));
        assertEq(viewContract.getDataSetAuthorizer(dataSetId), address(0));
    }

    function testDataSetAuthorizerIsOptionalAndAllowsDelegatedAddPieces() public {
        uint256 clientDataSetId = nextClientDataSetId;
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "acl");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        address bob = address(0xb0b);

        makeSignaturePass(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, bob));
        _addAuthorizerTestPiece(dataSetId, 1);

        TestDataSetAuthorizer authorizer = new TestDataSetAuthorizer(sessionKeyRegistry);
        authorizer.allow(dataSetId, bob);

        vm.prank(client);
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(authorizer));

        makeSignaturePass(bob);
        _addAuthorizerTestPiece(dataSetId, 2);

        // End-to-end with a genuine signature: clear the ecrecover mock and drive the full
        // FWSS -> authorizer -> recoverSigner path through a real vm.sign over the EIP-712 digest.
        vm.clearMockedCalls();
        uint256 signerKey = 0xA11CE;
        address realSigner = vm.addr(signerKey);
        authorizer.allow(dataSetId, realSigner);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("acl_real_sig")));
        string[] memory emptyMeta = new string[](0);
        string[][] memory allKeys = new string[][](1);
        string[][] memory allValues = new string[][](1);
        allKeys[0] = emptyMeta;
        allValues[0] = emptyMeta;

        bytes32 digest = _eip712Digest(
            LibSignatureVerification.addPiecesStructHash(clientDataSetId, 3, pieceData, allKeys, allValues)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            3,
            abi.encodePacked(r, s, v),
            emptyMeta,
            emptyMeta
        );
    }

    function testDataSetAuthorizerTreatsAuthorizedAccountSessionKeysAsAuthorized() public {
        uint256 clientDataSetId = nextClientDataSetId;
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "acl");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        address bob = address(0xb0b);

        TestDataSetAuthorizer authorizer = new TestDataSetAuthorizer(sessionKeyRegistry);
        authorizer.allow(dataSetId, bob);
        vm.prank(client);
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(authorizer));

        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = ADD_PIECES_TYPEHASH;
        vm.prank(bob);
        sessionKeyRegistry.login(sessionKey1, block.timestamp, permissions, "FilecoinWarmStorageServiceTest");

        makeSignaturePass(sessionKey1);
        _addAuthorizerTestPiece(dataSetId, 1);

        permissions[0] = SCHEDULE_PIECE_REMOVALS_TYPEHASH;
        vm.prank(bob);
        sessionKeyRegistry.login(sessionKey2, block.timestamp, permissions, "FilecoinWarmStorageServiceTest");

        // The authorizer returns false for sessionKey2 (wrong permission), so FWSS reverts Unauthorized.
        Cids.Cid[] memory rejectedPieceData = new Cids.Cid[](1);
        rejectedPieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("acl_piece", uint256(2))));
        string[] memory emptyMeta = new string[](0);
        string[][] memory allKeys = new string[][](1);
        string[][] memory allValues = new string[][](1);
        allKeys[0] = emptyMeta;
        allValues[0] = emptyMeta;
        bytes32 rejectedDigest = _eip712Digest(
            LibSignatureVerification.addPiecesStructHash(clientDataSetId, 2, rejectedPieceData, allKeys, allValues)
        );

        makeSignaturePass(sessionKey2);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.Unauthorized.selector, client, ADD_PIECES_TYPEHASH, rejectedDigest, FAKE_SIGNATURE
            )
        );
        _addAuthorizerTestPiece(dataSetId, 2);
    }

    function testDataSetAuthorizerAllowsDelegatedScheduleRemovals() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "acl");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        address bob = address(0xb0b);
        TestDataSetAuthorizer authorizer = new TestDataSetAuthorizer(sessionKeyRegistry);
        authorizer.allow(dataSetId, bob);
        // Once an authorizer is attached it is the sole gate, so the payer must be allowed explicitly.
        authorizer.allow(dataSetId, client);

        vm.prank(client);
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(authorizer));

        makeSignaturePass(client);
        _addAuthorizerTestPiece(dataSetId, 1);

        makeSignaturePass(bob);
        _scheduleAuthorizerTestPieceRemoval(dataSetId);
    }

    function testDataSetAuthorizerRevertBlocksAllWritesIncludingPayer() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "acl");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        RevertingDataSetAuthorizer authorizer = new RevertingDataSetAuthorizer();

        vm.prank(client);
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(authorizer));

        // A delegated signer is rejected: the authorizer is the sole gate and its revert bubbles up.
        makeSignaturePass(sessionKey1);
        vm.expectRevert(bytes("authorizer called"));
        _addAuthorizerTestPiece(dataSetId, 1);

        // The payer is no longer special-cased. Attaching an authorizer delegates every write
        // decision to it, so a reverting authorizer locks out the payer too.
        makeSignaturePass(client);
        vm.expectRevert(bytes("authorizer called"));
        _addAuthorizerTestPiece(dataSetId, 2);
    }

    function testDataSetAuthorizerReceivesOperationDataForEachWrite() public {
        uint256 clientDataSetId = nextClientDataSetId;
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "acl");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        address bob = address(0xb0b);
        OperationDataCheckingAuthorizer authorizer = new OperationDataCheckingAuthorizer(bob);

        vm.prank(client);
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(authorizer));

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("acl_signed_data")));
        (string[] memory pieceKeys, string[] memory pieceValues) = _getSingleMetadataKV("path", "/acl/piece");

        // Authorizer returns false (nonce mismatch), so FWSS reverts with Errors.Unauthorized,
        // distinct from an authorizer that itself reverts (whose revert would bubble up instead).
        string[][] memory addKeys = new string[][](1);
        string[][] memory addValues = new string[][](1);
        addKeys[0] = pieceKeys;
        addValues[0] = pieceValues;
        bytes32 addDigest = _eip712Digest(
            LibSignatureVerification.addPiecesStructHash(clientDataSetId, 99, pieceData, addKeys, addValues)
        );

        authorizer.expectAdd(dataSetId, clientDataSetId, 100, keccak256(pieceData[0].data));
        makeSignaturePass(bob);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Unauthorized.selector, client, ADD_PIECES_TYPEHASH, addDigest, FAKE_SIGNATURE)
        );
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            99,
            FAKE_SIGNATURE,
            pieceKeys,
            pieceValues
        );

        authorizer.expectAdd(dataSetId, clientDataSetId, 99, keccak256(pieceData[0].data));
        makeSignaturePass(bob);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            99,
            FAKE_SIGNATURE,
            pieceKeys,
            pieceValues
        );

        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        authorizer.expectRemoval(dataSetId, clientDataSetId, pieceIds[0]);
        makeSignaturePass(bob);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        authorizer.expectTerminate(dataSetId);
        makeSignaturePass(bob);
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSetId, abi.encode(FAKE_SIGNATURE));
    }

    function testDataSetAuthorizerCanMutateStateDuringAuthorization() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "acl");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);

        StatefulDataSetAuthorizer authorizer = new StatefulDataSetAuthorizer();
        vm.prank(client);
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(authorizer));

        // The authorizer writes to its own storage while deciding. This succeeds only because the
        // authorizer is invoked with a CALL, not a STATICCALL — the old `view` surface would revert.
        makeSignaturePass(client);
        _addAuthorizerTestPiece(dataSetId, 1);
        assertEq(authorizer.callCount(), 1, "authorizer should have mutated state once");

        makeSignaturePass(client);
        _addAuthorizerTestPiece(dataSetId, 2);
        assertEq(authorizer.callCount(), 2, "authorizer state should accumulate across writes");
    }

    function _addAuthorizerTestPiece(uint256 dataSetId, uint256 nonce) internal {
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("acl_piece", nonce)));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, pieceData, nonce, FAKE_SIGNATURE, keys, values
        );
    }

    function _scheduleAuthorizerTestPieceRemoval(uint256 dataSetId) internal {
        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );
    }

    // Wraps an EIP-712 struct hash with the live FWSS domain separator, matching _hashTypedDataV4.
    function _eip712Digest(bytes32 structHash) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            pdpServiceWithPayments.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    /**
     * @notice Test: Dataset deletion reverts if rail is not fully settled
     * @dev Verifies that dataSetDeleted requires rail.settledUpTo >= rail.endEpoch
     */
    function testDataSetDeleted_RevertsIfRailNotSettled() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Terminate the dataset
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Get termination info
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertTrue(info.pdpEndEpoch > 0, "Dataset should be terminated");

        // Advance past the lockup period but DON'T settle the rail
        vm.roll(info.pdpEndEpoch + 1);

        // Get rail info to check settlement status
        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        assertTrue(rail.settledUpTo < rail.endEpoch, "Rail should not be fully settled yet");

        // Attempt to delete - should revert because rail is not settled
        vm.expectRevert(
            abi.encodeWithSelector(Errors.RailNotFullySettled.selector, info.pdpRailId, rail.settledUpTo, rail.endEpoch)
        );
        vm.prank(sp1);
        mockPDPVerifier.deleteDataSet(PDPListener(address(pdpServiceWithPayments)), dataSetId, bytes(""));
    }

    /**
     * @notice Test: Dataset deletion succeeds after rail is fully settled
     * @dev Verifies that dataSetDeleted succeeds when rail.settledUpTo >= rail.endEpoch
     */
    function testDataSetDeleted_SucceedsAfterRailSettled() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Attach an authorizer so we can confirm it is cleared on deletion
        TestDataSetAuthorizer authorizer = new TestDataSetAuthorizer(sessionKeyRegistry);
        vm.prank(client);
        FWSSDataSetModule(address(pdpServiceWithPayments)).setDataSetAuthorizer(dataSetId, address(authorizer));
        assertEq(viewContract.getDataSetAuthorizer(dataSetId), address(authorizer));

        // Start proving so we can settle with validated payments
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        // Submit proof for first period
        vm.roll(challengeEpoch);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        // Terminate the dataset
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Get termination info
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertTrue(info.pdpEndEpoch > 0, "Dataset should be terminated");

        // Advance past the lockup period AND past the last proving period deadline
        // Settlement requires all period deadlines to have passed for unproven periods
        vm.roll(info.pdpEndEpoch + maxProvingPeriod + 1);

        // Settle the rail to completion
        // After full settlement, the rail gets finalized and zeroed out, so we can't access it via getRail()
        FilecoinPayV1.RailView memory railBefore = payments.getRail(info.pdpRailId);
        payments.settleRail(info.pdpRailId, railBefore.endEpoch);

        // Deletion should succeed (rail is either fully settled or finalized)
        vm.prank(sp1);
        mockPDPVerifier.deleteDataSet(PDPListener(address(pdpServiceWithPayments)), dataSetId, bytes(""));

        // Verify dataset is deleted (pdpRailId == 0 indicates deleted/unregistered)
        FilecoinWarmStorageService.DataSetInfoView memory deletedInfo = viewContract.getDataSet(dataSetId);
        assertEq(deletedInfo.pdpRailId, 0, "Dataset should be deleted");
        assertEq(viewContract.getDataSetAuthorizer(dataSetId), address(0), "Authorizer should be cleared on deletion");
    }

    /**
     * @notice Test: Dataset deletion clears pending scheduled piece metadata removals
     * @dev Reproduces the case where removals are scheduled but the dataset is deleted before
     *      the next proving-period callback can process them.
     */
    function testDataSetDeleted_ClearsScheduledPieceMetadataRemovals() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        Cids.Cid[] memory pieceData = new Cids.Cid[](2);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256("piece-0"));
        pieceData[1] = Cids.CommPv2FromDigest(0, 4, keccak256("piece-1"));

        string[] memory pieceMetadataKeys = new string[](1);
        string[] memory pieceMetadataValues = new string[](1);
        pieceMetadataKeys[0] = "filename";
        pieceMetadataValues[0] = "test.bin";

        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            7777,
            FAKE_SIGNATURE,
            pieceMetadataKeys,
            pieceMetadataValues
        );
        _seedLegacyPieceMetadata(dataSetId, 0, pieceMetadataKeys, pieceMetadataValues);
        _seedLegacyPieceMetadata(dataSetId, 1, pieceMetadataKeys, pieceMetadataValues);

        uint256[] memory pieceIds = new uint256[](2);
        pieceIds[0] = 0;
        pieceIds[1] = 1;

        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        assertEq(_scheduledPieceMetadataRemovalsLength(dataSetId), 2, "Removals should be queued before deletion");
        assertEq(
            _scheduledPieceMetadataRemovalAt(dataSetId, 1), 1, "Queued removal element should exist before deletion"
        );

        assertEq(_legacyPieceMetadataKeysLength(dataSetId, 0), 1, "Legacy piece metadata should exist");

        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        vm.roll(info.pdpEndEpoch + 1);

        FilecoinPayV1.RailView memory railBefore = payments.getRail(info.pdpRailId);
        payments.settleRail(info.pdpRailId, railBefore.endEpoch);

        vm.prank(sp1);
        mockPDPVerifier.deleteDataSet(PDPListener(address(pdpServiceWithPayments)), dataSetId, bytes(""));

        assertEq(_scheduledPieceMetadataRemovalsLength(dataSetId), 0, "Queued removals should be cleared on deletion");
        assertEq(
            _scheduledPieceMetadataRemovalAt(dataSetId, 1), 0, "Queued removal element should be cleared on deletion"
        );

        assertEq(_legacyPieceMetadataKeysLength(dataSetId, 0), 0, "Legacy metadata keys should be cleaned up");
        assertEq(_legacyPieceMetadataValue(dataSetId, 0, "filename"), "");
    }

    function setupDataSetWithPieceMetadata(
        uint256 pieceId,
        string[] memory keys,
        string[] memory values,
        bytes memory signature,
        address caller
    ) internal returns (PieceMetadataSetup memory setup) {
        (string[] memory metadataKeys, string[] memory metadataValues) =
            _getSingleMetadataKV("label", "Test Root Metadata");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 4, keccak256(abi.encodePacked("file")));

        // Convert to per-piece format: each piece gets same metadata
        string[][] memory allKeys = new string[][](1);
        string[][] memory allValues = new string[][](1);
        allKeys[0] = keys;
        allValues[0] = values;

        // Encode extraData: (nonce, metadataKeys, metadataValues, signature)
        uint256 nonce = pieceId + 1000; // Use unique nonce based on pieceId
        extraData = abi.encode(nonce, allKeys, allValues, signature);

        if (caller == address(mockPDPVerifier)) {
            vm.expectEmit(true, false, false, true);
            emit FWSSDataSetModule.PieceAdded(dataSetId, pieceId, pieceData[0], keys, values);
        } else {
            // Handle case where caller is not the PDP verifier
            vm.expectRevert(
                abi.encodeWithSelector(Errors.OnlyPDPVerifierAllowed.selector, address(mockPDPVerifier), caller)
            );
        }
        vm.prank(caller);
        FWSSDataSetModule(address(pdpServiceWithPayments)).piecesAdded(dataSetId, pieceId, pieceData, extraData);

        setup = PieceMetadataSetup({dataSetId: dataSetId, pieceId: pieceId, pieceData: pieceData, extraData: extraData});
    }
}
