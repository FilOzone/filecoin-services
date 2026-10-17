// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Cids} from "@pdp/Cids.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {AbiCheats} from "@erc8167/lib/AbiCheats.sol";
import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {FWSSOwnable} from "../../src/lib/FWSSOwnable.sol";
import {IFilecoinWarmStorageService} from "../../src/interfaces/IFilecoinWarmStorageService.sol";
import {CHALLENGES_PER_PROOF} from "../../src/lib/FWSSConstants.sol";
import {DataSetInfoView} from "../../src/lib/FWSSViewTypes.sol";
import {calculateStorageSizeBasedRatePerEpoch, DATASET_FEE_PER_EPOCH} from "../../src/lib/PriceListUSDFC.sol";
import {Errors} from "../../src/Errors.sol";
import {IFWSSConfig} from "../../src/interfaces/IFWSSConfig.sol";
import {FWSSConfigModule} from "../../src/modules/FWSSConfigModule.sol";
import {FWSSProvingModule} from "../../src/modules/FWSSProvingModule.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";

contract FWSSProvingModuleTest is FilecoinWarmStorageServiceFixture {
    FWSSProvingModule internal provingModule;

    function setUp() public override {
        super.setUp();
        provingModule = FWSSProvingModule(address(pdpServiceWithPayments));
    }

    function createDataSetForServiceProviderTest(address provider, address clientAddress, string memory)
        internal
        returns (uint256)
    {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "Test Data Set");
        return createDataSetForClient(provider, clientAddress, keys, values);
    }

    function testConstructorRejectsZeroPaymentsAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.FilecoinPayV1));
        new FWSSProvingModule(address(0), address(mockPDPVerifier));
    }

    function testConstructorRejectsZeroPDPVerifierAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.PDPVerifier));
        new FWSSProvingModule(address(payments), address(0));
    }

    function testOnlyConfiguredPDPVerifierCanSubmitProof() public {
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OnlyPDPVerifierAllowed.selector, address(mockPDPVerifier), client)
        );
        provingModule.possessionProven(1, 0, 0, CHALLENGES_PER_PROOF);
    }

    function testOnlyOwnerCanConfigureProvingPeriod() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, client));
        provingModule.configureProvingPeriod(120, 30);
    }

    function testProvingDoesNotExportConfigSelectors() public view {
        bytes4[] memory selectors = AbiCheats.getSelectors(vm, "out/FWSSProvingModule.sol/FWSSProvingModule.json");
        assertEq(selectors.length, 6);
        for (uint256 i; i < selectors.length; ++i) {
            assertTrue(selectors[i] != IFWSSConfig.paymentsContractAddress.selector);
            assertTrue(selectors[i] != IFWSSConfig.pdpVerifierAddress.selector);
            assertTrue(selectors[i] != IFWSSConfig.usdfcTokenAddress.selector);
        }
    }

    function testVerifierAuthorizationUsesImmutableAfterConfigRouteChanges() public {
        address newVerifier = address(0x1234);
        FWSSConfigModule configModule = new FWSSConfigModule(address(payments), newVerifier, mockUSDFC);
        _route(address(provingModule), IFWSSConfig.pdpVerifierAddress.selector, address(configModule));
        assertEq(IFWSSConfig(address(provingModule)).pdpVerifierAddress(), newVerifier);

        vm.prank(newVerifier);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OnlyPDPVerifierAllowed.selector, address(mockPDPVerifier), newVerifier)
        );
        provingModule.possessionProven(1, 0, 0, CHALLENGES_PER_PROOF);

        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Immutable verifier");
        (uint64 maxPeriod, uint256 window,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 deadline = block.number + maxPeriod;
        vm.prank(address(mockPDPVerifier));
        provingModule.nextProvingPeriod(dataSetId, deadline, 100, "");
        vm.roll(deadline - window / 2);
        vm.prank(address(mockPDPVerifier));
        provingModule.possessionProven(dataSetId, 100, 0, CHALLENGES_PER_PROOF);
        assertTrue(pdpServiceWithPayments.provenPeriods(dataSetId, 0));
    }

    function testProvenPeriods() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        for (uint256 i = 0; i < 2049; i++) {
            assertFalse(pdpServiceWithPayments.provenPeriods(testDataSetId, i));
        }
        (uint64 maxProvingPeriod, uint256 challengeWindowSize,,) = pdpServiceWithPayments.getPDPConfig();
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), testDataSetId, vm.getBlockNumber() + maxProvingPeriod, 100, ""
        );
        vm.roll(vm.getBlockNumber() + maxProvingPeriod - challengeWindowSize);
        for (uint256 i = 0; i < 2049; i++) {
            assertFalse(pdpServiceWithPayments.provenPeriods(testDataSetId, i));
            vm.prank(address(mockPDPVerifier));
            provingModule.possessionProven(testDataSetId, 100, 12345, CHALLENGES_PER_PROOF);
            assertTrue(pdpServiceWithPayments.provenPeriods(testDataSetId, i));

            vm.roll(vm.getBlockNumber() + challengeWindowSize);
            mockPDPVerifier.nextProvingPeriod(
                PDPListener(address(pdpServiceWithPayments)),
                testDataSetId,
                vm.getBlockNumber() + maxProvingPeriod,
                100,
                ""
            );
            vm.roll(vm.getBlockNumber() + maxProvingPeriod - challengeWindowSize);
        }

        for (uint256 i = 0; i < 2049; i++) {
            assertTrue(pdpServiceWithPayments.provenPeriods(testDataSetId, i));
        }
    }

    function testConfigureProvingPeriod() public {
        // Test that we can call configureProvingPeriod to set new proving period parameters
        uint64 newMaxProvingPeriod = 120; // 2 hours
        uint256 newChallengeWindowSize = 30;

        // The owner configures the existing proxy storage through the proving module.
        provingModule.configureProvingPeriod(newMaxProvingPeriod, newChallengeWindowSize);

        // Verify the values were set correctly
        (uint64 updatedMaxProvingPeriod, uint256 updatedChallengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        assertEq(updatedMaxProvingPeriod, newMaxProvingPeriod, "Max proving period should be updated");
        assertEq(updatedChallengeWindow, newChallengeWindowSize, "Challenge window size should be updated");
    }

    function testConfigureProvingPeriodWithInvalidParameters() public {
        // Test that configureChallengePeriod validates parameters correctly

        // Test zero max proving period
        vm.expectRevert(abi.encodeWithSelector(Errors.MaxProvingPeriodZero.selector));
        provingModule.configureProvingPeriod(0, 30);

        // Test zero challenge window size
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidChallengeWindowSize.selector, 120, 0));
        provingModule.configureProvingPeriod(120, 0);

        // Test challenge window size >= max proving period
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidChallengeWindowSize.selector, 120, 120));
        provingModule.configureProvingPeriod(120, 120);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidChallengeWindowSize.selector, 120, 150));
        provingModule.configureProvingPeriod(120, 150);
    }

    /**
     * @notice Empty dataset (no pieces ever added): SP cannot prove possession because
     * nextProvingPeriod was never called, so provingDeadlines remains NO_PROVING_DEADLINE.
     */
    function testEmptyDataset_CannotProveWhenNoPieces() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Empty");

        // Proving deadline is never set — possessionProven must revert
        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(abi.encodeWithSelector(Errors.ProvingNotStarted.selector, dataSetId));
        provingModule.possessionProven(dataSetId, 0, 12345, CHALLENGES_PER_PROOF);
    }

    function testEmptyDataset_ReactivationRejectsPreviouslyProvenPeriod() public {
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

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 firstDeadline = block.number + maxProvingPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstDeadline, leafCount, ""
        );

        vm.roll(firstDeadline - (challengeWindow / 2));
        vm.prank(address(mockPDPVerifier));
        provingModule.possessionProven(dataSetId, leafCount, 12345, CHALLENGES_PER_PROOF);

        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );
        mockPDPVerifier.nextProvingPeriod(PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, 0, "");
        mockPDPVerifier.setDataSetLeafCount(dataSetId, 0);

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

        uint256 firstAllowedDeadline = firstDeadline + maxProvingPeriod;
        uint256 firstAllowedWindowStart = firstAllowedDeadline - challengeWindow;
        assertEq(
            pdpServiceWithPayments.nextPDPChallengeWindowStart(dataSetId),
            firstAllowedWindowStart,
            "State view should skip the previously proven period"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidChallengeEpoch.selector,
                dataSetId,
                firstAllowedWindowStart,
                firstAllowedDeadline,
                firstDeadline
            )
        );
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstDeadline, leafCount, ""
        );

        uint256 challengeEpoch = firstAllowedWindowStart + (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, leafCount, ""
        );

        assertTrue(pdpServiceWithPayments.provenPeriods(dataSetId, 0), "Original period should remain proven");
        assertFalse(pdpServiceWithPayments.provenPeriods(dataSetId, 1), "Reactivated period should require a new proof");
        assertEq(
            pdpServiceWithPayments.provingDeadline(dataSetId),
            firstAllowedDeadline,
            "Reactivation should resume at the first safe deadline"
        );
    }

    function testEmptyDataset_ReactivationRejectsFarFutureChallengeEpoch() public {
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

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 firstDeadline = block.number + maxProvingPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstDeadline, leafCount, ""
        );

        vm.roll(firstDeadline - (challengeWindow / 2));
        vm.prank(address(mockPDPVerifier));
        provingModule.possessionProven(dataSetId, leafCount, 12345, CHALLENGES_PER_PROOF);

        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );
        mockPDPVerifier.nextProvingPeriod(PDPListener(address(pdpServiceWithPayments)), dataSetId, 0, 0, "");
        mockPDPVerifier.setDataSetLeafCount(dataSetId, 0);

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

        uint256 firstAllowedDeadline = firstDeadline + maxProvingPeriod;
        uint256 firstAllowedWindowStart = firstAllowedDeadline - challengeWindow;

        // A challengeEpoch landing in the period *after* the earliest allowed one must still be
        // rejected -- the SP cannot defer resumed proving by picking a later canonical period.
        uint256 farFutureChallengeEpoch = firstAllowedDeadline + maxProvingPeriod - (challengeWindow / 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidChallengeEpoch.selector,
                dataSetId,
                firstAllowedWindowStart,
                firstAllowedDeadline,
                farFutureChallengeEpoch
            )
        );
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, farFutureChallengeEpoch, leafCount, ""
        );
    }

    function testUpdatePaymentRates_NextProvingPeriodAfterRemovalUsesRawSize() public {
        address payer = makeAddr("rawSizeRemovalClient");
        require(mockUSDFC.transfer(payer, 100e18));
        vm.startPrank(payer);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), 100e18);
        payments.deposit(mockUSDFC, payer, 100e18);
        vm.stopPrank();

        (string[] memory dsKeys, string[] memory dsValues) = _getSingleMetadataKV("label", "Removal Raw Size Test");
        bytes memory createData = abi.encode(payer, uint256(7002), dsKeys, dsValues, FAKE_SIGNATURE);
        makeSignaturePass(payer);
        vm.prank(serviceProvider);
        uint256 dataSetId = mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), createData);

        // Two pieces; we'll remove one and verify nextProvingPeriod recomputes on the remaining.
        Cids.Cid[] memory pieceData = new Cids.Cid[](2);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256("piece_a"));
        pieceData[1] = Cids.CommPv2FromDigest(0, 35, keccak256("piece_b"));
        uint256 perPieceLeaves = Cids.leafCount(0, 35);

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

        (uint64 provingPeriod,,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 firstDeadline = block.number + provingPeriod;
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstDeadline, 2 * perPieceLeaves, ""
        );

        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 1;
        makeSignaturePass(payer);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        // Advance past the deadline and call nextProvingPeriod with the post-removal leaf count.
        vm.roll(firstDeadline + 1);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstDeadline + provingPeriod, perPieceLeaves, ""
        );

        uint256 actualRate = payments.getRail(pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId).paymentRate;
        uint256 expectedRate = calculateStorageSizeBasedRatePerEpoch(Cids.leafCountToRawSize(perPieceLeaves));
        uint256 buggyRate = calculateStorageSizeBasedRatePerEpoch(perPieceLeaves * 32);
        assertEq(actualRate, expectedRate, "post-removal rate should price on raw bytes");
        // 127/128 ratio applies only to the size-proportional component; strip the additive dataset fee before checking.
        assertApproxEqAbs(
            actualRate - DATASET_FEE_PER_EPOCH,
            ((buggyRate - DATASET_FEE_PER_EPOCH) * 127) / 128,
            1,
            "post-removal ratio between raw and Fr32 rates is 127/128"
        );
    }

    function testRailTerminated_RevertsIfCallerNotPaymentsContract() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

        vm.expectRevert(abi.encodeWithSelector(Errors.CallerNotPayments.selector, address(payments), address(sp1)));
        vm.prank(sp1);
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 123);
    }

    function testRailTerminated_RevertsIfTerminatorNotServiceContract() public {
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

        vm.expectEmit(true, true, true, true);
        emit IFilecoinWarmStorageService.PDPPaymentTerminated(dataSetId, 123, info.pdpRailId);
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 123);

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pdpEndEpoch, 123);
        // CDN rails don't track endEpoch in DataSetInfo
    }

    function testRailTerminated_DoesNotOverwritePdpEndEpoch() public {
        (string[] memory metadataKeys, string[] memory metadataValues) = _getSingleMetadataKV("withCDN", "true");
        uint256 dataSetId = createDataSetForClient(sp1, client, metadataKeys, metadataValues);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

        vm.expectEmit(true, true, true, true);
        emit IFilecoinWarmStorageService.PDPPaymentTerminated(dataSetId, 123, info.pdpRailId);
        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 123);

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pdpEndEpoch, 123);

        vm.prank(address(payments));
        pdpServiceWithPayments.railTerminated(info.pdpRailId, address(pdpServiceWithPayments), 321);

        info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pdpEndEpoch, 123);
    }

    /**
     * @notice Test: All epochs proven - should pay full amount
     */
    function testValidatePayment_AllEpochsProven() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();

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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 challengeEpoch = vm.getBlockNumber() + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Move forward 3 periods without submitting proofs
        vm.roll(activationEpoch + (maxProvingPeriod * 3));

        // Validate payment
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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
        assertEq(result.settleUpto, toEpoch, "Should settle to end epoch");
    }

    function testValidatePayment_FirstPeriodUnproven() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Test");

        // Start proving
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 firstChallengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, firstChallengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();
        assertEq(activationEpoch, pdpServiceWithPayments.provingActivationEpoch(dataSetId));

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

        assertFalse(pdpServiceWithPayments.provenPeriods(dataSetId, 0));
        assertTrue(pdpServiceWithPayments.provenPeriods(dataSetId, 1));
        assertTrue(pdpServiceWithPayments.provenPeriods(dataSetId, 2));

        // Validate payment for all 3 periods
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
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

        assertEq(pdpServiceWithPayments.provingDeadline(dataSetId), 0, "Empty dataset should suspend proving");
        assertEq(
            pdpServiceWithPayments.provingActivationEpoch(dataSetId),
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

        uint256 challengeWindowStart = pdpServiceWithPayments.nextPDPChallengeWindowStart(dataSetId);
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
            pdpServiceWithPayments.provingActivationEpoch(dataSetId),
            activationEpoch,
            "Reactivation should preserve the original activation epoch"
        );
        assertEq(
            pdpServiceWithPayments.provingDeadline(dataSetId),
            reactivationDeadline,
            "Callback should accept the deadline returned by the state view"
        );
        assertTrue(pdpServiceWithPayments.provenPeriods(dataSetId, 0), "Original proven period should remain recorded");

        uint256 reactivationPeriod =
            FWSSProvingModule(address(pdpServiceWithPayments)).getProvingPeriodForEpoch(dataSetId, challengeEpoch);
        assertFalse(
            pdpServiceWithPayments.provenPeriods(dataSetId, reactivationPeriod),
            "Reactivated period should not inherit an old proof bit"
        );

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        (uint256 oldSettlementAmount,,,, uint256 oldSettlementEpoch,) =
            payments.settleRail(info.pdpRailId, firstDeadline);
        assertGt(oldSettlementAmount, 0, "Original proven period should remain payable");
        assertEq(oldSettlementEpoch, firstDeadline, "Original period should settle after reactivation");

        vm.roll(challengeEpoch);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments))
            .possessionProven(dataSetId, leafCount, 67890, CHALLENGES_PER_PROOF);
        assertTrue(
            pdpServiceWithPayments.provenPeriods(dataSetId, reactivationPeriod),
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

        vm.roll(vm.getBlockNumber() + 1000);

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory railBeforeActivation = payments.getRail(info.pdpRailId);

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        vm.roll(block.number + 3);
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, leafCount, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();
        assertEq(pdpServiceWithPayments.provingActivationEpoch(dataSetId), activationEpoch, "Activation epoch mismatch");
        assertLt(railBeforeActivation.settledUpTo, activationEpoch, "Rail should need activation-boundary settlement");

        bytes memory sig = abi.encode(FAKE_SIGNATURE);
        makeSignaturePass(client);
        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId, sig);

        DataSetInfoView memory terminatedInfo = pdpServiceWithPayments.getDataSet(dataSetId);
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
        assertEq(
            pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId, 0, "Dataset should be deleted after finalization"
        );
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

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory railBeforeActivation = payments.getRail(info.pdpRailId);
        assertLt(
            railBeforeActivation.settledUpTo, block.number, "Second addition should leave a pre-activation rate segment"
        );

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
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
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Prove period 0
        vm.roll(challengeEpoch);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments)).possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

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
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Move forward 3 periods without submitting any proofs
        // All 3 period deadlines will have passed
        vm.roll(activationEpoch + (maxProvingPeriod * 3) + 1);

        // Validate payment - should advance settleUpTo to cover all passed periods
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 challengeEpoch = block.number + maxProvingPeriod - (challengeWindow / 2);

        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), dataSetId, challengeEpoch, 100, ""
        );

        uint256 activationEpoch = vm.getBlockNumber();

        // Move forward only halfway through the first period (deadline hasn't passed)
        vm.roll(activationEpoch + (maxProvingPeriod / 2));

        // Validate payment - should NOT advance because deadline hasn't passed
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
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
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
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
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);

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
        DataSetInfoView memory deletedInfo = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(deletedInfo.pdpRailId, 0, "Dataset should be deleted");
    }
}
