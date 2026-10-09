// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Cids} from "@pdp/Cids.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {AbiCheats} from "@erc8167/lib/AbiCheats.sol";
import {ProxyStorage} from "@erc8167/lib/ProxyStorage.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {FWSSOwnable} from "../../src/lib/FWSSOwnable.sol";
import {CHALLENGES_PER_PROOF, FilecoinWarmStorageService} from "../../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../../src/FilecoinWarmStorageServiceStateView.sol";
import {Errors} from "../../src/Errors.sol";
import {IFWSSConfig} from "../../src/interfaces/IFWSSConfig.sol";
import {FWSSConfigModule} from "../../src/modules/FWSSConfigModule.sol";
import {FWSSProvingModule} from "../../src/modules/FWSSProvingModule.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";

abstract contract FWSSProvingModuleFixture is FilecoinWarmStorageServiceFixture {
    FWSSProvingModule internal provingModule;
    FilecoinWarmStorageService internal warmStorageService;

    function _installProvingModule() internal {
        address proxy = address(pdpServiceWithPayments);
        address legacyImplementation = address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
        address legacyPayments = pdpServiceWithPayments.paymentsContractAddress();
        address legacyPDPVerifier = pdpServiceWithPayments.pdpVerifierAddress();
        address dispatcher = deployCode("lib/erc8167/out/Proxy.evm/Proxy.json");
        FWSSProvingModule implementation = new FWSSProvingModule();
        FWSSConfigModule configModule = new FWSSConfigModule(legacyPayments, legacyPDPVerifier, mockUSDFC);

        // Preserve legacy routes and route proving and configuration to their modules.
        bytes4[] memory selectors = AbiCheats.getSelectors(
            vm, "out/FilecoinWarmStorageServiceFixture.sol/FilecoinWarmStorageServiceHarness.json"
        );
        for (uint256 i; i < selectors.length; ++i) {
            _route(proxy, selectors[i], legacyImplementation);
        }
        selectors = AbiCheats.getSelectors(vm, "out/FWSSProvingModule.sol/FWSSProvingModule.json");
        for (uint256 i; i < selectors.length; ++i) {
            _route(proxy, selectors[i], address(implementation));
        }
        selectors = AbiCheats.getSelectors(vm, "out/FWSSConfigModule.sol/FWSSConfigModule.json");
        for (uint256 i; i < selectors.length; ++i) {
            _route(proxy, selectors[i], address(configModule));
        }

        vm.store(proxy, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(dispatcher))));
        provingModule = FWSSProvingModule(address(pdpServiceWithPayments));
        warmStorageService = pdpServiceWithPayments;
    }

    function _route(address proxy, bytes4 selector, address implementation) internal {
        vm.store(proxy, ProxyStorage.delegateStorageKey(selector), bytes32(uint256(uint160(implementation))));
    }

    function createDataSetForServiceProviderTest(address provider, address clientAddress, string memory)
        internal
        returns (uint256)
    {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "Test Data Set");
        return createDataSetForClient(provider, clientAddress, keys, values);
    }
}

