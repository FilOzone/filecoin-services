// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";

import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {PDPOffering} from "./PDPOffering.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {MockERC20, MockPDPVerifier} from "./mocks/SharedMocks.sol";
import {Errors} from "../src/Errors.sol";

contract ProviderValidationTest is MockFVMTest {
    using PDPOffering for PDPOffering.Schema;
    using SafeERC20 for MockERC20;

    FilecoinWarmStorageService public warmStorage;
    FilecoinWarmStorageServiceStateView public viewContract;
    ServiceProviderRegistry public serviceProviderRegistry;
    SessionKeyRegistry public sessionKeyRegistry;
    MockPDPVerifier public pdpVerifier;
    FilecoinPayV1 public payments;
    MockERC20 public usdfc;

    address public owner;
    address public provider1;
    address public provider2;
    address public client;
    address public filBeamController;
    address public filBeamBeneficiary;

    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        uint8(27)
    );

    function setUp() public override {
        super.setUp();
        owner = address(this);
        provider1 = address(0x1);
        provider2 = address(0x2);
        client = address(0x3);
        filBeamController = address(0x4);
        filBeamBeneficiary = address(0x5);

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

        // Deploy FilecoinPayV1 (no longer upgradeable)
        payments = new FilecoinPayV1();

        // Deploy FilecoinWarmStorageService
        FilecoinWarmStorageService warmStorageImpl = new FilecoinWarmStorageService(
            address(pdpVerifier),
            address(payments),
            usdfc,
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry
        );
        bytes memory warmStorageInitData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filBeamController,
            "Provider Validation Test Service",
            "Test service for provider validation"
        );
        MyERC1967Proxy warmStorageProxy = new MyERC1967Proxy(address(warmStorageImpl), warmStorageInitData);
        warmStorage = FilecoinWarmStorageService(address(warmStorageProxy));

        // Deploy view contract
        viewContract = new FilecoinWarmStorageServiceStateView(warmStorage);

        // Transfer tokens to client
        usdfc.safeTransfer(client, 10000 * 10 ** 18);
    }

    function testProviderNotRegistered() public {
        // Try to create dataset with unregistered provider
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        bytes memory extraData = abi.encode(client, 0, metadataKeys, metadataValues, FAKE_SIGNATURE);

        // Mock signature validation to pass
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(client));

        vm.prank(provider1);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotRegistered.selector, provider1));
        pdpVerifier.createDataSet(PDPListener(address(warmStorage)), extraData);
    }

    function testProviderRegisteredButNotApproved() public {
        PDPOffering.Schema memory pdpData = PDPOffering.Schema({
            serviceURL: "https://provider1.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerDay: 1 ether,
            minProvingPeriodInEpochs: 2880,
            location: "US-West",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });
        (string[] memory keys, bytes[] memory values) = pdpData.toCapabilities();
        // NOTE: This operation is expected to pass.
        // Approval is not required to perform onboarding actions.
        // Register provider1 in serviceProviderRegistry
        vm.prank(provider1);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            provider1, // payee
            "Provider 1",
            "Provider 1 Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Setup payment approvals for client
        vm.startPrank(client);
        payments.setOperatorApproval(
            usdfc,
            address(warmStorage),
            true,
            1000 * 10 ** 18, // rate allowance
            1000 * 10 ** 18, // lockup allowance
            365 days // max lockup period
        );
        usdfc.approve(address(payments), 100 * 10 ** 18);
        payments.deposit(usdfc, client, 100 * 10 ** 18);
        vm.stopPrank();

        // Create dataset without approval should now succeed
        string[] memory metadataKeys = new string[](0);
        string[] memory metadataValues = new string[](0);
        bytes memory extraData = abi.encode(client, 0, metadataKeys, metadataValues, FAKE_SIGNATURE);

        // Mock signature validation to pass
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(client));

        vm.prank(provider1);
        // Dataset creation shouldn't require provider be approved
        uint256 dataSetId = pdpVerifier.createDataSet(PDPListener(address(warmStorage)), extraData);

        // Verify the dataset was created
        assertTrue(dataSetId > 0, "Dataset should be created");
    }

    function testProviderApprovedCanCreateDataset() public {
        PDPOffering.Schema memory pdpData = PDPOffering.Schema({
            serviceURL: "https://provider1.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerDay: 1 ether,
            minProvingPeriodInEpochs: 2880,
            location: "US-West",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });
        (string[] memory keys, bytes[] memory values) = pdpData.toCapabilities();
        // Register provider1 in serviceProviderRegistry
        vm.prank(provider1);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            provider1, // payee
            "Provider 1",
            "Provider 1 Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Approve provider1
        warmStorage.addApprovedProvider(1);

        // Approve USDFC spending, deposit and set operator
        vm.startPrank(client);
        usdfc.approve(address(payments), 10000 * 10 ** 18);
        payments.deposit(usdfc, client, 10000 * 10 ** 18); // Deposit funds
        payments.setOperatorApproval(
            usdfc, // token
            address(warmStorage), // operator
            true, // approved
            10000 * 10 ** 18, // rateAllowance
            10000 * 10 ** 18, // lockupAllowance
            10000 * 10 ** 18 // allowance
        );
        vm.stopPrank();

        // Create dataset should succeed
        string[] memory metadataKeys = new string[](1);
        string[] memory metadataValues = new string[](1);
        metadataKeys[0] = "description";
        metadataValues[0] = "Test dataset";
        bytes memory extraData = abi.encode(client, 0, metadataKeys, metadataValues, FAKE_SIGNATURE);

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
        uint256[] memory providers = viewContract.getApprovedProviders(0, 0);
        assertEq(providers.length, 0, "Should have no approved providers initially");

        // Add some providers
        warmStorage.addApprovedProvider(1);
        warmStorage.addApprovedProvider(5);
        warmStorage.addApprovedProvider(10);

        // Test retrieval
        providers = viewContract.getApprovedProviders(0, 0);
        assertEq(providers.length, 3, "Should have 3 approved providers");
        assertEq(providers[0], 1, "First provider should be 1");
        assertEq(providers[1], 5, "Second provider should be 5");
        assertEq(providers[2], 10, "Third provider should be 10");

        // Remove one provider (provider 5 is at index 1)
        warmStorage.removeApprovedProvider(5, 1);

        // Test after removal (should have provider 10 in place of 5 due to swap-and-pop)
        providers = viewContract.getApprovedProviders(0, 0);
        assertEq(providers.length, 2, "Should have 2 approved providers after removal");
        assertEq(providers[0], 1, "First provider should still be 1");
        assertEq(providers[1], 10, "Second provider should be 10 (moved from last position)");

        // Remove another (provider 1 is at index 0)
        warmStorage.removeApprovedProvider(1, 0);
        providers = viewContract.getApprovedProviders(0, 0);
        assertEq(providers.length, 1, "Should have 1 approved provider");
        assertEq(providers[0], 10, "Remaining provider should be 10");

        // Remove last one (provider 10 is at index 0)
        warmStorage.removeApprovedProvider(10, 0);
        providers = viewContract.getApprovedProviders(0, 0);
        assertEq(providers.length, 0, "Should have no approved providers after removing all");
    }

    function testGetApprovedProvidersWithSingleProvider() public {
        // Add single provider and verify
        warmStorage.addApprovedProvider(42);
        uint256[] memory providers = viewContract.getApprovedProviders(0, 0);
        assertEq(providers.length, 1, "Should have 1 approved provider");
        assertEq(providers[0], 42, "Provider should be 42");

        // Remove and verify empty (provider 42 is at index 0)
        warmStorage.removeApprovedProvider(42, 0);
        providers = viewContract.getApprovedProviders(0, 0);
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
        uint256[] memory providers = viewContract.getApprovedProviders(0, 0);
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

        providers = viewContract.getApprovedProviders(0, 0);
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

    function testGetApprovedProvidersLength() public {
        // Initially should be 0
        assertEq(viewContract.getApprovedProvidersLength(), 0, "Initial length should be 0");

        // Add providers and check length
        warmStorage.addApprovedProvider(1);
        assertEq(viewContract.getApprovedProvidersLength(), 1, "Length should be 1 after adding one provider");

        warmStorage.addApprovedProvider(2);
        warmStorage.addApprovedProvider(3);
        assertEq(viewContract.getApprovedProvidersLength(), 3, "Length should be 3 after adding three providers");

        // Remove one and check length
        warmStorage.removeApprovedProvider(2, 1); // provider 2 is at index 1
        assertEq(viewContract.getApprovedProvidersLength(), 2, "Length should be 2 after removing one provider");
    }

    function testGetApprovedProvidersPaginated() public {
        // Test with empty list
        uint256[] memory providers = viewContract.getApprovedProviders(0, 10);
        assertEq(providers.length, 0, "Empty list should return empty array");

        // Add 5 providers
        for (uint256 i = 1; i <= 5; i++) {
            warmStorage.addApprovedProvider(i);
        }

        // Test pagination with different offsets and limits
        providers = viewContract.getApprovedProviders(0, 2);
        assertEq(providers.length, 2, "Should return 2 providers");
        assertEq(providers[0], 1, "First provider should be 1");
        assertEq(providers[1], 2, "Second provider should be 2");

        providers = viewContract.getApprovedProviders(2, 2);
        assertEq(providers.length, 2, "Should return 2 providers");
        assertEq(providers[0], 3, "First provider should be 3");
        assertEq(providers[1], 4, "Second provider should be 4");

        providers = viewContract.getApprovedProviders(4, 2);
        assertEq(providers.length, 1, "Should return 1 provider (only 5 total)");
        assertEq(providers[0], 5, "Provider should be 5");

        // Test offset beyond array length
        providers = viewContract.getApprovedProviders(10, 5);
        assertEq(providers.length, 0, "Offset beyond length should return empty array");

        // Test limit larger than remaining items
        providers = viewContract.getApprovedProviders(3, 10);
        assertEq(providers.length, 2, "Should return remaining 2 providers");
        assertEq(providers[0], 4, "First provider should be 4");
        assertEq(providers[1], 5, "Second provider should be 5");
    }

    function testGetApprovedProvidersPaginatedConsistency() public {
        // Add 10 providers
        for (uint256 i = 1; i <= 10; i++) {
            warmStorage.addApprovedProvider(i);
        }

        // Get all providers using original function
        uint256[] memory allProviders = viewContract.getApprovedProviders(0, 0);

        // Get all providers using pagination (in chunks of 3)
        uint256[] memory paginatedProviders = new uint256[](10);
        uint256 index = 0;

        for (uint256 offset = 0; offset < 10; offset += 3) {
            uint256[] memory chunk = viewContract.getApprovedProviders(offset, 3);
            for (uint256 i = 0; i < chunk.length; i++) {
                paginatedProviders[index] = chunk[i];
                index++;
            }
        }

        // Compare results
        assertEq(allProviders.length, paginatedProviders.length, "Lengths should match");
        for (uint256 i = 0; i < allProviders.length; i++) {
            // Avoid string concatenation in solidity test assertion messages
            assertEq(allProviders[i], paginatedProviders[i], "Provider mismatch in paginated results");
        }
    }

    function testGetApprovedProvidersPaginatedEdgeCases() public {
        // Add single provider
        warmStorage.addApprovedProvider(42);

        // Test various edge cases
        uint256[] memory providers;

        // Limit 0 should return empty array
        providers = viewContract.getApprovedProviders(0, 0);
        assertEq(providers.length, 1, "Offset 0, limit 0 should return all providers (backward compatibility)");

        // Offset 0, limit 1 should return the provider
        providers = viewContract.getApprovedProviders(0, 1);
        assertEq(providers.length, 1, "Should return 1 provider");
        assertEq(providers[0], 42, "Provider should be 42");

        // Offset 1 should return empty (beyond array)
        providers = viewContract.getApprovedProviders(1, 1);
        assertEq(providers.length, 0, "Offset beyond array should return empty");
    }

    function testGetApprovedProvidersPaginatedGasEfficiency() public {
        // Add many providers to test gas efficiency
        for (uint256 i = 1; i <= 100; i++) {
            warmStorage.addApprovedProvider(i);
        }

        // Test that pagination works with large numbers
        uint256[] memory providers = viewContract.getApprovedProviders(50, 10);
        assertEq(providers.length, 10, "Should return 10 providers");
        assertEq(providers[0], 51, "First provider should be 51");
        assertEq(providers[9], 60, "Last provider should be 60");

        // Test last chunk
        providers = viewContract.getApprovedProviders(95, 10);
        assertEq(providers.length, 5, "Should return remaining 5 providers");
        assertEq(providers[0], 96, "First provider should be 96");
        assertEq(providers[4], 100, "Last provider should be 100");
    }
}
