// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ServiceProviderRegistry.sol";
import "../src/ServiceProviderRegistryStorage.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ServiceProviderRegistryPaginationTest is Test {
    ServiceProviderRegistry public registry;

    address public owner = address(0x1);
    address public provider1 = address(0x2);
    address public provider2 = address(0x3);
    address public provider3 = address(0x4);
    address public provider4 = address(0x5);
    address public provider5 = address(0x6);
    address public provider6 = address(0x7);

    uint256 public constant REGISTRATION_FEE = 5 ether;
    string public constant SERVICE_URL = "https://test-service.com";

    ServiceProviderRegistryStorage.PDPOffering public defaultPDPData;
    bytes public encodedDefaultPDPData;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy implementation
        ServiceProviderRegistry implementation = new ServiceProviderRegistry();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        registry = ServiceProviderRegistry(address(proxy));

        vm.stopPrank();

        // Set up default PDP data
        defaultPDPData = ServiceProviderRegistryStorage.PDPOffering({
            serviceURL: SERVICE_URL,
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1048576,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerMonth: 100,
            minProvingPeriodInEpochs: 10,
            location: "US-WEST",
            paymentTokenAddress: IERC20(address(0))
        });

        encodedDefaultPDPData = registry.encodePDPOffering(defaultPDPData);

        // Give providers ETH for registration
        vm.deal(provider1, 10 ether);
        vm.deal(provider2, 10 ether);
        vm.deal(provider3, 10 ether);
        vm.deal(provider4, 10 ether);
        vm.deal(provider5, 10 ether);
        vm.deal(provider6, 10 ether);
    }

    // ========== Edge Case: No Providers ==========

    function testPaginationNoProviders() public {
        // Test with different offset and limit values
        (uint256[] memory ids, bool hasMore) = registry.getAllActiveProviders(0, 10);
        assertEq(ids.length, 0);
        assertFalse(hasMore);

        (ids, hasMore) = registry.getAllActiveProviders(5, 10);
        assertEq(ids.length, 0);
        assertFalse(hasMore);

        (ids, hasMore) = registry.getAllActiveProviders(0, 0);
        assertEq(ids.length, 0);
        assertFalse(hasMore);
    }

    // ========== Edge Case: Single Provider ==========

    function testPaginationSingleProvider() public {
        // Register one provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Provider 1",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            new string[](0),
            new string[](0)
        );

        // Get with limit larger than count
        (uint256[] memory ids, bool hasMore) = registry.getAllActiveProviders(0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);
        assertFalse(hasMore);

        // Get with exact limit
        (ids, hasMore) = registry.getAllActiveProviders(0, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);
        assertFalse(hasMore);

        // Get with offset beyond count
        (ids, hasMore) = registry.getAllActiveProviders(1, 10);
        assertEq(ids.length, 0);
        assertFalse(hasMore);

        // Get with offset at boundary
        (ids, hasMore) = registry.getAllActiveProviders(0, 1);
        assertEq(ids.length, 1);
        assertFalse(hasMore);
    }

    // ========== Test Page Boundaries ==========

    function testPaginationPageBoundaries() public {
        // Register 5 providers
        address[5] memory providers = [provider1, provider2, provider3, provider4, provider5];
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(providers[i]);
            registry.registerProvider{value: REGISTRATION_FEE}(
                "",
                string.concat("Provider ", vm.toString(i + 1)),
                ServiceProviderRegistryStorage.ProductType.PDP,
                encodedDefaultPDPData,
                new string[](0),
                new string[](0)
            );
        }

        // Test exact page size (2 items per page)
        (uint256[] memory ids, bool hasMore) = registry.getAllActiveProviders(0, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertTrue(hasMore);

        (ids, hasMore) = registry.getAllActiveProviders(2, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], 3);
        assertEq(ids[1], 4);
        assertTrue(hasMore);

        (ids, hasMore) = registry.getAllActiveProviders(4, 2);
        assertEq(ids.length, 1);
        assertEq(ids[0], 5);
        assertFalse(hasMore);

        // Test page boundaries with limit 3
        (ids, hasMore) = registry.getAllActiveProviders(0, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(ids[2], 3);
        assertTrue(hasMore);

        (ids, hasMore) = registry.getAllActiveProviders(3, 3);
        assertEq(ids.length, 2);
        assertEq(ids[0], 4);
        assertEq(ids[1], 5);
        assertFalse(hasMore);
    }

    // ========== Test with Inactive Providers ==========

    function testPaginationWithInactiveProviders() public {
        // Register 5 providers
        address[5] memory providers = [provider1, provider2, provider3, provider4, provider5];
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(providers[i]);
            registry.registerProvider{value: REGISTRATION_FEE}(
                "",
                string.concat("Provider ", vm.toString(i + 1)),
                ServiceProviderRegistryStorage.ProductType.PDP,
                encodedDefaultPDPData,
                new string[](0),
                new string[](0)
            );
        }

        // Remove provider 2 and 4
        vm.prank(provider2);
        registry.removeProvider();

        vm.prank(provider4);
        registry.removeProvider();

        // Should have 3 active providers (1, 3, 5)
        (uint256[] memory ids, bool hasMore) = registry.getAllActiveProviders(0, 10);
        assertEq(ids.length, 3);
        assertEq(ids[0], 1);
        assertEq(ids[1], 3);
        assertEq(ids[2], 5);
        assertFalse(hasMore);

        // Test pagination with limit 2
        (ids, hasMore) = registry.getAllActiveProviders(0, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 3);
        assertTrue(hasMore);

        (ids, hasMore) = registry.getAllActiveProviders(2, 2);
        assertEq(ids.length, 1);
        assertEq(ids[0], 5);
        assertFalse(hasMore);
    }

    // ========== Test Edge Cases with Limits ==========

    function testPaginationEdgeLimits() public {
        // Register 3 providers
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Provider 1",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            new string[](0),
            new string[](0)
        );

        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Provider 2",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            new string[](0),
            new string[](0)
        );

        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Provider 3",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            new string[](0),
            new string[](0)
        );

        // Test with limit 0 (should return empty)
        (uint256[] memory ids, bool hasMore) = registry.getAllActiveProviders(0, 0);
        assertEq(ids.length, 0);
        assertFalse(hasMore);

        // Test with very large limit
        (ids, hasMore) = registry.getAllActiveProviders(0, 1000);
        assertEq(ids.length, 3);
        assertFalse(hasMore);

        // Test with offset equal to count
        (ids, hasMore) = registry.getAllActiveProviders(3, 10);
        assertEq(ids.length, 0);
        assertFalse(hasMore);

        // Test with offset just before count
        (ids, hasMore) = registry.getAllActiveProviders(2, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], 3);
        assertFalse(hasMore);
    }

    // ========== Test Consistency with getAllActiveProviders ==========

    function testPaginationConsistencyWithGetAll() public {
        // Register 6 providers
        address[6] memory providers = [provider1, provider2, provider3, provider4, provider5, provider6];
        for (uint256 i = 0; i < 6; i++) {
            vm.prank(providers[i]);
            registry.registerProvider{value: REGISTRATION_FEE}(
                "",
                string.concat("Provider ", vm.toString(i + 1)),
                ServiceProviderRegistryStorage.ProductType.PDP,
                encodedDefaultPDPData,
                new string[](0),
                new string[](0)
            );
        }

        // Remove provider 3
        vm.prank(provider3);
        registry.removeProvider();

        // Get all active providers using paginated function with large limit
        (uint256[] memory allProviders, bool hasMore) = registry.getAllActiveProviders(0, 100);
        assertEq(allProviders.length, 5);
        assertFalse(hasMore);

        // Get all using paginated with same large limit for comparison
        (uint256[] memory paginatedAll, bool hasMore2) = registry.getAllActiveProviders(0, 100);
        assertEq(paginatedAll.length, 5);
        assertFalse(hasMore2);

        // Compare results
        for (uint256 i = 0; i < 5; i++) {
            assertEq(allProviders[i], paginatedAll[i]);
        }

        // Get all by iterating through pages
        uint256[] memory combined = new uint256[](5);
        uint256 combinedIndex = 0;
        uint256 offset = 0;
        uint256 pageSize = 2;

        while (true) {
            (uint256[] memory page, bool more) = registry.getAllActiveProviders(offset, pageSize);

            for (uint256 i = 0; i < page.length; i++) {
                combined[combinedIndex++] = page[i];
            }

            if (!more) break;
            offset += pageSize;
        }

        // Verify combined results match
        for (uint256 i = 0; i < 5; i++) {
            assertEq(allProviders[i], combined[i]);
        }
    }

    // ========== Test Active Count Tracking ==========

    function testActiveProviderCountTracking() public {
        // Initially should be 0
        assertEq(registry.activeProviderCount(), 0);

        // Register first provider
        vm.prank(provider1);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Provider 1",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            new string[](0),
            new string[](0)
        );
        assertEq(registry.activeProviderCount(), 1);

        // Register second provider
        vm.prank(provider2);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Provider 2",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            new string[](0),
            new string[](0)
        );
        assertEq(registry.activeProviderCount(), 2);

        // Remove first provider
        vm.prank(provider1);
        registry.removeProvider();
        assertEq(registry.activeProviderCount(), 1);

        // Register third provider
        vm.prank(provider3);
        registry.registerProvider{value: REGISTRATION_FEE}(
            "",
            "Provider 3",
            ServiceProviderRegistryStorage.ProductType.PDP,
            encodedDefaultPDPData,
            new string[](0),
            new string[](0)
        );
        assertEq(registry.activeProviderCount(), 2);

        // Remove all providers
        vm.prank(provider2);
        registry.removeProvider();
        assertEq(registry.activeProviderCount(), 1);

        vm.prank(provider3);
        registry.removeProvider();
        assertEq(registry.activeProviderCount(), 0);
    }

    // ========== Test Sequential Pages ==========

    function testSequentialPagination() public {
        // Register 10 providers (need 4 more addresses)
        address provider7 = address(0x8);
        address provider8 = address(0x9);
        address provider9 = address(0x10);
        address provider10 = address(0x11);

        vm.deal(provider7, 10 ether);
        vm.deal(provider8, 10 ether);
        vm.deal(provider9, 10 ether);
        vm.deal(provider10, 10 ether);

        address[10] memory providers = [
            provider1,
            provider2,
            provider3,
            provider4,
            provider5,
            provider6,
            provider7,
            provider8,
            provider9,
            provider10
        ];

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(providers[i]);
            registry.registerProvider{value: REGISTRATION_FEE}(
                "",
                string.concat("Provider ", vm.toString(i + 1)),
                ServiceProviderRegistryStorage.ProductType.PDP,
                encodedDefaultPDPData,
                new string[](0),
                new string[](0)
            );
        }

        // Page size of 3
        (uint256[] memory page1, bool hasMore1) = registry.getAllActiveProviders(0, 3);
        assertEq(page1.length, 3);
        assertEq(page1[0], 1);
        assertEq(page1[1], 2);
        assertEq(page1[2], 3);
        assertTrue(hasMore1);

        (uint256[] memory page2, bool hasMore2) = registry.getAllActiveProviders(3, 3);
        assertEq(page2.length, 3);
        assertEq(page2[0], 4);
        assertEq(page2[1], 5);
        assertEq(page2[2], 6);
        assertTrue(hasMore2);

        (uint256[] memory page3, bool hasMore3) = registry.getAllActiveProviders(6, 3);
        assertEq(page3.length, 3);
        assertEq(page3[0], 7);
        assertEq(page3[1], 8);
        assertEq(page3[2], 9);
        assertTrue(hasMore3);

        (uint256[] memory page4, bool hasMore4) = registry.getAllActiveProviders(9, 3);
        assertEq(page4.length, 1);
        assertEq(page4[0], 10);
        assertFalse(hasMore4);
    }
}
