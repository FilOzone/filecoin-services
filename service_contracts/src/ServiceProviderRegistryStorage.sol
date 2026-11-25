// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

/// @title ServiceProviderRegistryStorage
/// @notice Centralized storage contract for ServiceProviderRegistry
/// @dev All storage variables are declared here to prevent storage slot collisions during upgrades
contract ServiceProviderRegistryStorage {
    // ========== Enums ==========

    /// @notice Product types that can be offered by service providers
    enum ProductType {
        PDP
    }

    // ========== Structs ==========

    /// @notice Main provider information
    struct ServiceProviderInfo {
        address serviceProvider; // Worker address that operates the provider
        address payee; // Beneficiary address that receives payments and authorizes role changes
        string name; // Optional provider name (max 128 chars)
        string description; //Service description, ToC, contract info, website..
        bool isActive;
    }

    /// @notice Product offering of the Service Provider
    struct ServiceProduct {
        ProductType productType;
        string[] capabilityKeys; // Max MAX_CAPABILITY_KEY_LENGTH chars each
        bool isActive;
    }

    /// @notice Combined provider and product information for detailed queries
    struct ProviderWithProduct {
        uint256 providerId;
        ServiceProviderInfo providerInfo;
        ServiceProduct product;
        bytes[] productCapabilityValues;
    }

    /// @notice Paginated result for provider queries
    struct PaginatedProviders {
        ProviderWithProduct[] providers;
        bool hasMore;
    }

    // ========== Storage Variables ==========

    /// @notice Number of registered providers
    /// @dev Also used for generating unique provider IDs, where ID 0 is reserved
    uint256 internal numProviders;

    /// @notice Main registry of providers
    mapping(uint256 providerId => ServiceProviderInfo) public providers;

    /// @notice Provider products mapping (extensible for multiple product types)
    mapping(uint256 providerId => mapping(ProductType productType => ServiceProduct)) public providerProducts;

    /// @notice Address to provider ID lookup
    mapping(address providerAddress => uint256 providerId) public addressToProviderId;

    /// @notice Capability values mapping for efficient lookups
    mapping(uint256 providerId => mapping(ProductType productType => mapping(string key => bytes value))) public
        productCapabilities;

    /// @notice Count of providers (including inactive) offering each product type
    mapping(ProductType productType => uint256 count) public productTypeProviderCount;

    /// @notice Count of active providers offering each product type
    mapping(ProductType productType => uint256 count) public activeProductTypeProviderCount;

    /// @notice Count of active providers
    uint256 public activeProviderCount;

    /// @notice Per-provider EIP-712 nonce for payee-authorized actions
    /// @dev Appended for upgrade safety. Former workers keep their `addressToProviderId` entries
    ///      so `isAuthorizedWorker` can resolve from data-set-snapshotted addresses without a second map.
    mapping(uint256 providerId => uint256 nonce) public providerActionNonce;
}
