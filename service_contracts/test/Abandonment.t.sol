// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {PDPVerifier} from "@pdp/PDPVerifier.sol";
import {Cids} from "@pdp/Cids.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FilecoinWarmStorageService, PDP_INACTIVITY_WINDOW} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {
    PROVEN_PERIODS_SLOT,
    PROVING_ACTIVATION_EPOCH_SLOT,
    PROVING_DEADLINES_SLOT,
    PROVEN_THIS_PERIOD_SLOT
} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {EPOCHS_PER_DAY} from "../src/lib/PriceListUSDFC.sol";
import {Errors} from "../src/Errors.sol";
import {MockERC20} from "./mocks/SharedMocks.sol";
import {CDNServiceTerminated, DataSetAbandoned} from "../src/lib/Rails.sol";
import {PDPOffering} from "./PDPOffering.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";

contract AbandonmentTest is MockFVMTest {
    using PDPOffering for PDPOffering.Schema;

    PDPVerifier pdpVerifier;
    FilecoinWarmStorageService fwss;
    FilecoinWarmStorageServiceStateView viewContract;
    FilecoinPayV1 payments;
    MockERC20 usdfc;
    ServiceProviderRegistry serviceProviderRegistry;
    SessionKeyRegistry sessionKeyRegistry;

    address sp = address(0xb1);
    address client = address(0xb2);
    address keeper = address(0xb3);
    address filBeamBeneficiary = address(0xb4);
    address filBeamController = address(0xb5);

    uint256 constant CLEANUP_DEPOSIT = 0.1 ether;

    bytes constant FAKE_SIG = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        uint8(27)
    );

    function setUp() public override {
        super.setUp();

        vm.deal(sp, 10 ether);
        vm.deal(client, 10 ether);
        vm.deal(keeper, 10 ether);

        usdfc = new MockERC20();
        payments = new FilecoinPayV1();
        sessionKeyRegistry = new SessionKeyRegistry();

        // Deploy real PDPVerifier as a proxy
        PDPVerifier pdpVerifierImpl = new PDPVerifier(1, 0);
        MyERC1967Proxy pdpProxy =
            new MyERC1967Proxy(address(pdpVerifierImpl), abi.encodeCall(PDPVerifier.initialize, ()));
        pdpVerifier = PDPVerifier(address(pdpProxy));

        // Deploy ServiceProviderRegistry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry(1);
        MyERC1967Proxy regProxy =
            new MyERC1967Proxy(address(registryImpl), abi.encodeCall(ServiceProviderRegistry.initialize, ()));
        serviceProviderRegistry = ServiceProviderRegistry(address(regProxy));

        // Register SP
        PDPOffering.Schema memory offering = PDPOffering.Schema({
            serviceURL: "https://sp.example.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerDay: 1 ether,
            minProvingPeriodInEpochs: 2880,
            location: "US-West",
            paymentTokenAddress: IERC20(address(0))
        });
        (string[] memory capKeys, bytes[] memory capValues) = offering.toCapabilities();
        vm.prank(sp);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            sp, "SP", "Storage Provider", ServiceProviderRegistryStorage.ProductType.PDP, capKeys, capValues
        );

        // Deploy FWSS pointing to the real PDPVerifier
        FilecoinWarmStorageService fwssImpl = new FilecoinWarmStorageService(
            address(pdpVerifier),
            address(payments),
            usdfc,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry,
            4
        );
        MyERC1967Proxy fwssProxy = new MyERC1967Proxy(
            address(fwssImpl),
            abi.encodeCall(
                FilecoinWarmStorageService.initialize,
                (uint64(2880), uint256(60), filBeamController, "Test FWSS", "Abandonment test service")
            )
        );
        fwss = FilecoinWarmStorageService(address(fwssProxy));

        viewContract = new FilecoinWarmStorageServiceStateView(fwss);
        fwss.setViewContract(address(viewContract));
        fwss.addApprovedProvider(1); // SP registered as provider ID 1

        require(usdfc.transfer(client, 1000e18));
    }

    // Assert that all storage-backed fields of a deleted dataset are zero and metadata is empty.
    function _assertDataSetCleared(uint256 dataSetId) internal view {
        bytes32 activationSlot = keccak256(abi.encode(dataSetId, uint256(PROVING_ACTIVATION_EPOCH_SLOT)));
        assertEq(uint256(vm.load(address(fwss), activationSlot)), 0, "provingActivationEpoch");

        bytes32 deadlineSlot = keccak256(abi.encode(dataSetId, uint256(PROVING_DEADLINES_SLOT)));
        assertEq(uint256(vm.load(address(fwss), deadlineSlot)), 0, "provingDeadlines");

        bytes32 provenThisPeriodSlot = keccak256(abi.encode(dataSetId, uint256(PROVEN_THIS_PERIOD_SLOT)));
        assertEq(uint256(vm.load(address(fwss), provenThisPeriodSlot)), 0, "provenThisPeriod");

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertEq(info.pdpRailId, 0, "pdpRailId");
        assertEq(info.cacheMissRailId, 0, "cacheMissRailId");
        assertEq(info.cdnRailId, 0, "cdnRailId");
        assertEq(info.payer, address(0), "payer");
        assertEq(info.payee, address(0), "payee");
        assertEq(info.serviceProvider, address(0), "serviceProvider");
        assertEq(info.commissionBps, 0, "commissionBps");
        assertEq(info.pdpEndEpoch, 0, "pdpEndEpoch");
        assertEq(info.providerId, 0, "providerId");

        (string[] memory keys,) = viewContract.getAllDataSetMetadata(dataSetId);
        assertEq(keys.length, 0, "metadata keys");
    }

    // Mock ecrecover to return the expected signer, bypassing real EIP-712 verification.
    function _makeSignaturePass(address signer) internal {
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(signer));
    }

    // Create a dataset via the real PDPVerifier and return its ID.
    // Pass withCDN=true to include the "withCDN" metadata key, enabling CDN rails.
    function _createDataSet(bool withCDN) internal returns (uint256 dataSetId) {
        vm.startPrank(client);
        payments.setOperatorApproval(usdfc, address(fwss), true, 1000e18, 1000e18, 365 days);
        usdfc.approve(address(payments), 100e18);
        payments.deposit(usdfc, client, 100e18);
        vm.stopPrank();

        string[] memory keys;
        string[] memory values;
        if (withCDN) {
            keys = new string[](1);
            keys[0] = "withCDN";
            values = new string[](1);
            values[0] = "true";
        } else {
            keys = new string[](0);
            values = new string[](0);
        }
        bytes memory extraData = abi.encode(client, uint256(0), keys, values, FAKE_SIG);

        _makeSignaturePass(client);
        vm.prank(sp);
        dataSetId = pdpVerifier.createDataSet{value: CLEANUP_DEPOSIT}(address(fwss), extraData);
    }

    // A permissionless caller cannot trigger abandonment before INACTIVITY_WINDOW has elapsed.
    function testAbandonmentBlockedBeforeWindowByPDPVerifier() public {
        uint256 dataSetId = _createDataSet(false);

        vm.roll(vm.getBlockNumber() + PDP_INACTIVITY_WINDOW / 2);

        vm.prank(keeper);
        vm.expectRevert(PDPVerifier.OnlyStorageProviderCanDelete.selector);
        pdpVerifier.deleteDataSet(dataSetId, "");
    }

    // The SP can delete its own dataset at any time, but if proving was activated FWSS rejects
    // the abandonment path when INACTIVITY_WINDOW has not yet elapsed.
    // The SP's correct alternative is terminateService, which is always available.
    function testAbandonmentBlockedBeforeWindowByFWSS() public {
        uint256 dataSetId = _createDataSet(false);
        uint256 creationBlock = vm.getBlockNumber();

        // Simulate proving activation by writing directly to FWSS storage.
        bytes32 slot = keccak256(abi.encode(dataSetId, uint256(PROVING_ACTIVATION_EPOCH_SLOT)));
        vm.store(address(fwss), slot, bytes32(creationBlock));

        // PDPVerifier allows the SP to delete at any time, but FWSS should reject it because
        // the inactivity window has not yet passed.
        vm.prank(sp);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DataSetNotAbandoned.selector, dataSetId, creationBlock + PDP_INACTIVITY_WINDOW, block.number
            )
        );
        pdpVerifier.deleteDataSet(dataSetId, "");

        // terminateService is always available as the proper termination path.
        vm.prank(sp);
        fwss.terminateService(dataSetId, "");
        assertGt(viewContract.getDataSet(dataSetId).pdpEndEpoch, 0, "pdpEndEpoch should be set after terminateService");
    }

    // After INACTIVITY_WINDOW blocks without activity, any caller can trigger abandonment.
    // FWSS should clear all dataset state and finalize the payment rail.
    function testAbandonmentClears() public {
        uint256 dataSetId = _createDataSet(false);

        FilecoinWarmStorageService.DataSetInfoView memory before = viewContract.getDataSet(dataSetId);
        assertGt(before.pdpRailId, 0, "dataset should exist before abandonment");
        assertEq(before.payer, client, "payer should be set before abandonment");

        vm.roll(vm.getBlockNumber() + PDP_INACTIVITY_WINDOW + 1);

        vm.expectEmit(true, false, false, false, address(fwss));
        emit DataSetAbandoned(dataSetId, before.pdpRailId, 0, 0);

        vm.prank(keeper);
        pdpVerifier.deleteDataSet(dataSetId, "");

        _assertDataSetCleared(dataSetId);
        assertEq(viewContract.clientDataSets(client).length, 0, "client dataset list should be empty");
    }

    // Same as testAbandonmentClears but with CDN rails enabled, exercising the CDN teardown branch.
    function testAbandonmentClearsCDN() public {
        uint256 dataSetId = _createDataSet(true);

        FilecoinWarmStorageService.DataSetInfoView memory before = viewContract.getDataSet(dataSetId);
        assertGt(before.pdpRailId, 0, "pdpRailId should be set");
        assertGt(before.cacheMissRailId, 0, "cacheMissRailId should be set");
        assertGt(before.cdnRailId, 0, "cdnRailId should be set");
        assertEq(before.payer, client, "payer should be set");

        vm.roll(vm.getBlockNumber() + PDP_INACTIVITY_WINDOW + 1);

        vm.expectEmit(true, true, false, true, address(fwss));
        emit CDNServiceTerminated(address(pdpVerifier), dataSetId, before.cacheMissRailId, before.cdnRailId);

        vm.expectEmit(true, false, false, true, address(fwss));
        emit DataSetAbandoned(dataSetId, before.pdpRailId, before.cacheMissRailId, before.cdnRailId);

        vm.prank(keeper);
        pdpVerifier.deleteDataSet(dataSetId, "");

        _assertDataSetCleared(dataSetId);
        assertEq(viewContract.clientDataSets(client).length, 0, "client dataset list should be empty");
    }

    // CDN rails carry no validator callback, so the payer can terminate them directly via
    // FilecoinPay before abandonment fires. Abandonment should still succeed.
    function testAbandonmentClearsCDNPreTerminated() public {
        uint256 dataSetId = _createDataSet(true);

        FilecoinWarmStorageService.DataSetInfoView memory before = viewContract.getDataSet(dataSetId);

        // Payer terminates the CDN rails directly on FilecoinPay, bypassing FWSS.
        vm.prank(client);
        payments.terminateRail(before.cdnRailId);
        vm.prank(client);
        payments.terminateRail(before.cacheMissRailId);

        vm.roll(vm.getBlockNumber() + PDP_INACTIVITY_WINDOW + 1);

        vm.expectEmit(true, true, false, false, address(fwss));
        emit CDNServiceTerminated(address(pdpVerifier), dataSetId, before.cacheMissRailId, before.cdnRailId);

        vm.prank(keeper);
        pdpVerifier.deleteDataSet(dataSetId, "");

        _assertDataSetCleared(dataSetId);
        assertEq(viewContract.clientDataSets(client).length, 0, "client dataset list should be empty");
    }

    function _addSinglePiece(uint256 dataSetId) internal {
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, 4, keccak256("abandonment-piece"));

        string[][] memory metadataKeys = new string[][](1);
        string[][] memory metadataValues = new string[][](1);
        metadataKeys[0] = new string[](0);
        metadataValues[0] = new string[](0);
        bytes memory addPayload = abi.encode(uint256(1), metadataKeys, metadataValues, FAKE_SIG);

        _makeSignaturePass(client);
        vm.prank(sp);
        pdpVerifier.addPieces(dataSetId, address(0), pieces, addPayload);
    }

    // Activated, all periods faulted, final period open. Without the activation-epoch wipe
    // between settles, the finalize settle reverts NoProgressInSettlement against the open
    // final period.
    function testAbandonmentClearsActivatedFaultedDataSet() public {
        uint256 dataSetId = _createDataSet(false);
        _addSinglePiece(dataSetId);

        FilecoinWarmStorageService.DataSetInfoView memory before = viewContract.getDataSet(dataSetId);

        uint256 challengeEpoch = block.number + 2880 - 5;
        vm.prank(sp);
        pdpVerifier.nextProvingPeriod(dataSetId, challengeEpoch, "");

        uint256 lastActivity = pdpVerifier.getDataSetLastProvenEpoch(dataSetId);
        vm.roll(lastActivity + pdpVerifier.INACTIVITY_WINDOW() + 2880 * 3 + 1);

        vm.expectEmit(true, false, false, false, address(fwss));
        emit DataSetAbandoned(dataSetId, before.pdpRailId, 0, 0);

        vm.prank(keeper);
        pdpVerifier.deleteDataSet(dataSetId, "");

        _assertDataSetCleared(dataSetId);
        assertEq(viewContract.clientDataSets(client).length, 0, "client dataset list should be empty");

        vm.expectRevert();
        payments.getRail(before.pdpRailId);
    }

    // Mark periods [0..periodCount) proven via direct write to the FWSS bitmap. periodCount <= 256.
    function _markPeriodsProven(uint256 dataSetId, uint256 periodCount) internal {
        require(periodCount <= 256, "single-word helper");
        bytes32 outerSlot = keccak256(abi.encode(dataSetId, uint256(PROVEN_PERIODS_SLOT)));
        bytes32 innerSlot = keccak256(abi.encode(uint256(0), outerSlot));
        uint256 mask = periodCount == 256 ? type(uint256).max : (uint256(1) << periodCount) - 1;
        vm.store(address(fwss), innerSlot, bytes32(mask));
    }

    function _payeeFunds() internal view returns (uint256) {
        (, uint256 funds,,) = payments.getAccountInfoIfSettled(usdfc, sp);
        return funds;
    }

    // Activated, proven, then SP walks away. First settle pays proven epochs; finalize settle
    // still needs the activation wipe to advance past the open final period.
    function testAbandonmentClearsActivatedProvenThenFaultedDataSet() public {
        uint256 dataSetId = _createDataSet(false);
        _addSinglePiece(dataSetId);

        FilecoinWarmStorageService.DataSetInfoView memory before = viewContract.getDataSet(dataSetId);
        uint256 payeeFundsBefore = _payeeFunds();

        uint256 challengeEpoch = block.number + 2880 - 5;
        vm.prank(sp);
        pdpVerifier.nextProvingPeriod(dataSetId, challengeEpoch, "");

        _markPeriodsProven(dataSetId, 3);

        uint256 lastActivity = pdpVerifier.getDataSetLastProvenEpoch(dataSetId);
        vm.roll(lastActivity + pdpVerifier.INACTIVITY_WINDOW() + 2880 * 3 + 1);

        vm.expectEmit(true, false, false, false, address(fwss));
        emit DataSetAbandoned(dataSetId, before.pdpRailId, 0, 0);

        vm.prank(keeper);
        pdpVerifier.deleteDataSet(dataSetId, "");

        _assertDataSetCleared(dataSetId);
        assertEq(viewContract.clientDataSets(client).length, 0, "client dataset list should be empty");
        assertGt(_payeeFunds(), payeeFundsBefore, "payee should have received payment for proven periods");

        vm.expectRevert();
        payments.getRail(before.pdpRailId);
    }

    // CDN rails + activated proving + all periods faulted. Exercises CDN teardown and the
    // activation-epoch wipe in the same abandonRails call.
    function testAbandonmentClearsCDNActivatedFaultedDataSet() public {
        uint256 dataSetId = _createDataSet(true);
        _addSinglePiece(dataSetId);

        FilecoinWarmStorageService.DataSetInfoView memory before = viewContract.getDataSet(dataSetId);
        assertGt(before.pdpRailId, 0, "pdpRailId should be set");
        assertGt(before.cacheMissRailId, 0, "cacheMissRailId should be set");
        assertGt(before.cdnRailId, 0, "cdnRailId should be set");

        uint256 challengeEpoch = block.number + EPOCHS_PER_DAY - 5;
        vm.prank(sp);
        pdpVerifier.nextProvingPeriod(dataSetId, challengeEpoch, "");

        uint256 lastActivity = pdpVerifier.getDataSetLastProvenEpoch(dataSetId);
        vm.roll(lastActivity + pdpVerifier.INACTIVITY_WINDOW() + EPOCHS_PER_DAY * 3 + 1);

        vm.expectEmit(true, true, false, true, address(fwss));
        emit CDNServiceTerminated(address(pdpVerifier), dataSetId, before.cacheMissRailId, before.cdnRailId);

        vm.expectEmit(true, false, false, false, address(fwss));
        emit DataSetAbandoned(dataSetId, before.pdpRailId, before.cacheMissRailId, before.cdnRailId);

        vm.prank(keeper);
        pdpVerifier.deleteDataSet(dataSetId, "");

        _assertDataSetCleared(dataSetId);
        assertEq(viewContract.clientDataSets(client).length, 0, "client dataset list should be empty");

        vm.expectRevert();
        payments.getRail(before.pdpRailId);
        vm.expectRevert();
        payments.getRail(before.cacheMissRailId);
        vm.expectRevert();
        payments.getRail(before.cdnRailId);
    }

    // CDN rails are finalized before abandonment fires (modifyRailLockup and settleRail both fail).
    // Payer terminates and settles the CDN rails externally, then abandonment still succeeds.
    function testAbandonmentClearsCDNPreFinalized() public {
        uint256 dataSetId = _createDataSet(true);

        FilecoinWarmStorageService.DataSetInfoView memory before = viewContract.getDataSet(dataSetId);

        // Payer terminates the CDN rails directly on FilecoinPay, bypassing FWSS.
        vm.prank(client);
        payments.terminateRail(before.cdnRailId);
        vm.prank(client);
        payments.terminateRail(before.cacheMissRailId);

        // Roll past the inactivity window, which also puts us past endEpoch for the CDN rails
        // (endEpoch = lockupLastSettledAt + DEFAULT_LOCKUP_PERIOD = ~28800, window = 86400).
        vm.roll(vm.getBlockNumber() + PDP_INACTIVITY_WINDOW + 1);

        // Settle both CDN rails to their endEpoch, finalizing them (rail struct is zeroed out).
        payments.settleRail(before.cdnRailId, block.number);
        payments.settleRail(before.cacheMissRailId, block.number);

        // Confirm finalization: getRail reverts for a zeroed-out rail.
        vm.expectRevert();
        payments.getRail(before.cdnRailId);

        vm.expectEmit(true, true, false, false, address(fwss));
        emit CDNServiceTerminated(address(pdpVerifier), dataSetId, before.cacheMissRailId, before.cdnRailId);

        vm.prank(keeper);
        pdpVerifier.deleteDataSet(dataSetId, "");

        _assertDataSetCleared(dataSetId);
        assertEq(viewContract.clientDataSets(client).length, 0, "client dataset list should be empty");
    }
}
