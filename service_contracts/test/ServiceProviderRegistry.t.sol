// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";

contract ServiceProviderRegistryTest is MockFVMTest {
    ServiceProviderRegistry public implementation;
    ServiceProviderRegistry public registry;
    address public owner;
    address public user1;
    address public user2;

    function setUp() public override {
        super.setUp();
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        // Deploy implementation
        implementation = new ServiceProviderRegistry();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Cast proxy to ServiceProviderRegistry interface
        registry = ServiceProviderRegistry(address(proxy));
    }

    function testInitialState() public view {
        // Check version
        assertEq(registry.VERSION(), "0.3.0", "Version should be 0.3.0");

        // Check owner
        assertEq(registry.owner(), owner, "Service provider should be deployer");

        // Check next provider ID
        assertEq(registry.getNextProviderId(), 1, "Next provider ID should start at 1");
    }

    function testCannotReinitialize() public {
        // Attempt to reinitialize should fail
        vm.expectRevert();
        registry.initialize();
    }

    function testIsRegisteredProviderReturnsFalse() public view {
        // Should return false for unregistered addresses
        assertFalse(registry.isRegisteredProvider(user1), "Should return false for unregistered address");
        assertFalse(registry.isRegisteredProvider(user2), "Should return false for unregistered address");
    }

    function testRegisterProviderWithEmptyCapabilities() public {
        // Give user1 some ETH for registration fee
        vm.deal(user1, 10 ether);

        // Prepare PDP data
        ServiceProviderRegistryStorage.PDPOffering memory pdpData = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: "https://example.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerMonth: 500000000000000000, // 0.5 FIL per TiB per month
            minProvingPeriodInEpochs: 2880,
            location: "US-East",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });

        // Encode PDP data
        bytes memory encodedData = abi.encode(pdpData);

        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(user1);
        uint256 providerId = registry.registerProvider{
            value: 5 ether
        }(
            user1, // payee
            "Provider One",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedData,
            emptyKeys,
            emptyValues
        );
        assertEq(providerId, 1, "Should register with ID 1");
        assertTrue(registry.isRegisteredProvider(user1), "Should be registered");

        // Verify empty capabilities
        (, string[] memory returnedKeys,) =
            registry.getProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        assertEq(returnedKeys.length, 0, "Should have no capability keys");
    }

    function testRegisterProviderWithCapabilities() public {
        // Give user1 some ETH for registration fee
        vm.deal(user1, 10 ether);

        // Prepare PDP data
        ServiceProviderRegistryStorage.PDPOffering memory pdpData = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: "https://example.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerMonth: 500000000000000000, // 0.5 FIL per TiB per month
            minProvingPeriodInEpochs: 2880,
            location: "US-East",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });

        // Encode PDP data
        bytes memory encodedData = abi.encode(pdpData);

        // Non-empty capability arrays
        string[] memory capabilityKeys = new string[](3);
        capabilityKeys[0] = "region";
        capabilityKeys[1] = "tier";
        capabilityKeys[2] = "compliance";

        string[] memory capabilityValues = new string[](3);
        capabilityValues[0] = "us-east-1";
        capabilityValues[1] = "premium";
        capabilityValues[2] = "SOC2";

        vm.prank(user1);
        uint256 providerId = registry.registerProvider{
            value: 5 ether
        }(
            user1, // payee
            "Provider One",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedData,
            capabilityKeys,
            capabilityValues
        );
        assertEq(providerId, 1, "Should register with ID 1");
        assertTrue(registry.isRegisteredProvider(user1), "Should be registered");

        // Verify capabilities were stored correctly
        (, string[] memory returnedKeys,) =
            registry.getProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);

        assertEq(returnedKeys.length, 3, "Should have 3 capability keys");

        assertEq(returnedKeys[0], "region", "First key should be region");
        assertEq(returnedKeys[1], "tier", "Second key should be tier");
        assertEq(returnedKeys[2], "compliance", "Third key should be compliance");

        // Use the new query methods to verify values
        (bool existsRegion, string memory region) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "region");
        assertTrue(existsRegion, "region capability should exist");
        assertEq(region, "us-east-1", "First value should be us-east-1");

        (bool existsTier, string memory tier) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "tier");
        assertTrue(existsTier, "tier capability should exist");
        assertEq(tier, "premium", "Second value should be premium");

        (bool existsCompliance, string memory compliance) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "compliance");
        assertTrue(existsCompliance, "compliance capability should exist");
        assertEq(compliance, "SOC2", "Third value should be SOC2");
    }

    function testBeneficiaryIsSetCorrectly() public {
        // Give user1 some ETH for registration fee
        vm.deal(user1, 10 ether);

        // Register a provider with user2 as beneficiary
        ServiceProviderRegistryStorage.PDPOffering memory pdpData = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: "https://example.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerMonth: 500000000000000000, // 0.5 FIL per TiB per month
            minProvingPeriodInEpochs: 2880,
            location: "US-East",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });

        bytes memory encodedData = abi.encode(pdpData);

        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register with user2 as beneficiary
        vm.prank(user1);
        uint256 providerId = registry.registerProvider{
            value: 5 ether
        }(
            user2, // payee is different from owner
            "Provider One",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedData,
            emptyKeys,
            emptyValues
        );

        // Verify provider info
        ServiceProviderRegistry.ServiceProviderInfoView memory info = registry.getProvider(providerId);
        assertEq(info.providerId, providerId, "Provider ID should match");
        assertEq(info.info.serviceProvider, user1, "Service provider should be user1");
        assertEq(info.info.payee, user2, "Payee should be user2");
        assertTrue(info.info.isActive, "Provider should be active");
    }

    function testCannotRegisterWithZeroBeneficiary() public {
        // Give user1 some ETH for registration fee
        vm.deal(user1, 10 ether);

        ServiceProviderRegistryStorage.PDPOffering memory pdpData = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: "https://example.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerMonth: 500000000000000000,
            minProvingPeriodInEpochs: 2880,
            location: "US-East",
            paymentTokenAddress: IERC20(address(0))
        });

        bytes memory encodedData = abi.encode(pdpData);
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Try to register with zero beneficiary
        vm.prank(user1);
        vm.expectRevert("Payee cannot be zero address");
        registry.registerProvider{
            value: 5 ether
        }(
            address(0), // zero beneficiary
            "Provider One",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedData,
            emptyKeys,
            emptyValues
        );
    }

    function testGetProviderWorks() public {
        // Give user1 some ETH for registration fee
        vm.deal(user1, 10 ether);

        // Register a provider first
        ServiceProviderRegistryStorage.PDPOffering memory pdpData = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: "https://example.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerMonth: 750000000000000000, // 0.75 FIL per TiB per month
            minProvingPeriodInEpochs: 2880,
            location: "US-East",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });

        bytes memory encodedData = abi.encode(pdpData);

        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(user1);
        registry.registerProvider{
            value: 5 ether
        }(
            user1, // payee
            "Provider One",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedData,
            emptyKeys,
            emptyValues
        );

        // Now get provider should work
        ServiceProviderRegistry.ServiceProviderInfoView memory info = registry.getProvider(1);
        assertEq(info.providerId, 1, "Provider ID should be 1");
        assertEq(info.info.serviceProvider, user1, "Service provider should be user1");
        assertEq(info.info.payee, user1, "Payee should be user1");
    }

    // Note: We can't test non-PDP product types since Solidity doesn't allow
    // casting invalid values to enums. This test would be needed when we add
    // more product types to the enum but explicitly reject them in the contract.

    function testOnlyOwnerCanUpgrade() public {
        // Deploy new implementation
        ServiceProviderRegistry newImplementation = new ServiceProviderRegistry();

        // Non-owner cannot upgrade
        vm.prank(user1);
        vm.expectRevert();
        registry.upgradeToAndCall(address(newImplementation), "");

        // Owner can upgrade
        registry.upgradeToAndCall(address(newImplementation), "");
    }

    function testTransferOwnership() public {
        // Transfer ownership
        registry.transferOwnership(user1);
        assertEq(registry.owner(), user1, "Service provider should be transferred");
    }

    function testGetProviderPayeeReturnsCorrectAddress() public {
        // Give user1 some ETH for registration fee
        vm.deal(user1, 10 ether);

        // Prepare PDP data
        ServiceProviderRegistryStorage.PDPOffering memory pdpData = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: "https://example.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerMonth: 500000000000000000, // 0.5 FIL per TiB per month
            minProvingPeriodInEpochs: 2880,
            location: "US-East",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });

        // Encode PDP data
        bytes memory encodedData = abi.encode(pdpData);

        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider with user2 as payee
        vm.prank(user1);
        uint256 providerId = registry.registerProvider{
            value: 5 ether
        }(
            user2,
            "Provider One",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedData,
            emptyKeys,
            emptyValues
        );

        // Verify helper returns the payee address
        address payee = registry.getProviderPayee(providerId);
        assertEq(payee, user2, "getProviderPayee should return the registered payee");
    }

    function testGetProviderPayeeRevertsForInvalidProviderId() public {
        // 0 is invalid provider ID; expect revert due to providerExists modifier
        vm.expectRevert("Provider does not exist");
        registry.getProviderPayee(0);

        // Non-existent but non-zero ID should also revert
        vm.expectRevert("Provider does not exist");
        registry.getProviderPayee(1);
    }

    // ========== Tests for getProvidersByIds ==========

    function testGetProvidersByIdsEmptyArray() public {
        uint256[] memory emptyIds = new uint256[](0);

        (ServiceProviderRegistry.ServiceProviderInfoView[] memory providerInfos, bool[] memory validIds) =
            registry.getProvidersByIds(emptyIds);

        assertEq(providerInfos.length, 0, "Should return empty array for empty input");
        assertEq(validIds.length, 0, "Should return empty validIds array for empty input");
    }

    function testGetProvidersByIdsSingleValidProvider() public {
        // Register a provider first
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        uint256 providerId = registry.registerProvider{
            value: 5 ether
        }(
            user1,
            "Test Provider",
            "Test Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            _createValidPDPOffering(),
            new string[](0),
            new string[](0)
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = providerId;

        (ServiceProviderRegistry.ServiceProviderInfoView[] memory providerInfos, bool[] memory validIds) =
            registry.getProvidersByIds(ids);

        assertEq(providerInfos.length, 1, "Should return one provider");
        assertEq(validIds.length, 1, "Should return one validity flag");
        assertTrue(validIds[0], "Provider should be valid");
        assertEq(providerInfos[0].providerId, providerId, "Provider ID should match");
        assertEq(providerInfos[0].info.serviceProvider, user1, "Service provider address should match");
        assertEq(providerInfos[0].info.name, "Test Provider", "Provider name should match");
        assertEq(providerInfos[0].info.description, "Test Description", "Provider description should match");
        assertTrue(providerInfos[0].info.isActive, "Provider should be active");
    }

    function testGetProvidersByIdsMultipleValidProviders() public {
        // Register multiple providers
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        vm.prank(user1);
        uint256 providerId1 = registry.registerProvider{
            value: 5 ether
        }(
            user1,
            "Provider 1",
            "Description 1",
            ServiceProviderRegistryStorage.ProductType.PDP,
            _createValidPDPOffering(),
            new string[](0),
            new string[](0)
        );

        vm.prank(user2);
        uint256 providerId2 = registry.registerProvider{
            value: 5 ether
        }(
            user2,
            "Provider 2",
            "Description 2",
            ServiceProviderRegistryStorage.ProductType.PDP,
            _createValidPDPOffering(),
            new string[](0),
            new string[](0)
        );

        uint256[] memory ids = new uint256[](2);
        ids[0] = providerId1;
        ids[1] = providerId2;

        (ServiceProviderRegistry.ServiceProviderInfoView[] memory providerInfos, bool[] memory validIds) =
            registry.getProvidersByIds(ids);

        assertEq(providerInfos.length, 2, "Should return two providers");
        assertEq(validIds.length, 2, "Should return two validity flags");

        // Check first provider
        assertTrue(validIds[0], "First provider should be valid");
        assertEq(providerInfos[0].providerId, providerId1, "First provider ID should match");
        assertEq(providerInfos[0].info.serviceProvider, user1, "First provider address should match");
        assertEq(providerInfos[0].info.name, "Provider 1", "First provider name should match");

        // Check second provider
        assertTrue(validIds[1], "Second provider should be valid");
        assertEq(providerInfos[1].providerId, providerId2, "Second provider ID should match");
        assertEq(providerInfos[1].info.serviceProvider, user2, "Second provider address should match");
        assertEq(providerInfos[1].info.name, "Provider 2", "Second provider name should match");
    }

    function testGetProvidersByIdsInvalidIds() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 0; // Invalid ID (0)
        ids[1] = 999; // Non-existent ID
        ids[2] = 1; // Valid ID but no provider registered yet

        (ServiceProviderRegistry.ServiceProviderInfoView[] memory providerInfos, bool[] memory validIds) =
            registry.getProvidersByIds(ids);

        assertEq(providerInfos.length, 3, "Should return three results");
        assertEq(validIds.length, 3, "Should return three validity flags");

        // All should be invalid
        assertFalse(validIds[0], "ID 0 should be invalid");
        assertFalse(validIds[1], "Non-existent ID should be invalid");
        assertFalse(validIds[2], "Unregistered ID should be invalid");

        // All should have empty structs
        for (uint256 i = 0; i < 3; i++) {
            assertEq(providerInfos[i].info.serviceProvider, address(0), "Invalid provider should have zero address");
            assertEq(providerInfos[i].providerId, 0, "Invalid provider should have zero ID");
            assertFalse(providerInfos[i].info.isActive, "Invalid provider should be inactive");
        }
    }

    function testGetProvidersByIdsMixedValidAndInvalid() public {
        // Register one provider
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        uint256 validProviderId = registry.registerProvider{
            value: 5 ether
        }(
            user1,
            "Valid Provider",
            "Valid Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            _createValidPDPOffering(),
            new string[](0),
            new string[](0)
        );

        uint256[] memory ids = new uint256[](4);
        ids[0] = validProviderId; // Valid
        ids[1] = 0; // Invalid
        ids[2] = 999; // Invalid
        ids[3] = validProviderId; // Valid (duplicate)

        (ServiceProviderRegistry.ServiceProviderInfoView[] memory providerInfos, bool[] memory validIds) =
            registry.getProvidersByIds(ids);

        assertEq(providerInfos.length, 4, "Should return four results");
        assertEq(validIds.length, 4, "Should return four validity flags");

        // Check valid providers
        assertTrue(validIds[0], "First provider should be valid");
        assertEq(providerInfos[0].providerId, validProviderId, "First provider ID should match");
        assertEq(providerInfos[0].info.serviceProvider, user1, "First provider address should match");

        // Check invalid providers
        assertFalse(validIds[1], "Second provider should be invalid");
        assertFalse(validIds[2], "Third provider should be invalid");

        // Check duplicate valid provider
        assertTrue(validIds[3], "Fourth provider should be valid");
        assertEq(providerInfos[3].providerId, validProviderId, "Fourth provider ID should match");
        assertEq(providerInfos[3].info.serviceProvider, user1, "Fourth provider address should match");
    }

    function testGetProvidersByIdsInactiveProvider() public {
        // Register a provider
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        uint256 providerId = registry.registerProvider{
            value: 5 ether
        }(
            user1,
            "Test Provider",
            "Test Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            _createValidPDPOffering(),
            new string[](0),
            new string[](0)
        );

        // Remove the provider (make it inactive)
        vm.prank(user1);
        registry.removeProvider();

        uint256[] memory ids = new uint256[](1);
        ids[0] = providerId;

        (ServiceProviderRegistry.ServiceProviderInfoView[] memory providerInfos, bool[] memory validIds) =
            registry.getProvidersByIds(ids);

        assertEq(providerInfos.length, 1, "Should return one result");
        assertEq(validIds.length, 1, "Should return one validity flag");
        assertFalse(validIds[0], "Inactive provider should be invalid");
        assertEq(providerInfos[0].info.serviceProvider, address(0), "Inactive provider should have zero address");
        assertEq(providerInfos[0].providerId, 0, "Inactive provider should have zero ID");
        assertFalse(providerInfos[0].info.isActive, "Inactive provider should be inactive");
    }

    // Helper function to create a valid PDP offering for tests
    function _createValidPDPOffering() internal pure returns (bytes memory) {
        ServiceProviderRegistryStorage.PDPOffering memory pdpOffering = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: "https://example.com/api",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: true,
            storagePricePerTibPerMonth: 1000,
            minProvingPeriodInEpochs: 1,
            location: "US",
            paymentTokenAddress: IERC20(address(0))
        });
        return abi.encode(pdpOffering);
    }
}
