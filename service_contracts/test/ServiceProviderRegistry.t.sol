// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";

contract ServiceProviderRegistryTest is Test {
    ServiceProviderRegistry public implementation;
    ServiceProviderRegistry public registry;
    address public owner;
    address public user1;
    address public user2;

    function setUp() public {
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
        assertEq(registry.VERSION(), "0.0.1", "Version should be 0.0.1");

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
        uint256 providerId = registry.registerProvider{value: 5 ether}(
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
        uint256 providerId = registry.registerProvider{value: 5 ether}(
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
        uint256 providerId = registry.registerProvider{value: 5 ether}(
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
        registry.registerProvider{value: 5 ether}(
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
        registry.registerProvider{value: 5 ether}(
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
}
