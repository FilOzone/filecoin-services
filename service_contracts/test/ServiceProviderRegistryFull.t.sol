// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {BURN_ADDRESS} from "@fvm-solidity/FVMActors.sol";
import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {PDPOffering} from "./PDPOffering.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ServiceProviderRegistryFullTest is MockFVMTest {
    using PDPOffering for PDPOffering.Schema;
    using PDPOffering for ServiceProviderRegistry;

    ServiceProviderRegistry private implementation;
    ServiceProviderRegistry public registry;

    address public owner;
    address public provider1;
    address public provider2;
    address public provider3;
    address public user;

    string constant SERVICE_URL = "https://provider1.example.com";
    bytes constant SERVICE_URL_2 = "https://provider2.example.com";
    string constant UPDATED_SERVICE_URL = "https://provider1-updated.example.com";

    uint256 constant REGISTRATION_FEE = 5 ether; // 5 FIL in attoFIL

    PDPOffering.Schema public defaultPDPData;
    PDPOffering.Schema public updatedPDPData;
    bytes public encodedUpdatedPDPData;

    function setUp() public override {
        super.setUp();
        owner = address(this);
        provider1 = address(0x1);
        provider2 = address(0x2);
        provider3 = address(0x3);
        user = address(0x4);

        // Give providers some ETH for registration fees
        vm.deal(provider1, 10 ether);
        vm.deal(provider2, 10 ether);
        vm.deal(provider3, 10 ether);
        vm.deal(user, 10 ether);

        // Deploy implementation
        implementation = new ServiceProviderRegistry();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Cast proxy to ServiceProviderRegistry interface
        registry = ServiceProviderRegistry(address(proxy));

        // Setup default PDP data
        defaultPDPData = PDPOffering.Schema({
            serviceURL: SERVICE_URL,
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerDay: 1000000000000000000, // 1 FIL per TiB per month
            minProvingPeriodInEpochs: 2880, // 1 day in epochs (30 second blocks)
            location: "North America",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });

        updatedPDPData = PDPOffering.Schema({
            serviceURL: UPDATED_SERVICE_URL,
            minPieceSizeInBytes: 512,
            maxPieceSizeInBytes: 2 * 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: true,
            storagePricePerTibPerDay: 2000000000000000000, // 2 FIL per TiB per month
            minProvingPeriodInEpochs: 1440, // 12 hours in epochs
            location: "Europe",
            paymentTokenAddress: IERC20(address(0)) // Payment in FIL
        });
    }

    // ========== Initial State Tests ==========

    function testInitialState() public view {
        assertEq(registry.VERSION(), "0.3.0", "Version should be 0.3.0");
        assertEq(registry.owner(), owner, "Service provider should be deployer");
        assertEq(registry.getNextProviderId(), 1, "Next provider ID should start at 1");
        assertEq(registry.REGISTRATION_FEE(), 5 ether, "Registration fee should be 5 FIL");
        assertEq(registry.REGISTRATION_FEE(), 5 ether, "Registration fee constant should be 5 FIL");
        assertEq(registry.getProviderCount(), 0, "Provider count should be 0");

        // Verify capability constants
        assertEq(registry.MAX_CAPABILITY_KEY_LENGTH(), 32, "Max capability key length should be 32");
        assertEq(registry.MAX_CAPABILITY_VALUE_LENGTH(), 128, "Max capability value length should be 128");
        assertEq(registry.MAX_CAPABILITIES(), 24, "Max capabilities should be 24");
    }

    // ========== Registration Tests ==========

    function testRegisterProvider() public {
        // Check burn actor balance before
        uint256 burnActorBalanceBefore = BURN_ADDRESS.balance;

        vm.startPrank(provider1);

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit ServiceProviderRegistry.ProviderRegistered(1, provider1, provider1);

        // Non-empty capability arrays
        (string[] memory capKeys, bytes[] memory capValues) = defaultPDPData.toCapabilities(4);
        capKeys[0] = "datacenter";
        capKeys[1] = "redundancy";
        capKeys[2] = "latency";
        capKeys[3] = "cert";

        capValues[0] = bytes("EU-WEST");
        capValues[1] = bytes("3x");
        capValues[2] = bytes("low");
        capValues[3] = bytes("ISO27001");

        vm.expectEmit(true, true, false, true);
        emit ServiceProviderRegistry.ProductAdded(
            1, ServiceProviderRegistryStorage.ProductType.PDP, provider1, capKeys, capValues
        );

        // Register provider
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );

        vm.stopPrank();

        // Verify registration
        assertEq(providerId, 1, "Provider ID should be 1");
        ServiceProviderRegistry.ServiceProviderInfoView memory providerInfo = registry.getProviderByAddress(provider1);
        assertEq(providerInfo.providerId, 1, "Provider ID should be 1");
        assertEq(providerInfo.info.serviceProvider, provider1, "Provider address should match");
        assertTrue(providerInfo.info.isActive, "Provider should be active");
        assertTrue(registry.isRegisteredProvider(provider1), "Provider should be registered");
        assertTrue(registry.isProviderActive(1), "Provider should be active");

        // Verify provider info
        ServiceProviderRegistry.ServiceProviderInfoView memory info = registry.getProvider(1);
        assertEq(info.providerId, 1, "Provider ID should be 1");
        assertEq(info.info.serviceProvider, provider1, "Service provider should be provider1");
        assertEq(info.info.payee, provider1, "Payee should be provider1");
        assertEq(info.info.name, "", "Name should be empty");
        assertEq(info.info.description, "Test provider description", "Description should match");
        assertTrue(info.info.isActive, "Provider should be active");

        // Verify PDP service using getPDPService (including capabilities)
        (PDPOffering.Schema memory pdpData, string[] memory keys, bool isActive) = registry.getPDPService(1);
        assertEq(pdpData.serviceURL, SERVICE_URL, "Service URL should match");
        assertEq(pdpData.minPieceSizeInBytes, defaultPDPData.minPieceSizeInBytes, "Min piece size should match");
        assertEq(pdpData.maxPieceSizeInBytes, defaultPDPData.maxPieceSizeInBytes, "Max piece size should match");
        assertEq(pdpData.ipniPiece, defaultPDPData.ipniPiece, "IPNI piece should match");
        assertEq(pdpData.ipniIpfs, defaultPDPData.ipniIpfs, "IPNI IPFS should match");
        assertEq(
            pdpData.storagePricePerTibPerDay, defaultPDPData.storagePricePerTibPerDay, "Storage price should match"
        );
        assertEq(
            pdpData.minProvingPeriodInEpochs, defaultPDPData.minProvingPeriodInEpochs, "Min proving period should match"
        );
        assertEq(pdpData.location, defaultPDPData.location, "Location should match");
        assertTrue(isActive, "PDP service should be active");

        // Verify capabilities
        assertEq(keys.length, capKeys.length, "Should have 4 capability keys");
        assertEq(keys[0], "datacenter", "First key should be datacenter");
        assertEq(keys[1], "redundancy", "Second key should be redundancy");
        assertEq(keys[2], "latency", "Third key should be latency");
        assertEq(keys[3], "cert", "Fourth key should be cert");

        // Query values using new methods
        string[] memory queryKeys = new string[](4);
        queryKeys[0] = "datacenter";
        queryKeys[1] = "redundancy";
        queryKeys[2] = "latency";
        queryKeys[3] = "cert";

        bytes[] memory values =
            registry.getProductCapabilities(1, ServiceProviderRegistryStorage.ProductType.PDP, queryKeys);
        assertEq(values[0], "EU-WEST", "First value should be EU-WEST");
        assertEq(values[1], "3x", "Second value should be 3x");
        assertEq(values[2], "low", "Third value should be low");
        assertEq(values[3], "ISO27001", "Fourth value should be ISO27001");

        // Also verify using getProviderWithProduct
        ServiceProviderRegistryStorage.ProviderWithProduct memory providerWithProduct =
            registry.getProviderWithProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        assertTrue(providerWithProduct.product.isActive, "Product should be active");
        assertEq(
            providerWithProduct.product.capabilityKeys.length, capKeys.length, "Product should have 4 capability keys"
        );
        assertEq(providerWithProduct.product.capabilityKeys[0], "datacenter", "Product first key should be datacenter");

        // Verify value using direct mapping access
        bytes memory datacenterValue =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "datacenter");
        assertEq(datacenterValue, bytes("EU-WEST"), "Product first value should be EU-WEST");

        // Verify fee was burned
        uint256 burnActorBalanceAfter = BURN_ADDRESS.balance;
        assertEq(burnActorBalanceAfter - burnActorBalanceBefore, REGISTRATION_FEE, "Fee should be burned");
    }

    function testCannotRegisterTwice() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // First registration
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Try to register again
        vm.prank(provider1);
        vm.expectRevert("Address already registered");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );
    }

    function testRegisterMultipleProviders() public {
        // Provider 1 capabilities
        (string[] memory capKeys1, bytes[] memory capValues1) = defaultPDPData.toCapabilities(2);
        capKeys1[0] = "region";
        capKeys1[1] = "performance";

        capValues1[0] = "US-EAST";
        capValues1[1] = "high";

        // Register provider 1
        vm.prank(provider1);
        uint256 id1 = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Provider 1 description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys1,
            capValues1
        );

        // Provider 2 capabilities
        (string[] memory capKeys2, bytes[] memory capValues2) = defaultPDPData.toCapabilities(3);
        capKeys2[0] = "region";
        capKeys2[1] = "storage";
        capKeys2[2] = "availability";

        capValues2[0] = bytes("ASIA-PAC");
        capValues2[1] = bytes("100TB");
        capValues2[2] = bytes("99.999%");
        capValues2[3] = SERVICE_URL_2;

        // Register provider 2

        vm.prank(provider2);
        uint256 id2 = registry.registerProvider{value: REGISTRATION_FEE}(
            provider2, // payee
            "",
            "Provider 2 description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys2,
            capValues2
        );

        // Verify IDs are sequential
        assertEq(id1, 1, "First provider should have ID 1");
        assertEq(id2, 2, "Second provider should have ID 2");
        assertEq(registry.getProviderCount(), 2, "Provider count should be 2");

        // Verify both are in active list
        (uint256[] memory activeProviders,) = registry.getAllActiveProviders(0, 100);
        assertEq(activeProviders.length, 2, "Should have 2 active providers");
        assertEq(activeProviders[0], 1, "First active provider should be ID 1");
        assertEq(activeProviders[1], 2, "Second active provider should be ID 2");

        // Verify provider 1 capabilities
        (, string[] memory keys1,) = registry.getPDPService(1);
        assertEq(keys1.length, capKeys1.length, "Provider 1 should have as many capability keys as provided");
        assertEq(keys1[0], "region", "Provider 1 first key should be region");
        assertEq(keys1[1], "performance", "Provider 1 second key should be performance");

        // Query values for provider 1
        bytes[] memory values1 =
            registry.getProductCapabilities(1, ServiceProviderRegistryStorage.ProductType.PDP, keys1);
        assertEq(values1[0], "US-EAST", "Provider 1 first value should be US-EAST");
        assertEq(values1[1], "high", "Provider 1 second value should be high");

        // Verify provider 2 capabilities
        (, string[] memory keys2,) = registry.getPDPService(2);
        assertEq(keys2.length, capKeys2.length, "Provider 2 should have as many capability keys as provided");
        assertEq(keys2[0], "region", "Provider 2 first key should be region");
        assertEq(keys2[1], "storage", "Provider 2 second key should be storage");
        assertEq(keys2[2], "availability", "Provider 2 third key should be availability");

        // Query values for provider 2
        bytes[] memory values2 =
            registry.getProductCapabilities(2, ServiceProviderRegistryStorage.ProductType.PDP, keys2);
        assertEq(values2[0], "ASIA-PAC", "Provider 2 first value should be ASIA-PAC");
        assertEq(values2[1], "100TB", "Provider 2 second value should be 100TB");
        assertEq(values2[2], "99.999%", "Provider 2 third value should be 99.999%");
    }

    function testRegisterWithInsufficientFee() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Try to register with less than 5 FIL
        vm.prank(provider1);
        vm.expectRevert("Incorrect fee amount");
        registry.registerProvider{value: 1 ether}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Try with 0 fee
        vm.prank(provider1);
        vm.expectRevert("Incorrect fee amount");
        registry.registerProvider{value: 0}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );
    }

    function testRegisterWithExcessFee() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Try to register with 2 FIL (less than 5 FIL) - should fail
        vm.prank(provider1);
        vm.expectRevert("Incorrect fee amount");
        registry.registerProvider{value: 2 ether}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Verify provider was not registered
        ServiceProviderRegistry.ServiceProviderInfoView memory notRegisteredInfo =
            registry.getProviderByAddress(provider1);
        assertEq(notRegisteredInfo.info.serviceProvider, address(0), "Provider should not be registered");
    }

    function testRegisterWithInvalidData() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Test service URL too long
        values[0] = new bytes(129);
        vm.prank(provider1);
        vm.expectRevert("Capability value too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Test invalid PDP data - location too long
        values[7] = new bytes(129);
        for (uint256 i = 0; i < values.length; i++) {
            values[7][i] = "a";
        }
        vm.prank(provider1);
        vm.expectRevert("Capability value too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );
    }

    // ========== Update Tests ==========

    function testUpdateProduct() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Update PDP service using new updateProduct function
        (keys, values) = updatedPDPData.toCapabilities();
        vm.startPrank(provider1);

        vm.expectEmit(true, true, false, true);
        emit ServiceProviderRegistry.ProductUpdated(
            1, ServiceProviderRegistryStorage.ProductType.PDP, provider1, keys, values
        );

        registry.updateProduct(ServiceProviderRegistryStorage.ProductType.PDP, keys, values);

        vm.stopPrank();

        // Verify update
        (PDPOffering.Schema memory pdpData,, bool isActive) = registry.getPDPService(1);
        assertEq(pdpData.serviceURL, UPDATED_SERVICE_URL, "Service URL should be updated");
        assertEq(pdpData.minPieceSizeInBytes, updatedPDPData.minPieceSizeInBytes, "Min piece size should be updated");
        assertEq(pdpData.maxPieceSizeInBytes, updatedPDPData.maxPieceSizeInBytes, "Max piece size should be updated");
        assertEq(pdpData.ipniPiece, updatedPDPData.ipniPiece, "IPNI piece should be updated");
        assertEq(pdpData.ipniIpfs, updatedPDPData.ipniIpfs, "IPNI IPFS should be updated");
        assertEq(
            pdpData.storagePricePerTibPerDay, updatedPDPData.storagePricePerTibPerDay, "Storage price should be updated"
        );
        assertEq(
            pdpData.minProvingPeriodInEpochs,
            updatedPDPData.minProvingPeriodInEpochs,
            "Min proving period should be updated"
        );
        assertEq(pdpData.location, updatedPDPData.location, "Location should be updated");
        assertTrue(isActive, "PDP service should still be active");
    }

    function testOnlyOwnerCanUpdate() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Try to update as non-owner
        vm.prank(provider2);
        vm.expectRevert("Provider not registered");
        registry.updateProduct(ServiceProviderRegistryStorage.ProductType.PDP, keys, values);
    }

    function testCannotUpdateRemovedProvider() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register and remove provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        vm.prank(provider1);
        registry.removeProvider();

        // Try to update
        vm.prank(provider1);
        vm.expectRevert("Provider not registered");
        registry.updateProduct(ServiceProviderRegistryStorage.ProductType.PDP, keys, values);
    }

    // ========== Ownership Tests (Transfer functionality removed) ==========
    // Note: Ownership transfer functionality has been removed from the contract.
    // Provider ownership is now fixed to the address that performed the registration.

    // ========== Removal Tests ==========

    function testRemoveProvider() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Remove provider
        vm.startPrank(provider1);

        vm.expectEmit(true, true, false, true);
        emit ServiceProviderRegistry.ProviderRemoved(1);

        registry.removeProvider();

        vm.stopPrank();

        // Verify removal
        assertFalse(registry.isProviderActive(1), "Provider should be inactive");
        assertFalse(registry.isRegisteredProvider(provider1), "Provider should not be registered");
        ServiceProviderRegistry.ServiceProviderInfoView memory removedInfo = registry.getProviderByAddress(provider1);
        assertEq(removedInfo.info.serviceProvider, address(0), "Address lookup should return empty");

        // Verify provider info still exists (soft delete)
        ServiceProviderRegistry.ServiceProviderInfoView memory info = registry.getProvider(1);
        assertEq(info.providerId, 1, "Provider ID should still be 1");
        assertFalse(info.info.isActive, "Provider should be marked inactive");
        assertEq(info.info.serviceProvider, provider1, "Service provider should still be recorded");
        assertEq(info.info.payee, provider1, "Payee should still be recorded");

        // Verify PDP service is inactive
        (,, bool isActive) = registry.getPDPService(1);
        assertFalse(isActive, "PDP service should be inactive");

        // Verify not in active list
        (uint256[] memory activeProviders,) = registry.getAllActiveProviders(0, 100);
        assertEq(activeProviders.length, 0, "Should have no active providers");
    }

    function testCannotRemoveAlreadyRemoved() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        vm.prank(provider1);
        registry.removeProvider();

        vm.prank(provider1);
        vm.expectRevert("Provider not registered");
        registry.removeProvider();
    }

    function testOnlyOwnerCanRemove() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        vm.prank(provider2);
        vm.expectRevert("Provider not registered");
        registry.removeProvider();
    }

    function testCanReregisterAfterRemoval() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register, remove, then register again
        vm.prank(provider1);
        uint256 id1 = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Provider 1 description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        vm.prank(provider1);
        registry.removeProvider();

        (string[] memory updatedKeys, bytes[] memory updatedValues) = updatedPDPData.toCapabilities();
        vm.prank(provider1);
        uint256 id2 = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Provider 2 description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            updatedKeys,
            updatedValues
        );

        // Should get new ID
        assertEq(id1, 1, "First registration should be ID 1");
        assertEq(id2, 2, "Second registration should be ID 2");
        assertTrue(registry.isProviderActive(2), "New registration should be active");
        assertFalse(registry.isProviderActive(1), "Old registration should be inactive");
    }

    // ========== Multi-Product Tests ==========

    function testGetProvidersByProductType() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register 3 providers with PDP
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        values[0] = SERVICE_URL_2;
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider2, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        values[0] = "https://provider3.example.com";
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider3, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Get providers by product type with pagination
        ServiceProviderRegistryStorage.PaginatedProviders memory result =
            registry.getProvidersByProductType(ServiceProviderRegistryStorage.ProductType.PDP, false, 0, 10);
        assertEq(result.providers.length, 3, "Should have 3 providers with PDP");
        assertEq(result.providers[0].providerId, 1, "First provider should be ID 1");
        assertEq(result.providers[0].providerInfo.payee, provider1, "Unexpected provider payee");
        assertTrue(result.providers[0].product.isActive, "product should be active");
        assertEq(result.providers[0].product.capabilityKeys.length, keys.length, "capability key length mismatch ");
        assertEq(result.providers[0].product.capabilityKeys[0], keys[0], "capability key mismatch ");
        assertEq(
            uint256(result.providers[0].product.productType),
            uint256(ServiceProviderRegistryStorage.ProductType.PDP),
            "unexpected product type"
        );
        assertEq(result.providers[0].productCapabilityValues.length, values.length, "capability values length mismatch");
        assertEq(
            result.providers[0].productCapabilityValues[0],
            "https://provider1.example.com",
            "incorrect capabilities value"
        );
        assertEq(result.providers[1].providerId, 2, "Second provider should be ID 2");
        assertEq(result.providers[1].providerInfo.payee, provider2, "Unexpected provider payee");
        assertEq(result.providers[2].providerId, 3, "Third provider should be ID 3");
        assertEq(result.providers[2].providerInfo.payee, provider3, "Unexpected provider payee");
        assertFalse(result.hasMore, "Should not have more results");
    }

    function testGetActiveProvidersByProductType() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register 3 providers with PDP
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        values[0] = SERVICE_URL_2;
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider2, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        values[0] = "https://provider3.example.com";
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider3, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Remove provider 2
        vm.prank(provider2);
        registry.removeProvider();

        // Get active providers by product type with pagination
        ServiceProviderRegistryStorage.PaginatedProviders memory activeResult =
            registry.getProvidersByProductType(ServiceProviderRegistryStorage.ProductType.PDP, true, 0, 10);
        assertEq(activeResult.providers.length, 2, "Should have 2 active providers with PDP");
        assertEq(activeResult.providers[0].providerId, 1, "First active should be ID 1");
        assertEq(
            activeResult.providers[0].providerInfo.description, "Test provider description", "description mismatch"
        );
        assertTrue(activeResult.providers[0].product.isActive, "should be active");
        assertEq(
            activeResult.providers[0].product.capabilityKeys.length, keys.length, "capability keys length mismatch"
        );
        assertEq(
            activeResult.providers[1].productCapabilityValues.length, values.length, "capability values length mismatch"
        );
        assertEq(activeResult.providers[1].providerId, 3, "Second active should be ID 3");
        assertEq(
            activeResult.providers[1].product.capabilityKeys.length, keys.length, "capability keys length mismatch"
        );
        assertEq(
            activeResult.providers[1].productCapabilityValues.length, values.length, "capability values length mismatch"
        );
        assertFalse(activeResult.hasMore, "Should not have more results");
    }

    function testProviderHasProduct() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        assertTrue(
            registry.providerHasProduct(1, ServiceProviderRegistryStorage.ProductType.PDP),
            "Provider should have PDP product"
        );
    }

    function testGetProduct() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        ServiceProviderRegistryStorage.ProviderWithProduct memory providerWithProduct =
            registry.getProviderWithProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        assertTrue(providerWithProduct.product.isActive, "Product should be active");
        string[] memory getProductKeys = providerWithProduct.product.capabilityKeys;
        bytes[] memory getProductCapabilities = providerWithProduct.productCapabilityValues;

        // Decode and verify
        PDPOffering.Schema memory decoded = PDPOffering.fromCapabilities(getProductKeys, getProductCapabilities);
        assertEq(decoded.serviceURL, SERVICE_URL, "Service URL should match");

        // compare to getAllProductCapabilities
        (
            bool getAllProductCapabilitiesIsActive,
            string[] memory getAllProductCapabilitiesKeys,
            bytes[] memory getAllProductCapabilitiesValues
        ) = registry.getAllProductCapabilities(1, ServiceProviderRegistryStorage.ProductType.PDP);
        assertTrue(getAllProductCapabilitiesIsActive, "Product should be active");
        assertEq(
            getAllProductCapabilitiesKeys.length,
            getAllProductCapabilitiesValues.length,
            "keys and values length mismatch"
        );
        assertEq(getProductKeys.length, getAllProductCapabilitiesKeys.length, "key length mismatch");
        assertEq(getProductCapabilities.length, getAllProductCapabilitiesValues.length, "key length mismatch");
        for (uint256 i = 0; i < getProductCapabilities.length; i++) {
            assertEq(getProductKeys[i], getAllProductCapabilitiesKeys[i], "key length mismatch");
            assertEq(getProductCapabilities[i], getAllProductCapabilitiesValues[i], "key length mismatch");
        }
    }

    function testCannotAddProductTwice() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        (string[] memory updatedKeys, bytes[] memory updatedValues) = updatedPDPData.toCapabilities();
        // Try to add PDP again
        vm.prank(provider1);
        vm.expectRevert("Product already exists for this provider");
        registry.addProduct(ServiceProviderRegistryStorage.ProductType.PDP, updatedKeys, updatedValues);
    }

    function testCanRemoveLastProduct() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "serviceURL",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Verify product exists before removal
        assertTrue(registry.providerHasProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP));

        // Remove the only product - should succeed now
        vm.prank(provider1);
        vm.expectEmit(true, true, false, true);
        emit ServiceProviderRegistry.ProductRemoved(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        registry.removeProduct(ServiceProviderRegistryStorage.ProductType.PDP);

        // Verify product is removed
        assertFalse(registry.providerHasProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP));

        (PDPOffering.Schema memory pdpData, string[] memory keysAfter, bool isActive) =
            registry.getPDPService(providerId);
        assertFalse(isActive);
        assertEq(keysAfter.length, 0);
        assertEq(bytes(pdpData.serviceURL).length, 0);
        assertEq(bytes(pdpData.location).length, 0);
        assertEq(pdpData.minPieceSizeInBytes, 0);
        assertEq(pdpData.minPieceSizeInBytes, 0);
        assertEq(pdpData.maxPieceSizeInBytes, 0);
        assertFalse(pdpData.ipniPiece);
        assertFalse(pdpData.ipniIpfs);
        assertEq(pdpData.minProvingPeriodInEpochs, 0);
        assertEq(pdpData.storagePricePerTibPerDay, 0);
        assertEq(address(pdpData.paymentTokenAddress), address(0));
    }

    // ========== Getter Tests ==========

    function testGetAllActiveProviders() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register 3 providers
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        values[0] = SERVICE_URL_2;
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider2, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        values[0] = "https://provider3.example.com";
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider3, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Remove provider 2
        vm.prank(provider2);
        registry.removeProvider();

        // Get active providers
        (uint256[] memory activeProviders,) = registry.getAllActiveProviders(0, 100);
        assertEq(activeProviders.length, 2, "Should have 2 active providers");
        assertEq(activeProviders[0], 1, "First active should be ID 1");
        assertEq(activeProviders[1], 3, "Second active should be ID 3");
    }

    function testGetProviderCount() public {
        assertEq(registry.getProviderCount(), 0, "Initial count should be 0");

        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );
        assertEq(registry.getProviderCount(), 1, "Count should be 1");

        values[0] = SERVICE_URL_2;
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider2, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );
        assertEq(registry.getProviderCount(), 2, "Count should be 2");

        // Remove one - count should still be 2 (includes inactive)
        vm.prank(provider1);
        registry.removeProvider();
        assertEq(registry.getProviderCount(), 2, "Count should still be 2");
    }

    function testGetNonExistentProvider() public {
        vm.expectRevert("Provider does not exist");
        registry.getProvider(1);

        vm.expectRevert("Provider does not exist");
        registry.getProviderWithProduct(1, ServiceProviderRegistryStorage.ProductType.PDP);

        vm.expectRevert("Provider does not exist");
        registry.isProviderActive(1);
    }

    // ========== Edge Cases ==========

    function testMultipleUpdatesInSameBlock() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        vm.startPrank(provider1);

        (string[] memory updatedKeys, bytes[] memory updatedValues) = updatedPDPData.toCapabilities();
        // Expect the update event with timestamp
        vm.expectEmit(true, true, true, true);
        emit ServiceProviderRegistry.ProductUpdated(
            1, ServiceProviderRegistryStorage.ProductType.PDP, provider1, updatedKeys, updatedValues
        );

        registry.updateProduct(ServiceProviderRegistryStorage.ProductType.PDP, updatedKeys, updatedValues);
        vm.stopPrank();

        // Verify the product was updated (check the actual data)
        (PDPOffering.Schema memory pdpData,,) = registry.getPDPService(1);
        assertEq(pdpData.serviceURL, UPDATED_SERVICE_URL, "Service URL should be updated");
    }

    // ========== Provider Info Update Tests ==========

    function testUpdateProviderDescription() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Initial description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Verify initial description
        ServiceProviderRegistry.ServiceProviderInfoView memory info = registry.getProvider(1);
        assertEq(info.providerId, 1, "Provider ID should be 1");
        assertEq(info.info.description, "Initial description", "Initial description should match");

        // Update description
        vm.prank(provider1);
        vm.expectEmit(true, true, false, true);
        emit ServiceProviderRegistry.ProviderInfoUpdated(1);
        registry.updateProviderInfo("Updated Name", "Updated description");

        // Verify updated description
        info = registry.getProvider(1);
        assertEq(info.providerId, 1, "Provider ID should still be 1");
        assertEq(info.info.description, "Updated description", "Description should be updated");
    }

    function testCannotUpdateProviderDescriptionIfNotOwner() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Initial description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Try to update as non-owner
        vm.prank(provider2);
        vm.expectRevert("Provider not registered");
        registry.updateProviderInfo("", "Unauthorized update");
    }

    function testCannotUpdateProviderDescriptionTooLong() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Initial description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Try to update with description that's too long
        string memory longDescription =
            "This is a very long description that exceeds the maximum allowed length of 256 characters. It just keeps going and going and going and going and going and going and going and going and going and going and going and going and going and going and going and characters limit!";

        vm.prank(provider1);
        vm.expectRevert("Description too long");
        registry.updateProviderInfo("", longDescription);
    }

    function testNameTooLongOnRegister() public {
        // Create a name that's too long (129 chars, max is 128)
        bytes memory longName = new bytes(129);
        for (uint256 i = 0; i < 129; i++) {
            longName[i] = "a";
        }

        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        vm.expectRevert("Name too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            string(longName),
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );
    }

    function testNameTooLongOnUpdate() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "Initial Name",
            "Initial description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        // Create a name that's too long (129 chars, max is 128)
        bytes memory longName = new bytes(129);
        for (uint256 i = 0; i < 129; i++) {
            longName[i] = "b";
        }

        vm.prank(provider1);
        vm.expectRevert("Name too long");
        registry.updateProviderInfo(string(longName), "Updated description");
    }

    // ========== Event Timestamp Tests ==========

    function testEventTimestampsEmittedCorrectly() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Test ProviderRegistered and ProductAdded events
        vm.prank(provider1);
        vm.expectEmit(true, true, true, true);
        emit ServiceProviderRegistry.ProviderRegistered(1, provider1, provider1);
        vm.expectEmit(true, true, true, true);
        emit ServiceProviderRegistry.ProductAdded(
            1, ServiceProviderRegistryStorage.ProductType.PDP, provider1, keys, values
        );

        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        (string[] memory updatedKeys, bytes[] memory updatedValues) = updatedPDPData.toCapabilities();
        // Test ProductUpdated event
        vm.prank(provider1);
        vm.expectEmit(true, true, true, true);
        emit ServiceProviderRegistry.ProductUpdated(
            1, ServiceProviderRegistryStorage.ProductType.PDP, provider1, updatedKeys, updatedValues
        );
        registry.updateProduct(ServiceProviderRegistryStorage.ProductType.PDP, updatedKeys, updatedValues);

        // Test ProviderRemoved event
        vm.prank(provider1);
        vm.expectEmit(true, true, false, true);
        emit ServiceProviderRegistry.ProviderRemoved(1);
        registry.removeProvider();
    }

    // ========== Capability K/V Tests ==========

    function testRegisterWithCapabilities() public {
        // Create capability arrays
        (string[] memory capKeys, bytes[] memory capValues) = updatedPDPData.toCapabilities(3);
        capKeys[0] = "region";
        capKeys[1] = "bandwidth";
        capKeys[2] = "encryption";

        capValues[0] = "us-west-2";
        capValues[1] = "10Gbps";
        capValues[2] = "AES256";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );

        // Get the product and verify capabilities
        ServiceProviderRegistryStorage.ProviderWithProduct memory providerWithProduct =
            registry.getProviderWithProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        string[] memory returnedKeys = providerWithProduct.product.capabilityKeys;
        bool isActive = providerWithProduct.product.isActive;

        assertEq(returnedKeys.length, capKeys.length, "Should have same number of capability keys");
        assertEq(returnedKeys[0], "region", "First key should be region");
        assertEq(returnedKeys[1], "bandwidth", "Second key should be bandwidth");
        assertEq(returnedKeys[2], "encryption", "Third key should be encryption");

        // Query values using new methods
        bytes[] memory returnedValues =
            registry.getProductCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, returnedKeys);
        assertEq(returnedValues[0], "us-west-2", "First value should be us-west-2");
        assertEq(returnedValues[1], "10Gbps", "Second value should be 10Gbps");
        assertEq(returnedValues[2], "AES256", "Third value should be AES256");
        assertTrue(isActive, "Product should be active");
    }

    function testUpdateWithCapabilities() public {
        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        // Register with empty capabilities
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        (string[] memory updatedKeys, bytes[] memory updatedValues) = updatedPDPData.toCapabilities(2);
        // Update with capabilities
        updatedKeys[0] = "support";
        updatedKeys[1] = "sla";

        updatedValues[0] = bytes("24/7");
        updatedValues[1] = bytes("99.99%");

        vm.prank(provider1);
        registry.updateProduct(ServiceProviderRegistryStorage.ProductType.PDP, updatedKeys, updatedValues);

        // Verify capabilities updated
        ServiceProviderRegistryStorage.ProviderWithProduct memory updatedProviderWithProduct =
            registry.getProviderWithProduct(1, ServiceProviderRegistryStorage.ProductType.PDP);
        string[] memory returnedKeys = updatedProviderWithProduct.product.capabilityKeys;

        assertEq(returnedKeys.length, updatedKeys.length, "Should have 2 capability keys");
        assertEq(returnedKeys[0], "support", "First key should be support");

        // Verify value using new method
        bytes memory supportVal =
            registry.productCapabilities(1, ServiceProviderRegistryStorage.ProductType.PDP, "support");
        assertEq(supportVal, "24/7", "First value should be 24/7");
    }

    function testInvalidCapabilityKeyTooLong() public {
        (string[] memory capKeys, bytes[] memory capValues) = defaultPDPData.toCapabilities(1);
        capKeys[0] = "thisKeyIsWayTooLongAndExceedsLimit"; // 35 chars, max is MAX_CAPABILITY_KEY_LENGTH (32)

        capValues[0] = "value";

        vm.prank(provider1);
        vm.expectRevert("Capability key too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );
    }

    function testInvalidCapabilityValueTooLong() public {
        (string[] memory capKeys, bytes[] memory capValues) = defaultPDPData.toCapabilities(1);
        capKeys[0] = "key";

        capValues[0] =
            "This value is way too long and exceeds the maximum allowed length. It is specifically designed to be longer than 128 characters to test the validation of capability values"; // > MAX_CAPABILITY_VALUE_LENGTH (128) chars

        vm.prank(provider1);
        vm.expectRevert("Capability value too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );
    }

    function testInvalidCapabilityArrayLengthMismatch() public {
        string[] memory capKeys = new string[](2);
        capKeys[0] = "key1";
        capKeys[1] = "key2";

        bytes[] memory capValues = new bytes[](1);
        capValues[0] = "value1";

        vm.prank(provider1);
        vm.expectRevert("Keys and values arrays must have same length");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );
    }

    function testDescriptionTooLong() public {
        // Create a description that's too long (> 256 chars)
        string memory longDescription =
            "This is a very long description that exceeds the maximum allowed length of 256 characters. It just keeps going and going and going and going and going and going and going and going and going and going and going and going and going and going and going and characters limit!";

        (string[] memory keys, bytes[] memory values) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        vm.expectRevert("Description too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            longDescription,
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );
    }

    function testEmptyCapabilityKey() public {
        (string[] memory capKeys, bytes[] memory capValues) = updatedPDPData.toCapabilities(1);
        capKeys[0] = "";

        capValues[0] = "value";

        vm.prank(provider1);
        vm.expectRevert("Capability key cannot be empty");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );
    }

    function testEmptyCapabilityValue() public {
        (string[] memory capKeys, bytes[] memory capValues) = updatedPDPData.toCapabilities(1);
        capKeys[0] = "key";

        capValues[0] = "";

        vm.prank(provider1);
        vm.expectRevert("Capability value cannot be empty");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );
    }

    function testTooManyCapabilities() public {
        (string[] memory capKeys, bytes[] memory capValues) = defaultPDPData.toCapabilities(25);

        for (uint256 i = 0; i < 16; i++) {
            capKeys[i] = string(abi.encodePacked("key", vm.toString(i)));
            capValues[i] = abi.encodePacked("value", vm.toString(i));
        }

        vm.prank(provider1);
        vm.expectRevert("Too many capabilities");
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );
    }

    function testMaxCapabilitiesAllowed() public {
        (string[] memory capKeys, bytes[] memory capValues) = defaultPDPData.toCapabilities(16);

        for (uint256 i = 0; i < 16; i++) {
            capKeys[i] = string(abi.encodePacked("key", vm.toString(i)));
            capValues[i] = abi.encodePacked("value", vm.toString(i));
        }

        assertEq(capKeys.length, registry.MAX_CAPABILITIES());

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );

        assertEq(providerId, 1, "Should register successfully with 10 capabilities");

        // Verify all 10 capabilities were stored
        ServiceProviderRegistryStorage.ProviderWithProduct memory maxCapProviderWithProduct =
            registry.getProviderWithProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        assertEq(
            maxCapProviderWithProduct.product.capabilityKeys.length,
            capKeys.length,
            "Should have the same number of keys"
        );
    }

    // ========== New Capability Query Methods Tests ==========

    function testGetProductCapability() public {
        (string[] memory capKeys, bytes[] memory capValues) = defaultPDPData.toCapabilities(3);
        // Register provider with capabilities
        capKeys[0] = "region";
        capKeys[1] = "tier";
        capKeys[2] = "storage";

        capValues[0] = "us-west-2";
        capValues[1] = "premium";
        capValues[2] = "100TB";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );

        // Test single capability queries
        bytes memory region =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "region");
        assertEq(region, "us-west-2", "Region capability should match");

        bytes memory tier =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "tier");
        assertEq(tier, "premium", "Tier capability should match");

        bytes memory storageVal =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "storage");
        assertEq(storageVal, "100TB", "Storage capability should match");

        // Test querying non-existent capability
        bytes memory nonExistent =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "nonexistent");
        assertEq(nonExistent, "", "Non-existent capability should return empty string");
    }

    function testGetProductCapabilities() public {
        (string[] memory capKeys, bytes[] memory capValues) = defaultPDPData.toCapabilities(4);
        // Register provider with capabilities
        capKeys[0] = "region";
        capKeys[1] = "tier";
        capKeys[2] = "storage";
        capKeys[3] = "compliance";

        capValues[0] = "eu-west-1";
        capValues[1] = "standard";
        capValues[2] = "50TB";
        capValues[3] = "GDPR";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );

        // Query multiple capabilities
        string[] memory queryKeys = new string[](3);
        queryKeys[0] = "tier";
        queryKeys[1] = "compliance";
        queryKeys[2] = "region";

        bytes[] memory results =
            registry.getProductCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, queryKeys);

        assertEq(results.length, 3, "Should return 3 values");
        assertEq(results[0], "standard", "First result should be tier value");
        assertEq(results[1], "GDPR", "Second result should be compliance value");
        assertEq(results[2], "eu-west-1", "Third result should be region value");

        // Test with some non-existent keys
        string[] memory mixedKeys = new string[](4);
        mixedKeys[0] = "region";
        mixedKeys[1] = "nonexistent1";
        mixedKeys[2] = "storage";
        mixedKeys[3] = "nonexistent2";

        bytes[] memory mixedResults =
            registry.getProductCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, mixedKeys);

        assertEq(mixedResults.length, 4, "Should return 4 values");
        assertEq(mixedResults[0], "eu-west-1", "First result should be region");
        assertEq(mixedResults[1], "", "Second result should be empty");
        assertEq(mixedResults[2], "50TB", "Third result should be storage");
        assertEq(mixedResults[3], "", "Fourth result should be empty");
    }

    function testDirectMappingAccess() public {
        (string[] memory capKeys, bytes[] memory capValues) = updatedPDPData.toCapabilities(2);
        // Register provider with capabilities
        capKeys[0] = "datacenter";
        capKeys[1] = "bandwidth";

        capValues[0] = "NYC-01";
        capValues[1] = "10Gbps";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );

        // Test direct public mapping access
        bytes memory datacenter =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "datacenter");
        assertEq(datacenter, "NYC-01", "Direct mapping access should work");

        bytes memory bandwidth =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "bandwidth");
        assertEq(bandwidth, "10Gbps", "Direct mapping access should work for bandwidth");
    }

    function testUpdateWithTooManyCapabilities() public {
        (string[] memory capKeys, bytes[] memory capValues) = defaultPDPData.toCapabilities();

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capKeys,
            capValues
        );

        (string[] memory updatedKeys, bytes[] memory updatedValues) = updatedPDPData.toCapabilities(16);
        // Try to update with 11 capabilities (exceeds MAX_CAPABILITIES of 10)
        for (uint256 i = 0; i < 16; i++) {
            updatedKeys[i] = string(abi.encodePacked("key", vm.toString(i)));
            updatedValues[i] = abi.encodePacked("value", vm.toString(i));
        }

        assertEq(updatedKeys.length, registry.MAX_CAPABILITIES() + 1);

        vm.prank(provider1);
        vm.expectRevert("Too many capabilities");
        registry.updateProduct(ServiceProviderRegistryStorage.ProductType.PDP, updatedKeys, updatedValues);
    }

    function testCapabilityUpdateClearsOldValues() public {
        (string[] memory initialKeys, bytes[] memory initialValues) = updatedPDPData.toCapabilities(3);
        // Register provider with initial capabilities
        initialKeys[0] = "region";
        initialKeys[1] = "tier";
        initialKeys[2] = "oldkey";

        initialValues[0] = "us-east-1";
        initialValues[1] = "basic";
        initialValues[2] = "oldvalue";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            provider1, // payee
            "",
            "Test provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            initialKeys,
            initialValues
        );

        // Verify initial values
        bytes memory oldValue =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "oldkey");
        assertEq(oldValue, "oldvalue", "Old key should have value initially");

        (string[] memory newKeys, bytes[] memory newValues) = updatedPDPData.toCapabilities(2);
        // Update with new capabilities (without oldkey)
        newKeys[0] = "region";
        newKeys[1] = "newkey";

        newValues[0] = "eu-central-1";
        newValues[1] = "newvalue";

        vm.prank(provider1);
        registry.updateProduct(ServiceProviderRegistryStorage.ProductType.PDP, newKeys, newValues);

        // Verify old key is cleared
        bytes memory clearedValue =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "oldkey");
        assertEq(clearedValue, "", "Old key should be cleared after update");

        // Verify new values are set
        bytes memory newRegion =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "region");
        assertEq(newRegion, "eu-central-1", "Region should be updated");

        bytes memory newKey =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "newkey");
        assertEq(newKey, "newvalue", "New key should have value");

        // Verify tier key is also cleared (was in initial but not in update)
        bytes memory clearedTier =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "tier");
        assertEq(clearedTier, "", "Tier key should be cleared after update");
    }
}
