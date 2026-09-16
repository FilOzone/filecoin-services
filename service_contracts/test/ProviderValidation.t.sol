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
import {APPROVED_PROVIDERS_SLOT, APPROVED_PROVIDER_IDS_SLOT} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";

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
        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry(2);
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
            sessionKeyRegistry,
            4
        );
        bytes memory warmStorageInitData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector, uint64(2880), uint256(60), filBeamController
        );
        MyERC1967Proxy warmStorageProxy = new MyERC1967Proxy(address(warmStorageImpl), warmStorageInitData);
        warmStorage = FilecoinWarmStorageService(address(warmStorageProxy));

        // Deploy view contract
        viewContract = new FilecoinWarmStorageServiceStateView(warmStorage);

        // Transfer tokens to client
        usdfc.safeTransfer(client, 10000 * 10 ** 18);
    }

    // Temporary migration helper: seed legacy FWSS storage directly until ProviderManagementModule
    // and ViewModule are routed through the shared ERC-8167 proxy.
    function _seedApprovedProvider(uint256 providerId) internal {
        bytes32 approvedProviderSlot = keccak256(abi.encode(providerId, APPROVED_PROVIDERS_SLOT));
        vm.store(address(warmStorage), approvedProviderSlot, bytes32(uint256(1)));

        uint256 length = uint256(vm.load(address(warmStorage), APPROVED_PROVIDER_IDS_SLOT));
        bytes32 arrayDataSlot = keccak256(abi.encode(APPROVED_PROVIDER_IDS_SLOT));
        vm.store(address(warmStorage), bytes32(uint256(arrayDataSlot) + length), bytes32(providerId));
        vm.store(address(warmStorage), APPROVED_PROVIDER_IDS_SLOT, bytes32(length + 1));
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

    function testGetApprovedProvidersPaginated() public {
        // Test with empty list
        uint256[] memory providers = viewContract.getApprovedProviders(0, 10);
        assertEq(providers.length, 0, "Empty list should return empty array");

        // Add 5 providers
        for (uint256 i = 1; i <= 5; i++) {
            _seedApprovedProvider(i);
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
            _seedApprovedProvider(i);
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
        _seedApprovedProvider(42);

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
            _seedApprovedProvider(i);
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
