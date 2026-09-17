// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {Errors} from "../../src/Errors.sol";
import {ProviderManagementModule} from "../../src/modules/ProviderManagementModule.sol";

contract ProviderManagementModuleHarness is ProviderManagementModule {
    function isProviderApproved(uint256 providerId) external view returns (bool) {
        return approvedProviders[providerId];
    }

    function getApprovedProviders() external view returns (uint256[] memory) {
        return approvedProviderIds;
    }

    function getApprovedProvidersLength() external view returns (uint256) {
        return approvedProviderIds.length;
    }
}

contract ProviderManagementModuleTest is Test {
    bytes32 private constant OWNABLE_STORAGE_LOCATION =
        0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    ProviderManagementModuleHarness public providerManagementModule;

    address public owner;
    address public provider1;

    function setUp() public {
        owner = address(this);
        provider1 = address(0x1);

        ProviderManagementModuleHarness implementation = new ProviderManagementModuleHarness();
        MyERC1967Proxy proxy = new MyERC1967Proxy(address(implementation), "");
        providerManagementModule = ProviderManagementModuleHarness(address(proxy));

        vm.store(address(proxy), OWNABLE_STORAGE_LOCATION, bytes32(uint256(uint160(owner))));
    }

    function testAddAndRemoveApprovedProvider() public {
        // Test adding provider
        providerManagementModule.addApprovedProvider(1);
        assertTrue(providerManagementModule.isProviderApproved(1), "Provider 1 should be approved");

        // Test adding already approved provider (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderAlreadyApproved.selector, 1));
        providerManagementModule.addApprovedProvider(1);

        // Test removing provider
        providerManagementModule.removeApprovedProvider(1, 0); // Provider 1 is at index 0
        assertFalse(providerManagementModule.isProviderApproved(1), "Provider 1 should not be approved");

        // Test removing non-approved provider (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 2));
        providerManagementModule.removeApprovedProvider(2, 0);

        // Test removing already removed provider (should revert)
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 1));
        providerManagementModule.removeApprovedProvider(1, 0);
    }

    function testOnlyOwnerCanManageApprovedProviders() public {
        // Non-owner tries to add provider
        vm.prank(provider1);
        vm.expectRevert();
        providerManagementModule.addApprovedProvider(1);

        // Non-owner tries to remove provider
        providerManagementModule.addApprovedProvider(1);
        vm.prank(provider1);
        vm.expectRevert();
        providerManagementModule.removeApprovedProvider(1, 0);
    }

    function testAddApprovedProviderAlreadyApproved() public {
        // First add should succeed
        providerManagementModule.addApprovedProvider(5);
        assertTrue(providerManagementModule.isProviderApproved(5), "Provider 5 should be approved");

        // Second add should revert with ProviderAlreadyApproved error
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderAlreadyApproved.selector, 5));
        providerManagementModule.addApprovedProvider(5);
    }

    function testGetApprovedProviders() public {
        // Test empty list initially
        uint256[] memory providers = providerManagementModule.getApprovedProviders();
        assertEq(providers.length, 0, "Should have no approved providers initially");

        // Add some providers
        providerManagementModule.addApprovedProvider(1);
        providerManagementModule.addApprovedProvider(5);
        providerManagementModule.addApprovedProvider(10);

        // Test retrieval
        providers = providerManagementModule.getApprovedProviders();
        assertEq(providers.length, 3, "Should have 3 approved providers");
        assertEq(providers[0], 1, "First provider should be 1");
        assertEq(providers[1], 5, "Second provider should be 5");
        assertEq(providers[2], 10, "Third provider should be 10");

        // Remove one provider (provider 5 is at index 1)
        providerManagementModule.removeApprovedProvider(5, 1);

        // Test after removal (should have provider 10 in place of 5 due to swap-and-pop)
        providers = providerManagementModule.getApprovedProviders();
        assertEq(providers.length, 2, "Should have 2 approved providers after removal");
        assertEq(providers[0], 1, "First provider should still be 1");
        assertEq(providers[1], 10, "Second provider should be 10 (moved from last position)");

        // Remove another (provider 1 is at index 0)
        providerManagementModule.removeApprovedProvider(1, 0);
        providers = providerManagementModule.getApprovedProviders();
        assertEq(providers.length, 1, "Should have 1 approved provider");
        assertEq(providers[0], 10, "Remaining provider should be 10");

        // Remove last one (provider 10 is at index 0)
        providerManagementModule.removeApprovedProvider(10, 0);
        providers = providerManagementModule.getApprovedProviders();
        assertEq(providers.length, 0, "Should have no approved providers after removing all");
    }

    function testGetApprovedProvidersWithSingleProvider() public {
        // Add single provider and verify
        providerManagementModule.addApprovedProvider(42);
        uint256[] memory providers = providerManagementModule.getApprovedProviders();
        assertEq(providers.length, 1, "Should have 1 approved provider");
        assertEq(providers[0], 42, "Provider should be 42");

        // Remove and verify empty (provider 42 is at index 0)
        providerManagementModule.removeApprovedProvider(42, 0);
        providers = providerManagementModule.getApprovedProviders();
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
            providerManagementModule.addApprovedProvider(idsToAdd[i]);
        }

        // Verify consistency - all providers in the array should return true for isProviderApproved
        uint256[] memory providers = providerManagementModule.getApprovedProviders();
        assertEq(providers.length, 5, "Should have 5 approved providers");

        for (uint256 i = 0; i < providers.length; i++) {
            assertTrue(
                providerManagementModule.isProviderApproved(providers[i]),
                string.concat("Provider ", vm.toString(providers[i]), " should be approved")
            );
        }

        // Verify that non-approved providers return false
        assertFalse(providerManagementModule.isProviderApproved(2), "Provider 2 should not be approved");
        assertFalse(providerManagementModule.isProviderApproved(50), "Provider 50 should not be approved");

        // Remove some providers and verify consistency
        // Find indices of providers 3 and 15 in the array
        // Based on adding order: [1, 3, 7, 15, 100]
        providerManagementModule.removeApprovedProvider(3, 1); // provider 3 is at index 1
        // After removing 3 with swap-and-pop, array becomes: [1, 100, 7, 15]
        providerManagementModule.removeApprovedProvider(15, 3); // provider 15 is now at index 3

        providers = providerManagementModule.getApprovedProviders();
        assertEq(providers.length, 3, "Should have 3 approved providers after removal");

        // Verify all remaining are still approved
        for (uint256 i = 0; i < providers.length; i++) {
            assertTrue(
                providerManagementModule.isProviderApproved(providers[i]),
                string.concat("Remaining provider ", vm.toString(providers[i]), " should be approved")
            );
        }

        // Verify removed ones are not approved
        assertFalse(providerManagementModule.isProviderApproved(3), "Provider 3 should not be approved after removal");
        assertFalse(providerManagementModule.isProviderApproved(15), "Provider 15 should not be approved after removal");
    }

    function testRemoveApprovedProviderNotInList() public {
        // Trying to remove a provider that was never approved should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 10));
        providerManagementModule.removeApprovedProvider(10, 0);

        // Add and then remove a provider
        providerManagementModule.addApprovedProvider(6);
        providerManagementModule.removeApprovedProvider(6, 0); // provider 6 is at index 0

        // Trying to remove the same provider again should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.ProviderNotInApprovedList.selector, 6));
        providerManagementModule.removeApprovedProvider(6, 0);
    }

    function testGetApprovedProvidersLength() public {
        // Initially should be 0
        assertEq(providerManagementModule.getApprovedProvidersLength(), 0, "Initial length should be 0");

        // Add providers and check length
        providerManagementModule.addApprovedProvider(1);
        assertEq(
            providerManagementModule.getApprovedProvidersLength(), 1, "Length should be 1 after adding one provider"
        );

        providerManagementModule.addApprovedProvider(2);
        providerManagementModule.addApprovedProvider(3);
        assertEq(
            providerManagementModule.getApprovedProvidersLength(), 3, "Length should be 3 after adding three providers"
        );

        // Remove one and check length
        providerManagementModule.removeApprovedProvider(2, 1); // provider 2 is at index 1
        assertEq(
            providerManagementModule.getApprovedProvidersLength(), 2, "Length should be 2 after removing one provider"
        );
    }
}
