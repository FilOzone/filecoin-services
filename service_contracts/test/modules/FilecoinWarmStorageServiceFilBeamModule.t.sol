// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console, Vm} from "forge-std/Test.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";

import {Errors} from "../../src/Errors.sol";
import {FilecoinWarmStorageService} from "../../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceFilBeamModule} from "../../src/modules/FilecoinWarmStorageServiceFilBeamModule.sol";
import {CDNPaymentRailsToppedUp, CDNServiceTerminated} from "../../src/lib/Rails.sol";
import {
    FilecoinWarmStorageServiceFixture,
    FilecoinWarmStorageServiceFilBeamHarness
} from "../helpers/FilecoinWarmStorageServiceFixture.sol";

contract FilecoinWarmStorageServiceFilBeamModuleTest is FilecoinWarmStorageServiceFixture {
    FilecoinWarmStorageServiceFilBeamModule internal filBeamModule;

    function setUp() public override {
        super.setUp();
        filBeamModule = FilecoinWarmStorageServiceFilBeamModule(address(pdpServiceWithPayments));
    }

    function _deployServiceImplementation() internal override returns (FilecoinWarmStorageService) {
        return new FilecoinWarmStorageServiceFilBeamHarness(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry,
            4
        );
    }

    function testTerminateCDNServiceLifecycle() public {
        console.log("=== Test: CDN Payment Termination Lifecycle ===");

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
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
        console.log("Created data set with ID:", dataSetId);

        // 2. Submit a valid proof.
        console.log("\n2. Starting proving period and submitting proof");
        // Start proving period
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(pdpServiceWithPayments, dataSetId, challengeEpoch, 100, "");

        assertEq(viewContract.provingActivationEpoch(dataSetId), block.number);

        // Warp to challenge window
        uint256 provingDeadline = viewContract.provingDeadline(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );
        console.log("Proof submitted successfully");

        // 3. Try to terminate payment from client address
        console.log("\n3. Terminating CDN payment rails from client address -- should revert");
        console.log("Current block:", block.number);
        vm.prank(client); // client terminates
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.OnlyFilBeamControllerAllowed.selector, address(filBeamController), address(client)
            )
        );
        filBeamModule.terminateCDNService(dataSetId);

        // 4. Try to terminate payment from FilBeam address
        console.log("\n4. Terminating CDN payment rails from FilBeam address -- should pass");
        console.log("Current block:", block.number);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        vm.prank(viewContract.filBeamControllerAddress()); // FilBeam terminates
        vm.expectEmit(true, true, true, true);
        emit CDNServiceTerminated(filBeamController, dataSetId, info.cacheMissRailId, info.cdnRailId);
        filBeamModule.terminateCDNService(dataSetId);

        // 5. Assertions
        // Check if CDN data is cleared
        info = viewContract.getDataSet(dataSetId);
        (bool exists, string memory withCDN) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists, "withCDN metadata should not exist after termination");
        assertEq(withCDN, "", "withCDN value should be cleared for dataset");
        console.log("CDN service termination successful. Flag `withCDN` is cleared");

        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(info.cdnRailId);

        assertEq(pdpRail.endEpoch, 0, "PDP rail should NOT be terminated");
        assertTrue(cacheMissRail.endEpoch > 0, "Cache miss rail should be terminated");
        assertTrue(cdnRail.endEpoch > 0, "CDN rail should be terminated");

        // Ensure future CDN service termination reverts
        vm.prank(filBeamController);
        vm.expectRevert(abi.encodeWithSelector(Errors.FilBeamServiceNotConfigured.selector, dataSetId));
        filBeamModule.terminateCDNService(dataSetId);

        console.log("\n=== Test completed successfully! ===");
    }

    function testTerminateCDNService_checkPDPPaymentRate() public {
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
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);
        console.log("Created data set with ID:", dataSetId);

        // 2. Submit a valid proof.
        console.log("\n2. Starting proving period and submitting proof");
        // Start proving period
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(pdpServiceWithPayments, dataSetId, challengeEpoch, 100, "");

        assertEq(viewContract.provingActivationEpoch(dataSetId), block.number);

        // Warp to challenge window
        uint256 provingDeadline = viewContract.provingDeadline(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );
        console.log("Proof submitted successfully");

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory pdpRailPreTermination = payments.getRail(info.pdpRailId);

        // 3. Try to terminate payment from FilBeam address
        console.log("\n4. Terminating CDN payment rails from FilBeam address -- should pass");
        console.log("Current block:", block.number);
        vm.prank(viewContract.filBeamControllerAddress()); // FilBeam terminates
        vm.expectEmit(true, true, true, true);
        emit CDNServiceTerminated(filBeamController, dataSetId, info.cacheMissRailId, info.cdnRailId);
        filBeamModule.terminateCDNService(dataSetId);

        // 4. Start new proving period and submit new proof
        console.log("\n4. Starting proving period and submitting proof");
        challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(pdpServiceWithPayments, dataSetId, challengeEpoch, 100, "");

        // Warp to challenge window
        provingDeadline = viewContract.provingDeadline(dataSetId);
        vm.roll(provingDeadline - (challengeWindow / 2));

        assertFalse(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // Submit proof
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, 100, 12345, 5);
        assertTrue(
            viewContract.provenPeriods(
                dataSetId, pdpServiceWithPayments.getProvingPeriodForEpoch(dataSetId, block.number)
            )
        );

        // 5. Assert that payment rate has remained unchanged
        console.log("\n5. Assert that payment rate has remained unchanged");
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertEq(pdpRailPreTermination.paymentRate, pdpRail.paymentRate, "FilecoinPayV1 rate should remain unchanged");

        console.log("\n=== Test completed successfully! ===");
    }

    function testTerminateCDNService_dataSetHasNoCDNEnabled() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Try to terminate CDN service
        console.log("Terminating CDN service for data set with -- should revert");
        console.log("Current block:", block.number);
        vm.prank(filBeamController);
        vm.expectRevert(abi.encodeWithSelector(Errors.FilBeamServiceNotConfigured.selector, dataSetId));
        filBeamModule.terminateCDNService(dataSetId);
    }

    function testTerminateCDNService_AfterExternalCDNRailTermination() public {
        console.log("=== Test: terminateCDNService after external CDN rail termination ===");

        // 1. Create dataset with CDN
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // 2. Externally terminate only one CDN rail
        console.log("Externally terminating cacheMissRailId only...");
        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cacheMissRailId);

        // Verify cache miss rail is terminated
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);
        assertTrue(cacheMissRail.endEpoch > 0, "Cache miss rail should be terminated");

        // 3. Call terminateCDNService - should succeed and terminate the other rail
        console.log("Calling terminateCDNService - should succeed...");
        vm.prank(filBeamController);
        filBeamModule.terminateCDNService(dataSetId);

        // 4. Verify both CDN rails are now terminated
        cacheMissRail = payments.getRail(info.cacheMissRailId);
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        assertTrue(cacheMissRail.endEpoch > 0, "Cache miss rail should still be terminated");
        assertTrue(cdnRail.endEpoch > 0, "CDN rail should be terminated");

        // 5. Verify CDN metadata is cleaned up
        (bool exists2,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists2, "withCDN flag should be deleted");

        console.log("=== Test completed successfully! ===");
    }

    function testTerminateCDNService_AfterExternalCDNRailFinalization() public {
        console.log("=== Test: terminateCDNService after external CDN rail finalization ===");

        // 1. Create dataset with CDN
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // 2. Externally terminate only one CDN rail
        console.log("Externally terminating cacheMissRailId only...");
        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cacheMissRailId);

        // Verify cache miss rail is terminated
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);
        assertTrue(cacheMissRail.endEpoch > 0, "Cache miss rail should be terminated");

        // 3. Settle and finalize the cache miss rail
        console.log("Settling cache miss rail to finalize it...");
        vm.roll(cacheMissRail.endEpoch + 1);
        payments.settleRail(info.cacheMissRailId, cacheMissRail.endEpoch);

        // Verify cache miss rail is finalized (getRail should revert for finalized rails)
        vm.expectRevert();
        payments.getRail(info.cacheMissRailId);

        // 4. Call terminateCDNService - should succeed and terminate the other rail
        console.log("Calling terminateCDNService - should succeed...");
        vm.prank(filBeamController);
        filBeamModule.terminateCDNService(dataSetId);

        // 5. Verify CDN rail is now terminated
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        assertTrue(cdnRail.endEpoch > 0, "CDN rail should be terminated");

        // 6. Verify CDN metadata is cleaned up
        (bool exists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists, "withCDN flag should be deleted");

        console.log("=== Test completed successfully! ===");
    }

    function testTransferCDNController() public {
        address newController = address(0xDEADBEEF);
        vm.prank(filBeamController);
        filBeamModule.transferFilBeamController(newController);
        assertEq(viewContract.filBeamControllerAddress(), newController, "CDN controller should be updated");

        // Attempt transfer from old controller should revert
        vm.prank(filBeamController);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OnlyFilBeamControllerAllowed.selector, newController, filBeamController)
        );
        filBeamModule.transferFilBeamController(address(0x1234));

        // Restore the original state
        vm.prank(newController);
        filBeamModule.transferFilBeamController(filBeamController);
    }

    function testTransferCDNController_revertsIfZeroAddress() public {
        vm.prank(filBeamController);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.FilBeamController));
        filBeamModule.transferFilBeamController(address(0));
    }

    function testSettleFilBeamPaymentRails_BothAmounts() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 50000;
        uint256 cacheMissAmount = 25000;

        // Top up the rails first to allow for settlement
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId,
            cdnAmount,
            defaultCDNLockup + cdnAmount,
            cacheMissAmount,
            defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Now settle the payments
        vm.expectEmit(true, false, false, true, address(payments));
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );
        vm.expectEmit(true, false, false, true, address(payments));
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_OnlyCdnAmount() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 75000;
        uint256 cacheMissAmount = 0;

        // Top up only the CDN rail
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId,
            cdnAmount,
            defaultCDNLockup + cdnAmount,
            cacheMissAmount,
            defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Now settle only the CDN payment
        vm.expectEmit(true, false, false, true, address(payments));
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_OnlyCacheMissAmount() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 0;
        uint256 cacheMissAmount = 30000;

        // Top up only the cache miss rail
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId,
            cdnAmount,
            defaultCDNLockup + cdnAmount,
            cacheMissAmount,
            defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Now settle only the cache miss payment
        vm.expectEmit(true, false, false, true, address(payments));
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_ZeroAmounts() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, 0, 0);
    }

    function testSettleFilBeamPaymentRails_OnlyfilBeamController() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Expecting the payment to fail due to insufficient lockup (OneTimePaymentExceedsLockup error)
        // Try to settle more than the initial lockup
        uint256 cdnAmount = defaultCDNLockup + 50000; // More than initial 0.7 USDFC
        uint256 cacheMissAmount = defaultCacheMissLockup + 25000; // More than initial 0.3 USDFC

        vm.expectRevert();
        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_RevertIfNotController() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyFilBeamControllerAllowed.selector, filBeamController, client));
        vm.prank(client);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, 50000, 25000);

        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyFilBeamControllerAllowed.selector, filBeamController, sp1));
        vm.prank(sp1);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, 50000, 25000);
    }

    function testSettleFilBeamPaymentRails_InvalidDataSetId() public {
        uint256 invalidDataSetId = 999999;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDataSetId.selector, invalidDataSetId));
        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(invalidDataSetId, 50000, 25000);
    }

    function testSettleFilBeamPaymentRails_DataSetWithoutCDN() public {
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, emptyKeys, emptyValues);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidDataSetId.selector, dataSetId));
        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, 50000, 25000);
    }

    function testSettleFilBeamPaymentRails_DataSetWithEmptyCDNMetadata() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        uint256 cdnAmount = 50000;
        uint256 cacheMissAmount = 25000;

        // Top up the rails first
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId,
            cdnAmount,
            defaultCDNLockup + cdnAmount,
            cacheMissAmount,
            defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Empty CDN metadata still creates CDN rails and can be settled after top-up
        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_EmitsCorrectEvents() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 100000;
        uint256 cacheMissAmount = 50000;

        // Top up the rails first
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId,
            cdnAmount,
            defaultCDNLockup + cdnAmount,
            cacheMissAmount,
            defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Verify correct events are emitted
        vm.expectEmit(true, false, false, true, address(payments));
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );
        vm.expectEmit(true, false, false, true, address(payments));
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_NoEventsForZeroAmounts() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        vm.recordLogs();
        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, 0, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(
                logs[i].topics[0] == FilecoinPayV1.RailOneTimePaymentProcessed.selector,
                "RailOneTimePaymentProcessed should not be emitted for zero amounts"
            );
        }
    }

    function testSettleFilBeamPaymentRails_ProcessesPaymentsCorrectly() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnAmount = 75000;
        uint256 cacheMissAmount = 35000;

        // Top up the rails first
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId,
            cdnAmount,
            defaultCDNLockup + cdnAmount,
            cacheMissAmount,
            defaultCacheMissLockup + cacheMissAmount
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        // Verify rails have correct lockup before settlement (initial + top-up)
        FilecoinPayV1.RailView memory cdnRailBefore = payments.getRail(info.cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRailBefore = payments.getRail(info.cacheMissRailId);
        assertEq(
            cdnRailBefore.lockupFixed,
            defaultCDNLockup + cdnAmount,
            "CDN rail should have lockup equal to initial plus top-up"
        );
        assertEq(
            cacheMissRailBefore.lockupFixed,
            defaultCacheMissLockup + cacheMissAmount,
            "Cache miss rail should have lockup equal to initial plus top-up"
        );

        // Process the payments
        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_FailsWithInsufficientLockup() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Try to settle more than the initial lockup amount
        uint256 cdnAmount = defaultCDNLockup + 50000; // More than initial 0.7 USDFC
        uint256 cacheMissAmount = defaultCacheMissLockup + 10000; // More than initial 0.3 USDFC

        // Attempt to settle without additional top-up (only initial lockup available)
        // Expecting OneTimePaymentExceedsLockup error
        vm.expectRevert();
        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_FailsWhenLockupLessThanSettlement() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Top up with smaller amounts than we'll try to settle
        uint256 topUpCdn = 10000;
        uint256 topUpCacheMiss = 5000;
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, topUpCdn, topUpCacheMiss);

        // Try to settle with amounts larger than initial plus top-up
        uint256 cdnAmount = defaultCDNLockup + topUpCdn + 50000; // More than available lockup
        uint256 cacheMissAmount = defaultCacheMissLockup + topUpCacheMiss + 10000; // More than available lockup

        // Should fail due to insufficient lockup
        vm.expectRevert();
        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_AfterTermination() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Top up CDN rails with sufficient funds
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, 100000, 50000);

        // Terminate the CDN service (this removes withCDN metadata)
        vm.prank(filBeamController);
        filBeamModule.terminateCDNService(dataSetId);

        // Verify withCDN metadata is removed
        (bool exists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertFalse(exists, "withCDN metadata should be removed after termination");

        // Should still be able to settle CDN payment rails after termination
        uint256 cdnAmount = 50000;
        uint256 cacheMissAmount = 25000;

        // Expect the correct events to be emitted for successful settlement
        vm.expectEmit(true, false, false, true);
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );
        vm.expectEmit(true, false, false, true);
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testSettleFilBeamPaymentRails_AfterServiceTermination() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Top up CDN rails with sufficient funds
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, 100000, 50000);

        // Terminate the entire service (this also removes withCDN metadata and terminates CDN rails)
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // CDN service persists through lockup window — withCDN metadata still present
        (bool exists,) = viewContract.getDataSetMetadata(dataSetId, "withCDN");
        assertTrue(exists, "withCDN metadata should still exist after service termination");

        // Should still be able to settle CDN payment rails after termination
        uint256 cdnAmount = 50000;
        uint256 cacheMissAmount = 25000;

        // Expect the correct events to be emitted for successful settlement
        vm.expectEmit(true, false, false, true);
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cdnRailId,
            cdnAmount - cdnAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cdnAmount / payments.NETWORK_FEE_DENOMINATOR()
        );
        vm.expectEmit(true, false, false, true);
        emit FilecoinPayV1.RailOneTimePaymentProcessed(
            info.cacheMissRailId,
            cacheMissAmount - cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR(),
            0,
            cacheMissAmount / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.prank(filBeamController);
        filBeamModule.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);
    }

    function testTopUpCDNPaymentRails_Success() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        // Verify initial lockup matches expected values
        FilecoinPayV1.RailView memory cdnRailBefore = payments.getRail(info.cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRailBefore = payments.getRail(info.cacheMissRailId);
        assertEq(cdnRailBefore.lockupFixed, defaultCDNLockup, "CDN rail should start with 0.7 USDFC lockup");
        assertEq(
            cacheMissRailBefore.lockupFixed,
            defaultCacheMissLockup,
            "Cache miss rail should start with 0.3 USDFC lockup"
        );

        // Top up the rails
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnTopUp, defaultCDNLockup + cdnTopUp, cacheMissTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Verify lockup increased by top-up amount
        FilecoinPayV1.RailView memory cdnRailAfter = payments.getRail(info.cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRailAfter = payments.getRail(info.cacheMissRailId);
        assertEq(
            cdnRailAfter.lockupFixed, defaultCDNLockup + cdnTopUp, "CDN rail lockup should equal initial plus top-up"
        );
        assertEq(
            cacheMissRailAfter.lockupFixed,
            defaultCacheMissLockup + cacheMissTopUp,
            "Cache miss rail lockup should equal initial plus top-up"
        );
    }

    function testTopUpCDNPaymentRails_OnlyPayerCanTopUp() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Try to top up as non-payer
        vm.expectRevert();
        vm.prank(sp1);
        filBeamModule.topUpCDNPaymentRails(dataSetId, 1000, 1000);

        // Try to top up as another random address
        vm.expectRevert();
        vm.prank(address(0x123));
        filBeamModule.topUpCDNPaymentRails(dataSetId, 1000, 1000);

        // Should work as payer
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(dataSetId, 1000, defaultCDNLockup + 1000, 1000, defaultCacheMissLockup + 1000);
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, 1000, 1000);
    }

    function testTopUpCDNPaymentRails_RequiresCDNEnabled() public {
        // Create dataset without CDN
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, emptyKeys, emptyValues);

        // Should fail because CDN is not enabled
        vm.expectRevert();
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, 1000, 1000);
    }

    function testTopUpCDNPaymentRails_IncrementalTopUps() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // First top-up
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(dataSetId, 1000, defaultCDNLockup + 1000, 500, defaultCacheMissLockup + 500);
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, 1000, 500);

        FilecoinPayV1.RailView memory cdnRail1 = payments.getRail(info.cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRail1 = payments.getRail(info.cacheMissRailId);
        assertEq(cdnRail1.lockupFixed, defaultCDNLockup + 1000);
        assertEq(cacheMissRail1.lockupFixed, defaultCacheMissLockup + 500);

        // Second top-up (should be additive)
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(dataSetId, 2000, defaultCDNLockup + 3000, 1500, defaultCacheMissLockup + 2000);
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, 2000, 1500);

        FilecoinPayV1.RailView memory cdnRail2 = payments.getRail(info.cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRail2 = payments.getRail(info.cacheMissRailId);
        assertEq(cdnRail2.lockupFixed, defaultCDNLockup + 3000, "CDN lockup should be initial plus cumulative top-ups");
        assertEq(
            cacheMissRail2.lockupFixed,
            defaultCacheMissLockup + 2000,
            "Cache miss lockup should be initial plus cumulative top-ups"
        );
    }

    function testTopUpCDNPaymentRails_ZeroAmounts() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Top up with zero amounts (should revert with InvalidTopUpAmount error)
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTopUpAmount.selector, dataSetId));
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, 0, 0);

        // Verify lockup remains at initial values
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);
        assertEq(cdnRail.lockupFixed, defaultCDNLockup, "CDN lockup should remain at initial 0.7 USDFC");
        assertEq(
            cacheMissRail.lockupFixed, defaultCacheMissLockup, "Cache miss lockup should remain at initial 0.3 USDFC"
        );
    }

    function testTopUpCDNPaymentRails_InvalidDataSetId() public {
        uint256 invalidDataSetId = 99999999999999999;

        vm.expectRevert();
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(invalidDataSetId, 1000, 1000);
    }

    function testTopUpCDNPaymentRails_RevertsAfterCDNTermination() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Top up initially (should succeed)
        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnTopUp, defaultCDNLockup + cdnTopUp, cacheMissTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Terminate CDN service
        vm.prank(filBeamController);
        filBeamModule.terminateCDNService(dataSetId);

        // Attempt to top up again (should fail because withCDN metadata was removed)
        vm.expectRevert(abi.encodeWithSelector(Errors.FilBeamServiceNotConfigured.selector, dataSetId));
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);
    }

    function testTopUpCDNPaymentRails_RevertsAfterServiceTermination() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);

        // Top up initially (should succeed)
        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnTopUp, defaultCDNLockup + cdnTopUp, cacheMissTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Terminate storage service — CDN rails remain active through the lockup window
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        // Top-up should still succeed: CDN rails are active and withCDN metadata persists
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId,
            cdnTopUp,
            defaultCDNLockup + cdnTopUp + cdnTopUp,
            cacheMissTopUp,
            defaultCacheMissLockup + cacheMissTopUp + cacheMissTopUp
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);
    }

    function testTopUpCDNPaymentRails_RevertsForIndividuallyTerminatedRails() public {
        // Create dataset with CDN enabled
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Top up initially (should succeed)
        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnTopUp, defaultCDNLockup + cdnTopUp, cacheMissTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Directly terminate CDN rail through FilecoinPayV1 contract (simulating edge case)
        // Note: The service contract is the controller of the rails
        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cdnRailId);

        // Attempt to top up only CDN rail (should fail since CDN rail is terminated)
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNPaymentAlreadyTerminated.selector, dataSetId));
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, 0);

        // Attempt to top up only cache miss rail (should also fail since CDN rail is terminated)
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNPaymentAlreadyTerminated.selector, dataSetId));
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, 0, cacheMissTopUp);

        // Now terminate cache miss rail too
        vm.prank(address(pdpServiceWithPayments));
        payments.terminateRail(info.cacheMissRailId);

        // Attempt to top up both (should fail on first check)
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNPaymentAlreadyTerminated.selector, dataSetId));
        vm.prank(client);
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);
    }

    function testTopUpCDNPaymentRails_SucceedsBeforeTermination() public {
        // Positive test to ensure normal functionality still works
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 cdnTopUp = 100000;
        uint256 cacheMissTopUp = 50000;

        // Multiple top-ups should all succeed before termination
        vm.startPrank(client);

        // First top-up
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnTopUp, defaultCDNLockup + cdnTopUp, cacheMissTopUp, defaultCacheMissLockup + cacheMissTopUp
        );
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, cacheMissTopUp);

        // Second top-up
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId,
            cdnTopUp * 2,
            defaultCDNLockup + cdnTopUp * 3,
            cacheMissTopUp * 2,
            defaultCacheMissLockup + cacheMissTopUp * 3
        );
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp * 2, cacheMissTopUp * 2);

        // Third top-up (only CDN)
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnTopUp, defaultCDNLockup + cdnTopUp * 4, 0, defaultCacheMissLockup + cacheMissTopUp * 3
        );
        filBeamModule.topUpCDNPaymentRails(dataSetId, cdnTopUp, 0);

        // Fourth top-up (only cache miss)
        vm.expectEmit(true, false, false, true);
        emit CDNPaymentRailsToppedUp(
            dataSetId, 0, defaultCDNLockup + cdnTopUp * 4, cacheMissTopUp, defaultCacheMissLockup + cacheMissTopUp * 4
        );
        filBeamModule.topUpCDNPaymentRails(dataSetId, 0, cacheMissTopUp);

        vm.stopPrank();

        // Verify rails are still active and have correct lockup amounts
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);

        // Rails should not be terminated
        assertEq(cdnRail.endEpoch, 0, "CDN rail should not be terminated");
        assertEq(cacheMissRail.endEpoch, 0, "Cache miss rail should not be terminated");

        // Verify lockup amounts (initial lockup plus sum of all top-ups)
        uint256 expectedCdnLockupTotal = defaultCDNLockup + (cdnTopUp * 4); // initial + (1 + 2 + 1 + 0 = 4x)
        uint256 defaultCacheMissLockupTotal = defaultCacheMissLockup + (cacheMissTopUp * 4); // initial + (1 + 2 + 0 + 1 = 4x)
        assertEq(cdnRail.lockupFixed, expectedCdnLockupTotal, "CDN rail lockup incorrect");
        assertEq(cacheMissRail.lockupFixed, defaultCacheMissLockupTotal, "Cache miss rail lockup incorrect");
    }
}
