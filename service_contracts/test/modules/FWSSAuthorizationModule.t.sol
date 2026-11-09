// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {console} from "forge-std/Test.sol";
import {Cids} from "@pdp/Cids.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IFilecoinWarmStorageService} from "../../src/interfaces/IFilecoinWarmStorageService.sol";
import {FWSSDataSetModule} from "../../src/modules/FWSSDataSetModule.sol";
import {DataSetInfoView, DataSetStatus} from "../../src/lib/FWSSViewTypes.sol";
import {Errors} from "../../src/Errors.sol";
import {FWSSProvingModule} from "../../src/modules/FWSSProvingModule.sol";
import {
    ADD_PIECES_BASE_FEE,
    ADD_PIECES_PER_PIECE_FEE,
    CREATE_DATA_SET_FEE,
    DATASET_FEE_PER_MONTH,
    DEFAULT_LOCKUP_PERIOD,
    LIFECYCLE_RESERVE_TARGET,
    REPLENISH_THRESHOLD,
    SCHEDULE_PIECE_REMOVALS_FEE,
    TERMINATE_FEE
} from "../../src/lib/PriceListUSDFC.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";
import {TestDataSetAuthorizer} from "../FilecoinWarmStorageService.t.sol";

contract FWSSAuthorizationModuleTest is FilecoinWarmStorageServiceFixture {
    function createDataSetForServiceProviderTest(address provider, address clientAddress, string memory label)
        internal
        returns (uint256)
    {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", label);
        return createDataSetForClient(provider, clientAddress, keys, values);
    }

    uint256 constant PIECE_HEIGHT = 4;
    uint256 constant PIECE_LEAVES = 1 << PIECE_HEIGHT;
    // Current upstream ceiling from PDPVerifier's PiecesAdded event under the FVM event value limit.
    uint256 constant BATCH_CAP = 41;
    // Fee drained by each full-BATCH_CAP addPieces call (CREATE_DATA_SET_FEE only appears in the first call).
    uint256 constant PER_CALL_DRAIN = ADD_PIECES_BASE_FEE + BATCH_CAP * ADD_PIECES_PER_PIECE_FEE;
    // Full-BATCH_CAP calls that flush safely before the reserve crosses the replenishment threshold.
    uint256 constant NUM_SAFE_CALLS =
        (LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - REPLENISH_THRESHOLD) / PER_CALL_DRAIN;
    // Reserve remaining after createDataSet + NUM_SAFE_CALLS batch addPieces (CREATE_DATA_SET_FEE
    // is folded into the first addPieces flush).
    uint256 constant RESERVE_AFTER_SAFE_ADD_CALLS =
        LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - NUM_SAFE_CALLS * PER_CALL_DRAIN;
    // Complete removal+flush cycles that safely drain SCHEDULE_PIECE_REMOVALS_FEE each before the
    // reserve falls below the replenishment threshold for the next scheduling call.
    uint256 constant NUM_SAFE_REMOVAL_CYCLES =
        (RESERVE_AFTER_SAFE_ADD_CALLS - REPLENISH_THRESHOLD) / SCHEDULE_PIECE_REMOVALS_FEE;

    function testTerminateServiceLifecycle() public {
        console.log("=== Test: Data Set Payment Termination Lifecycle ===");

        // 0. Verify that DataSet with ID 1 is not found
        DataSetStatus status = pdpServiceWithPayments.getDataSetStatus(1);
        assertEq(uint256(status), uint256(DataSetStatus.Inactive), "expected Inactive");

        // 1. Setup: Create a dataset with CDN enabled.
        console.log("1. Setting up: Creating dataset with service provider");

        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "");

        // Prepare data set creation data
        FWSSDataSetModule.DataSetCreateData memory createData = FWSSDataSetModule.DataSetCreateData({
            clientDataSetId: 0,
            metadataKeys: metadataKeys,
            metadataValues: metadataValues,
            payer: client,
            signature: FAKE_SIGNATURE
        });

        bytes memory encodedData = abi.encode(
            createData.payer,
            createData.clientDataSetId,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Setup client payment approval and deposit
        vm.startPrank(client);
        payments.setOperatorApproval(
            mockUSDFC,
            address(pdpServiceWithPayments),
            true,
            1000e18, // rate allowance
            1000e18, // lockup allowance
            365 days // max lockup period
        );
        uint256 depositAmount = 100e18;
        mockUSDFC.approve(address(payments), depositAmount);
        payments.deposit(mockUSDFC, client, depositAmount);
        vm.stopPrank();

        // Create data set
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedData);
        console.log("Created data set with ID:", dataSetId);

        status = pdpServiceWithPayments.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(DataSetStatus.Inactive), "expected Inactive (no pieces yet)");

        // 2. Submit a valid proof.
        console.log("\n2. Starting proving period and submitting proof");
        // Start proving period
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 challengeEpoch = vm.getBlockNumber() + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        assertEq(pdpServiceWithPayments.provingActivationEpoch(dataSetId), vm.getBlockNumber());

        // Warp to challenge window
        uint256 provingDeadline = pdpServiceWithPayments.provingDeadline(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            pdpServiceWithPayments.provenPeriods(
                dataSetId,
                FWSSProvingModule(address(pdpServiceWithPayments)).getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            pdpServiceWithPayments.provenPeriods(
                dataSetId,
                FWSSProvingModule(address(pdpServiceWithPayments)).getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );
        console.log("Proof submitted successfully");

        status = pdpServiceWithPayments.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(DataSetStatus.Active), "expected Active");

        // 3. Terminate payment
        console.log("\n3. Terminating payment rails");
        console.log("Current block:", block.number);
        vm.prank(client); // client terminates
        pdpServiceWithPayments.terminateService(dataSetId);

        // 4. Assertions
        // Check pdpEndEpoch is set
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertTrue(info.pdpEndEpoch > 0, "pdpEndEpoch should be set after termination");
        console.log("PDP termination successful. PDP end epoch:", info.pdpEndEpoch);
        // CDN service persists through the lockup window — metadata and rails still active
        (bool exists, string memory withCDN) = pdpServiceWithPayments.getDataSetMetadata(dataSetId, "withCDN");
        assertTrue(exists, "withCDN metadata should still exist after terminateService");
        assertEq(withCDN, "", "withCDN value should be empty string");
        FilecoinPayV1.RailView memory cdnRailView = payments.getRail(info.cdnRailId);
        assertEq(cdnRailView.endEpoch, 0, "CDN rail should still be active after terminateService");
        FilecoinPayV1.RailView memory cacheMissRailView = payments.getRail(info.cacheMissRailId);
        assertEq(cacheMissRailView.endEpoch, 0, "Cache miss rail should still be active after terminateService");

        // check status remains active (terminated datasets are still Active)
        status = pdpServiceWithPayments.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(DataSetStatus.Active), "expected Active (terminating)");

        // Ensure piecesAdded reverts
        console.log("\n4. Testing operations after termination");
        console.log("Testing piecesAdded - should revert (payment terminated)");
        vm.prank(address(mockPDPVerifier));
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        bytes32 pieceData = hex"010203";
        pieces[0] = Cids.CommPv2FromDigest(0, 4, pieceData);

        bytes memory addPiecesExtraData = abi.encode(FAKE_SIGNATURE, metadataKeys, metadataValues);
        makeSignaturePass(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataSetPaymentAlreadyTerminated.selector, dataSetId));
        pdpServiceWithPayments.piecesAdded(dataSetId, 0, pieces, addPiecesExtraData);
        console.log("[OK] piecesAdded correctly reverted after termination");

        console.log("Testing dataSetDeleted - should revert (in grace period)");
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentRailsNotFinalized.selector, dataSetId, info.pdpEndEpoch));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 10, bytes(""));

        // Wait for payment end epoch to elapse
        console.log("\n5. Rolling past payment end epoch");
        console.log("Current block:", block.number);
        console.log("Rolling to block:", info.pdpEndEpoch + 1);
        vm.roll(info.pdpEndEpoch + 1);

        // check status is still Active as data set is not yet deleted from PDP
        status = pdpServiceWithPayments.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(DataSetStatus.Active), "expected Active (terminating)");

        // Ensure other functions also revert now
        console.log("\n6. Testing operations after payment end epoch");
        // piecesScheduledRemove
        console.log("Testing piecesScheduledRemove - should revert (beyond payment end epoch)");
        vm.prank(address(mockPDPVerifier));
        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        bytes memory scheduleRemoveData = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetPaymentBeyondEndEpoch.selector, dataSetId, info.pdpEndEpoch, block.number
            )
        );
        mockPDPVerifier.piecesScheduledRemove(dataSetId, pieceIds, address(pdpServiceWithPayments), scheduleRemoveData);
        console.log("[OK] piecesScheduledRemove correctly reverted");

        // possessionProven
        console.log("Testing possessionProven - should revert (beyond payment end epoch)");
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetPaymentBeyondEndEpoch.selector, dataSetId, info.pdpEndEpoch, block.number
            )
        );
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, 5);
        console.log("[OK] possessionProven correctly reverted");

        // nextProvingPeriod
        console.log("Testing nextProvingPeriod - should revert (beyond payment end epoch)");
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetPaymentBeyondEndEpoch.selector, dataSetId, info.pdpEndEpoch, block.number
            )
        );
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, block.number + maxProvingPeriod, 100, ""
        );
        console.log("[OK] nextProvingPeriod correctly reverted");

        // Roll past the last period deadline to allow settlement
        vm.roll(info.pdpEndEpoch + maxProvingPeriod + 1);

        // Settle the rail before deletion
        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        payments.settleRail(info.pdpRailId, rail.endEpoch);

        console.log("\n7. Testring dataSetDeleted");
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 10, bytes(""));

        status = pdpServiceWithPayments.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(DataSetStatus.Inactive), "expected Inactive (deleted)");

        // CDN rails terminated in dataSetDeleted
        FilecoinPayV1.RailView memory cdnRailAfter = payments.getRail(info.cdnRailId);
        assertTrue(cdnRailAfter.endEpoch > 0, "CDN rail should be terminated after dataSetDeleted");
        FilecoinPayV1.RailView memory cacheMissRailAfter = payments.getRail(info.cacheMissRailId);
        assertTrue(cacheMissRailAfter.endEpoch > 0, "Cache miss rail should be terminated after dataSetDeleted");

        // withCDN metadata cleared as part of dataset cleanup
        (exists,) = pdpServiceWithPayments.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists, "withCDN metadata should be cleared after dataSetDeleted");

        console.log("\n=== Test completed successfully! ===");
    }

    function testTerminateService_AfterExternalCDNRailTermination() public {
        console.log("=== Test: terminateService after external CDN rail termination ===");

        // 1. Create dataset with CDN
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

        // 2. Externally terminate CDN rails (simulating payer calling FilecoinPayV1.terminateRail directly)
        console.log("Externally terminating CDN rails via FilecoinPayV1...");
        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cacheMissRailId);

        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cdnRailId);

        // Verify CDN rails are terminated
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        assertTrue(cacheMissRail.endEpoch > 0, "Cache miss rail should be terminated");
        assertTrue(cdnRail.endEpoch > 0, "CDN rail should be terminated");

        // 3. Call terminateService - should succeed without reverting
        console.log("Calling terminateService - should succeed...");
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // 4. Verify PDP rail is terminated
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertTrue(pdpRail.endEpoch > 0, "PDP rail should be terminated");

        // 5. CDN metadata persists after terminateService; cleared when dataSetDeleted runs
        (bool exists,) = pdpServiceWithPayments.getDataSetMetadata(dataSetId, "withCDN");
        assertTrue(exists, "withCDN flag should still exist after terminateService");

        // 6. Complete deletion lifecycle and verify metadata is cleared
        DataSetInfoView memory terminatedInfo = pdpServiceWithPayments.getDataSet(dataSetId);
        (uint64 maxProvingPeriod,,,) = pdpServiceWithPayments.getPDPConfig();
        vm.roll(terminatedInfo.pdpEndEpoch + maxProvingPeriod + 1);
        FilecoinPayV1.RailView memory settledPdpRail = payments.getRail(terminatedInfo.pdpRailId);
        payments.settleRail(terminatedInfo.pdpRailId, settledPdpRail.endEpoch);
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 0, bytes(""));
        (bool existsAfter,) = pdpServiceWithPayments.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(existsAfter, "withCDN metadata should be cleared after dataSetDeleted");

        console.log("=== Test completed successfully! ===");
    }

    function testTerminateService_AfterExternalCDNRailFinalization() public {
        console.log("=== Test: terminateService after external CDN rail finalization ===");

        // 1. Create dataset with CDN
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

        // 2. Externally terminate CDN rails (simulating payer calling FilecoinPayV1.terminateRail directly)
        console.log("Externally terminating CDN rails via FilecoinPayV1...");
        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cacheMissRailId);

        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cdnRailId);

        // Verify CDN rails are terminated
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        assertTrue(cacheMissRail.endEpoch > 0, "Cache miss rail should be terminated");
        assertTrue(cdnRail.endEpoch > 0, "CDN rail should be terminated");

        // 3. Settle and finalize CDN rails by advancing past endEpoch and settling
        console.log("Settling CDN rails to finalize them...");
        vm.roll(cacheMissRail.endEpoch + 1);
        payments.settleRail(info.cacheMissRailId, cacheMissRail.endEpoch);
        payments.settleRail(info.cdnRailId, cdnRail.endEpoch);

        // Verify rails are finalized (getRail should revert for finalized rails)
        vm.expectRevert();
        payments.getRail(info.cacheMissRailId);
        vm.expectRevert();
        payments.getRail(info.cdnRailId);

        // 4. Call terminateService - should succeed without reverting
        console.log("Calling terminateService - should succeed...");
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // 5. Verify PDP rail is terminated
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertTrue(pdpRail.endEpoch > 0, "PDP rail should be terminated");

        // 6. CDN metadata persists after terminateService; cleared when dataSetDeleted runs
        (bool exists,) = pdpServiceWithPayments.getDataSetMetadata(dataSetId, "withCDN");
        assertTrue(exists, "withCDN flag should still exist after terminateService");

        // 7. Complete deletion lifecycle and verify metadata is cleared
        DataSetInfoView memory terminatedInfo = pdpServiceWithPayments.getDataSet(dataSetId);
        (uint64 maxProvingPeriod,,,) = pdpServiceWithPayments.getPDPConfig();
        vm.roll(terminatedInfo.pdpEndEpoch + maxProvingPeriod + 1);
        FilecoinPayV1.RailView memory settledPdpRail = payments.getRail(terminatedInfo.pdpRailId);
        payments.settleRail(terminatedInfo.pdpRailId, settledPdpRail.endEpoch);
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 0, bytes(""));
        (bool existsAfter,) = pdpServiceWithPayments.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(existsAfter, "withCDN metadata should be cleared after dataSetDeleted");

        console.log("=== Test completed successfully! ===");
    }

    // ============================================================
    // terminateService extraData / session-key tests
    // ============================================================

    function testTerminateService_signatureApprover() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "sig test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(client);

        vm.expectEmit(true, true, false, true);
        emit IFilecoinWarmStorageService.ServiceTerminated(client, dataSetId, info.pdpRailId, 0, 0);
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSetId, sig);

        assertTrue(pdpServiceWithPayments.getDataSet(dataSetId).pdpEndEpoch > 0, "dataset should be terminated");
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertEq(pdpRail.lockupPeriod, 0, "lockup period should be 0 for immediate termination");
        assertEq(pdpRail.lockupFixed, 0, "lockup fixed should be 0 for immediate termination");

        // With lockupPeriod = 0, endEpoch = block.number — no need to advance blocks
        payments.settleRail(info.pdpRailId, pdpRail.endEpoch);
        vm.prank(serviceProvider);
        mockPDPVerifier.deleteDataSet(PDPListener(address(pdpServiceWithPayments)), dataSetId, "");
        assertEq(pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId, 0, "dataset should be deleted");
    }

    function testTerminateService_extraData_callerNotServiceProvider() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "caller not sp test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);

        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.CallerNotServiceProvider.selector, dataSetId, serviceProvider, client)
        );
        pdpServiceWithPayments.terminateService(dataSetId, sig);
    }

    function testTerminateService_directPayer_emitsApprover() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

        vm.expectEmit(true, true, false, true);
        emit IFilecoinWarmStorageService.ServiceTerminated(client, dataSetId, info.pdpRailId, 0, 0);
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);
    }

    function testTerminateService_directSP_emitsApprover() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

        vm.expectEmit(true, true, false, true);
        emit IFilecoinWarmStorageService.ServiceTerminated(serviceProvider, dataSetId, info.pdpRailId, 0, 0);
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSetId);

        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertEq(
            pdpRail.lockupPeriod,
            DEFAULT_LOCKUP_PERIOD,
            "lockup period should remain DEFAULT_LOCKUP_PERIOD for non-consensual termination"
        );
    }

    function testTerminateService_sessionKey() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "session key test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = TERMINATE_SERVICE_TYPEHASH;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp, permissions, "test");

        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(sessionKey1);

        // approver in event is the session key, not the payer
        vm.expectEmit(true, true, false, true);
        emit IFilecoinWarmStorageService.ServiceTerminated(sessionKey1, dataSetId, info.pdpRailId, 0, 0);
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSetId, sig);

        assertTrue(pdpServiceWithPayments.getDataSet(dataSetId).pdpEndEpoch > 0, "dataset should be terminated");
    }

    function testTerminateService_sessionKey_unauthorizedKey() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);

        // sessionKey2 is not registered at all
        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(sessionKey2);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey2));
        pdpServiceWithPayments.terminateService(dataSetId, sig);
    }

    function testTerminateService_sessionKey_expiredKey() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);

        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = TERMINATE_SERVICE_TYPEHASH;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp, permissions, "test");

        vm.warp(block.timestamp + 1); // one second past expiry

        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(sessionKey1);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey1));
        pdpServiceWithPayments.terminateService(dataSetId, sig);
    }

    function testTerminateService_sessionKey_wrongPermission() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);

        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = CREATE_DATA_SET_TYPEHASH; // not TERMINATE_SERVICE_TYPEHASH
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp, permissions, "test");

        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(sessionKey1);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, client, sessionKey1));
        pdpServiceWithPayments.terminateService(dataSetId, sig);
    }

    function testDataSetAuthorizerAllowsDelegatedTerminateService() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "acl");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        address bob = address(0xb0b);
        TestDataSetAuthorizer authorizer = new TestDataSetAuthorizer(sessionKeyRegistry);
        authorizer.allow(dataSetId, bob);

        vm.prank(client);
        pdpServiceWithPayments.setDataSetAuthorizer(dataSetId, address(authorizer));

        makeSignaturePass(bob);
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSetId, abi.encode(FAKE_SIGNATURE));

        assertGt(pdpServiceWithPayments.getDataSet(dataSetId).pdpEndEpoch, 0);
    }

    function _buildBatch(uint256 n) internal pure returns (Cids.Cid[] memory pieces) {
        pieces = new Cids.Cid[](n);
        for (uint256 i = 0; i < n; i++) {
            pieces[i] = Cids.CommPv2FromDigest(0, uint8(PIECE_HEIGHT), keccak256(abi.encodePacked(i)));
        }
    }

    // Rolls past currentDeadline, calls nextProvingPeriod, and returns the new deadline.
    function _advanceProvingPeriod(uint256 dataSetId, uint256 currentDeadline, uint256 maxPeriod, uint256 leafCount)
        internal
        returns (uint256 newDeadline)
    {
        vm.roll(currentDeadline + 1);
        newDeadline = currentDeadline + maxPeriod;
        (, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, newDeadline - challengeWindow / 2, leafCount, ""
        );
    }

    // Creates a dataset with one piece added and the first proving period initialized.
    // Returns (dataSetId, pdpRailId, leafCount, firstDeadline, maxProvingPeriod).
    // On return: pendingOneTimePayments == 0, lifecycleReserveBalance == LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - ADD_PIECES_BASE_FEE - ADD_PIECES_PER_PIECE_FEE.
    function _createDataSetWithPiece()
        internal
        returns (uint256 dataSetId, uint256 pdpRailId, uint256 leafCount, uint256 firstDeadline, uint256 maxPeriod)
    {
        dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        leafCount = PIECE_LEAVES;

        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, uint8(PIECE_HEIGHT), keccak256("op-fees-piece"));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieces,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            keys,
            values
        );

        uint256 challengeWindow;
        (maxPeriod, challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        firstDeadline = block.number + maxPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstDeadline - challengeWindow / 2, leafCount, ""
        );
    }

    function test_addPiecesFee_immediateFlush() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint256 pdpRailId = info.pdpRailId;

        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET);
        assertEq(info.pendingOneTimePayments, CREATE_DATA_SET_FEE, "create dataset fee pending");

        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, uint8(PIECE_HEIGHT), keccak256("piece0"));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieces,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            keys,
            values
        );

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "fees flushed immediately in piecesAdded");
        assertEq(
            info.lifecycleReserveBalance,
            LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - ADD_PIECES_BASE_FEE - ADD_PIECES_PER_PIECE_FEE,
            "reserve decreased by both fees"
        );

        FilecoinPayV1.RailView memory rail = payments.getRail(pdpRailId);
        assertEq(rail.lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    function test_scheduledRemovalFee_deferredThenFlushed() public {
        (uint256 dataSetId, uint256 pdpRailId,, uint256 firstDeadline, uint256 maxPeriod) = _createDataSetWithPiece();

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint96 reserveBefore = info.lifecycleReserveBalance;

        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, SCHEDULE_PIECE_REMOVALS_FEE, "fee pending, not yet flushed");
        assertEq(info.lifecycleReserveBalance, reserveBefore, "reserve unchanged before flush");

        // nextProvingPeriod processes the removal and flushes the fee
        _advanceProvingPeriod(dataSetId, firstDeadline, maxPeriod, 0);

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "fee flushed");
        assertEq(info.lifecycleReserveBalance, reserveBefore - SCHEDULE_PIECE_REMOVALS_FEE, "reserve decreased by fee");

        FilecoinPayV1.RailView memory rail = payments.getRail(pdpRailId);
        assertEq(rail.lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    function test_multipleRemovalFees_accumulate() public {
        (uint256 dataSetId, uint256 pdpRailId, uint256 leafCount, uint256 firstDeadline, uint256 maxPeriod) =
            _createDataSetWithPiece();

        // Add a second piece
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, uint8(PIECE_HEIGHT), keccak256("piece1"));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            1,
            pieces,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            keys,
            values
        );
        leafCount += PIECE_LEAVES;

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint96 reserveBefore = info.lifecycleReserveBalance;

        // Schedule two separate removal batches
        uint256[] memory ids0 = new uint256[](1);
        ids0[0] = 0;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, ids0, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = 1;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, ids1, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 2 * SCHEDULE_PIECE_REMOVALS_FEE, "both fees accumulated");

        _advanceProvingPeriod(dataSetId, firstDeadline, maxPeriod, 0);

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(info.lifecycleReserveBalance, reserveBefore - 2 * SCHEDULE_PIECE_REMOVALS_FEE);

        FilecoinPayV1.RailView memory rail = payments.getRail(pdpRailId);
        assertEq(rail.lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    function test_addPiecesFee_largeBatch_triggersReplenishment() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");

        uint256 added = 0;
        for (uint256 i = 0; i < NUM_SAFE_CALLS; i++) {
            makeSignaturePass(client);
            mockPDPVerifier.addPieces(
                PDPListener(address(pdpServiceWithPayments)),
                dataSetId,
                added,
                _buildBatch(BATCH_CAP),
                nextClientDataSetId++,
                FAKE_SIGNATURE,
                new string[](0),
                new string[](0)
            );
            added += BATCH_CAP;
        }
        // One more call crosses the threshold and triggers replenishment.
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            added,
            _buildBatch(BATCH_CAP),
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "fees flushed");
        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET, "reserve replenished to target");

        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        assertEq(rail.lockupFixed, LIFECYCLE_RESERVE_TARGET, "lockupFixed reflects replenishment");
    }

    function test_addPiecesFee_largeBatch_revertsInsufficientFunds() public {
        // Client has just enough for safe flushes (lifecycle reserve + 2× dataset fee covers
        // the rate-based lockup from adding pieces) but not enough for replenishment
        // (which needs ≈ LIFECYCLE_RESERVE_TARGET - REPLENISH_THRESHOLD ≈ 0.095 USDFC more).
        address minClient = makeAddr("minClient");
        uint256 minAmount = LIFECYCLE_RESERVE_TARGET + 2 * DATASET_FEE_PER_MONTH;
        require(mockUSDFC.transfer(minClient, minAmount));
        vm.startPrank(minClient);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), minAmount);
        payments.deposit(mockUSDFC, minClient, minAmount);
        vm.stopPrank();

        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        bytes memory encodedData = abi.encode(minClient, nextClientDataSetId++, emptyKeys, emptyValues, FAKE_SIGNATURE);
        makeSignaturePass(minClient);
        vm.prank(sp1);
        uint256 dataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedData);

        uint256 added = 0;
        for (uint256 i = 0; i < NUM_SAFE_CALLS; i++) {
            makeSignaturePass(minClient);
            mockPDPVerifier.addPieces(
                PDPListener(address(pdpServiceWithPayments)),
                dataSetId,
                added,
                _buildBatch(BATCH_CAP),
                nextClientDataSetId++,
                FAKE_SIGNATURE,
                new string[](0),
                new string[](0)
            );
            added += BATCH_CAP;
        }

        makeSignaturePass(minClient);
        vm.expectRevert("invariant failure: insufficient funds to cover lockup after function execution");
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            added,
            _buildBatch(BATCH_CAP),
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );
    }

    function test_addPieces_depleted_reserve_reverts() public {
        address minClient = makeAddr("minClient2");
        uint256 minAmount = LIFECYCLE_RESERVE_TARGET + 2 * DATASET_FEE_PER_MONTH;
        require(mockUSDFC.transfer(minClient, minAmount));
        vm.startPrank(minClient);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), minAmount);
        payments.deposit(mockUSDFC, minClient, minAmount);
        vm.stopPrank();

        bytes memory encodedData =
            abi.encode(minClient, nextClientDataSetId++, new string[](0), new string[](0), FAKE_SIGNATURE);
        makeSignaturePass(minClient);
        vm.prank(sp1);
        uint256 dataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedData);

        uint256 added = 0;
        for (uint256 i = 0; i < NUM_SAFE_CALLS; i++) {
            makeSignaturePass(minClient);
            mockPDPVerifier.addPieces(
                PDPListener(address(pdpServiceWithPayments)),
                dataSetId,
                added,
                _buildBatch(BATCH_CAP),
                nextClientDataSetId++,
                FAKE_SIGNATURE,
                new string[](0),
                new string[](0)
            );
            added += BATCH_CAP;
        }

        assertLt(
            pdpServiceWithPayments.getDataSet(dataSetId).lifecycleReserveBalance,
            REPLENISH_THRESHOLD + PER_CALL_DRAIN,
            "reserve is now below the replenishment trigger for one more batch"
        );

        makeSignaturePass(minClient);
        vm.expectRevert("invariant failure: insufficient funds to cover lockup after function execution");
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            added,
            _buildBatch(BATCH_CAP),
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );
    }

    function test_schedulePieceRemoval_depleted_reserve_reverts_remainingPaid() public {
        address minClient = makeAddr("minClient3");
        uint256 minAmount = LIFECYCLE_RESERVE_TARGET + 2 * DATASET_FEE_PER_MONTH;
        require(mockUSDFC.transfer(minClient, minAmount));
        vm.startPrank(minClient);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), minAmount);
        payments.deposit(mockUSDFC, minClient, minAmount);
        vm.stopPrank();

        bytes memory encodedData =
            abi.encode(minClient, nextClientDataSetId++, new string[](0), new string[](0), FAKE_SIGNATURE);
        makeSignaturePass(minClient);
        vm.prank(sp1);
        uint256 dataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), encodedData);

        // Drain reserve via NUM_SAFE_CALLS batch addPieces.
        uint256 added = 0;
        for (uint256 i = 0; i < NUM_SAFE_CALLS; i++) {
            makeSignaturePass(minClient);
            mockPDPVerifier.addPieces(
                PDPListener(address(pdpServiceWithPayments)),
                dataSetId,
                added,
                _buildBatch(BATCH_CAP),
                nextClientDataSetId++,
                FAKE_SIGNATURE,
                new string[](0),
                new string[](0)
            );
            added += BATCH_CAP;
        }

        // Initialize proving (pending=0, no drain).
        (uint256 maxPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 deadline = block.number + maxPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            deadline - challengeWindow / 2,
            added * PIECE_LEAVES,
            ""
        );

        // NUM_SAFE_REMOVAL_CYCLES - 1 complete removal+flush cycles each safely drain the fee.
        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        for (uint256 i = 0; i < NUM_SAFE_REMOVAL_CYCLES - 1; i++) {
            makeSignaturePass(minClient);
            mockPDPVerifier.piecesScheduledRemove(
                dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
            );
            deadline = _advanceProvingPeriod(dataSetId, deadline, maxPeriod, added * PIECE_LEAVES);
        }

        // One final removal succeeds — reserve still covers it without replenishment.
        makeSignaturePass(minClient);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        // With the unflushed fee in pending, the next removal would push accumulated pending
        // above the replenishment threshold and the payer cannot fund the top-up.
        assertLt(
            pdpServiceWithPayments.getDataSet(dataSetId).lifecycleReserveBalance,
            2 * SCHEDULE_PIECE_REMOVALS_FEE + REPLENISH_THRESHOLD,
            "reserve below trigger for next removal given unflushed pending"
        );
        makeSignaturePass(minClient);
        vm.expectRevert("invariant failure: insufficient funds to cover lockup after function execution");
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        // nextProvingPeriod still succeeds and pays the fee from the last successful removal.
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        uint96 reserveBefore = pdpServiceWithPayments.getDataSet(dataSetId).lifecycleReserveBalance;
        _advanceProvingPeriod(dataSetId, deadline, maxPeriod, added * PIECE_LEAVES);

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "pending flushed");
        assertEq(info.lifecycleReserveBalance, reserveBefore - SCHEDULE_PIECE_REMOVALS_FEE, "fee paid in full");
        assertEq(payments.getRail(pdpRailId).lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    function test_terminateFee_chargedOnConsentCase() public {
        (uint256 dataSetId, uint256 pdpRailId,,,) = _createDataSetWithPiece();

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint96 reserveBefore = info.lifecycleReserveBalance;
        assertEq(
            reserveBefore,
            LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - ADD_PIECES_BASE_FEE - ADD_PIECES_PER_PIECE_FEE
        );
        assertEq(info.pendingOneTimePayments, 0);

        (, uint256 spFundsBefore,,) = payments.getAccountInfoIfSettled(mockUSDFC, sp1);

        // Consent case: payer signs off-chain, SP submits with signature in extraData
        makeSignaturePass(client);
        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId, abi.encode(FAKE_SIGNATURE));

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "fee flushed at termination");
        assertEq(info.lifecycleReserveBalance, 0, "reserve fully released on immediate termination");
        assertEq(payments.getRail(pdpRailId).lockupFixed, 0, "lockupFixed zeroed after fee deducted");

        uint256 networkFee = (TERMINATE_FEE * payments.NETWORK_FEE_NUMERATOR() + payments.NETWORK_FEE_DENOMINATOR() - 1)
            / payments.NETWORK_FEE_DENOMINATOR();
        (, uint256 spFundsAfter,,) = payments.getAccountInfoIfSettled(mockUSDFC, sp1);
        assertEq(
            spFundsAfter - spFundsBefore, TERMINATE_FEE - networkFee, "SP received terminate fee net of network fee"
        );
    }

    function test_terminateFee_notChargedOnPayerDirectCall() public {
        (uint256 dataSetId,,,,) = _createDataSetWithPiece();

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint96 reserveBefore = info.lifecycleReserveBalance;
        (, uint256 spFundsBefore,,) = payments.getAccountInfoIfSettled(mockUSDFC, sp1);
        assertEq(info.pendingOneTimePayments, 0);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        assertEq(
            pdpServiceWithPayments.getDataSet(dataSetId).pendingOneTimePayments, 0, "no fee on payer direct termination"
        );

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.lifecycleReserveBalance, reserveBefore, "reserve unchanged without terminate fee");
        (, uint256 spFundsAfter,,) = payments.getAccountInfoIfSettled(mockUSDFC, sp1);
        assertEq(spFundsAfter, spFundsBefore, "SP funds unchanged without terminate fee");
    }

    function test_terminateFee_notChargedOnSpInitiated() public {
        (uint256 dataSetId,,,,) = _createDataSetWithPiece();

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint96 reserveBefore = info.lifecycleReserveBalance;
        (, uint256 spFundsBefore,,) = payments.getAccountInfoIfSettled(mockUSDFC, sp1);
        assertEq(info.pendingOneTimePayments, 0);

        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId);

        assertEq(
            pdpServiceWithPayments.getDataSet(dataSetId).pendingOneTimePayments, 0, "no fee on SP-initiated termination"
        );

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.lifecycleReserveBalance, reserveBefore, "reserve unchanged without terminate fee");
        (, uint256 spFundsAfter,,) = payments.getAccountInfoIfSettled(mockUSDFC, sp1);
        assertEq(spFundsAfter, spFundsBefore, "SP funds unchanged without terminate fee");
    }

    // TERMINATE_FEE must flush at termination time even when no piece removals are pending.
    function test_terminateFee_flushedWithoutRemovals() public {
        (uint256 dataSetId, uint256 pdpRailId,,,) = _createDataSetWithPiece();

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint96 reserveAfterAdd = info.lifecycleReserveBalance;
        assertEq(
            reserveAfterAdd,
            LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - ADD_PIECES_BASE_FEE - ADD_PIECES_PER_PIECE_FEE
        );

        (, uint256 spFundsBefore,,) = payments.getAccountInfoIfSettled(mockUSDFC, sp1);

        // Consent case: payer signs off-chain, SP submits; no removals scheduled
        makeSignaturePass(client);
        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId, abi.encode(FAKE_SIGNATURE));

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "TERMINATE_FEE flushed at termination");
        assertEq(info.lifecycleReserveBalance, 0, "reserve fully released on immediate termination");

        assertEq(payments.getRail(pdpRailId).lockupFixed, 0, "lockupFixed zeroed after fee deducted");

        uint256 networkFee = (TERMINATE_FEE * payments.NETWORK_FEE_NUMERATOR() + payments.NETWORK_FEE_DENOMINATOR() - 1)
            / payments.NETWORK_FEE_DENOMINATOR();
        (, uint256 spFundsAfter,,) = payments.getAccountInfoIfSettled(mockUSDFC, sp1);
        assertEq(
            spFundsAfter - spFundsBefore, TERMINATE_FEE - networkFee, "SP received terminate fee net of network fee"
        );
    }

    // CREATE_DATA_SET_FEE must be collected even when the dataset is terminated before any proving.
    function test_createTerminate_createFeeFlushes() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, CREATE_DATA_SET_FEE, "create fee pending before termination");
        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "create fee flushed at termination");
        assertEq(
            info.lifecycleReserveBalance,
            LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE,
            "reserve decreased by create fee"
        );
        assertEq(payments.getRail(pdpRailId).lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    function test_topUpLifecycleReserve_nonExistentDataSet_reverts() public {
        uint256 nonExistentId = 9999;
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDataSetId.selector, nonExistentId));
        pdpServiceWithPayments.topUpLifecycleReserve(nonExistentId, 1e18);
    }

    function test_topUpLifecycleReserve_callerNotPayer_reverts() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        address notPayer = makeAddr("notPayer");
        vm.prank(notPayer);
        vm.expectRevert(abi.encodeWithSelector(Errors.CallerNotPayer.selector, dataSetId, client, notPayer));
        pdpServiceWithPayments.topUpLifecycleReserve(dataSetId, 1e18);
    }

    function test_topUpLifecycleReserve_terminated_reverts() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataSetPaymentAlreadyTerminated.selector, dataSetId));
        pdpServiceWithPayments.topUpLifecycleReserve(dataSetId, 1e18);
    }

    // topUpLifecycleReserve must revert rather than silently wrap around and produce a newBalance
    // smaller than lifecycleReserveBalance.
    function test_topUpLifecycleReserve_overflow_reverts() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        uint96 currentBalance = pdpServiceWithPayments.getDataSet(dataSetId).lifecycleReserveBalance;
        // amount chosen so uint96(amount) == amount (no truncation) yet currentBalance + amount overflows uint96
        uint256 amount = uint256(type(uint96).max) - currentBalance + 1;
        vm.prank(client);
        vm.expectRevert(stdError.arithmeticError);
        pdpServiceWithPayments.topUpLifecycleReserve(dataSetId, amount);
    }

    // Post-termination replenishment is disabled; try exhausting the lifecycleReserveBalance and verify that the one time payment succeeds.
    function test_nextProvingPeriod_postTermination_withExhaustedReserve() public {
        (uint256 dataSetId,, uint256 leafCount, uint256 firstDeadline, uint256 maxPeriod) = _createDataSetWithPiece();
        (, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();

        // Roll 1 block so the next nextProvingPeriod call clears the "already called this period" guard.
        vm.roll(vm.getBlockNumber() + 1);

        // Standard termination: reserve preserved, pdpEndEpoch set to a future epoch.
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        uint96 reserveBalance = pdpServiceWithPayments.getDataSet(dataSetId).lifecycleReserveBalance;
        assertGt(reserveBalance, 0);

        // Schedule enough removals to push pending above the reserve.
        // replenishReserveIfNeeded is a no-op because pdpEndEpoch != 0.
        uint256 removalsNeeded = uint256(reserveBalance) / SCHEDULE_PIECE_REMOVALS_FEE + 1;
        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        for (uint256 i = 0; i < removalsNeeded; i++) {
            makeSignaturePass(client);
            mockPDPVerifier.piecesScheduledRemove(
                dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
            );
        }
        assertGt(
            pdpServiceWithPayments.getDataSet(dataSetId).pendingOneTimePayments,
            reserveBalance,
            "pending exceeds reserve"
        );

        // nextProvingPeriod should flush pending and clamp lifecycleReserveBalance to 0.
        uint256 nextDeadline = firstDeadline + maxPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, nextDeadline - challengeWindow / 2, leafCount, ""
        );

        assertEq(pdpServiceWithPayments.getDataSet(dataSetId).pendingOneTimePayments, 0, "pending flushed");
        assertEq(pdpServiceWithPayments.getDataSet(dataSetId).lifecycleReserveBalance, 0, "reserve clamped to zero");
    }

    // When amount has bits above the uint96 range set, uint96(amount) silently truncates them;
    // only the lower 96 bits contribute to the balance increase.
    function test_topUpLifecycleReserve_bit97_truncated() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint256 pdpRailId = info.pdpRailId;

        uint256 topUp = 1e18;
        // bit 97 is above the uint96 range; uint96(amount) == topUp after truncation
        uint256 amount = (uint256(1) << 97) | topUp;
        uint96 expectedBalance = info.lifecycleReserveBalance + uint96(topUp);

        vm.prank(client);
        pdpServiceWithPayments.topUpLifecycleReserve(dataSetId, amount);

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.lifecycleReserveBalance, expectedBalance, "upper bits truncated, lower bits applied");
        assertEq(payments.getRail(pdpRailId).lockupFixed, expectedBalance, "lockupFixed mirrors reserve");
    }
}