contract FWSSProvingModuleTest is FWSSProvingModuleFixture {
    function setUp() public override {
        super.setUp();
        _installProvingModule();
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
        assertEq(selectors.length, 4);
        for (uint256 i; i < selectors.length; ++i) {
            assertTrue(selectors[i] != IFWSSConfig.paymentsContractAddress.selector);
            assertTrue(selectors[i] != IFWSSConfig.pdpVerifierAddress.selector);
        }
    }

    function testVerifierAuthorizationFollowsConfigRoute() public {
        address newVerifier = address(0x1234);
        FWSSConfigModule configModule = new FWSSConfigModule(address(payments), newVerifier, mockUSDFC);
        _route(address(provingModule), IFWSSConfig.pdpVerifierAddress.selector, address(configModule));

        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OnlyPDPVerifierAllowed.selector, newVerifier, address(mockPDPVerifier))
        );
        provingModule.possessionProven(1, 0, 0, CHALLENGES_PER_PROOF);

        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Updated verifier");
        (uint64 maxPeriod, uint256 window,,) = viewContract.getPDPConfig();
        uint256 deadline = block.number + maxPeriod;
        vm.prank(newVerifier);
        provingModule.nextProvingPeriod(dataSetId, deadline, 100, "");
        vm.roll(deadline - window / 2);
        vm.prank(newVerifier);
        provingModule.possessionProven(dataSetId, 100, 0, CHALLENGES_PER_PROOF);
        assertTrue(viewContract.provenPeriods(dataSetId, 0));
    }

    function testProvenPeriods() public {
        uint256 testDataSetId = createDataSetForServiceProviderTest(sp1, client, "Test Data Set");
        for (uint256 i = 0; i < 2049; i++) {
            assertFalse(viewContract.provenPeriods(testDataSetId, i));
        }
        (uint64 maxProvingPeriod, uint256 challengeWindowSize,,) = viewContract.getPDPConfig();
        mockPDPVerifier.nextProvingPeriod(
            PDPListener(address(pdpServiceWithPayments)), testDataSetId, vm.getBlockNumber() + maxProvingPeriod, 100, ""
        );
        vm.roll(vm.getBlockNumber() + maxProvingPeriod - challengeWindowSize);
        for (uint256 i = 0; i < 2049; i++) {
            assertFalse(viewContract.provenPeriods(testDataSetId, i));
            vm.prank(address(mockPDPVerifier));
            provingModule.possessionProven(testDataSetId, 100, 12345, CHALLENGES_PER_PROOF);
            assertTrue(viewContract.provenPeriods(testDataSetId, i));

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
            assertTrue(viewContract.provenPeriods(testDataSetId, i));
        }
    }

    function testConfigureProvingPeriod() public {
        // Test that we can call configureProvingPeriod to set new proving period parameters
        uint64 newMaxProvingPeriod = 120; // 2 hours
        uint256 newChallengeWindowSize = 30;

        // The owner configures the existing proxy storage through the proving module.
        provingModule.configureProvingPeriod(newMaxProvingPeriod, newChallengeWindowSize);

        // Deploy view contract and verify values through it
        FilecoinWarmStorageServiceStateView viewContract = new FilecoinWarmStorageServiceStateView(warmStorageService);
        warmStorageService.setViewContract(address(viewContract));

        // Verify the values were set correctly through the view contract
        (uint64 updatedMaxProvingPeriod, uint256 updatedChallengeWindow,,) = viewContract.getPDPConfig();
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

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
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
            viewContract.nextPDPChallengeWindowStart(dataSetId),
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

        assertTrue(viewContract.provenPeriods(dataSetId, 0), "Original period should remain proven");
        assertFalse(viewContract.provenPeriods(dataSetId, 1), "Reactivated period should require a new proof");
        assertEq(
            viewContract.provingDeadline(dataSetId),
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

        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = viewContract.getPDPConfig();
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
}

contract FWSSProvingModuleLegacyStateTest is FWSSProvingModuleFixture {
    function testExistingProofsAndPendingPaymentsSurviveExtraction() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "Legacy");
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, 35, keccak256("legacy-piece"));
        uint256 leafCount = Cids.leafCount(0, 35);
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments,
            dataSetId,
            0,
            pieces,
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        (uint64 maxPeriod, uint256 window,,) = viewContract.getPDPConfig();
        uint256 firstDeadline = block.number + maxPeriod;
        mockPDPVerifier.nextProvingPeriod(pdpServiceWithPayments, dataSetId, firstDeadline, leafCount, "");
        vm.roll(firstDeadline - window / 2);
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, leafCount, 0, CHALLENGES_PER_PROOF);

        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("legacy", "value");
        _seedLegacyPieceMetadata(dataSetId, 0, keys, values);
        uint256[] memory pieceIds = new uint256[](1);
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );
        FilecoinWarmStorageService.DataSetInfoView memory beforeInfo = viewContract.getDataSet(dataSetId);
        assertGt(beforeInfo.pendingOneTimePayments, 0);
        uint256 activation = viewContract.provingActivationEpoch(dataSetId);

        _installProvingModule();

        assertEq(abi.encode(viewContract.getDataSet(dataSetId)), abi.encode(beforeInfo));
        assertEq(viewContract.provingActivationEpoch(dataSetId), activation);
        assertEq(viewContract.provingDeadline(dataSetId), firstDeadline);
        assertTrue(viewContract.provenPeriods(dataSetId, 0));
        assertEq(_legacyPieceMetadataValue(dataSetId, 0, "legacy"), "value");

        mockPDPVerifier.nextProvingPeriod(pdpServiceWithPayments, dataSetId, firstDeadline + maxPeriod, leafCount, "");
        FilecoinWarmStorageService.DataSetInfoView memory afterInfo = viewContract.getDataSet(dataSetId);
        assertEq(afterInfo.pdpRailId, beforeInfo.pdpRailId);
        assertEq(afterInfo.pendingOneTimePayments, 0);
        assertEq(
            afterInfo.lifecycleReserveBalance, beforeInfo.lifecycleReserveBalance - beforeInfo.pendingOneTimePayments
        );
        assertEq(payments.getRail(afterInfo.pdpRailId).lockupFixed, afterInfo.lifecycleReserveBalance);
        assertEq(_legacyPieceMetadataKeysLength(dataSetId, 0), 0);
        assertEq(_legacyPieceMetadataValue(dataSetId, 0, "legacy"), "");
        assertTrue(viewContract.provenPeriods(dataSetId, 0));
        assertEq(viewContract.provingActivationEpoch(dataSetId), activation);
    }
}
