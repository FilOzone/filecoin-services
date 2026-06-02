// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {PDPVerifier} from "@pdp/PDPVerifier.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FilecoinWarmStorageService, PDP_INACTIVITY_WINDOW} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {PROVING_ACTIVATION_EPOCH_SLOT} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {Errors} from "../src/Errors.sol";
import {MockERC20} from "./mocks/SharedMocks.sol";
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

    // Mock ecrecover to return the expected signer, bypassing real EIP-712 verification.
    function _makeSignaturePass(address signer) internal {
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(signer));
    }

    // Create a dataset via the real PDPVerifier and return its ID.
    function _createDataSet() internal returns (uint256 dataSetId) {
        vm.startPrank(client);
        payments.setOperatorApproval(usdfc, address(fwss), true, 1000e18, 1000e18, 365 days);
        usdfc.approve(address(payments), 100e18);
        payments.deposit(usdfc, client, 100e18);
        vm.stopPrank();

        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        bytes memory extraData = abi.encode(client, uint256(0), emptyKeys, emptyValues, FAKE_SIG);

        _makeSignaturePass(client);
        vm.prank(sp);
        dataSetId = pdpVerifier.createDataSet{value: CLEANUP_DEPOSIT}(address(fwss), extraData);
    }

    // A permissionless caller cannot trigger abandonment before INACTIVITY_WINDOW has elapsed.
    function testAbandonmentBlockedBeforeWindowByPDPVerifier() public {
        uint256 dataSetId = _createDataSet();

        vm.roll(vm.getBlockNumber() + PDP_INACTIVITY_WINDOW / 2);

        vm.prank(keeper);
        vm.expectRevert(PDPVerifier.OnlyStorageProviderCanDelete.selector);
        pdpVerifier.deleteDataSet(dataSetId, "");
    }

    // The SP can delete its own dataset at any time, but if proving was activated FWSS rejects
    // the abandonment path when INACTIVITY_WINDOW has not yet elapsed.
    // The SP's correct alternative is terminateService, which is always available.
    function testAbandonmentBlockedBeforeWindowByFWSS() public {
        uint256 dataSetId = _createDataSet();
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
        uint256 dataSetId = _createDataSet();

        FilecoinWarmStorageService.DataSetInfoView memory before = viewContract.getDataSet(dataSetId);
        assertGt(before.pdpRailId, 0, "dataset should exist before abandonment");
        assertEq(before.payer, client, "payer should be set before abandonment");

        vm.roll(vm.getBlockNumber() + PDP_INACTIVITY_WINDOW + 1);

        vm.expectEmit(true, false, false, false, address(fwss));
        emit FilecoinWarmStorageService.DataSetAbandoned(dataSetId, before.pdpRailId, 0, 0);

        vm.prank(keeper);
        pdpVerifier.deleteDataSet(dataSetId, "");

        FilecoinWarmStorageService.DataSetInfoView memory after_ = viewContract.getDataSet(dataSetId);
        assertEq(after_.pdpRailId, 0, "pdpRailId should be cleared");
        assertEq(after_.payer, address(0), "payer should be cleared");

        uint256[] memory remaining = viewContract.clientDataSets(client);
        assertEq(remaining.length, 0, "client dataset list should be empty");
    }
}
