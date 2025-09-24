// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Payments} from "@fws-payments/Payments.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";

import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {MockERC20, MockPDPVerifier} from "./mocks/SharedMocks.sol";
import {Errors} from "../src/Errors.sol";

contract ProviderValidationTest is Test {
    using SafeERC20 for MockERC20;

    FilecoinWarmStorageService public warmStorage;
    FilecoinWarmStorageServiceStateView public viewContract;
    ServiceProviderRegistry public serviceProviderRegistry;
    SessionKeyRegistry public sessionKeyRegistry;
    MockPDPVerifier public pdpVerifier;
    Payments public payments;
    MockERC20 public usdfc;

    address public owner;
    address public provider1;
    address public provider2;
    address public client;
    address public filCDNController;
    address public filCDNBeneficiary;

    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        uint8(27)
    );

    function setUp() public {
        owner = address(this);
        provider1 = address(0x1);
        provider2 = address(0x2);
        client = address(0x3);
        filCDNController = address(0x4);
        filCDNBeneficiary = address(0x5);

        // Fund accounts
        vm.deal(provider1, 10 ether);
        vm.deal(provider2, 10 ether);

        // Deploy contracts
        usdfc = new MockERC20();
        pdpVerifier = new MockPDPVerifier();

        // Deploy ServiceProviderRegistry
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry();
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        serviceProviderRegistry = ServiceProviderRegistry(address(registryProxy));
        sessionKeyRegistry = new SessionKeyRegistry();

        // Deploy Payments (no longer upgradeable)
        payments = new Payments();

        // Deploy FilecoinWarmStorageService
        FilecoinWarmStorageService warmStorageImpl = new FilecoinWarmStorageService(
            address(pdpVerifier),
            address(payments),
            usdfc,
            filCDNBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );
        bytes memory warmStorageInitData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filCDNController,
            "Provider Validation Test Service",
            "Test service for provider validation"
        );
        MyERC1967Proxy warmStorageProxy = new MyERC1967Proxy(address(warmStorageImpl), warmStorageInitData);
        warmStorage = FilecoinWarmStorageService(address(warmStorageProxy));

        // Deploy view contract
        viewContract = new FilecoinWarmStorageServiceStateView(warmStorage);

        // Transfer tokens to client
        usdfc.safeTransfer(client, 10000 * 10 ** 6);
    }

    function testProviderNotRegistered() public {
        // Try to create dataset with unregistered provider
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        bytes memory extraData = abi.encode(client, metadataKeys, metadataValues, FAKE_SIGNATURE);

        // Mock signature validation to pass
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(client));

        vm.prank(provider1);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotRegistered.selector, provider1));
        pdpVerifier.createDataSet(PDPListener(address(warmStorage)), extraData);
    }

    function testProviderRegisteredButNotApproved() public {
        // Register provider1 in serviceProviderRegistry
        vm.prank(provider1);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            provider1, // payee
            "Provider 1",
            "Provider 1 Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://provider1.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether,
                    minProvingPeriodInEpochs: 2880,
                    location: "US-West",
                    paymentTokenAddress: IERC20(address(0)) // Payment in FIL
                })
            ),
            new string[](0),
            new string[](0)
        );

        // Try to create dataset without approval
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        bytes memory extraData = abi.encode(client, metadataKeys, metadataValues, FAKE_SIGNATURE);

        // Mock signature validation to pass
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(client));

        vm.prank(provider1);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotApproved.selector, provider1, 1));
        pdpVerifier.createDataSet(PDPListener(address(warmStorage)), extraData);
    }

    function testProviderApprovedCanCreateDataset() public {
        // Register provider1 in serviceProviderRegistry
        vm.prank(provider1);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            provider1, // payee
            "Provider 1",
            "Provider 1 Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            abi.encode(
                ServiceProviderRegistryStorage.PDPOffering({
                    serviceURL: "https://provider1.com",
                    minPieceSizeInBytes: 1024,
                    maxPieceSizeInBytes: 1024 * 1024,
                    ipniPiece: true,
                    ipniIpfs: false,
                    storagePricePerTibPerMonth: 1 ether,
                    minProvingPeriodInEpochs: 2880,
                    location: "US-West",
                    paymentTokenAddress: IERC20(address(0)) // Payment in FIL
                })
            ),
            new string[](0),
            new string[](0)
        );

        // Approve provider1
        warmStorage.addApprovedProvider(1);

        // Approve USDFC spending, deposit and set operator
        vm.startPrank(client);
        usdfc.approve(address(payments), 10000 * 10 ** 6);
        payments.deposit(usdfc, client, 10000 * 10 ** 6); // Deposit funds
        payments.setOperatorApproval(
            usdfc, // token
            address(warmStorage), // operator
            true, // approved
            10000 * 10 ** 6, // rateAllowance
            10000 * 10 ** 6, // lockupAllowance
            10000 * 10 ** 6 // allowance
        );
        vm.stopPrank();

        // Create dataset should succeed
        string[] memory metadataKeys = new string[](1);
        string[] memory metadataValues = new string[](1);
        metadataKeys[0] = "description";
        metadataValues[0] = "Test dataset";
        bytes memory extraData = abi.encode(client, metadataKeys, metadataValues, FAKE_SIGNATURE);

        // Mock signature validation to pass
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(client));

        vm.prank(provider1);
        uint256 dataSetId = pdpVerifier.createDataSet(PDPListener(address(warmStorage)), extraData);
        assertEq(dataSetId, 1, "Dataset should be created");
    }

    function testAddAndRemoveApprovedProvider() public {
        // Test adding provider
        warmStorage.addApprovedProvider(1);
        assertTrue(viewContract.isProviderApproved(1), "Provider 1 should be approved");

        // Test adding already approved provider (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderAlreadyApproved.selector, 1));
        warmStorage.addApprovedProvider(1);

        // Test removing provider
        warmStorage.removeApprovedProvider(1, 0); // Provider 1 is at index 0
        assertFalse(viewContract.isProviderApproved(1), "Provider 1 should not be approved");

        // Test removing non-approved provider (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 2));
        warmStorage.removeApprovedProvider(2, 0);

        // Test removing already removed provider (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 1));
        warmStorage.removeApprovedProvider(1, 0);
    }

    function testOnlyOwnerCanManageApprovedProviders() public {
        // Non-owner tries to add provider
        vm.prank(provider1);
        vm.expectRevert();
        warmStorage.addApprovedProvider(1);

        // Non-owner tries to remove provider
        warmStorage.addApprovedProvider(1);
        vm.prank(provider1);
        vm.expectRevert();
        warmStorage.removeApprovedProvider(1, 0);
    }

    function testAddApprovedProviderAlreadyApproved() public {
        // First add should succeed
        warmStorage.addApprovedProvider(5);
        assertTrue(viewContract.isProviderApproved(5), "Provider 5 should be approved");

        // Second add should revert with ProviderAlreadyApproved error
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderAlreadyApproved.selector, 5));
        warmStorage.addApprovedProvider(5);
    }

    function testGetApprovedProviders() public {
        // Test empty list initially
        uint256[] memory providers = viewContract.getApprovedProviders();
        assertEq(providers.length, 0, "Should have no approved providers initially");

        // Add some providers
        warmStorage.addApprovedProvider(1);
        warmStorage.addApprovedProvider(5);
        warmStorage.addApprovedProvider(10);

        // Test retrieval
        providers = viewContract.getApprovedProviders();
        assertEq(providers.length, 3, "Should have 3 approved providers");
        assertEq(providers[0], 1, "First provider should be 1");
        assertEq(providers[1], 5, "Second provider should be 5");
        assertEq(providers[2], 10, "Third provider should be 10");

        // Remove one provider (provider 5 is at index 1)
        warmStorage.removeApprovedProvider(5, 1);

        // Test after removal (should have provider 10 in place of 5 due to swap-and-pop)
        providers = viewContract.getApprovedProviders();
        assertEq(providers.length, 2, "Should have 2 approved providers after removal");
        assertEq(providers[0], 1, "First provider should still be 1");
        assertEq(providers[1], 10, "Second provider should be 10 (moved from last position)");

        // Remove another (provider 1 is at index 0)
        warmStorage.removeApprovedProvider(1, 0);
        providers = viewContract.getApprovedProviders();
        assertEq(providers.length, 1, "Should have 1 approved provider");
        assertEq(providers[0], 10, "Remaining provider should be 10");

        // Remove last one (provider 10 is at index 0)
        warmStorage.removeApprovedProvider(10, 0);
        providers = viewContract.getApprovedProviders();
        assertEq(providers.length, 0, "Should have no approved providers after removing all");
    }

    function testGetApprovedProvidersWithSingleProvider() public {
        // Add single provider and verify
        warmStorage.addApprovedProvider(42);
        uint256[] memory providers = viewContract.getApprovedProviders();
        assertEq(providers.length, 1, "Should have 1 approved provider");
        assertEq(providers[0], 42, "Provider should be 42");

        // Remove and verify empty (provider 42 is at index 0)
        warmStorage.removeApprovedProvider(42, 0);
        providers = viewContract.getApprovedProviders();
        assertEq(providers.length, 0, "Should have no approved providers");
    }

    function testConsistencyBetweenIsApprovedAndGetAll() public {
        // Add multiple providers
        uint256[] memory idsToAdd = new uint256[](5);
        idsToAdd[0] = 1;
        idsToAdd[1] = 3;
        idsToAdd[2] = 7;
        idsToAdd[3] = 15;
        idsToAdd[4] = 100;

        for (uint256 i = 0; i < idsToAdd.length; i++) {
            warmStorage.addApprovedProvider(idsToAdd[i]);
        }

        // Verify consistency - all providers in the array should return true for isProviderApproved
        uint256[] memory providers = viewContract.getApprovedProviders();
        assertEq(providers.length, 5, "Should have 5 approved providers");

        for (uint256 i = 0; i < providers.length; i++) {
            assertTrue(
                viewContract.isProviderApproved(providers[i]),
                string.concat("Provider ", vm.toString(providers[i]), " should be approved")
            );
        }

        // Verify that non-approved providers return false
        assertFalse(viewContract.isProviderApproved(2), "Provider 2 should not be approved");
        assertFalse(viewContract.isProviderApproved(50), "Provider 50 should not be approved");

        // Remove some providers and verify consistency
        // Find indices of providers 3 and 15 in the array
        // Based on adding order: [1, 3, 7, 15, 100]
        warmStorage.removeApprovedProvider(3, 1); // provider 3 is at index 1
        // After removing 3 with swap-and-pop, array becomes: [1, 100, 7, 15]
        warmStorage.removeApprovedProvider(15, 3); // provider 15 is now at index 3

        providers = viewContract.getApprovedProviders();
        assertEq(providers.length, 3, "Should have 3 approved providers after removal");

        // Verify all remaining are still approved
        for (uint256 i = 0; i < providers.length; i++) {
            assertTrue(
                viewContract.isProviderApproved(providers[i]),
                string.concat("Remaining provider ", vm.toString(providers[i]), " should be approved")
            );
        }

        // Verify removed ones are not approved
        assertFalse(viewContract.isProviderApproved(3), "Provider 3 should not be approved after removal");
        assertFalse(viewContract.isProviderApproved(15), "Provider 15 should not be approved after removal");
    }

    function testRemoveApprovedProviderNotInList() public {
        // Trying to remove a provider that was never approved should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 10));
        warmStorage.removeApprovedProvider(10, 0);

        // Add and then remove a provider
        warmStorage.addApprovedProvider(6);
        warmStorage.removeApprovedProvider(6, 0); // provider 6 is at index 0

        // Trying to remove the same provider again should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 6));
        warmStorage.removeApprovedProvider(6, 0);
    }
}
