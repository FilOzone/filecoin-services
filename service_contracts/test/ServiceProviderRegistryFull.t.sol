// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ServiceProviderRegistry.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ServiceProviderRegistryFullTest is Test {
    ServiceProviderRegistry public implementation;
    ServiceProviderRegistry public registry;

    address public owner;
    address public provider1;
    address public provider2;
    address public provider3;
    address public user;

    string constant SERVICE_URL = "https://provider1.example.com";
    string constant SERVICE_URL_2 = "https://provider2.example.com";
    string constant UPDATED_SERVICE_URL = "https://provider1-updated.example.com";

    uint256 constant REGISTRATION_FEE = 1 ether; // 1 FIL in attoFIL

    ServiceProviderRegistry.PDPOffering public defaultPDPData;
    ServiceProviderRegistry.PDPOffering public updatedPDPData;
    bytes public encodedDefaultPDPData;
    bytes public encodedUpdatedPDPData;

    event ProviderRegistered(uint256 indexed providerId, address indexed owner, uint256 registeredAt);
    event ServiceUpdated(
        uint256 indexed providerId, ServiceProviderRegistry.ProductType indexed productType, uint256 updatedAt
    );
    event ProductAdded(
        uint256 indexed providerId, ServiceProviderRegistry.ProductType indexed productType, uint256 addedAt
    );
    event ProductRemoved(
        uint256 indexed providerId, ServiceProviderRegistry.ProductType indexed productType, uint256 removedAt
    );
    event OwnershipTransferred(
        uint256 indexed providerId, address indexed previousOwner, address indexed newOwner, uint256 transferredAt
    );
    event ProviderRemoved(uint256 indexed providerId, uint256 removedAt);

    function setUp() public {
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
        defaultPDPData = ServiceProviderRegistry.PDPOffering({
            serviceURL: SERVICE_URL,
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerMonth: 1000000000000000000 // 1 FIL per TiB per month
        });

        updatedPDPData = ServiceProviderRegistry.PDPOffering({
            serviceURL: UPDATED_SERVICE_URL,
            minPieceSizeInBytes: 512,
            maxPieceSizeInBytes: 2 * 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: true,
            storagePricePerTibPerMonth: 2000000000000000000 // 2 FIL per TiB per month
        });

        // Encode PDP data
        encodedDefaultPDPData = abi.encode(defaultPDPData);

        encodedUpdatedPDPData = abi.encode(updatedPDPData);
    }

    // ========== Initial State Tests ==========

    function testInitialState() public view {
        assertEq(registry.VERSION(), "0.0.1", "Version should be 0.0.1");
        assertEq(registry.owner(), owner, "Owner should be deployer");
        assertEq(registry.getNextProviderId(), 1, "Next provider ID should start at 1");
        assertEq(registry.getRegistrationFee(), 1 ether, "Registration fee should be 1 FIL");
        assertEq(registry.REGISTRATION_FEE(), 1 ether, "Registration fee constant should be 1 FIL");
        assertEq(registry.getProviderCount(), 0, "Provider count should be 0");

        // Verify capability constants
        assertEq(registry.MAX_CAPABILITY_KEY_LENGTH(), 12, "Max capability key length should be 12");
        assertEq(registry.MAX_CAPABILITY_VALUE_LENGTH(), 64, "Max capability value length should be 64");
    }

    // ========== Registration Tests ==========

    function testRegisterProvider() public {
        // Check burn actor balance before
        uint256 burnActorBalanceBefore = registry.BURN_ACTOR().balance;

        vm.startPrank(provider1);

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit ProviderRegistered(1, provider1, block.number);

        vm.expectEmit(true, true, false, true);
        emit ServiceUpdated(1, ServiceProviderRegistry.ProductType.PDP, block.number);

        // Non-empty capability arrays
        string[] memory capKeys = new string[](4);
        capKeys[0] = "datacenter";
        capKeys[1] = "redundancy";
        capKeys[2] = "latency";
        capKeys[3] = "cert";

        string[] memory capValues = new string[](4);
        capValues[0] = "EU-WEST";
        capValues[1] = "3x";
        capValues[2] = "low";
        capValues[3] = "ISO27001";

        // Register provider
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        vm.stopPrank();

        // Verify registration
        assertEq(providerId, 1, "Provider ID should be 1");
        assertEq(registry.getProviderByAddress(provider1), 1, "Provider ID lookup should work");
        assertTrue(registry.isRegisteredProvider(provider1), "Provider should be registered");
        assertTrue(registry.isProviderActive(1), "Provider should be active");

        // Verify provider info
        ServiceProviderRegistry.ServiceProviderInfo memory info = registry.getProvider(1);
        assertEq(info.owner, provider1, "Owner should be provider1");
        assertEq(info.description, "Test provider description", "Description should match");
        assertTrue(info.isActive, "Provider should be active");

        // Verify PDP service using getPDPService (including capabilities)
        (
            ServiceProviderRegistry.PDPOffering memory pdpData,
            string[] memory keys,
            string[] memory values,
            bool isActive
        ) = registry.getPDPService(1);
        assertEq(pdpData.serviceURL, SERVICE_URL, "Service URL should match");
        assertEq(pdpData.minPieceSizeInBytes, defaultPDPData.minPieceSizeInBytes, "Min piece size should match");
        assertEq(pdpData.maxPieceSizeInBytes, defaultPDPData.maxPieceSizeInBytes, "Max piece size should match");
        assertEq(pdpData.ipniPiece, defaultPDPData.ipniPiece, "IPNI piece should match");
        assertEq(pdpData.ipniIpfs, defaultPDPData.ipniIpfs, "IPNI IPFS should match");
        assertEq(
            pdpData.storagePricePerTibPerMonth, defaultPDPData.storagePricePerTibPerMonth, "Storage price should match"
        );
        assertTrue(isActive, "PDP service should be active");

        // Verify capabilities
        assertEq(keys.length, 4, "Should have 4 capability keys");
        assertEq(values.length, 4, "Should have 4 capability values");
        assertEq(keys[0], "datacenter", "First key should be datacenter");
        assertEq(values[0], "EU-WEST", "First value should be EU-WEST");
        assertEq(keys[1], "redundancy", "Second key should be redundancy");
        assertEq(values[1], "3x", "Second value should be 3x");
        assertEq(keys[2], "latency", "Third key should be latency");
        assertEq(values[2], "low", "Third value should be low");
        assertEq(keys[3], "cert", "Fourth key should be cert");
        assertEq(values[3], "ISO27001", "Fourth value should be ISO27001");

        // Also verify using getProduct
        (bytes memory productData, string[] memory productKeys, string[] memory productValues, bool productActive) =
            registry.getProduct(providerId, ServiceProviderRegistry.ProductType.PDP);
        assertTrue(productActive, "Product should be active");
        assertEq(productKeys.length, 4, "Product should have 4 capability keys");
        assertEq(productKeys[0], "datacenter", "Product first key should be datacenter");
        assertEq(productValues[0], "EU-WEST", "Product first value should be EU-WEST");

        // Verify fee was burned
        uint256 burnActorBalanceAfter = registry.BURN_ACTOR().balance;
        assertEq(burnActorBalanceAfter - burnActorBalanceBefore, REGISTRATION_FEE, "Fee should be burned");
    }

    function testCannotRegisterTwice() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // First registration
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to register again
        vm.prank(provider1);
        vm.expectRevert("Address already registered");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );
    }

    function testRegisterMultipleProviders() public {
        // Provider 1 capabilities
        string[] memory capKeys1 = new string[](2);
        capKeys1[0] = "region";
        capKeys1[1] = "performance";

        string[] memory capValues1 = new string[](2);
        capValues1[0] = "US-EAST";
        capValues1[1] = "high";

        // Register provider 1
        vm.prank(provider1);
        uint256 id1 = registry.registerProvider{value: REGISTRATION_FEE}(
            "Provider 1 description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys1,
            capValues1
        );

        // Provider 2 capabilities
        string[] memory capKeys2 = new string[](3);
        capKeys2[0] = "region";
        capKeys2[1] = "storage";
        capKeys2[2] = "availability";

        string[] memory capValues2 = new string[](3);
        capValues2[0] = "ASIA-PAC";
        capValues2[1] = "100TB";
        capValues2[2] = "99.999%";

        // Register provider 2
        ServiceProviderRegistry.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);

        vm.prank(provider2);
        uint256 id2 = registry.registerProvider{value: REGISTRATION_FEE}(
            "Provider 2 description", ServiceProviderRegistry.ProductType.PDP, encodedPDPData2, capKeys2, capValues2
        );

        // Verify IDs are sequential
        assertEq(id1, 1, "First provider should have ID 1");
        assertEq(id2, 2, "Second provider should have ID 2");
        assertEq(registry.getProviderCount(), 2, "Provider count should be 2");

        // Verify both are in active list
        uint256[] memory activeProviders = registry.getAllActiveProviders();
        assertEq(activeProviders.length, 2, "Should have 2 active providers");
        assertEq(activeProviders[0], 1, "First active provider should be ID 1");
        assertEq(activeProviders[1], 2, "Second active provider should be ID 2");

        // Verify provider 1 capabilities
        (, string[] memory keys1, string[] memory values1,) = registry.getPDPService(1);
        assertEq(keys1.length, 2, "Provider 1 should have 2 capability keys");
        assertEq(keys1[0], "region", "Provider 1 first key should be region");
        assertEq(values1[0], "US-EAST", "Provider 1 first value should be US-EAST");
        assertEq(keys1[1], "performance", "Provider 1 second key should be performance");
        assertEq(values1[1], "high", "Provider 1 second value should be high");

        // Verify provider 2 capabilities
        (, string[] memory keys2, string[] memory values2,) = registry.getPDPService(2);
        assertEq(keys2.length, 3, "Provider 2 should have 3 capability keys");
        assertEq(keys2[0], "region", "Provider 2 first key should be region");
        assertEq(values2[0], "ASIA-PAC", "Provider 2 first value should be ASIA-PAC");
        assertEq(keys2[1], "storage", "Provider 2 second key should be storage");
        assertEq(values2[1], "100TB", "Provider 2 second value should be 100TB");
        assertEq(keys2[2], "availability", "Provider 2 third key should be availability");
        assertEq(values2[2], "99.999%", "Provider 2 third value should be 99.999%");
    }

    function testRegisterWithInsufficientFee() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Try to register with less than 1 FIL
        vm.prank(provider1);
        vm.expectRevert("Incorrect fee amount");
        registry.registerProvider{value: 0.5 ether}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try with 0 fee
        vm.prank(provider1);
        vm.expectRevert("Incorrect fee amount");
        registry.registerProvider{value: 0}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );
    }

    function testRegisterWithExcessFee() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Try to register with 2 FIL (1 FIL extra) - should fail
        vm.prank(provider1);
        vm.expectRevert("Incorrect fee amount");
        registry.registerProvider{value: 2 ether}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Verify provider was not registered
        assertEq(registry.getProviderByAddress(provider1), 0, "Provider should not be registered");
    }

    function testRegisterWithInvalidData() public {
        // Test empty service URL
        ServiceProviderRegistry.PDPOffering memory invalidPDP = defaultPDPData;
        invalidPDP.serviceURL = "";
        bytes memory encodedInvalidPDP = abi.encode(invalidPDP);
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        vm.expectRevert("Service URL cannot be empty");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedInvalidPDP,
            emptyKeys,
            emptyValues
        );

        // Test service URL too long
        string memory longURL = new string(257);
        invalidPDP.serviceURL = longURL;
        encodedInvalidPDP = abi.encode(invalidPDP);
        vm.prank(provider1);
        vm.expectRevert("Service URL too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedInvalidPDP,
            emptyKeys,
            emptyValues
        );

        // Test invalid PDP data - min piece size 0
        invalidPDP = defaultPDPData;
        invalidPDP.minPieceSizeInBytes = 0;
        encodedInvalidPDP = abi.encode(invalidPDP);
        vm.prank(provider1);
        vm.expectRevert("Min piece size must be greater than 0");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedInvalidPDP,
            emptyKeys,
            emptyValues
        );

        // Test invalid PDP data - max < min
        invalidPDP.minPieceSizeInBytes = 1024;
        invalidPDP.maxPieceSizeInBytes = 512;
        encodedInvalidPDP = abi.encode(invalidPDP);
        vm.prank(provider1);
        vm.expectRevert("Max piece size must be >= min piece size");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedInvalidPDP,
            emptyKeys,
            emptyValues
        );
    }

    // ========== Update Tests ==========

    function testUpdateProduct() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Update PDP service using new updateProduct function
        vm.startPrank(provider1);

        vm.expectEmit(true, true, false, true);
        emit ServiceUpdated(1, ServiceProviderRegistry.ProductType.PDP, block.number);

        registry.updateProduct(ServiceProviderRegistry.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues);

        vm.stopPrank();

        // Verify update
        (
            ServiceProviderRegistry.PDPOffering memory pdpData,
            string[] memory keys,
            string[] memory values,
            bool isActive
        ) = registry.getPDPService(1);
        assertEq(pdpData.serviceURL, UPDATED_SERVICE_URL, "Service URL should be updated");
        assertEq(pdpData.minPieceSizeInBytes, updatedPDPData.minPieceSizeInBytes, "Min piece size should be updated");
        assertEq(pdpData.maxPieceSizeInBytes, updatedPDPData.maxPieceSizeInBytes, "Max piece size should be updated");
        assertEq(pdpData.ipniPiece, updatedPDPData.ipniPiece, "IPNI piece should be updated");
        assertEq(pdpData.ipniIpfs, updatedPDPData.ipniIpfs, "IPNI IPFS should be updated");
        assertEq(
            pdpData.storagePricePerTibPerMonth,
            updatedPDPData.storagePricePerTibPerMonth,
            "Storage price should be updated"
        );
        assertTrue(isActive, "PDP service should still be active");
    }

    function testUpdatePDPService() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Update PDP service using legacy updatePDPService function
        vm.startPrank(provider1);

        vm.expectEmit(true, true, false, true);
        emit ServiceUpdated(1, ServiceProviderRegistry.ProductType.PDP, block.number);

        registry.updatePDPService(updatedPDPData);

        vm.stopPrank();

        // Verify update
        (
            ServiceProviderRegistry.PDPOffering memory pdpData,
            string[] memory keys,
            string[] memory values,
            bool isActive
        ) = registry.getPDPService(1);
        assertEq(pdpData.serviceURL, UPDATED_SERVICE_URL, "Service URL should be updated");
        assertTrue(isActive, "PDP service should still be active");
    }

    function testOnlyOwnerCanUpdate() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to update as non-owner
        vm.prank(provider2);
        vm.expectRevert("Provider not registered");
        registry.updateProduct(ServiceProviderRegistry.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues);
    }

    function testCannotUpdateRemovedProvider() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register and remove provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider1);
        registry.removeProvider();

        // Try to update
        vm.prank(provider1);
        vm.expectRevert("Provider not registered");
        registry.updateProduct(ServiceProviderRegistry.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues);
    }

    // ========== Ownership Transfer Tests ==========

    function testTransferProviderOwnership() public {
        // Register with capabilities
        string[] memory capKeys = new string[](3);
        capKeys[0] = "tier";
        capKeys[1] = "backup";
        capKeys[2] = "encryption";

        string[] memory capValues = new string[](3);
        capValues[0] = "premium";
        capValues[1] = "daily";
        capValues[2] = "AES-256";

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        // Verify capabilities before transfer
        (, string[] memory keysBefore, string[] memory valuesBefore,) = registry.getPDPService(1);
        assertEq(keysBefore.length, 3, "Should have 3 capability keys before transfer");
        assertEq(keysBefore[0], "tier", "First key should be tier");
        assertEq(valuesBefore[0], "premium", "First value should be premium");

        // Transfer ownership
        vm.startPrank(provider1);

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(1, provider1, provider2, block.number);

        registry.transferProviderOwnership(provider2);

        vm.stopPrank();

        // Verify transfer
        ServiceProviderRegistry.ServiceProviderInfo memory info = registry.getProvider(1);
        assertEq(info.owner, provider2, "Owner should be updated");
        assertEq(registry.getProviderByAddress(provider2), 1, "New owner lookup should work");
        assertEq(registry.getProviderByAddress(provider1), 0, "Old owner lookup should return 0");
        assertTrue(registry.isRegisteredProvider(provider2), "New owner should be registered");
        assertFalse(registry.isRegisteredProvider(provider1), "Old owner should not be registered");

        // Verify capabilities persist after transfer
        (, string[] memory keysAfter, string[] memory valuesAfter,) = registry.getPDPService(1);
        assertEq(keysAfter.length, 3, "Should still have 3 capability keys after transfer");
        assertEq(keysAfter[0], "tier", "First key should still be tier");
        assertEq(valuesAfter[0], "premium", "First value should still be premium");
        assertEq(keysAfter[1], "backup", "Second key should still be backup");
        assertEq(valuesAfter[1], "daily", "Second value should still be daily");
        assertEq(keysAfter[2], "encryption", "Third key should still be encryption");
        assertEq(valuesAfter[2], "AES-256", "Third value should still be AES-256");

        // Verify new owner can update with new capabilities
        string[] memory newCapKeys = new string[](2);
        newCapKeys[0] = "support";
        newCapKeys[1] = "sla";

        string[] memory newCapValues = new string[](2);
        newCapValues[0] = "24/7";
        newCapValues[1] = "99.9%";

        vm.prank(provider2);
        registry.updateProduct(ServiceProviderRegistry.ProductType.PDP, encodedUpdatedPDPData, newCapKeys, newCapValues);

        // Verify capabilities were updated
        (, string[] memory updatedKeys, string[] memory updatedValues,) = registry.getPDPService(1);
        assertEq(updatedKeys.length, 2, "Should have 2 capability keys after update");
        assertEq(updatedKeys[0], "support", "First updated key should be support");
        assertEq(updatedValues[0], "24/7", "First updated value should be 24/7");

        // Verify old owner cannot update
        vm.prank(provider1);
        vm.expectRevert("Provider not registered");
        registry.updatePDPService(defaultPDPData);
    }

    function testCannotTransferToZeroAddress() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider1);
        vm.expectRevert("New owner cannot be zero address");
        registry.transferProviderOwnership(address(0));
    }

    function testCannotTransferToExistingProvider() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register two providers
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistry.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedPDPData2,
            emptyKeys,
            emptyValues
        );

        // Try to transfer to existing provider
        vm.prank(provider1);
        vm.expectRevert("New owner already has a provider");
        registry.transferProviderOwnership(provider2);
    }

    function testOnlyOwnerCanTransfer() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider2);
        vm.expectRevert("Provider not registered");
        registry.transferProviderOwnership(provider3);
    }

    // ========== Removal Tests ==========

    function testRemoveProvider() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Remove provider
        vm.startPrank(provider1);

        vm.expectEmit(true, true, false, true);
        emit ProviderRemoved(1, block.number);

        registry.removeProvider();

        vm.stopPrank();

        // Verify removal
        assertFalse(registry.isProviderActive(1), "Provider should be inactive");
        assertFalse(registry.isRegisteredProvider(provider1), "Provider should not be registered");
        assertEq(registry.getProviderByAddress(provider1), 0, "Address lookup should return 0");

        // Verify provider info still exists (soft delete)
        ServiceProviderRegistry.ServiceProviderInfo memory info = registry.getProvider(1);
        assertFalse(info.isActive, "Provider should be marked inactive");
        assertEq(info.owner, provider1, "Owner should still be recorded");

        // Verify PDP service is inactive
        (,,, bool isActive) = registry.getPDPService(1);
        assertFalse(isActive, "PDP service should be inactive");

        // Verify not in active list
        uint256[] memory activeProviders = registry.getAllActiveProviders();
        assertEq(activeProviders.length, 0, "Should have no active providers");
    }

    function testCannotRemoveAlreadyRemoved() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider1);
        registry.removeProvider();

        vm.prank(provider1);
        vm.expectRevert("Provider not registered");
        registry.removeProvider();
    }

    function testOnlyOwnerCanRemove() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider2);
        vm.expectRevert("Provider not registered");
        registry.removeProvider();
    }

    function testCanReregisterAfterRemoval() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register, remove, then register again
        vm.prank(provider1);
        uint256 id1 = registry.registerProvider{value: REGISTRATION_FEE}(
            "Provider 1 description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider1);
        registry.removeProvider();

        vm.prank(provider1);
        uint256 id2 = registry.registerProvider{value: REGISTRATION_FEE}(
            "Provider 2 description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedUpdatedPDPData,
            emptyKeys,
            emptyValues
        );

        // Should get new ID
        assertEq(id1, 1, "First registration should be ID 1");
        assertEq(id2, 2, "Second registration should be ID 2");
        assertTrue(registry.isProviderActive(2), "New registration should be active");
        assertFalse(registry.isProviderActive(1), "Old registration should be inactive");
    }

    // ========== Multi-Product Tests ==========

    function testGetProvidersByProductType() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register 3 providers with PDP
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistry.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedPDPData2,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistry.PDPOffering memory pdpData3 = defaultPDPData;
        pdpData3.serviceURL = "https://provider3.example.com";
        bytes memory encodedPDPData3 = abi.encode(pdpData3);
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedPDPData3,
            emptyKeys,
            emptyValues
        );

        // Get providers by product type
        uint256[] memory providers = registry.getProvidersByProductType(ServiceProviderRegistry.ProductType.PDP);
        assertEq(providers.length, 3, "Should have 3 providers with PDP");
        assertEq(providers[0], 1, "First provider should be ID 1");
        assertEq(providers[1], 2, "Second provider should be ID 2");
        assertEq(providers[2], 3, "Third provider should be ID 3");
    }

    function testGetActiveProvidersByProductType() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register 3 providers with PDP
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistry.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedPDPData2,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistry.PDPOffering memory pdpData3 = defaultPDPData;
        pdpData3.serviceURL = "https://provider3.example.com";
        bytes memory encodedPDPData3 = abi.encode(pdpData3);
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedPDPData3,
            emptyKeys,
            emptyValues
        );

        // Remove provider 2
        vm.prank(provider2);
        registry.removeProvider();

        // Get active providers by product type
        uint256[] memory activeProviders =
            registry.getActiveProvidersByProductType(ServiceProviderRegistry.ProductType.PDP);
        assertEq(activeProviders.length, 2, "Should have 2 active providers with PDP");
        assertEq(activeProviders[0], 1, "First active should be ID 1");
        assertEq(activeProviders[1], 3, "Second active should be ID 3");
    }

    function testProviderHasProduct() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        assertTrue(
            registry.providerHasProduct(1, ServiceProviderRegistry.ProductType.PDP), "Provider should have PDP product"
        );
    }

    function testGetProduct() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        (bytes memory productData, string[] memory keys, string[] memory values, bool isActive) =
            registry.getProduct(1, ServiceProviderRegistry.ProductType.PDP);
        assertTrue(productData.length > 0, "Product data should exist");
        assertTrue(isActive, "Product should be active");

        // Decode and verify
        ServiceProviderRegistry.PDPOffering memory decoded =
            abi.decode(productData, (ServiceProviderRegistry.PDPOffering));
        assertEq(decoded.serviceURL, SERVICE_URL, "Service URL should match");
    }

    function testCannotAddProductTwice() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to add PDP again
        vm.prank(provider1);
        vm.expectRevert("Product already exists for this provider");
        registry.addProduct(ServiceProviderRegistry.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues);
    }

    function testCannotRemoveLastProduct() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to remove the only product
        vm.prank(provider1);
        vm.expectRevert("Cannot remove last product");
        registry.removeProduct(ServiceProviderRegistry.ProductType.PDP);
    }

    // ========== Getter Tests ==========

    function testGetAllActiveProviders() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register 3 providers
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistry.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedPDPData2,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistry.PDPOffering memory pdpData3 = defaultPDPData;
        pdpData3.serviceURL = "https://provider3.example.com";
        bytes memory encodedPDPData3 = abi.encode(pdpData3);
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedPDPData3,
            emptyKeys,
            emptyValues
        );

        // Remove provider 2
        vm.prank(provider2);
        registry.removeProvider();

        // Get active providers
        uint256[] memory activeProviders = registry.getAllActiveProviders();
        assertEq(activeProviders.length, 2, "Should have 2 active providers");
        assertEq(activeProviders[0], 1, "First active should be ID 1");
        assertEq(activeProviders[1], 3, "Second active should be ID 3");
    }

    function testGetProviderCount() public {
        assertEq(registry.getProviderCount(), 0, "Initial count should be 0");

        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );
        assertEq(registry.getProviderCount(), 1, "Count should be 1");

        ServiceProviderRegistry.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedPDPData2,
            emptyKeys,
            emptyValues
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
        registry.getPDPService(1);

        vm.expectRevert("Provider does not exist");
        registry.isProviderActive(1);
    }

    // ========== Edge Cases ==========

    function testMultipleUpdatesInSameBlock() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.startPrank(provider1);

        // Expect the update event with timestamp
        vm.expectEmit(true, true, true, true);
        emit ServiceUpdated(1, ServiceProviderRegistry.ProductType.PDP, block.number);

        registry.updateProduct(ServiceProviderRegistry.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues);
        vm.stopPrank();

        // Verify the product was updated (check the actual data)
        (ServiceProviderRegistry.PDPOffering memory pdpData,,,) = registry.getPDPService(1);
        assertEq(pdpData.serviceURL, UPDATED_SERVICE_URL, "Service URL should be updated");
    }

    // ========== Event Timestamp Tests ==========

    function testEventTimestampsEmittedCorrectly() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Test ProviderRegistered event
        vm.prank(provider1);
        vm.expectEmit(true, true, true, true);
        emit ProviderRegistered(1, provider1, block.number);
        vm.expectEmit(true, true, true, true);
        emit ServiceUpdated(1, ServiceProviderRegistry.ProductType.PDP, block.number);

        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Test ServiceUpdated event
        vm.prank(provider1);
        vm.expectEmit(true, true, true, true);
        emit ServiceUpdated(1, ServiceProviderRegistry.ProductType.PDP, block.number);
        registry.updateProduct(ServiceProviderRegistry.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues);

        // Test OwnershipTransferred event
        vm.prank(provider1);
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(1, provider1, provider2, block.number);
        registry.transferProviderOwnership(provider2);

        // Test ProviderRemoved event
        vm.prank(provider2);
        vm.expectEmit(true, true, false, true);
        emit ProviderRemoved(1, block.number);
        registry.removeProvider();
    }

    // ========== Capability K/V Tests ==========

    function testRegisterWithCapabilities() public {
        // Create capability arrays
        string[] memory capKeys = new string[](3);
        capKeys[0] = "region";
        capKeys[1] = "bandwidth";
        capKeys[2] = "encryption";

        string[] memory capValues = new string[](3);
        capValues[0] = "us-west-2";
        capValues[1] = "10Gbps";
        capValues[2] = "AES256";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        // Get the product and verify capabilities
        (bytes memory productData, string[] memory returnedKeys, string[] memory returnedValues, bool isActive) =
            registry.getProduct(providerId, ServiceProviderRegistry.ProductType.PDP);

        assertEq(returnedKeys.length, 3, "Should have 3 capability keys");
        assertEq(returnedValues.length, 3, "Should have 3 capability values");
        assertEq(returnedKeys[0], "region", "First key should be region");
        assertEq(returnedValues[0], "us-west-2", "First value should be us-west-2");
        assertEq(returnedKeys[1], "bandwidth", "Second key should be bandwidth");
        assertEq(returnedValues[1], "10Gbps", "Second value should be 10Gbps");
        assertEq(returnedKeys[2], "encryption", "Third key should be encryption");
        assertEq(returnedValues[2], "AES256", "Third value should be AES256");
        assertTrue(isActive, "Product should be active");
    }

    function testUpdateWithCapabilities() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register with empty capabilities
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Update with capabilities
        string[] memory capKeys = new string[](2);
        capKeys[0] = "support";
        capKeys[1] = "sla";

        string[] memory capValues = new string[](2);
        capValues[0] = "24/7";
        capValues[1] = "99.99%";

        vm.prank(provider1);
        registry.updateProduct(ServiceProviderRegistry.ProductType.PDP, encodedUpdatedPDPData, capKeys, capValues);

        // Verify capabilities updated
        (, string[] memory returnedKeys, string[] memory returnedValues,) =
            registry.getProduct(1, ServiceProviderRegistry.ProductType.PDP);

        assertEq(returnedKeys.length, 2, "Should have 2 capability keys");
        assertEq(returnedKeys[0], "support", "First key should be support");
        assertEq(returnedValues[0], "24/7", "First value should be 24/7");
    }

    function testInvalidCapabilityKeyTooLong() public {
        string[] memory capKeys = new string[](1);
        capKeys[0] = "thisKeyIsTooLong"; // 16 chars, max is MAX_CAPABILITY_KEY_LENGTH (12)

        string[] memory capValues = new string[](1);
        capValues[0] = "value";

        vm.prank(provider1);
        vm.expectRevert("Capability key exceeds 12 characters");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );
    }

    function testInvalidCapabilityValueTooLong() public {
        string[] memory capKeys = new string[](1);
        capKeys[0] = "key";

        string[] memory capValues = new string[](1);
        capValues[0] =
            "This value is way too long and exceeds the maximum of 64 characters allowed for capability values"; // > MAX_CAPABILITY_VALUE_LENGTH (64) chars

        vm.prank(provider1);
        vm.expectRevert("Capability value exceeds 64 characters");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );
    }

    function testInvalidCapabilityArrayLengthMismatch() public {
        string[] memory capKeys = new string[](2);
        capKeys[0] = "key1";
        capKeys[1] = "key2";

        string[] memory capValues = new string[](1);
        capValues[0] = "value1";

        vm.prank(provider1);
        vm.expectRevert("Keys and values arrays must have same length");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );
    }

    function testDescriptionTooLong() public {
        // Create a description that's too long (> 256 chars)
        string memory longDescription =
            "This is a very long description that exceeds the maximum allowed length of 256 characters. It just keeps going and going and going and going and going and going and going and going and going and going and going and going and going and going and going and characters limit!";

        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        vm.expectRevert("Description too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            longDescription, ServiceProviderRegistry.ProductType.PDP, encodedDefaultPDPData, emptyKeys, emptyValues
        );
    }

    function testEmptyCapabilityKey() public {
        string[] memory capKeys = new string[](1);
        capKeys[0] = "";

        string[] memory capValues = new string[](1);
        capValues[0] = "value";

        vm.prank(provider1);
        vm.expectRevert("Capability key cannot be empty");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Test provider description",
            ServiceProviderRegistry.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );
    }
}
