// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {console} from "forge-std/Test.sol";
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
import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {Errors} from "../../src/Errors.sol";
import {
    DATASET_FEE_PER_MONTH,
    EPOCHS_PER_MONTH,
    DEFAULT_LOCKUP_PERIOD,
    LIFECYCLE_RESERVE_TARGET,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    CDN_EGRESS_PRICE_PER_TIB,
    CACHE_MISS_EGRESS_PRICE_PER_TIB
} from "../../src/lib/PriceListUSDFC.sol";

import {FWSSPaymentModule} from "../../src/modules/FWSSPaymentModule.sol";
import {TestDataSetAuthorizer, OperationDataCheckingAuthorizer} from "../FilecoinWarmStorageService.t.sol";
import {
    ADD_PIECES_BASE_FEE,
    ADD_PIECES_PER_PIECE_FEE,
    CREATE_DATA_SET_FEE,
    SCHEDULE_PIECE_REMOVALS_FEE,
    TERMINATE_FEE
} from "../../src/lib/PriceListUSDFC.sol";

contract FWSSPaymentModuleTest is FilecoinWarmStorageServiceFixture {
    using FilecoinWarmStorageServiceStateLibrary for FilecoinWarmStorageService;

    function setUp() public override {
        super.setUp();

        address proxy = address(pdpServiceWithPayments);
        address legacyImplementation = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        FWSSConfigModule configModule = new FWSSConfigModule(
            pdpServiceWithPayments.paymentsContractAddress(), pdpServiceWithPayments.pdpVerifierAddress(), mockUSDFC
        );
        FWSSPaymentModule module = new FWSSPaymentModule(mockUSDFC, sessionKeyRegistry);
        FWSSEIP712Module eip712Module = new FWSSEIP712Module();
        address dispatcher = deployCode("lib/erc8167/out/Proxy.evm/Proxy.json");

        // Preserve legacy routes and route payment operations and configuration to their modules.
        bytes4[] memory selectors = AbiCheats.getSelectors(
            vm, "out/FilecoinWarmStorageServiceFixture.sol/FilecoinWarmStorageServiceHarness.json"
        );
        for (uint256 i; i < selectors.length; ++i) {
            _route(proxy, selectors[i], legacyImplementation);
        }
        selectors = AbiCheats.getSelectors(vm, "out/FWSSPaymentModule.sol/FWSSPaymentModule.json");
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

    uint256 constant PIECE_HEIGHT = 4;
    uint256 constant PIECE_LEAVES = 1 << PIECE_HEIGHT;

    function testGetServicePriceValues() public view {
        // Test the values returned by getServicePrice
        FilecoinWarmStorageService.ServicePricing memory pricing = pdpServiceWithPayments.getServicePrice();

        assertEq(pricing.pricePerTiBPerMonthNoCDN, STORAGE_PRICE_PER_TIB_PER_MONTH, "No CDN price should be 2.5 USDFC");
        assertEq(pricing.pricePerTiBCdnEgress, CDN_EGRESS_PRICE_PER_TIB, "CDN egress price should be 7 USDFC per TiB");
        assertEq(
            pricing.pricePerTiBCacheMissEgress,
            CACHE_MISS_EGRESS_PRICE_PER_TIB,
            "Cache miss egress price should be 7 USDFC per TiB"
        );
        assertEq(address(pricing.tokenAddress), address(mockUSDFC), "Token address should match USDFC");
        assertEq(pricing.epochsPerMonth, EPOCHS_PER_MONTH, "Epochs per month should be 86400");
        assertEq(pricing.datasetFeePerMonth, DATASET_FEE_PER_MONTH, "Dataset fee should be 0.12 USDFC");

        // Verify the values are in expected range
        assert(pricing.pricePerTiBPerMonthNoCDN < 10 ** 20); // Less than 10^20
        assert(pricing.pricePerTiBCdnEgress < 10 ** 20); // Less than 10^20
        assert(pricing.pricePerTiBCacheMissEgress < 10 ** 20); // Less than 10^20
    }

    function testGetEffectiveRatesValues() public view {
        // Test the values returned by getEffectiveRates
        (uint256 serviceFee, uint256 spPayment) = pdpServiceWithPayments.getEffectiveRates();

        uint256 decimals = 18; // MockUSDFC uses 18 decimals in tests
        // Total is 2.5 USDFC with 18 decimals
        uint256 expectedTotal = 25 * 10 ** (decimals - 1);

        // Test setup uses 0% commission
        uint256 expectedServiceFee = 0; // 0% commission
        uint256 expectedSpPayment = expectedTotal; // 100% goes to SP

        assertEq(serviceFee, expectedServiceFee, "Service fee should be 0 with 0% commission");
        assertEq(spPayment, expectedSpPayment, "SP payment should be 2.5 * 10^18");
        assertEq(serviceFee + spPayment, expectedTotal, "Total should equal 2.5 * 10^18");

        // Verify the values are in expected range
        assert(serviceFee + spPayment < 10 ** 20); // Less than 10^20
    }

    function testTerminateServiceLifecycle() public {
        console.log("=== Test: Data Set Payment Termination Lifecycle ===");

        // 0. Verify that DataSet with ID 1 is not found
        FilecoinWarmStorageService.DataSetStatus status = viewContract.getDataSetStatus(1);
        assertEq(uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.Inactive), "expected Inactive");

        // 1. Setup: Create a dataset with CDN enabled.
        console.log("1. Setting up: Creating dataset with service provider");

        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "");

        // Prepare data set creation data
        FilecoinWarmStorageService.DataSetCreateData memory createData = FilecoinWarmStorageService.DataSetCreateData({
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

        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(
            uint256(status),
            uint256(FilecoinWarmStorageService.DataSetStatus.Inactive),
            "expected Inactive (no pieces yet)"
        );

        // 2. Submit a valid proof.
        console.log("\n2. Starting proving period and submitting proof");
        // Start proving period
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        assertEq(viewContract.provingActivationEpoch(dataSetId), block.number);

        // Warp to challenge window
        uint256 provingDeadline = viewContract.provingDeadline(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            viewContract.provenPeriods(
                dataSetId,
                FWSSProvingModule(address(pdpServiceWithPayments)).getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            viewContract.provenPeriods(
                dataSetId,
                FWSSProvingModule(address(pdpServiceWithPayments)).getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );
        console.log("Proof submitted successfully");

        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.Active), "expected Active");

        // 3. Terminate payment
        console.log("\n3. Terminating payment rails");
        console.log("Current block:", block.number);
        vm.prank(client); // client terminates
        pdpServiceWithPayments.terminateService(dataSetId);

        // 4. Assertions
        // Check pdpEndEpoch is set
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertTrue(info.pdpEndEpoch > 0, "pdpEndEpoch should be set after termination");
        console.log("PDP termination successful. PDP end epoch:", info.pdpEndEpoch);
        // CDN service persists through the lockup window — metadata and rails still active
        (bool exists, string memory withCDN) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertTrue(exists, "withCDN metadata should still exist after terminateService");
        assertEq(withCDN, "", "withCDN value should be empty string");
        FilecoinPayV1.RailView memory cdnRailView = payments.getRail(info.cdnRailId);
        assertEq(cdnRailView.endEpoch, 0, "CDN rail should still be active after terminateService");
        FilecoinPayV1.RailView memory cacheMissRailView = payments.getRail(info.cacheMissRailId);
        assertEq(cacheMissRailView.endEpoch, 0, "Cache miss rail should still be active after terminateService");

        // check status remains active (terminated datasets are still Active)
        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(
            uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.Active), "expected Active (terminating)"
        );

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
        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(
            uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.Active), "expected Active (terminating)"
        );

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

        status = viewContract.getDataSetStatus(dataSetId);
        assertEq(
            uint256(status), uint256(FilecoinWarmStorageService.DataSetStatus.Inactive), "expected Inactive (deleted)"
        );

        // CDN rails terminated in dataSetDeleted
        FilecoinPayV1.RailView memory cdnRailAfter = payments.getRail(info.cdnRailId);
        assertTrue(cdnRailAfter.endEpoch > 0, "CDN rail should be terminated after dataSetDeleted");
        FilecoinPayV1.RailView memory cacheMissRailAfter = payments.getRail(info.cacheMissRailId);
        assertTrue(cacheMissRailAfter.endEpoch > 0, "Cache miss rail should be terminated after dataSetDeleted");

        // withCDN metadata cleared as part of dataset cleanup
        (exists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists, "withCDN metadata should be cleared after dataSetDeleted");

        console.log("\n=== Test completed successfully! ===");
    }

    function testTerminateService_AfterExternalCDNRailTermination() public {
        console.log("=== Test: terminateService after external CDN rail termination ===");

        // 1. Create dataset with CDN
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

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
        (bool exists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertTrue(exists, "withCDN flag should still exist after terminateService");

        // 6. Complete deletion lifecycle and verify metadata is cleared
        FilecoinWarmStorageService.DataSetInfoView memory terminatedInfo = viewContract.getDataSet(dataSetId);
        (uint64 maxProvingPeriod,,,) = viewContract.getPDPConfig();
        vm.roll(terminatedInfo.pdpEndEpoch + maxProvingPeriod + 1);
        FilecoinPayV1.RailView memory settledPdpRail = payments.getRail(terminatedInfo.pdpRailId);
        payments.settleRail(terminatedInfo.pdpRailId, settledPdpRail.endEpoch);
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 0, bytes(""));
        (bool existsAfter,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(existsAfter, "withCDN metadata should be cleared after dataSetDeleted");

        console.log("=== Test completed successfully! ===");
    }

    function testTerminateService_AfterExternalCDNRailFinalization() public {
        console.log("=== Test: terminateService after external CDN rail finalization ===");

        // 1. Create dataset with CDN
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

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
        (bool exists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertTrue(exists, "withCDN flag should still exist after terminateService");

        // 7. Complete deletion lifecycle and verify metadata is cleared
        FilecoinWarmStorageService.DataSetInfoView memory terminatedInfo = viewContract.getDataSet(dataSetId);
        (uint64 maxProvingPeriod,,,) = viewContract.getPDPConfig();
        vm.roll(terminatedInfo.pdpEndEpoch + maxProvingPeriod + 1);
        FilecoinPayV1.RailView memory settledPdpRail = payments.getRail(terminatedInfo.pdpRailId);
        payments.settleRail(terminatedInfo.pdpRailId, settledPdpRail.endEpoch);
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.dataSetDeleted(dataSetId, 0, bytes(""));
        (bool existsAfter,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(existsAfter, "withCDN metadata should be cleared after dataSetDeleted");

        console.log("=== Test completed successfully! ===");
    }

    // ============================================================
    // terminateService extraData / session-key tests
    // ============================================================

    function testTerminateService_signatureApprover() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "sig test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(client);

        vm.expectEmit(true, true, false, true);
        emit FilecoinWarmStorageService.ServiceTerminated(client, dataSetId, info.pdpRailId, 0, 0);
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSetId, sig);

        assertTrue(viewContract.getDataSet(dataSetId).pdpEndEpoch > 0, "dataset should be terminated");
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertEq(pdpRail.lockupPeriod, 0, "lockup period should be 0 for immediate termination");
        assertEq(pdpRail.lockupFixed, 0, "lockup fixed should be 0 for immediate termination");

        // With lockupPeriod = 0, endEpoch = block.number — no need to advance blocks
        payments.settleRail(info.pdpRailId, pdpRail.endEpoch);
        vm.prank(serviceProvider);
        mockPDPVerifier.deleteDataSet(PDPListener(address(pdpServiceWithPayments)), dataSetId, "");
        assertEq(viewContract.getDataSet(dataSetId).pdpRailId, 0, "dataset should be deleted");
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
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectEmit(true, true, false, true);
        emit FilecoinWarmStorageService.ServiceTerminated(client, dataSetId, info.pdpRailId, 0, 0);
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);
    }

    function testTerminateService_directSP_emitsApprover() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "test");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectEmit(true, true, false, true);
        emit FilecoinWarmStorageService.ServiceTerminated(serviceProvider, dataSetId, info.pdpRailId, 0, 0);
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
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = TERMINATE_SERVICE_TYPEHASH;
        vm.prank(client);
        sessionKeyRegistry.login(sessionKey1, block.timestamp, permissions, "test");

        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(sessionKey1);

        // approver in event is the session key, not the payer
        vm.expectEmit(true, true, false, true);
        emit FilecoinWarmStorageService.ServiceTerminated(sessionKey1, dataSetId, info.pdpRailId, 0, 0);
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSetId, sig);

        assertTrue(viewContract.getDataSet(dataSetId).pdpEndEpoch > 0, "dataset should be terminated");
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

    function testRailTerminated_RevertsIfCallerNotPaymentsContract() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectRevert(abi.encodeWithSelector(Errors.CallerNotPayments.selector, address(payments), address(sp1)));
        vm.prank(sp1);
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 123);
    }

    function testRailTerminated_RevertsIfTerminatorNotServiceContract() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectRevert(abi.encodeWithSelector(Errors.ServiceContractMustTerminateRail.selector));
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(0xdead), 123);
    }

    function testRailTerminated_RevertsIfRailNotAssociated() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.DataSetNotFoundForRail.selector, 1337));
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(1337, address(pdpServiceWithPayments), 123);
    }

    function testRailTerminated_SetsPdpEndEpochAndEmitsEvent() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.PDPPaymentTerminated(dataSetId, 123, info.pdpRailId);
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 123);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pdpEndEpoch, 123);
        // CDN rails don't track endEpoch in DataSetInfo
    }

    function testRailTerminated_DoesNotOverwritePdpEndEpoch() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        vm.expectEmit(true, true, true, true);
        emit FilecoinWarmStorageService.PDPPaymentTerminated(dataSetId, 123, info.pdpRailId);
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 123);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pdpEndEpoch, 123);

        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 321);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pdpEndEpoch, 123);
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

        assertGt(viewContract.getDataSet(dataSetId).pdpEndEpoch, 0);
    }

    function testDataSetAuthorizerReceivesOperationDataForEachWrite() public {
        uint256 clientDataSetId = nextClientDataSetId;
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "acl");
        uint256 dataSetId = createDataSetForClient(serviceProvider, client, keys, values);
        address bob = address(0xb0b);
        OperationDataCheckingAuthorizer authorizer = new OperationDataCheckingAuthorizer(bob);

        vm.prank(client);
        pdpServiceWithPayments.setDataSetAuthorizer(dataSetId, address(authorizer));

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
     * @notice Test: All epochs proven - should pay full amount
     */
    function testValidatePayment_AllEpochsProven() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();

        // Capture activation epoch BEFORE calling nextProvingPeriod
        uint256 _activationEpoch = vm.getBlockNumber();
        uint256 firstChallengeEpoch = _activationEpoch + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstChallengeEpoch, 100, ""
        );

        uint256 firstDeadline = _activationEpoch + maxProvingPeriod;

        // Submit proof for period 0
        vm.roll(firstChallengeEpoch);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        // Move just past the first deadline
        vm.roll(firstDeadline + 1);

        uint256 secondDeadline = firstDeadline + maxProvingPeriod;
        uint256 challengeEpoch1 = secondDeadline - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch1, 100, ""
        );

        // Submit proof for period 1
        vm.roll(challengeEpoch1);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        // Move to period 2
        vm.roll(secondDeadline + 1);
        uint256 thirdDeadline = secondDeadline + maxProvingPeriod;
        uint256 challengeEpoch2 = thirdDeadline - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch2, 100, ""
        );

        // Submit proof for period 2
        vm.roll(challengeEpoch2);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        // Now validate payment for epochs within these proven periods
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = _activationEpoch; // exclusive start
        uint256 toEpoch = _activationEpoch + (maxProvingPeriod * 3); // inclusive end, all 3 periods
        uint256 proposedAmount = 1000e6;

        // Move past the periods we're validating, so that toEpoch becomes less than block.number
        vm.roll(toEpoch);
        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        // Should pay full amount since all epochs are proven
        assertEq(result.modifiedAmount, proposedAmount, "Should pay full amount");
        assertEq(result.settleUpto, toEpoch, "Should settle to end epoch");
    }

    /**
     * @notice Test: No epochs proven - should pay nothing
     */
    function testValidatePayment_NoEpochsProven() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving but don't submit any proofs
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Move forward 3 periods without submitting proofs
        vm.roll(activationEpoch + (maxProvingPeriod * 3));

        // Validate payment
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = activationEpoch; // exclusive
        uint256 toEpoch = vm.getBlockNumber() - 1;
        uint256 proposedAmount = 1000e6;

        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        // Should settle two unproven periods
        assertEq(result.modifiedAmount, 0, "Should pay nothing");
        assertEq(result.settleUpto, activationEpoch + (maxProvingPeriod * 2), "Should not settle last period");
        assertEq(result.note, "No proven epochs in the requested range");

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch + maxProvingPeriod * 2, 100, ""
        );

        // Should settle up to start of current period
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, activationEpoch, toEpoch, 0);
        assertEq(result.modifiedAmount, 0, "Should pay nothing");
        assertEq(result.settleUpto, activationEpoch + (maxProvingPeriod * 2), "Should not settle last period");
        assertEq(result.note, "No proven epochs in the requested range");

        // For partial first period, settlement doesn't advance until deadline passed
        vm.roll(activationEpoch + maxProvingPeriod);
        toEpoch = activationEpoch + 1;
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, activationEpoch, toEpoch, 0);
        assertEq(result.modifiedAmount, 0, "Should pay nothing");
        assertEq(result.settleUpto, activationEpoch, "Should not settle partial first period");
        assertEq(result.note, "No proven epochs in the requested range");

        // Never settle less than 1 proving period when that period is unproven
        vm.roll(activationEpoch + (maxProvingPeriod * 3));
        fromEpoch = activationEpoch + maxProvingPeriod * 2;
        toEpoch = activationEpoch + maxProvingPeriod * 2 + 1;
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        assertEq(result.modifiedAmount, 0, "Should pay nothing");
        assertEq(result.settleUpto, fromEpoch, "Should not settle");
        assertEq(result.note, "No proven epochs in the requested range");

        // Settle only up to the start of current period
        fromEpoch = activationEpoch + maxProvingPeriod * 2 - 2;
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        assertEq(result.modifiedAmount, 0, "Should pay nothing");
        assertEq(result.settleUpto, activationEpoch + maxProvingPeriod * 2, "Should not settle into last period");
        assertEq(result.note, "No proven epochs in the requested range");

        // Settle only up to the start of current period
        fromEpoch = activationEpoch + maxProvingPeriod / 2;
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        assertEq(result.modifiedAmount, 0, "Should pay nothing");
        assertEq(result.settleUpto, activationEpoch + maxProvingPeriod * 2, "Should not settle into last period");
        assertEq(result.note, "No proven epochs in the requested range");
    }

    /**
     * @notice Test: Some epochs proven - should pay proportionally
     */
    function testValidatePayment_SomeEpochsProven() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 firstChallengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstChallengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Submit proof for period 0
        vm.roll(firstChallengeEpoch);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        // Move to period 1 - DON'T submit proof
        uint256 deadline0 = activationEpoch + maxProvingPeriod;
        vm.roll(deadline0 + 1);
        uint256 challengeEpoch1 = deadline0 + 1 + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch1, 100, ""
        );

        // Skip proof for period 1

        // Move to period 2 and submit proof
        uint256 deadline1 = deadline0 + maxProvingPeriod;
        vm.roll(deadline1 + 1);
        uint256 challengeEpoch2 = deadline1 + 1 + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch2, 100, ""
        );

        vm.roll(challengeEpoch2);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        // Validate payment for all 3 periods
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = activationEpoch;
        uint256 toEpoch = activationEpoch + (maxProvingPeriod * 3);
        uint256 proposedAmount = 3000e6;

        vm.roll(toEpoch + 1);

        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        // Should pay 2/3 of amount (2 proven periods out of 3)
        uint256 totalEpochs = toEpoch - fromEpoch;
        uint256 provenEpochs = maxProvingPeriod * 2;
        uint256 expectedAmount = (proposedAmount * provenEpochs) / totalEpochs;

        assertEq(result.modifiedAmount, expectedAmount, "Should pay for 2/3 of epochs");
        assertTrue(result.settleUpto > fromEpoch, "Should settle past start");
    }

    function testValidatePayment_FirstPeriodUnproven() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 firstChallengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstChallengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();
        assertEq(activationEpoch, viewContract.provingActivationEpoch(dataSetId));

        // Skip proof for period 0

        // Move to period 1
        uint256 deadline0 = activationEpoch + maxProvingPeriod;
        vm.roll(deadline0 + 1);
        uint256 challengeEpoch1 = deadline0 + 1 + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch1, 100, ""
        );

        // Prove period 1
        vm.roll(challengeEpoch1);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        // Move to period 2 and submit proof
        uint256 deadline1 = deadline0 + maxProvingPeriod;
        vm.roll(deadline1 + 1);
        uint256 challengeEpoch2 = deadline1 + 1 + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch2, 100, ""
        );

        vm.roll(challengeEpoch2);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        assertFalse(viewContract.provenPeriods(dataSetId, 0));
        assertTrue(viewContract.provenPeriods(dataSetId, 1));
        assertTrue(viewContract.provenPeriods(dataSetId, 2));

        // Validate payment for all 3 periods
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = activationEpoch;
        uint256 toEpoch = activationEpoch + (maxProvingPeriod * 3);
        uint256 proposedAmount = 3000e6;

        vm.roll(toEpoch + 1);

        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        assertTrue(result.settleUpto == toEpoch, "Should settle toEpoch");
        // Should pay 2/3 of amount (2 proven periods out of 3)
        uint256 totalEpochs = toEpoch - fromEpoch;
        uint256 provenEpochs = maxProvingPeriod * 2;
        uint256 expectedAmount = (proposedAmount * provenEpochs) / totalEpochs;

        assertEq(result.modifiedAmount, expectedAmount, "Should pay for 2/3 of epochs");

        // Verify can settle unproven period if that period has passed
        fromEpoch = activationEpoch;
        toEpoch = activationEpoch + maxProvingPeriod / 2;
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, toEpoch, "Should partial-settle faulted period");

        // Verify cannot settle unproven period on deadline
        vm.roll(activationEpoch + maxProvingPeriod);
        toEpoch = activationEpoch + maxProvingPeriod;
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, fromEpoch, "Should not partial-settle current unproven period");

        // Verify can settle through fault period that just ended
        vm.roll(activationEpoch + maxProvingPeriod + 1);
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        assertEq(result.modifiedAmount, 0);
        assertEq(result.settleUpto, toEpoch, "Should partial-settle previous fault period");

        // Verify can settle past fault for partial payment of proven period
        toEpoch = activationEpoch + maxProvingPeriod + 1;
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        expectedAmount = proposedAmount / (1 + maxProvingPeriod);
        assertEq(result.modifiedAmount, expectedAmount);
        assertEq(result.settleUpto, toEpoch, "Should partial-settle beyond fault period");

        // Settle first epoch in proven period after fault
        fromEpoch = activationEpoch + maxProvingPeriod;
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        expectedAmount = proposedAmount;
        assertEq(result.modifiedAmount, expectedAmount);
        assertEq(result.settleUpto, toEpoch, "Should first proven epoch after fault period");

        // Settle last epoch in fault period
        fromEpoch = activationEpoch + maxProvingPeriod - 1;
        toEpoch = activationEpoch + maxProvingPeriod;
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        expectedAmount = 0;
        assertEq(result.modifiedAmount, expectedAmount);
        assertEq(result.settleUpto, toEpoch, "Should settle last epoch in fault period");
    }

    /**
     * @notice Test: Proving never activated - should pay nothing
     */
    function testValidatePayment_ProvingNeverActivated() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Don't start proving at all
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = block.number;
        uint256 toEpoch = block.number + 1000;
        uint256 proposedAmount = 1000e6;

        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        assertEq(result.modifiedAmount, 0, "Should pay nothing");
        assertEq(result.settleUpto, toEpoch, "Should advance settlement at zero cost");
        assertEq(result.note, "No proving activity");
    }

    /**
     * @notice Empty dataset (no pieces ever added): payment rate is zero and validatePayment
     * returns 0 because proving was never activated.
     */
    function testEmptyDataset_NoPaymentWhenNoPieces() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Empty");

        // No pieces added — modifyRailPayment was never called, so the rail rate is 0
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        assertEq(rail.paymentRate, 0, "Rail rate must be 0 for empty dataset");

        // validatePayment returns 0 because provingActivationEpoch was never set
        uint256 fromEpoch = block.number;
        uint256 toEpoch = block.number + 1000;

        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, 1000e18, fromEpoch, toEpoch, 0);

        assertEq(result.modifiedAmount, 0, "No payment to SP when dataset has no pieces");
        assertEq(result.settleUpto, toEpoch, "Settlement advances at zero cost when proving never activated");
    }

    /**
     * @notice After all pieces are removed the dataset becomes empty. The PDPVerifier signals
     * this by passing NO_CHALLENGE_SCHEDULED (0) to nextProvingPeriod, which resets
     * provingDeadlines to 0. Subsequent possessionProven calls must revert, and
     * validatePayment must return 0 for epochs that fall in the now-empty period.
     */
    function testEmptyDataset_CannotProveAfterAllPiecesRemoved() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "WillEmpty");

        // Add a single piece so the dataset is non-empty and proving can start
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256("piece_to_remove"));
        uint256 leafCount = Cids.leafCount(0, 35);

        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        // Start the first proving period
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 firstDeadline = block.number + maxProvingPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstDeadline, leafCount, ""
        );

        uint256 activationEpoch = block.number;

        // Submit a valid proof for period 0
        vm.roll(firstDeadline - (challengeWindow / 2));
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments))
            .possessionProven(dataSetId, leafCount, 12345, CHALLENGES_PER_PROOF);

        // Schedule removal of the only piece
        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        // Advance past the first deadline; PDPVerifier signals the dataset is now empty by
        // passing challengeEpoch = NO_CHALLENGE_SCHEDULED (0).
        vm.roll(firstDeadline + 1);
        mockPDPVerifier.nextProvingPeriod(PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, 0, "");

        // provingDeadlines is now 0 — possessionProven must revert
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.ProvingNotStarted.selector, dataSetId));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 0, 12345, CHALLENGES_PER_PROOF);

        // validatePayment for an epoch range that falls entirely in the empty period must
        // return 0 (the period is faulted — no proof was submitted before proving stopped).
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 emptyFrom = activationEpoch + maxProvingPeriod; // start of the now-empty period
        uint256 emptyTo = activationEpoch + maxProvingPeriod * 2; // one full period later

        vm.roll(emptyTo + 1);
        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, 1000e18, emptyFrom, emptyTo, 0);

        assertEq(result.modifiedAmount, 0, "No payment to SP for empty period after all pieces removed");
    }

    function testEmptyDataset_ReactivationPreservesProvingTimeline() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Reactivated");
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256("original-piece"));
        uint256 leafCount = Cids.leafCount(0, 35);

        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 firstDeadline = block.number + maxProvingPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstDeadline, leafCount, ""
        );
        uint256 activationEpoch = vm.getBlockNumber();

        vm.roll(firstDeadline - (challengeWindow / 2));
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments))
            .possessionProven(dataSetId, leafCount, 12345, CHALLENGES_PER_PROOF);

        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        vm.roll(firstDeadline + 1);
        mockPDPVerifier.nextProvingPeriod(PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, 0, "");
        mockPDPVerifier.setDataSetLeafCount(dataSetId, 0);

        assertEq(viewContract.provingDeadline(dataSetId), 0, "Empty dataset should suspend proving");
        assertEq(
            viewContract.provingActivationEpoch(dataSetId),
            activationEpoch,
            "Empty dataset should retain its activation epoch"
        );

        vm.roll(activationEpoch + maxProvingPeriod * 3 + (maxProvingPeriod / 2));
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256("reactivated-piece"));
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            1,
            pieceData,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );
        uint256 additionEpoch = vm.getBlockNumber();

        uint256 challengeWindowStart = viewContract.nextPDPChallengeWindowStart(dataSetId);
        uint256 reactivationDeadline = challengeWindowStart + challengeWindow;
        uint256 challengeEpoch = challengeWindowStart + (challengeWindow / 2);
        assertEq(
            (reactivationDeadline - activationEpoch) % maxProvingPeriod,
            0,
            "Reactivation deadline should remain aligned to original activation"
        );
        assertGe(
            challengeEpoch - additionEpoch,
            maxProvingPeriod - (challengeWindow / 2),
            "Challenge should retain finality headroom"
        );
        assertLt(
            challengeEpoch - additionEpoch, maxProvingPeriod * 2, "Challenge should remain within two proving periods"
        );

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, leafCount, ""
        );

        assertEq(
            viewContract.provingActivationEpoch(dataSetId),
            activationEpoch,
            "Reactivation should preserve the original activation epoch"
        );
        assertEq(
            viewContract.provingDeadline(dataSetId),
            reactivationDeadline,
            "Callback should accept the deadline returned by the state view"
        );
        assertTrue(viewContract.provenPeriods(dataSetId, 0), "Original proven period should remain recorded");

        uint256 reactivationPeriod =
            FWSSProvingModule(address(pdpServiceWithPayments)).getProvingPeriodForEpoch(dataSetId, challengeEpoch);
        assertFalse(
            viewContract.provenPeriods(dataSetId, reactivationPeriod),
            "Reactivated period should not inherit an old proof bit"
        );

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        (uint256 oldSettlementAmount,,,, uint256 oldSettlementEpoch,) =
            payments.settleRail(info.pdpRailId, firstDeadline);
        assertGt(oldSettlementAmount, 0, "Original proven period should remain payable");
        assertEq(oldSettlementEpoch, firstDeadline, "Original period should settle after reactivation");

        vm.roll(challengeEpoch);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments))
            .possessionProven(dataSetId, leafCount, 67890, CHALLENGES_PER_PROOF);
        assertTrue(
            viewContract.provenPeriods(dataSetId, reactivationPeriod),
            "Reactivated proof should use its canonical period ID"
        );

        uint256 reactivationPeriodStart = reactivationDeadline - maxProvingPeriod;
        uint256 requestedEpochs = challengeEpoch - additionEpoch;
        uint256 provenEpochs = challengeEpoch - reactivationPeriodStart;
        uint256 proposedAmount = requestedEpochs * 1e6;
        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, additionEpoch, challengeEpoch, 0);
        assertEq(
            result.modifiedAmount,
            provenEpochs * 1e6,
            "Payment should cover only the proven canonical portion after reactivation"
        );
        assertEq(result.settleUpto, challengeEpoch, "Proven reactivation period should settle normally");
    }

    /**
     * @notice Test: Request range before activation - should advance without payment
     */
    function testValidatePayment_BeforeActivationSettlesWithZeroPayment() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        vm.roll(block.number + 1000);

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = activationEpoch - 500;
        uint256 toEpoch = activationEpoch - 100;

        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, 1000e6, fromEpoch, toEpoch, 0);

        assertEq(result.modifiedAmount, 0, "Pre-activation epochs should not be payable");
        assertEq(result.settleUpto, toEpoch, "Settlement should consume the pre-activation range");
    }

    function testValidatePayment_ActivationBoundarySettlesWithZeroPayment() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 proposedAmount = 1000e6;

        vm.prank(address(payments));
        IValidator.ValidationResult memory result = pdpServiceWithPayments.validatePayment(
            info.pdpRailId, proposedAmount, activationEpoch - 1, activationEpoch, 0
        );

        assertEq(result.modifiedAmount, 0, "Activation boundary should not be payable");
        assertEq(result.settleUpto, activationEpoch, "Should settle to activation boundary");
        assertEq(result.note, "No proving activity");
    }

    function testSettleRail_EndEpochAtActivationBoundaryFinalizes() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256("activation-boundary-piece"));
        uint256 leafCount = Cids.leafCount(0, 35);

        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory railBeforeActivation = payments.getRail(info.pdpRailId);

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        vm.roll(block.number + 3);
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, leafCount, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();
        assertEq(viewContract.provingActivationEpoch(dataSetId), activationEpoch, "Activation epoch mismatch");
        assertLt(railBeforeActivation.settledUpTo, activationEpoch, "Rail should need activation-boundary settlement");

        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(client);
        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId, sig);

        FilecoinWarmStorageService.DataSetInfoView memory terminatedInfo = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory terminatedRail = payments.getRail(terminatedInfo.pdpRailId);
        assertEq(terminatedRail.lockupPeriod, 0, "Immediate termination should use zero lockup period");
        assertEq(terminatedRail.endEpoch, activationEpoch, "End epoch should equal activation epoch");

        (uint256 settledAmount,,,, uint256 finalEpoch,) =
            payments.settleRail(terminatedInfo.pdpRailId, terminatedRail.endEpoch);

        assertEq(settledAmount, 0, "Pre-activation settlement should not pay");
        assertEq(finalEpoch, activationEpoch, "Rail should settle to activation boundary");

        vm.roll(activationEpoch + 1);
        vm.prank(sp1);
        mockPDPVerifier.deleteDataSet(PDPListener(address(pdpServiceWithPayments)), dataSetId, "");
        assertEq(viewContract.getDataSet(dataSetId).pdpRailId, 0, "Dataset should be deleted after finalization");
    }

    function testSettleRail_MultiplePreActivationRateSegmentsSettleWithZeroPayment() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256("first-pre-activation-piece"));
        uint256 leafCount = Cids.leafCount(0, 35);

        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        vm.roll(block.number + 3);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256("second-pre-activation-piece"));
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            1,
            pieceData,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory railBeforeActivation = payments.getRail(info.pdpRailId);
        assertLt(
            railBeforeActivation.settledUpTo, block.number, "Second addition should leave a pre-activation rate segment"
        );

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        vm.roll(block.number + 3);
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, leafCount * 2, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();
        (uint256 settledAmount,,,, uint256 finalEpoch,) = payments.settleRail(info.pdpRailId, activationEpoch);

        assertEq(settledAmount, 0, "Pre-activation rate segments should not be payable");
        assertEq(finalEpoch, activationEpoch, "Settlement should consume every pre-activation rate segment");
        assertEq(
            payments.getRail(info.pdpRailId).settledUpTo,
            activationEpoch,
            "Rail should be settled to the activation boundary"
        );
    }

    /**
     * @notice Test: Partial period coverage - epochs span within a proven period
     */
    function testValidatePayment_PartialPeriodCoverage() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Submit proof for period 0
        vm.roll(challengeEpoch);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        // Validate payment for middle portion of period 0
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = activationEpoch + 100; // Start 100 epochs into period
        uint256 toEpoch = activationEpoch + maxProvingPeriod - 100; // End 100 epochs before period ends
        uint256 proposedAmount = 1000e6;

        vm.roll(toEpoch + 1);

        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        // Since the period is proven, should pay full amount for the requested range
        assertEq(result.modifiedAmount, proposedAmount, "Should pay full amount for proven period");
        assertEq(result.settleUpto, toEpoch, "Should settle to end of range");

        vm.roll(activationEpoch + maxProvingPeriod + 1);
        result = pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);
        assertEq(result.modifiedAmount, proposedAmount, "Should pay full amount for proven period");
        assertEq(result.settleUpto, toEpoch, "Should settle to end of range");
    }

    /**
     * @notice Test: toEpoch lands exactly on period deadline with fromEpoch mid-period
     * to ensure we settle using the single-period path rather than multi-period which would
     * incur double-counting.
     */
    function testValidatePayment_ToEpochExactlyOnDeadline() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Prove period 0
        vm.roll(challengeEpoch);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // fromEpoch mid-period, toEpoch exactly on the deadline, should only settle via
        // single-period logic
        uint256 fromEpoch = activationEpoch + 100;
        uint256 toEpoch = activationEpoch + maxProvingPeriod; // == period 0 deadline
        uint256 proposedAmount = 1000e6;

        // Roll past the deadline so the period is resolved
        vm.roll(toEpoch + 1);

        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        assertEq(result.modifiedAmount, proposedAmount, "Should pay exactly full amount");
        assertEq(result.settleUpto, toEpoch, "Should settle to deadline");
    }

    /**
     * @notice Test: Invalid rail ID - settles in the payer's favor instead of reverting.
     */
    function testValidatePayment_InvalidRailId() public {
        uint256 invalidRailId = 999999;

        vm.prank(address(payments));
        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(invalidRailId, 1000e6, 100, 200, 0);

        assertEq(result.modifiedAmount, 0, "unassociated rail should pay nothing");
        assertEq(result.settleUpto, 200, "unassociated rail should settle to toEpoch");
    }

    /**
     * @notice Test: Invalid epoch range - should revert
     */
    function testValidatePayment_InvalidEpochRange() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // fromEpoch >= toEpoch
        vm.prank(address(payments));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidEpochRange.selector, 200, 200));
        pdpServiceWithPayments.validatePayment(info.pdpRailId, 1000e6, 200, 200, 0);
    }

    // ===== Settlement with Passed Deadlines Tests =====

    /**
     * @notice Test: Settlement advances past unproven periods when deadlines have passed
     * @dev Verifies that validatePayment advances settleUpTo for periods with passed deadlines
     */
    function testValidatePayment_AdvancesPastUnprovenPeriodsWithPassedDeadlines() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Move forward 3 periods without submitting any proofs
        // All 3 period deadlines will have passed
        vm.roll(activationEpoch + (maxProvingPeriod * 3) + 1);

        // Validate payment - should advance settleUpTo to cover all passed periods
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = activationEpoch;
        uint256 toEpoch = activationEpoch + (maxProvingPeriod * 3);
        uint256 proposedAmount = 1000e6;

        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        // With the fix, settlement should advance to toEpoch even with no proofs
        // because all period deadlines have passed
        assertEq(result.modifiedAmount, 0, "Should pay nothing for unproven epochs");
        assertEq(result.settleUpto, toEpoch, "Should advance settleUpTo to toEpoch since all deadlines passed");
    }

    /**
     * @notice Test: Settlement blocks on current period if deadline hasn't passed
     * @dev Verifies that validatePayment blocks on unproven period if deadline is still open
     */
    function testValidatePayment_BlocksOnUnprovenPeriodWithOpenDeadline() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Move forward only halfway through the first period (deadline hasn't passed)
        vm.roll(activationEpoch + (maxProvingPeriod / 2));

        // Validate payment - should NOT advance because deadline hasn't passed
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = activationEpoch;
        uint256 toEpoch = activationEpoch + (maxProvingPeriod / 2);
        uint256 proposedAmount = 1000e6;

        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        // Settlement should block because the period isn't proven and deadline hasn't passed
        assertEq(result.modifiedAmount, 0, "Should pay nothing");
        assertEq(result.settleUpto, fromEpoch, "Should not advance since deadline hasn't passed");
    }

    /**
     * @notice Test: Mixed proven and unproven periods with passed deadlines
     * @dev Verifies correct payment calculation when some periods are proven and others have passed deadlines
     */
    function testValidatePayment_MixedProvenAndUnprovenWithPassedDeadlines() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 firstChallengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstChallengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Submit proof for period 0 only
        vm.roll(firstChallengeEpoch);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        // Move forward past 3 periods (only period 0 is proven)
        vm.roll(activationEpoch + (maxProvingPeriod * 3) + 1);

        // Validate payment
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 fromEpoch = activationEpoch;
        uint256 toEpoch = activationEpoch + (maxProvingPeriod * 3);
        uint256 proposedAmount = 3000e6; // 1000 per period

        IValidator.ValidationResult memory result =
            pdpServiceWithPayments.validatePayment(info.pdpRailId, proposedAmount, fromEpoch, toEpoch, 0);

        // Should pay for period 0 only, but advance to toEpoch since all deadlines passed
        // Note: provenEpochs is maxProvingPeriod + 1 because of how the first period calculation
        // includes epochs from (fromEpoch, startingPeriodDeadline] which is M + 1 epochs
        uint256 totalEpochs = toEpoch - fromEpoch;
        uint256 provenEpochs = maxProvingPeriod; // Period 0 from (A, A+M]
        uint256 expectedAmount = (proposedAmount * provenEpochs) / totalEpochs;

        assertEq(result.modifiedAmount, expectedAmount, "Should pay for proven period only");
        assertEq(result.settleUpto, toEpoch, "Should advance to toEpoch since all deadlines passed");
    }

    /**
     * @notice Test: Full flow - SP abandons service, client can still settle and cleanup
     * @dev Simulates the scenario from issue #375 where SP fails to prove
     */
    function testFullFlow_SPAbandonsService_ClientCanSettleAndCleanup() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // SP abandons - no proofs submitted
        // Move past the first period deadline
        vm.roll(activationEpoch + maxProvingPeriod + 1);

        // Terminate the dataset (by client since SP abandoned)
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Get termination info
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Advance past the lockup period AND past the last proving period deadline
        // Settlement requires all period deadlines to have passed for unproven periods
        vm.roll(info.pdpEndEpoch + maxProvingPeriod + 1);

        // With the fix, client can now settle the rail even with no proofs
        // because all proving deadlines have passed
        FilecoinPayV1.RailView memory railBefore = payments.getRail(info.pdpRailId);
        (, uint256 clientBalanceBefore,,) = payments.getAccountInfoIfSettled(mockUSDFC, client);

        // Settle the rail - should succeed and pay nothing (no proofs)
        // After full settlement, the rail gets finalized and zeroed out
        payments.settleRail(info.pdpRailId, railBefore.endEpoch);

        (, uint256 clientBalanceAfter,,) = payments.getAccountInfoIfSettled(mockUSDFC, client);

        // Client should not have lost money (SP got nothing because no proofs)
        assertGe(clientBalanceAfter, clientBalanceBefore, "Client should not have paid for unproven service");

        // SP can delete the dataset (rail is fully settled/finalized)
        vm.prank(sp1);
        mockPDPVerifier.deleteDataSet(PDPListener(address(pdpServiceWithPayments)), dataSetId, bytes(""));

        // Verify dataset is deleted (pdpRailId == 0 indicates deleted/unregistered)
        FilecoinWarmStorageService.DataSetInfoView memory deletedInfo = viewContract.getDataSet(dataSetId);
        assertEq(deletedInfo.pdpRailId, 0, "Dataset should be deleted");
    }

    // Creates a dataset with one piece added and the first proving period initialized.
    // Returns (dataSetId, pdpRailId, leafCount, firstDeadline, maxProvingPeriod).
    // On return: pendingOneTimePayments == 0, lifecycleReserveBalance == LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - ADD_PIECES_BASE_FEE - ADD_PIECES_PER_PIECE_FEE.
    function _createDataSetWithPiece()
        internal
        returns (uint256 dataSetId, uint256 pdpRailId, uint256 leafCount, uint256 firstDeadline, uint256 maxPeriod)
    {
        dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        pdpRailId = viewContract.getDataSet(dataSetId).pdpRailId;
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
        (maxPeriod, challengeWindow,,) = viewContract.getPDPConfig();
        firstDeadline = block.number + maxPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstDeadline - challengeWindow / 2, leafCount, ""
        );
    }

    function test_terminateFee_chargedOnConsentCase() public {
        (uint256 dataSetId, uint256 pdpRailId,,,) = _createDataSetWithPiece();

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
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

        info = viewContract.getDataSet(dataSetId);
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

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0, "no fee on payer direct termination");
    }

    function test_terminateFee_notChargedOnSpInitiated() public {
        (uint256 dataSetId,,,,) = _createDataSetWithPiece();

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0);

        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId);

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0, "no fee on SP-initiated termination");
    }

    // TERMINATE_FEE must flush at termination time even when no piece removals are pending.
    function test_terminateFee_flushedWithoutRemovals() public {
        (uint256 dataSetId, uint256 pdpRailId,,,) = _createDataSetWithPiece();

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
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

        info = viewContract.getDataSet(dataSetId);
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
        uint256 pdpRailId = viewContract.getDataSet(dataSetId).pdpRailId;

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, CREATE_DATA_SET_FEE, "create fee pending before termination");
        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        info = viewContract.getDataSet(dataSetId);
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
        uint96 currentBalance = viewContract.getDataSet(dataSetId).lifecycleReserveBalance;
        // amount chosen so uint96(amount) == amount (no truncation) yet currentBalance + amount overflows uint96
        uint256 amount = uint256(type(uint96).max) - currentBalance + 1;
        vm.prank(client);
        vm.expectRevert(stdError.arithmeticError);
        pdpServiceWithPayments.topUpLifecycleReserve(dataSetId, amount);
    }

    // Post-termination replenishment is disabled; try exhausting the lifecycleReserveBalance and verify that the one time payment succeeds.
    function test_nextProvingPeriod_postTermination_withExhaustedReserve() public {
        (uint256 dataSetId,, uint256 leafCount, uint256 firstDeadline, uint256 maxPeriod) = _createDataSetWithPiece();
        (, uint256 challengeWindow,,) = viewContract.getPDPConfig();

        // Roll 1 block so the next nextProvingPeriod call clears the "already called this period" guard.
        vm.roll(vm.getBlockNumber() + 1);

        // Standard termination: reserve preserved, pdpEndEpoch set to a future epoch.
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        uint96 reserveBalance = viewContract.getDataSet(dataSetId).lifecycleReserveBalance;
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
        assertGt(viewContract.getDataSet(dataSetId).pendingOneTimePayments, reserveBalance, "pending exceeds reserve");

        // nextProvingPeriod should flush pending and clamp lifecycleReserveBalance to 0.
        uint256 nextDeadline = firstDeadline + maxPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, nextDeadline - challengeWindow / 2, leafCount, ""
        );

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0, "pending flushed");
        assertEq(viewContract.getDataSet(dataSetId).lifecycleReserveBalance, 0, "reserve clamped to zero");
    }

    // When amount has bits above the uint96 range set, uint96(amount) silently truncates them;
    // only the lower 96 bits contribute to the balance increase.
    function test_topUpLifecycleReserve_bit97_truncated() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 pdpRailId = info.pdpRailId;

        uint256 topUp = 1e18;
        // bit 97 is above the uint96 range; uint96(amount) == topUp after truncation
        uint256 amount = (uint256(1) << 97) | topUp;
        uint96 expectedBalance = info.lifecycleReserveBalance + uint96(topUp);

        vm.prank(client);
        pdpServiceWithPayments.topUpLifecycleReserve(dataSetId, amount);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.lifecycleReserveBalance, expectedBalance, "upper bits truncated, lower bits applied");
        assertEq(payments.getRail(pdpRailId).lockupFixed, expectedBalance, "lockupFixed mirrors reserve");
    }
}
