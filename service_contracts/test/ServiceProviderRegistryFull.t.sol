// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ServiceProviderRegistry.sol";
import "../src/ServiceProviderRegistryStorage.sol";
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

    uint256 constant REGISTRATION_FEE = 5 ether; // 5 FIL in attoFIL

    ServiceProviderRegistryStorage.PDPOffering public defaultPDPData;
    ServiceProviderRegistryStorage.PDPOffering public updatedPDPData;
    bytes public encodedDefaultPDPData;
    bytes public encodedUpdatedPDPData;

    event ProviderRegistered(uint256 indexed providerId, address indexed beneficiary, uint256 registeredAt);
    event ProductUpdated(
        uint256 indexed providerId,
        ServiceProviderRegistryStorage.ProductType indexed productType,
        uint256 updatedAt,
        string serviceUrl,
        address beneficiary,
        string[] capabilityKeys,
        string[] capabilityValues
    );
    event ProductAdded(
        uint256 indexed providerId,
        ServiceProviderRegistryStorage.ProductType indexed productType,
        uint256 addedAt,
        string serviceUrl,
        address beneficiary,
        string[] capabilityKeys,
        string[] capabilityValues
    );
    event ProductRemoved(
        uint256 indexed providerId, ServiceProviderRegistryStorage.ProductType indexed productType, uint256 removedAt
    );
    event BeneficiaryTransferred(
        uint256 indexed providerId,
        address indexed previousBeneficiary,
        address indexed newBeneficiary,
        uint256 transferredAt
    );
    event ProviderRemoved(uint256 indexed providerId, uint256 removedAt);
    event ProviderInfoUpdated(uint256 indexed providerId, uint256 updatedAt);

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
        defaultPDPData = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: SERVICE_URL,
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerMonth: 1000000000000000000, // 1 FIL per TiB per month
            minProvingPeriodInEpochs: 2880, // 1 day in epochs (30 second blocks)
            location: "North America",
            paymentTokenAddress: address(0) // Payment in FIL
        });

        updatedPDPData = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: UPDATED_SERVICE_URL,
            minPieceSizeInBytes: 512,
            maxPieceSizeInBytes: 2 * 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: true,
            storagePricePerTibPerMonth: 2000000000000000000, // 2 FIL per TiB per month
            minProvingPeriodInEpochs: 1440, // 12 hours in epochs
            location: "Europe",
            paymentTokenAddress: address(0) // Payment in FIL
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
        assertEq(registry.getRegistrationFee(), 5 ether, "Registration fee should be 5 FIL");
        assertEq(registry.REGISTRATION_FEE(), 5 ether, "Registration fee constant should be 5 FIL");
        assertEq(registry.getProviderCount(), 0, "Provider count should be 0");

        // Verify capability constants
        assertEq(registry.MAX_CAPABILITY_KEY_LENGTH(), 32, "Max capability key length should be 32");
        assertEq(registry.MAX_CAPABILITY_VALUE_LENGTH(), 128, "Max capability value length should be 128");
        assertEq(registry.MAX_CAPABILITIES(), 10, "Max capabilities should be 10");
    }

    // ========== Registration Tests ==========

    function testRegisterProvider() public {
        // Check burn actor balance before
        uint256 burnActorBalanceBefore = registry.BURN_ACTOR().balance;

        vm.startPrank(provider1);

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit ProviderRegistered(1, provider1, block.number);

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

        vm.expectEmit(true, true, false, true);
        emit ProductAdded(
            1, ServiceProviderRegistryStorage.ProductType.PDP, block.number, SERVICE_URL, provider1, capKeys, capValues
        );

        // Register provider
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        vm.stopPrank();

        // Verify registration
        assertEq(providerId, 1, "Provider ID should be 1");
        ServiceProviderRegistryStorage.ServiceProviderInfo memory providerInfo =
            registry.getProviderByAddress(provider1);
        assertEq(providerInfo.beneficiary, provider1, "Provider address should match");
        assertTrue(providerInfo.isActive, "Provider should be active");
        assertTrue(registry.isRegisteredProvider(provider1), "Provider should be registered");
        assertTrue(registry.isProviderActive(1), "Provider should be active");

        // Verify provider info
        ServiceProviderRegistryStorage.ServiceProviderInfo memory info = registry.getProvider(1);
        assertEq(info.beneficiary, provider1, "Beneficiary should be provider1");
        assertEq(info.name, "", "Name should be empty");
        assertEq(info.description, "Test provider description", "Description should match");
        assertTrue(info.isActive, "Provider should be active");

        // Verify PDP service using getPDPService (including capabilities)
        (ServiceProviderRegistryStorage.PDPOffering memory pdpData, string[] memory keys, bool isActive) =
            registry.getPDPService(1);
        assertEq(pdpData.serviceURL, SERVICE_URL, "Service URL should match");
        assertEq(pdpData.minPieceSizeInBytes, defaultPDPData.minPieceSizeInBytes, "Min piece size should match");
        assertEq(pdpData.maxPieceSizeInBytes, defaultPDPData.maxPieceSizeInBytes, "Max piece size should match");
        assertEq(pdpData.ipniPiece, defaultPDPData.ipniPiece, "IPNI piece should match");
        assertEq(pdpData.ipniIpfs, defaultPDPData.ipniIpfs, "IPNI IPFS should match");
        assertEq(
            pdpData.storagePricePerTibPerMonth, defaultPDPData.storagePricePerTibPerMonth, "Storage price should match"
        );
        assertEq(
            pdpData.minProvingPeriodInEpochs, defaultPDPData.minProvingPeriodInEpochs, "Min proving period should match"
        );
        assertEq(pdpData.location, defaultPDPData.location, "Location should match");
        assertTrue(isActive, "PDP service should be active");

        // Verify capabilities
        assertEq(keys.length, 4, "Should have 4 capability keys");
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

        (bool[] memory exists, string[] memory values) =
            registry.getProductCapabilities(1, ServiceProviderRegistryStorage.ProductType.PDP, queryKeys);
        assertTrue(exists[0], "First key should exist");
        assertEq(values[0], "EU-WEST", "First value should be EU-WEST");
        assertTrue(exists[1], "Second key should exist");
        assertEq(values[1], "3x", "Second value should be 3x");
        assertTrue(exists[2], "Third key should exist");
        assertEq(values[2], "low", "Third value should be low");
        assertTrue(exists[3], "Fourth key should exist");
        assertEq(values[3], "ISO27001", "Fourth value should be ISO27001");

        // Also verify using getProduct
        (bytes memory productData, string[] memory productKeys, bool productActive) =
            registry.getProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        assertTrue(productActive, "Product should be active");
        assertEq(productKeys.length, 4, "Product should have 4 capability keys");
        assertEq(productKeys[0], "datacenter", "Product first key should be datacenter");

        // Verify value using direct mapping access
        string memory datacenterValue =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "datacenter");
        assertEq(datacenterValue, "EU-WEST", "Product first value should be EU-WEST");

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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to register again
        vm.prank(provider1);
        vm.expectRevert("Address already registered");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Provider 1 description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
        ServiceProviderRegistryStorage.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);

        vm.prank(provider2);
        uint256 id2 = registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Provider 2 description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedPDPData2,
            capKeys2,
            capValues2
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
        (, string[] memory keys1,) = registry.getPDPService(1);
        assertEq(keys1.length, 2, "Provider 1 should have 2 capability keys");
        assertEq(keys1[0], "region", "Provider 1 first key should be region");
        assertEq(keys1[1], "performance", "Provider 1 second key should be performance");

        // Query values for provider 1
        (bool[] memory exists1, string[] memory values1) =
            registry.getProductCapabilities(1, ServiceProviderRegistryStorage.ProductType.PDP, keys1);
        assertTrue(exists1[0] && exists1[1], "All keys should exist for provider 1");
        assertEq(values1[0], "US-EAST", "Provider 1 first value should be US-EAST");
        assertEq(values1[1], "high", "Provider 1 second value should be high");

        // Verify provider 2 capabilities
        (, string[] memory keys2,) = registry.getPDPService(2);
        assertEq(keys2.length, 3, "Provider 2 should have 3 capability keys");
        assertEq(keys2[0], "region", "Provider 2 first key should be region");
        assertEq(keys2[1], "storage", "Provider 2 second key should be storage");
        assertEq(keys2[2], "availability", "Provider 2 third key should be availability");

        // Query values for provider 2
        (bool[] memory exists2, string[] memory values2) =
            registry.getProductCapabilities(2, ServiceProviderRegistryStorage.ProductType.PDP, keys2);
        assertTrue(exists2[0] && exists2[1], "All keys should exist for provider 2");
        assertEq(values2[0], "ASIA-PAC", "Provider 2 first value should be ASIA-PAC");
        assertEq(values2[1], "100TB", "Provider 2 second value should be 100TB");
        assertEq(values2[2], "99.999%", "Provider 2 third value should be 99.999%");
    }

    function testRegisterWithInsufficientFee() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Try to register with less than 5 FIL
        vm.prank(provider1);
        vm.expectRevert("Incorrect fee amount");
        registry.registerProvider{value: 1 ether}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try with 0 fee
        vm.prank(provider1);
        vm.expectRevert("Incorrect fee amount");
        registry.registerProvider{value: 0}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );
    }

    function testRegisterWithExcessFee() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Try to register with 2 FIL (less than 5 FIL) - should fail
        vm.prank(provider1);
        vm.expectRevert("Incorrect fee amount");
        registry.registerProvider{value: 2 ether}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Verify provider was not registered
        ServiceProviderRegistryStorage.ServiceProviderInfo memory notRegisteredInfo =
            registry.getProviderByAddress(provider1);
        assertEq(notRegisteredInfo.beneficiary, address(0), "Provider should not be registered");
    }

    function testRegisterWithInvalidData() public {
        // Test empty service URL
        ServiceProviderRegistryStorage.PDPOffering memory invalidPDP = defaultPDPData;
        invalidPDP.serviceURL = "";
        bytes memory encodedInvalidPDP = abi.encode(invalidPDP);
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        vm.expectRevert("Service URL cannot be empty");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedInvalidPDP,
            emptyKeys,
            emptyValues
        );

        // Test invalid PDP data - min proving period 0
        invalidPDP = defaultPDPData;
        invalidPDP.minProvingPeriodInEpochs = 0;
        encodedInvalidPDP = abi.encode(invalidPDP);
        vm.prank(provider1);
        vm.expectRevert("Min proving period must be greater than 0");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedInvalidPDP,
            emptyKeys,
            emptyValues
        );

        // Test invalid PDP data - empty location
        invalidPDP = defaultPDPData;
        invalidPDP.location = "";
        encodedInvalidPDP = abi.encode(invalidPDP);
        vm.prank(provider1);
        vm.expectRevert("Location cannot be empty");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedInvalidPDP,
            emptyKeys,
            emptyValues
        );

        // Test invalid PDP data - location too long
        invalidPDP = defaultPDPData;
        bytes memory longLocation = new bytes(129);
        for (uint256 i = 0; i < 129; i++) {
            longLocation[i] = "a";
        }
        invalidPDP.location = string(longLocation);
        encodedInvalidPDP = abi.encode(invalidPDP);
        vm.prank(provider1);
        vm.expectRevert("Location too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Update PDP service using new updateProduct function
        vm.startPrank(provider1);

        vm.expectEmit(true, true, false, true);
        emit ProductUpdated(
            1,
            ServiceProviderRegistryStorage.ProductType.PDP,
            block.number,
            UPDATED_SERVICE_URL,
            provider1,
            emptyKeys,
            emptyValues
        );

        registry.updateProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues
        );

        vm.stopPrank();

        // Verify update
        (ServiceProviderRegistryStorage.PDPOffering memory pdpData, string[] memory keys, bool isActive) =
            registry.getPDPService(1);
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
        assertEq(
            pdpData.minProvingPeriodInEpochs,
            updatedPDPData.minProvingPeriodInEpochs,
            "Min proving period should be updated"
        );
        assertEq(pdpData.location, updatedPDPData.location, "Location should be updated");
        assertTrue(isActive, "PDP service should still be active");
    }

    function testOnlyBeneficiaryCanUpdate() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to update as non-beneficiary
        vm.prank(provider2);
        vm.expectRevert("Provider not registered");
        registry.updateProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues
        );
    }

    function testCannotUpdateRemovedProvider() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register and remove provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider1);
        registry.removeProvider();

        // Try to update
        vm.prank(provider1);
        vm.expectRevert("Provider not registered");
        registry.updateProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues
        );
    }

    // ========== Beneficiary Transfer Tests ==========

    function testTransferProviderBeneficiary() public {
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        // Verify capabilities before transfer
        (, string[] memory keysBefore,) = registry.getPDPService(1);
        assertEq(keysBefore.length, 3, "Should have 3 capability keys before transfer");
        assertEq(keysBefore[0], "tier", "First key should be tier");

        // Verify value before transfer
        (bool tierExists, string memory tierBefore) =
            registry.getProductCapability(1, ServiceProviderRegistryStorage.ProductType.PDP, "tier");
        assertTrue(tierExists, "tier capability should exist");
        assertEq(tierBefore, "premium", "First value should be premium");

        // Transfer beneficiary
        vm.startPrank(provider1);

        vm.expectEmit(true, true, true, true);
        emit BeneficiaryTransferred(1, provider1, provider2, block.number);

        registry.transferProviderBeneficiary(provider2);

        vm.stopPrank();

        // Verify transfer
        ServiceProviderRegistryStorage.ServiceProviderInfo memory info = registry.getProvider(1);
        assertEq(info.beneficiary, provider2, "Beneficiary should be updated");
        ServiceProviderRegistryStorage.ServiceProviderInfo memory newBeneficiaryInfo =
            registry.getProviderByAddress(provider2);
        assertEq(newBeneficiaryInfo.beneficiary, provider2, "New beneficiary lookup should work");
        ServiceProviderRegistryStorage.ServiceProviderInfo memory oldBeneficiaryInfo =
            registry.getProviderByAddress(provider1);
        assertEq(oldBeneficiaryInfo.beneficiary, address(0), "Old beneficiary lookup should return empty");
        assertTrue(registry.isRegisteredProvider(provider2), "New beneficiary should be registered");
        assertFalse(registry.isRegisteredProvider(provider1), "Old beneficiary should not be registered");

        // Verify capabilities persist after transfer
        (, string[] memory keysAfter,) = registry.getPDPService(1);
        assertEq(keysAfter.length, 3, "Should still have 3 capability keys after transfer");
        assertEq(keysAfter[0], "tier", "First key should still be tier");
        assertEq(keysAfter[1], "backup", "Second key should still be backup");
        assertEq(keysAfter[2], "encryption", "Third key should still be encryption");

        // Verify values persist after transfer
        (bool[] memory existsAfter, string[] memory valuesAfter) =
            registry.getProductCapabilities(1, ServiceProviderRegistryStorage.ProductType.PDP, keysAfter);
        assertTrue(existsAfter[0] && existsAfter[1], "All keys should still exist after transfer");
        assertEq(valuesAfter[0], "premium", "First value should still be premium");
        assertEq(valuesAfter[1], "daily", "Second value should still be daily");
        assertEq(valuesAfter[2], "AES-256", "Third value should still be AES-256");

        // Verify new beneficiary can update with new capabilities
        string[] memory newCapKeys = new string[](2);
        newCapKeys[0] = "support";
        newCapKeys[1] = "sla";

        string[] memory newCapValues = new string[](2);
        newCapValues[0] = "24/7";
        newCapValues[1] = "99.9%";

        vm.prank(provider2);
        registry.updateProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, newCapKeys, newCapValues
        );

        // Verify capabilities were updated
        (, string[] memory updatedKeys,) = registry.getPDPService(1);
        assertEq(updatedKeys.length, 2, "Should have 2 capability keys after update");
        assertEq(updatedKeys[0], "support", "First updated key should be support");

        // Verify value was updated
        (bool supportExists, string memory supportValue) =
            registry.getProductCapability(1, ServiceProviderRegistryStorage.ProductType.PDP, "support");
        assertTrue(supportExists, "support capability should exist");
        assertEq(supportValue, "24/7", "First updated value should be 24/7");
    }

    function testCannotTransferToZeroAddress() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider1);
        vm.expectRevert("New beneficiary cannot be zero address");
        registry.transferProviderBeneficiary(address(0));
    }

    function testCannotTransferToExistingProvider() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register two providers
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistryStorage.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedPDPData2,
            emptyKeys,
            emptyValues
        );

        // Try to transfer to existing provider
        vm.prank(provider1);
        vm.expectRevert("New beneficiary already has a provider");
        registry.transferProviderBeneficiary(provider2);
    }

    function testOnlyBeneficiaryCanTransfer() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider2);
        vm.expectRevert("Provider not registered");
        registry.transferProviderBeneficiary(provider3);
    }

    // ========== Removal Tests ==========

    function testRemoveProvider() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
        ServiceProviderRegistryStorage.ServiceProviderInfo memory removedInfo = registry.getProviderByAddress(provider1);
        assertEq(removedInfo.beneficiary, address(0), "Address lookup should return empty");

        // Verify provider info still exists (soft delete)
        ServiceProviderRegistryStorage.ServiceProviderInfo memory info = registry.getProvider(1);
        assertFalse(info.isActive, "Provider should be marked inactive");
        assertEq(info.beneficiary, provider1, "Beneficiary should still be recorded");

        // Verify PDP service is inactive
        (,, bool isActive) = registry.getPDPService(1);
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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

    function testOnlyBeneficiaryCanRemove() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Provider 1 description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.prank(provider1);
        registry.removeProvider();

        vm.prank(provider1);
        uint256 id2 = registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Provider 2 description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistryStorage.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedPDPData2,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistryStorage.PDPOffering memory pdpData3 = defaultPDPData;
        pdpData3.serviceURL = "https://provider3.example.com";
        bytes memory encodedPDPData3 = abi.encode(pdpData3);
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedPDPData3,
            emptyKeys,
            emptyValues
        );

        // Get providers by product type with pagination
        ServiceProviderRegistryStorage.PaginatedProviders memory result =
            registry.getProvidersByProductType(ServiceProviderRegistryStorage.ProductType.PDP, 0, 10);
        assertEq(result.providers.length, 3, "Should have 3 providers with PDP");
        assertEq(result.providers[0].providerId, 1, "First provider should be ID 1");
        assertEq(result.providers[1].providerId, 2, "Second provider should be ID 2");
        assertEq(result.providers[2].providerId, 3, "Third provider should be ID 3");
        assertFalse(result.hasMore, "Should not have more results");
    }

    function testGetActiveProvidersByProductType() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register 3 providers with PDP
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistryStorage.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedPDPData2,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistryStorage.PDPOffering memory pdpData3 = defaultPDPData;
        pdpData3.serviceURL = "https://provider3.example.com";
        bytes memory encodedPDPData3 = abi.encode(pdpData3);
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedPDPData3,
            emptyKeys,
            emptyValues
        );

        // Remove provider 2
        vm.prank(provider2);
        registry.removeProvider();

        // Get active providers by product type with pagination
        ServiceProviderRegistryStorage.PaginatedProviders memory activeResult =
            registry.getActiveProvidersByProductType(ServiceProviderRegistryStorage.ProductType.PDP, 0, 10);
        assertEq(activeResult.providers.length, 2, "Should have 2 active providers with PDP");
        assertEq(activeResult.providers[0].providerId, 1, "First active should be ID 1");
        assertEq(activeResult.providers[1].providerId, 3, "Second active should be ID 3");
        assertFalse(activeResult.hasMore, "Should not have more results");
    }

    function testProviderHasProduct() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        assertTrue(
            registry.providerHasProduct(1, ServiceProviderRegistryStorage.ProductType.PDP),
            "Provider should have PDP product"
        );
    }

    function testGetProduct() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        (bytes memory productData, string[] memory keys, bool isActive) =
            registry.getProduct(1, ServiceProviderRegistryStorage.ProductType.PDP);
        assertTrue(productData.length > 0, "Product data should exist");
        assertTrue(isActive, "Product should be active");

        // Decode and verify
        ServiceProviderRegistryStorage.PDPOffering memory decoded =
            abi.decode(productData, (ServiceProviderRegistryStorage.PDPOffering));
        assertEq(decoded.serviceURL, SERVICE_URL, "Service URL should match");
    }

    function testCannotAddProductTwice() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to add PDP again
        vm.prank(provider1);
        vm.expectRevert("Product already exists for this provider");
        registry.addProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues
        );
    }

    function testCannotRemoveLastProduct() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to remove the only product
        vm.prank(provider1);
        vm.expectRevert("Cannot remove last product");
        registry.removeProduct(ServiceProviderRegistryStorage.ProductType.PDP);
    }

    // ========== Getter Tests ==========

    function testGetAllActiveProviders() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register 3 providers
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistryStorage.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedPDPData2,
            emptyKeys,
            emptyValues
        );

        ServiceProviderRegistryStorage.PDPOffering memory pdpData3 = defaultPDPData;
        pdpData3.serviceURL = "https://provider3.example.com";
        bytes memory encodedPDPData3 = abi.encode(pdpData3);
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );
        assertEq(registry.getProviderCount(), 1, "Count should be 1");

        ServiceProviderRegistryStorage.PDPOffering memory pdpData2 = defaultPDPData;
        pdpData2.serviceURL = SERVICE_URL_2;
        bytes memory encodedPDPData2 = abi.encode(pdpData2);
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        vm.startPrank(provider1);

        // Expect the update event with timestamp
        vm.expectEmit(true, true, true, true);
        emit ProductUpdated(
            1,
            ServiceProviderRegistryStorage.ProductType.PDP,
            block.number,
            UPDATED_SERVICE_URL,
            provider1,
            emptyKeys,
            emptyValues
        );

        registry.updateProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues
        );
        vm.stopPrank();

        // Verify the product was updated (check the actual data)
        (ServiceProviderRegistryStorage.PDPOffering memory pdpData,,) = registry.getPDPService(1);
        assertEq(pdpData.serviceURL, UPDATED_SERVICE_URL, "Service URL should be updated");
    }

    // ========== Provider Info Update Tests ==========

    function testUpdateProviderDescription() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Initial description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Verify initial description
        ServiceProviderRegistryStorage.ServiceProviderInfo memory info = registry.getProvider(1);
        assertEq(info.description, "Initial description", "Initial description should match");

        // Update description
        vm.prank(provider1);
        vm.expectEmit(true, true, false, true);
        emit ProviderInfoUpdated(1, block.number);
        registry.updateProviderInfo("Updated Name", "Updated description");

        // Verify updated description
        info = registry.getProvider(1);
        assertEq(info.description, "Updated description", "Description should be updated");
    }

    function testCannotUpdateProviderDescriptionIfNotBeneficiary() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Initial description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to update as non-beneficiary
        vm.prank(provider2);
        vm.expectRevert("Provider not registered");
        registry.updateProviderInfo("", "Unauthorized update");
    }

    function testCannotUpdateProviderDescriptionTooLong() public {
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Register provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Initial description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
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

        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        vm.expectRevert("Name too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            string(longName),
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );
    }

    function testNameTooLongOnUpdate() public {
        // Register provider first
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "Initial Name",
            "Initial description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
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
        // Empty capability arrays
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        // Test ProviderRegistered and ProductAdded events
        vm.prank(provider1);
        vm.expectEmit(true, true, true, true);
        emit ProviderRegistered(1, provider1, block.number);
        vm.expectEmit(true, true, true, true);
        emit ProductAdded(
            1,
            ServiceProviderRegistryStorage.ProductType.PDP,
            block.number,
            SERVICE_URL,
            provider1,
            emptyKeys,
            emptyValues
        );

        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Test ProductUpdated event
        vm.prank(provider1);
        vm.expectEmit(true, true, true, true);
        emit ProductUpdated(
            1,
            ServiceProviderRegistryStorage.ProductType.PDP,
            block.number,
            UPDATED_SERVICE_URL,
            provider1,
            emptyKeys,
            emptyValues
        );
        registry.updateProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, emptyKeys, emptyValues
        );

        // Test BeneficiaryTransferred event
        vm.prank(provider1);
        vm.expectEmit(true, true, true, true);
        emit BeneficiaryTransferred(1, provider1, provider2, block.number);
        registry.transferProviderBeneficiary(provider2);

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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        // Get the product and verify capabilities
        (bytes memory productData, string[] memory returnedKeys, bool isActive) =
            registry.getProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);

        assertEq(returnedKeys.length, 3, "Should have 3 capability keys");
        assertEq(returnedKeys[0], "region", "First key should be region");
        assertEq(returnedKeys[1], "bandwidth", "Second key should be bandwidth");
        assertEq(returnedKeys[2], "encryption", "Third key should be encryption");

        // Query values using new methods
        (bool[] memory existsReturned, string[] memory returnedValues) =
            registry.getProductCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, returnedKeys);
        assertTrue(existsReturned[0] && existsReturned[1] && existsReturned[2], "All keys should exist");
        assertEq(returnedValues[0], "us-west-2", "First value should be us-west-2");
        assertEq(returnedValues[1], "10Gbps", "Second value should be 10Gbps");
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
        registry.updateProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, capKeys, capValues
        );

        // Verify capabilities updated
        (, string[] memory returnedKeys,) = registry.getProduct(1, ServiceProviderRegistryStorage.ProductType.PDP);

        assertEq(returnedKeys.length, 2, "Should have 2 capability keys");
        assertEq(returnedKeys[0], "support", "First key should be support");

        // Verify value using new method
        (bool supExists, string memory supportVal) =
            registry.getProductCapability(1, ServiceProviderRegistryStorage.ProductType.PDP, "support");
        assertTrue(supExists, "support capability should exist");
        assertEq(supportVal, "24/7", "First value should be 24/7");
    }

    function testInvalidCapabilityKeyTooLong() public {
        string[] memory capKeys = new string[](1);
        capKeys[0] = "thisKeyIsWayTooLongAndExceedsLimit"; // 35 chars, max is MAX_CAPABILITY_KEY_LENGTH (32)

        string[] memory capValues = new string[](1);
        capValues[0] = "value";

        vm.prank(provider1);
        vm.expectRevert("Capability key too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "This value is way too long and exceeds the maximum allowed length. It is specifically designed to be longer than 128 characters to test the validation of capability values"; // > MAX_CAPABILITY_VALUE_LENGTH (128) chars

        vm.prank(provider1);
        vm.expectRevert("Capability value too long");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
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
            "",
            longDescription,
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
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
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );
    }

    function testTooManyCapabilities() public {
        // Create 11 capabilities (exceeds MAX_CAPABILITIES of 10)
        string[] memory capKeys = new string[](11);
        string[] memory capValues = new string[](11);

        for (uint256 i = 0; i < 11; i++) {
            capKeys[i] = string(abi.encodePacked("key", vm.toString(i)));
            capValues[i] = string(abi.encodePacked("value", vm.toString(i)));
        }

        vm.prank(provider1);
        vm.expectRevert("Too many capabilities");
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );
    }

    function testMaxCapabilitiesAllowed() public {
        // Create exactly 10 capabilities (should succeed)
        string[] memory capKeys = new string[](10);
        string[] memory capValues = new string[](10);

        for (uint256 i = 0; i < 10; i++) {
            capKeys[i] = string(abi.encodePacked("key", vm.toString(i)));
            capValues[i] = string(abi.encodePacked("value", vm.toString(i)));
        }

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        assertEq(providerId, 1, "Should register successfully with 10 capabilities");

        // Verify all 10 capabilities were stored
        (, string[] memory returnedKeys,) =
            registry.getProduct(providerId, ServiceProviderRegistryStorage.ProductType.PDP);
        assertEq(returnedKeys.length, 10, "Should have exactly 10 capability keys");
    }

    // ========== New Capability Query Methods Tests ==========

    function testGetProductCapability() public {
        // Register provider with capabilities
        string[] memory capKeys = new string[](3);
        capKeys[0] = "region";
        capKeys[1] = "tier";
        capKeys[2] = "storage";

        string[] memory capValues = new string[](3);
        capValues[0] = "us-west-2";
        capValues[1] = "premium";
        capValues[2] = "100TB";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        // Test single capability queries
        (bool regionExists, string memory region) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "region");
        assertTrue(regionExists, "region capability should exist");
        assertEq(region, "us-west-2", "Region capability should match");

        (bool tierExists, string memory tier) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "tier");
        assertTrue(tierExists, "tier capability should exist");
        assertEq(tier, "premium", "Tier capability should match");

        (bool storageExists, string memory storageVal) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "storage");
        assertTrue(storageExists, "storage capability should exist");
        assertEq(storageVal, "100TB", "Storage capability should match");

        // Test querying non-existent capability
        (bool nonExists, string memory nonExistent) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "nonexistent");
        assertFalse(nonExists, "Non-existent capability should not exist");
        assertEq(nonExistent, "", "Non-existent capability should return empty string");
    }

    function testGetProductCapabilities() public {
        // Register provider with capabilities
        string[] memory capKeys = new string[](4);
        capKeys[0] = "region";
        capKeys[1] = "tier";
        capKeys[2] = "storage";
        capKeys[3] = "compliance";

        string[] memory capValues = new string[](4);
        capValues[0] = "eu-west-1";
        capValues[1] = "standard";
        capValues[2] = "50TB";
        capValues[3] = "GDPR";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        // Query multiple capabilities
        string[] memory queryKeys = new string[](3);
        queryKeys[0] = "tier";
        queryKeys[1] = "compliance";
        queryKeys[2] = "region";

        (bool[] memory resultsExist, string[] memory results) =
            registry.getProductCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, queryKeys);

        assertEq(results.length, 3, "Should return 3 values");
        assertTrue(resultsExist[0] && resultsExist[1] && resultsExist[2], "All queried keys should exist");
        assertEq(results[0], "standard", "First result should be tier value");
        assertEq(results[1], "GDPR", "Second result should be compliance value");
        assertEq(results[2], "eu-west-1", "Third result should be region value");

        // Test with some non-existent keys
        string[] memory mixedKeys = new string[](4);
        mixedKeys[0] = "region";
        mixedKeys[1] = "nonexistent1";
        mixedKeys[2] = "storage";
        mixedKeys[3] = "nonexistent2";

        (bool[] memory mixedExist, string[] memory mixedResults) =
            registry.getProductCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, mixedKeys);

        assertEq(mixedResults.length, 4, "Should return 4 values");
        assertTrue(mixedExist[0], "First key should exist");
        assertFalse(mixedExist[1], "Second key should not exist");
        assertTrue(mixedExist[2], "Third key should exist");
        assertFalse(mixedExist[3], "Fourth key should not exist");
        assertEq(mixedResults[0], "eu-west-1", "First result should be region");
        assertEq(mixedResults[1], "", "Second result should be empty");
        assertEq(mixedResults[2], "50TB", "Third result should be storage");
        assertEq(mixedResults[3], "", "Fourth result should be empty");
    }

    function testDirectMappingAccess() public {
        // Register provider with capabilities
        string[] memory capKeys = new string[](2);
        capKeys[0] = "datacenter";
        capKeys[1] = "bandwidth";

        string[] memory capValues = new string[](2);
        capValues[0] = "NYC-01";
        capValues[1] = "10Gbps";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            capKeys,
            capValues
        );

        // Test direct public mapping access
        string memory datacenter =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "datacenter");
        assertEq(datacenter, "NYC-01", "Direct mapping access should work");

        string memory bandwidth =
            registry.productCapabilities(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "bandwidth");
        assertEq(bandwidth, "10Gbps", "Direct mapping access should work for bandwidth");
    }

    function testUpdateWithTooManyCapabilities() public {
        // Register provider with empty capabilities first
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            emptyKeys,
            emptyValues
        );

        // Try to update with 11 capabilities (exceeds MAX_CAPABILITIES of 10)
        string[] memory capKeys = new string[](11);
        string[] memory capValues = new string[](11);

        for (uint256 i = 0; i < 11; i++) {
            capKeys[i] = string(abi.encodePacked("key", vm.toString(i)));
            capValues[i] = string(abi.encodePacked("value", vm.toString(i)));
        }

        vm.prank(provider1);
        vm.expectRevert("Too many capabilities");
        registry.updateProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, capKeys, capValues
        );
    }

    function testCapabilityUpdateClearsOldValues() public {
        // Register provider with initial capabilities
        string[] memory initialKeys = new string[](3);
        initialKeys[0] = "region";
        initialKeys[1] = "tier";
        initialKeys[2] = "oldkey";

        string[] memory initialValues = new string[](3);
        initialValues[0] = "us-east-1";
        initialValues[1] = "basic";
        initialValues[2] = "oldvalue";

        vm.prank(provider1);
        uint256 providerId = registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Test provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            initialKeys,
            initialValues
        );

        // Verify initial values
        (bool oldExists, string memory oldValue) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "oldkey");
        assertTrue(oldExists, "Old key should exist initially");
        assertEq(oldValue, "oldvalue", "Old key should have value initially");

        // Update with new capabilities (without oldkey)
        string[] memory newKeys = new string[](2);
        newKeys[0] = "region";
        newKeys[1] = "newkey";

        string[] memory newValues = new string[](2);
        newValues[0] = "eu-central-1";
        newValues[1] = "newvalue";

        vm.prank(provider1);
        registry.updateProduct(
            ServiceProviderRegistryStorage.ProductType.PDP, encodedUpdatedPDPData, newKeys, newValues
        );

        // Verify old key is cleared
        (bool clearedExists, string memory clearedValue) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "oldkey");
        assertFalse(clearedExists, "Old key should not exist after update");
        assertEq(clearedValue, "", "Old key should be cleared after update");

        // Verify new values are set
        (bool regionExists, string memory newRegion) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "region");
        assertTrue(regionExists, "Region key should exist");
        assertEq(newRegion, "eu-central-1", "Region should be updated");

        (bool newKeyExists, string memory newKey) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "newkey");
        assertTrue(newKeyExists, "New key should exist");
        assertEq(newKey, "newvalue", "New key should have value");

        // Verify tier key is also cleared (was in initial but not in update)
        (bool tierCleared, string memory clearedTier) =
            registry.getProductCapability(providerId, ServiceProviderRegistryStorage.ProductType.PDP, "tier");
        assertFalse(tierCleared, "Tier key should not exist after update");
        assertEq(clearedTier, "", "Tier key should be cleared after update");
    }
}
