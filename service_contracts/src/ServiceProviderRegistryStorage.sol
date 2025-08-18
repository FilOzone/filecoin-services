// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

/// @title ServiceProviderRegistryStorage
/// @notice Centralized storage contract for ServiceProviderRegistry
/// @dev All storage variables are declared here to prevent storage slot collisions during upgrades
contract ServiceProviderRegistryStorage {
    // ========== Enums ==========

    /// @notice Product types that can be offered by service providers
    enum ProductType {
        PDP // Perpetual Data Preservation

    }

    // ========== Structs ==========

    /// @notice Main provider information
    struct ServiceProviderInfo {
        address owner;
        string description;
        bool isActive;
    }

    /// @notice Product offering of the Service Provider
    struct ServiceProduct {
        ProductType productType;
        bytes productData; // ABI-encoded service-specific data
        string[] capabilityKeys; // Max MAX_CAPABILITY_KEY_LENGTH chars each
        string[] capabilityValues; // Max MAX_CAPABILITY_VALUE_LENGTH chars each
        bool isActive;
    }

    /// @notice PDP-specific service data
    struct PDPOffering {
        string serviceURL; // HTTP API endpoint
        uint256 minPieceSizeInBytes; // Minimum piece size accepted in bytes
        uint256 maxPieceSizeInBytes; // Maximum piece size accepted in bytes
        bool ipniPiece; // Supports IPNI piece CID indexing
        bool ipniIpfs; // Supports IPNI IPFS CID indexing
        uint256 storagePricePerTibPerMonth; // Storage price per TiB per month in attoFIL
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
}
