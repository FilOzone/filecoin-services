// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Migrate} from "@erc8167/interfaces/Migrate.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Cids} from "@pdp/Cids.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IFilecoinWarmStorageService} from "../src/interfaces/IFilecoinWarmStorageService.sol";
import {ILegacyFilecoinWarmStorageService} from "../src/interfaces/ILegacyFilecoinWarmStorageService.sol";
import {Errors} from "../src/Errors.sol";
import {FWSSDispatcherTransition} from "../src/FWSSDispatcherTransition.sol";
import {CHALLENGES_PER_PROOF} from "../src/lib/FWSSConstants.sol";
import {FilecoinWarmStorageServiceStateLibrary as State} from "../src/lib/FilecoinWarmStorageServiceStateLibrary.sol";
import {DataSetInfoView} from "../src/lib/FWSSViewTypes.sol";
import {TestDataSetAuthorizer} from "./FilecoinWarmStorageService.t.sol";
import {
    FilecoinWarmStorageServiceFixture,
    LegacyPieceMetadataFacet
} from "./helpers/FilecoinWarmStorageServiceFixture.sol";

/// @dev Seeds data sets, rails, proofs and pending payments through the deployed mainnet v1.4.0 bytecode, runs the
/// dispatcher transition, then drives that state through the facets. Remove it with `FWSSDispatcherTransition` once
/// Calibnet and Mainnet run the dispatcher.
contract FWSSV140DataTransitionTest is FilecoinWarmStorageServiceFixture {
    string private constant V1_4_0_MAINNET = "test/fixtures/fwss-v1.4.0-mainnet.json";
    uint64 private constant MAX_PROVING_PERIOD = 2880;
    // v1.4.0's slots for dataSetPieceMetadataKeys and scheduledPieceMetadataRemovals
    uint256 private constant PIECE_METADATA_KEYS_SLOT = 14;
    uint256 private constant SCHEDULED_REMOVALS_SLOT = 22;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    ILegacyFilecoinWarmStorageService internal legacy;
    address internal proxy;
    address internal dispatcher;
    address internal migration;
    FWSSDispatcherTransition internal transition;

    // The v1.4.0 dependency immutables as deployed, before this fixture repoints them.
    address[6] internal mainnetDependencies;

    // Pays for the proving data set, with a key so it can sign for real.
    address internal signer;
    uint256 internal signerKey;

    uint256 internal cdnDataSetId;
    uint256 internal provingDataSetId;
    uint256 internal provingClientDataSetId;
    uint256 internal addPiecesNonce;
    uint256 internal leafCount;
    uint256 internal firstDeadline;
    uint256 internal activationBefore;
    DataSetInfoView internal cdnBefore;
    DataSetInfoView internal provingBefore;

    function setUp() public override {
        super.setUp();
        string memory fixture = vm.readFile(V1_4_0_MAINNET);

        // Its UUPS onlyProxy check compares the implementation slot with its own mainnet address, so it stays there.
        address implementation = vm.parseJsonAddress(fixture, ".implementation.address");
        vm.etch(implementation, vm.parseJsonBytes(fixture, ".implementation.code"));
        ILegacyFilecoinWarmStorageService mainnet = ILegacyFilecoinWarmStorageService(implementation);
        mainnetDependencies = [
            mainnet.paymentsContractAddress(),
            mainnet.pdpVerifierAddress(),
            address(mainnet.usdfcTokenAddress()),
            mainnet.filBeamBeneficiaryAddress(),
            address(mainnet.serviceProviderRegistry()),
            address(mainnet.sessionKeyRegistry())
        ];

        // Repoint the six dependency immutables at this fixture's stack; the rest is the deployed bytecode.
        address[6] memory local = [
            address(payments),
            address(mockPDPVerifier),
            address(mockUSDFC),
            filBeamBeneficiary,
            address(serviceProviderRegistry),
            address(sessionKeyRegistry)
        ];
        bytes memory code = implementation.code;
        for (uint256 i; i < local.length; ++i) {
            _patchImmutable(code, mainnetDependencies[i], local[i]);
        }
        vm.etch(implementation, code);
        for (uint256 i; i < 2; ++i) {
            string memory lib = i == 0 ? ".signatureVerificationLib" : ".railsLib";
            vm.etch(
                vm.parseJsonAddress(fixture, string.concat(lib, ".address")),
                vm.parseJsonBytes(fixture, string.concat(lib, ".code"))
            );
        }

        proxy = vm.parseJsonAddress(fixture, ".proxy.address");
        vm.etch(proxy, vm.parseJsonBytes(fixture, ".proxy.code"));
        vm.store(proxy, ERC1967Utils.IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
        legacy = ILegacyFilecoinWarmStorageService(proxy);
        legacy.initialize(MAX_PROVING_PERIOD, 60, filBeamController);
        for (uint256 providerId = 1; providerId <= 4; ++providerId) {
            legacy.addApprovedProvider(providerId);
        }

        // The fixture's helpers now drive v1.4.0; the facets get the same dependencies from super.setUp().
        pdpServiceWithPayments = IFilecoinWarmStorageService(proxy);
        dispatcher = _deployDispatcher();
        migration = _createFacetMigration();
        transition = new FWSSDispatcherTransition(implementation, dispatcher, migration);
        legacy.announceUpgradePlan(address(transition), 1);

        (signer, signerKey) = makeAddrAndKey("v1.4.0 payer");
        assertTrue(mockUSDFC.transfer(signer, 1000e18));
        _seedCDNDataSet();
        _seedProvingDataSet();

        (, uint96 afterEpoch) = State.nextUpgrade(pdpServiceWithPayments);
        if (block.number < afterEpoch) vm.roll(afterEpoch);
    }

    function testFacetDependenciesMatchV140Mainnet() public view {
        string memory json = vm.readFile("josuke.json");
        string[6] memory names = [
            "_paymentsContractAddress",
            "_pdpVerifierAddress",
            "_usdfc",
            "_filBeamBeneficiaryAddress",
            "_serviceProviderRegistry",
            "_sessionKeyRegistry"
        ];
        for (uint256 i; i < names.length; ++i) {
            string memory key = string.concat(".[0].deployments.314.constructorArgs.", names[i]);
            assertEq(vm.parseJsonAddress(json, key), mainnetDependencies[i], names[i]);
        }
    }

    function testFacetsReadV140State() public {
        _transition();

        assertEq(abi.encode(pdpServiceWithPayments.getDataSet(cdnDataSetId)), abi.encode(cdnBefore));
        assertEq(abi.encode(pdpServiceWithPayments.getDataSet(provingDataSetId)), abi.encode(provingBefore));
        assertEq(pdpServiceWithPayments.provingActivationEpoch(provingDataSetId), activationBefore);
        assertEq(pdpServiceWithPayments.provingDeadline(provingDataSetId), firstDeadline);
        assertTrue(pdpServiceWithPayments.provenPeriods(provingDataSetId, 0));
        assertEq(_legacyPieceMetadataValue(provingDataSetId, 0, "legacy"), "value");

        // The comparisons above read through the same generated layout on both sides; these do not depend on it.
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(provingDataSetId);
        assertEq(info.dataSetId, provingDataSetId);
        assertEq(info.clientDataSetId, provingClientDataSetId);
        assertEq(info.payer, signer);
        assertEq(info.serviceProvider, sp1);
        assertEq(pdpServiceWithPayments.railToDataSet(info.pdpRailId), provingDataSetId);
        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        assertEq(rail.from, signer);
        assertEq(rail.to, info.payee);
        assertEq(rail.operator, proxy);
        assertEq(rail.validator, proxy);
        assertEq(payments.getRail(cdnBefore.cdnRailId).from, client);

        (bool withCDN,) = pdpServiceWithPayments.getDataSetMetadata(cdnDataSetId, "withCDN");
        assertTrue(withCDN);
        assertEq(pdpServiceWithPayments.owner(), address(this));
        assertEq(pdpServiceWithPayments.filBeamControllerAddress(), filBeamController);
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        assertEq(maxProvingPeriod, MAX_PROVING_PERIOD);
        assertEq(challengeWindow, 60);
    }

    function testProvingAndPendingPaymentsContinue() public {
        _transition();

        (uint64 maxPeriod,,,) = pdpServiceWithPayments.getPDPConfig();
        mockPDPVerifier.nextProvingPeriod(
            pdpServiceWithPayments, provingDataSetId, firstDeadline + maxPeriod, leafCount, ""
        );

        DataSetInfoView memory afterInfo = pdpServiceWithPayments.getDataSet(provingDataSetId);
        assertEq(afterInfo.pdpRailId, provingBefore.pdpRailId);
        assertEq(afterInfo.pendingOneTimePayments, 0);
        assertEq(
            afterInfo.lifecycleReserveBalance,
            provingBefore.lifecycleReserveBalance - provingBefore.pendingOneTimePayments
        );
        assertEq(payments.getRail(afterInfo.pdpRailId).lockupFixed, afterInfo.lifecycleReserveBalance);
        assertEq(_legacyPieceMetadataKeysLength(provingDataSetId, 0), 0);
        assertEq(_legacyPieceMetadataValue(provingDataSetId, 0, "legacy"), "");
        assertTrue(pdpServiceWithPayments.provenPeriods(provingDataSetId, 0));
        assertEq(pdpServiceWithPayments.provingActivationEpoch(provingDataSetId), activationBefore);
    }

    function testCDNRailsContinue() public {
        _transition();
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(cdnBefore.cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(cdnBefore.cacheMissRailId);

        vm.prank(client);
        pdpServiceWithPayments.topUpCDNPaymentRails(cdnDataSetId, 100000, 50000);
        assertEq(payments.getRail(cdnBefore.cdnRailId).lockupFixed, cdnRail.lockupFixed + 100000);
        assertEq(payments.getRail(cdnBefore.cacheMissRailId).lockupFixed, cacheMissRail.lockupFixed + 50000);

        vm.prank(filBeamController);
        pdpServiceWithPayments.settleFilBeamPaymentRails(cdnDataSetId, 50000, 25000);
        assertEq(payments.getRail(cdnBefore.cdnRailId).lockupFixed, cdnRail.lockupFixed + 50000);
        assertEq(payments.getRail(cdnBefore.cacheMissRailId).lockupFixed, cacheMissRail.lockupFixed + 25000);

        vm.prank(filBeamController);
        pdpServiceWithPayments.terminateCDNService(cdnDataSetId);
        assertGt(payments.getRail(cdnBefore.cdnRailId).endEpoch, 0);
        assertGt(payments.getRail(cdnBefore.cacheMissRailId).endEpoch, 0);
        assertEq(payments.getRail(cdnBefore.pdpRailId).endEpoch, 0);
        (bool withCDN,) = pdpServiceWithPayments.getDataSetMetadata(cdnDataSetId, "withCDN");
        assertFalse(withCDN);
    }

    /// @dev Settles across a proven and an unproven period, so the facets' validatePayment must pay what v1.4.0 pays.
    function testSettlementMatchesV140() public {
        vm.roll(firstDeadline + MAX_PROVING_PERIOD + 10);
        _assertSameAcrossTransition(_settleProvingRail);
    }

    function testNextProvingPeriodMatchesV140() public {
        _assertSameAcrossTransition(_startNextProvingPeriod);
    }

    /// @dev Terminating goes through FilecoinPay's terminateRail and back into railTerminated on the proxy.
    function testTerminationMatchesV140() public {
        _assertSameAcrossTransition(_terminateCDNDataSet);
    }

    function testDataSetTerminatedOnV140DeletesAfterTransition() public {
        vm.prank(signer);
        legacy.terminateService(provingDataSetId);
        uint256 endEpoch = State.getDataSet(pdpServiceWithPayments, provingDataSetId).pdpEndEpoch;
        assertGt(endEpoch, 0);
        uint256 clientDataSets = State.getClientDataSetsLength(pdpServiceWithPayments, signer);

        _transition();
        // Settlement waits for the deadline of the last period
        vm.roll(endEpoch + MAX_PROVING_PERIOD + 1);
        payments.settleRail(provingBefore.pdpRailId, endEpoch);
        mockPDPVerifier.deleteDataSet(pdpServiceWithPayments, provingDataSetId, "");

        assertEq(pdpServiceWithPayments.getDataSet(provingDataSetId).pdpRailId, 0);
        assertEq(pdpServiceWithPayments.provingActivationEpoch(provingDataSetId), 0);
        assertFalse(pdpServiceWithPayments.provenPeriods(provingDataSetId, 0));
        assertEq(State.getClientDataSetsLength(pdpServiceWithPayments, signer), clientDataSets - 1);
        assertEq(pdpServiceWithPayments.clientNonces(signer, provingClientDataSetId), provingDataSetId);
    }

    function testV140NoncesStillBlockReplay() public {
        _transition();

        bytes memory createData =
            abi.encode(signer, provingClientDataSetId, new string[](0), new string[](0), FAKE_SIGNATURE);
        makeSignaturePass(signer);
        vm.prank(sp1);
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, provingClientDataSetId));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, createData);

        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, 35, keccak256("replayed-piece"));
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, addPiecesNonce));
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments,
            provingDataSetId,
            2,
            pieces,
            addPiecesNonce,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );
    }

    /// @dev A client signs against the domain v1.4.0 reports, and the facets accept it after the transition.
    function testSignatureForV140DomainVerifiesAfterTransition() public {
        bytes32 domainBefore = _domainSeparator();
        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 1;
        bytes32 structHash = keccak256(
            abi.encode(SCHEDULE_PIECE_REMOVALS_TYPEHASH, provingClientDataSetId, keccak256(abi.encodePacked(pieceIds)))
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, keccak256(abi.encodePacked("\x19\x01", domainBefore, structHash)));

        _transition();
        vm.clearMockedCalls();
        assertEq(_domainSeparator(), domainBefore);

        uint256[] memory otherPieces = new uint256[](1);
        otherPieces[0] = 2;
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        mockPDPVerifier.piecesScheduledRemove(
            provingDataSetId, otherPieces, proxy, abi.encode(abi.encodePacked(r, s, v))
        );

        mockPDPVerifier.piecesScheduledRemove(provingDataSetId, pieceIds, proxy, abi.encode(abi.encodePacked(r, s, v)));
        assertGt(
            pdpServiceWithPayments.getDataSet(provingDataSetId).pendingOneTimePayments,
            provingBefore.pendingOneTimePayments
        );
    }

    /// @dev An authorizer attached on v1.4.0 still decides for its data set after the transition.
    function testAuthorizerSetOnV140DecidesAfterTransition() public {
        (address delegate, uint256 delegateKey) = makeAddrAndKey("authorized delegate");
        TestDataSetAuthorizer authorizer = new TestDataSetAuthorizer(sessionKeyRegistry);
        authorizer.allow(cdnDataSetId, delegate);
        vm.prank(client);
        legacy.setDataSetAuthorizer(cdnDataSetId, address(authorizer));
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", _domainSeparator(), keccak256(abi.encode(TERMINATE_SERVICE_TYPEHASH, cdnDataSetId))
            )
        );

        _transition();
        vm.clearMockedCalls();
        assertEq(pdpServiceWithPayments.getDataSetAuthorizer(cdnDataSetId), address(authorizer));

        // The payer's own key is not on the authorizer's list, so only the authorizer path can reject it
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory rejected = abi.encodePacked(r, s, v);
        vm.prank(sp1);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.Unauthorized.selector, client, TERMINATE_SERVICE_TYPEHASH, digest, rejected)
        );
        pdpServiceWithPayments.terminateService(cdnDataSetId, abi.encode(rejected));

        (v, r, s) = vm.sign(delegateKey, digest);
        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(cdnDataSetId, abi.encode(abi.encodePacked(r, s, v)));
        assertGt(pdpServiceWithPayments.getDataSet(cdnDataSetId).pdpEndEpoch, 0);
    }

    function _transition() internal {
        legacy.upgradeToAndCall(address(transition), abi.encodeCall(Migrate.migrate, (migration)));
        assertEq(address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))), dispatcher);

        LegacyPieceMetadataFacet pieceMetadata = new LegacyPieceMetadataFacet();
        _route(proxy, LegacyPieceMetadataFacet.legacyPieceMetadataKeysLength.selector, address(pieceMetadata));
        _route(proxy, LegacyPieceMetadataFacet.legacyPieceMetadataValue.selector, address(pieceMetadata));
    }

    /// @dev Runs `action` once on v1.4.0 and once after the transition, from the same state, and compares the results.
    function _assertSameAcrossTransition(function() internal returns (bytes memory) action) internal {
        uint256 snapshot = vm.snapshotState();
        bytes memory onV140 = action();

        vm.revertToState(snapshot);
        _transition();
        assertEq(action(), onV140, "facets diverge from v1.4.0");
    }

    function _settleProvingRail() internal returns (bytes memory) {
        (uint256 settled, uint256 netPayee, uint256 commission, uint256 networkFee, uint256 settledUpTo,) =
            payments.settleRail(provingBefore.pdpRailId, block.number);
        assertGt(settled, 0);
        return abi.encode(
            settled,
            netPayee,
            commission,
            networkFee,
            settledUpTo,
            payments.getRail(provingBefore.pdpRailId),
            _account(signer),
            _account(sp1)
        );
    }

    function _account(address owner) internal view returns (bytes memory) {
        (uint256 funds, uint256 lockupCurrent, uint256 lockupRate, uint256 lockupLastSettledAt) =
            payments.accounts(mockUSDFC, owner);
        return abi.encode(funds, lockupCurrent, lockupRate, lockupLastSettledAt);
    }

    function _startNextProvingPeriod() internal returns (bytes memory) {
        mockPDPVerifier.nextProvingPeriod(
            pdpServiceWithPayments, provingDataSetId, firstDeadline + MAX_PROVING_PERIOD, leafCount, ""
        );
        (bytes32 removals, bytes32 pieceKeys) = _pieceCleanupSlots();
        return abi.encode(
            State.getDataSet(pdpServiceWithPayments, provingDataSetId),
            State.provingDeadline(pdpServiceWithPayments, provingDataSetId),
            State.provingActivationEpoch(pdpServiceWithPayments, provingDataSetId),
            State.provenPeriods(pdpServiceWithPayments, provingDataSetId, 0),
            vm.load(proxy, removals),
            vm.load(proxy, pieceKeys),
            payments.getRail(provingBefore.pdpRailId)
        );
    }

    /// @dev Raw v1.4.0 slots, so the piece metadata cleanup is compared without going through FWSSStorage.
    function _pieceCleanupSlots() internal view returns (bytes32 removals, bytes32 pieceKeys) {
        removals = keccak256(abi.encode(provingDataSetId, SCHEDULED_REMOVALS_SLOT));
        pieceKeys = keccak256(abi.encode(0, keccak256(abi.encode(provingDataSetId, PIECE_METADATA_KEYS_SLOT))));
    }

    function _terminateCDNDataSet() internal returns (bytes memory) {
        vm.prank(client);
        pdpServiceWithPayments.terminateService(cdnDataSetId);
        return abi.encode(
            State.getDataSet(pdpServiceWithPayments, cdnDataSetId),
            payments.getRail(cdnBefore.pdpRailId),
            payments.getRail(cdnBefore.cdnRailId),
            payments.getRail(cdnBefore.cacheMissRailId)
        );
    }

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            pdpServiceWithPayments.eip712Domain();
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract
            )
        );
    }

    function _seedCDNDataSet() internal {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("withCDN", "true");
        cdnDataSetId = createDataSetForClient(sp1, client, keys, values);
        cdnBefore = State.getDataSet(pdpServiceWithPayments, cdnDataSetId);
        assertGt(cdnBefore.cdnRailId, 0);
        assertGt(cdnBefore.cacheMissRailId, 0);
    }

    /// @dev Two pieces, a proven period, a scheduled removal of piece 0 with its one-time payment pending, and piece
    /// metadata from before v1.4.0, which v1.4.0 no longer writes but still cleans up.
    function _seedProvingDataSet() internal {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "Legacy");
        provingClientDataSetId = nextClientDataSetId;
        provingDataSetId = createDataSetForClient(sp1, signer, keys, values);

        Cids.Cid[] memory pieces = new Cids.Cid[](2);
        pieces[0] = Cids.CommPv2FromDigest(0, 35, keccak256("legacy-piece"));
        pieces[1] = Cids.CommPv2FromDigest(0, 35, keccak256("legacy-piece-2"));
        leafCount = 2 * Cids.leafCount(0, 35);
        addPiecesNonce = nextClientDataSetId++;
        makeSignaturePass(signer);
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments,
            provingDataSetId,
            0,
            pieces,
            addPiecesNonce,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        (uint64 maxPeriod, uint256 window,,) = State.getPDPConfig(pdpServiceWithPayments);
        firstDeadline = block.number + maxPeriod;
        mockPDPVerifier.nextProvingPeriod(pdpServiceWithPayments, provingDataSetId, firstDeadline, leafCount, "");
        vm.roll(firstDeadline - window / 2);
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(provingDataSetId, leafCount, 0, CHALLENGES_PER_PROOF);

        (keys, values) = _getSingleMetadataKV("legacy", "value");
        _seedPieceMetadataInProxy(provingDataSetId, 0, keys, values);
        uint256[] memory pieceIds = new uint256[](1);
        makeSignaturePass(signer);
        mockPDPVerifier.piecesScheduledRemove(provingDataSetId, pieceIds, proxy, abi.encode(FAKE_SIGNATURE));

        (bytes32 removals, bytes32 pieceKeys) = _pieceCleanupSlots();
        assertEq(uint256(vm.load(proxy, removals)), 1);
        assertEq(uint256(vm.load(proxy, pieceKeys)), 1);

        provingBefore = State.getDataSet(pdpServiceWithPayments, provingDataSetId);
        assertGt(provingBefore.pendingOneTimePayments, 0);
        activationBefore = State.provingActivationEpoch(pdpServiceWithPayments, provingDataSetId);
    }

    /// @dev Runs the seeding facet in the proxy's storage by swapping its code, since v1.4.0 routes nothing to it.
    function _seedPieceMetadataInProxy(uint256 dataSetId, uint256 pieceId, string[] memory keys, string[] memory values)
        internal
    {
        bytes memory proxyCode = proxy.code;
        vm.etch(proxy, address(new LegacyPieceMetadataFacet()).code);
        LegacyPieceMetadataFacet(proxy).seedLegacyPieceMetadata(dataSetId, pieceId, keys, values);
        vm.etch(proxy, proxyCode);
    }

    /// @dev Replaces every PUSH32 of `from`, which is how solc embeds an address immutable.
    function _patchImmutable(bytes memory code, address from, address to) internal pure {
        bytes32 word = bytes32(uint256(uint160(from)));
        uint256 patched;
        for (uint256 i; i + 33 <= code.length; ++i) {
            bytes32 candidate;
            assembly ("memory-safe") {
                candidate := mload(add(add(code, 0x21), i))
            }
            if (code[i] == 0x7f && candidate == word) {
                assembly ("memory-safe") {
                    mstore(add(add(code, 0x21), i), to)
                }
                ++patched;
            }
        }
        require(patched != 0, "immutable not found");
    }
}
