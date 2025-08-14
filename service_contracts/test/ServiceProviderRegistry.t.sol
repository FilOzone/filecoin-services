// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ServiceProviderRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
        assertEq(registry.version(), "1.0.0", "Version should be 1.0.0");

        // Check owner
        assertEq(registry.owner(), owner, "Owner should be deployer");

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
        vm.deal(user1, 2 ether);

        // Prepare PDP data
        ServiceProviderRegistry.PDPData memory pdpData = ServiceProviderRegistry.PDPData({
            serviceURL: "https://example.com",
            minPieceSize: 1024,
            maxPieceSize: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            withCDN: true
        });

        // Encode PDP data
        bytes memory encodedData = abi.encode(pdpData);

        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(user1);
        uint256 providerId = registry.registerProvider{value: 1 ether}(
            ServiceProviderRegistry.ProductType.PDP, encodedData, emptyKeys, emptyValues
        );
        assertEq(providerId, 1, "Should register with ID 1");
        assertTrue(registry.isRegisteredProvider(user1), "Should be registered");

        // Verify empty capabilities
        (, string[] memory returnedKeys, string[] memory returnedValues,) =
            registry.getProduct(providerId, ServiceProviderRegistry.ProductType.PDP);
        assertEq(returnedKeys.length, 0, "Should have no capability keys");
        assertEq(returnedValues.length, 0, "Should have no capability values");
    }

    function testRegisterProviderWithCapabilities() public {
        // Give user1 some ETH for registration fee
        vm.deal(user1, 2 ether);

        // Prepare PDP data
        ServiceProviderRegistry.PDPData memory pdpData = ServiceProviderRegistry.PDPData({
            serviceURL: "https://example.com",
            minPieceSize: 1024,
            maxPieceSize: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            withCDN: true
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
        uint256 providerId = registry.registerProvider{value: 1 ether}(
            ServiceProviderRegistry.ProductType.PDP, encodedData, capabilityKeys, capabilityValues
        );
        assertEq(providerId, 1, "Should register with ID 1");
        assertTrue(registry.isRegisteredProvider(user1), "Should be registered");

        // Verify capabilities were stored correctly
        (, string[] memory returnedKeys, string[] memory returnedValues,) =
            registry.getProduct(providerId, ServiceProviderRegistry.ProductType.PDP);

        assertEq(returnedKeys.length, 3, "Should have 3 capability keys");
        assertEq(returnedValues.length, 3, "Should have 3 capability values");

        assertEq(returnedKeys[0], "region", "First key should be region");
        assertEq(returnedKeys[1], "tier", "Second key should be tier");
        assertEq(returnedKeys[2], "compliance", "Third key should be compliance");

        assertEq(returnedValues[0], "us-east-1", "First value should be us-east-1");
        assertEq(returnedValues[1], "premium", "Second value should be premium");
        assertEq(returnedValues[2], "SOC2", "Third value should be SOC2");
    }

    function testGetProviderWorks() public {
        // Give user1 some ETH for registration fee
        vm.deal(user1, 2 ether);

        // Register a provider first
        ServiceProviderRegistry.PDPData memory pdpData = ServiceProviderRegistry.PDPData({
            serviceURL: "https://example.com",
            minPieceSize: 1024,
            maxPieceSize: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            withCDN: true
        });

        bytes memory encodedData = abi.encode(pdpData);

        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(user1);
        registry.registerProvider{value: 1 ether}(
            ServiceProviderRegistry.ProductType.PDP, encodedData, emptyKeys, emptyValues
        );

        // Now get provider should work
        ServiceProviderRegistry.ServiceProviderInfo memory info = registry.getProvider(1);
        assertEq(info.owner, user1, "Owner should be user1");
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
        assertEq(registry.owner(), user1, "Owner should be transferred");
    }
}
