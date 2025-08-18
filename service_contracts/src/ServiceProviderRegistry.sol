// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Errors} from "./Errors.sol";

/// @title ServiceProviderRegistry
/// @notice A registry contract for managing service providers across the Filecoin Services ecosystem
contract ServiceProviderRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable, EIP712Upgradeable {
    /// @notice Enum representing different service types
    enum ProductType {
        PDP
    }

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

    /// @notice Version of the contract implementation
    string public constant VERSION = "0.0.1";

    /// @notice Maximum length for service URL
    uint256 private constant MAX_SERVICE_URL_LENGTH = 256;

    /// @notice Maximum length for provider description
    uint256 private constant MAX_DESCRIPTION_LENGTH = 256;

    /// @notice Maximum length for capability keys
    uint256 public constant MAX_CAPABILITY_KEY_LENGTH = 12;

    /// @notice Maximum length for capability values
    uint256 public constant MAX_CAPABILITY_VALUE_LENGTH = 64;

    /// @notice Burn actor address for burning FIL
    address public constant BURN_ACTOR = 0xff00000000000000000000000000000000000063;

    /// @notice Registration fee in attoFIL (1 FIL = 10^18 attoFIL)
    uint256 public constant REGISTRATION_FEE = 1e18;

    // ========== State Variables ==========

    /// @notice Counter for generating unique provider IDs
    /// @dev Starts at 1, ID 0 is reserved to indicate "not registered"
    uint256 private nextProviderId;

    /// @notice Main registry of providers
    mapping(uint256 providerId => ServiceProviderInfo) public providers;

    /// @notice Provider products mapping (extensible for multiple product types)
    mapping(uint256 providerId => mapping(ProductType productType => ServiceProduct)) public providerProducts;

    /// @notice Address to provider ID lookup
    mapping(address providerAddress => uint256 providerId) public addressToProviderId;

    /// @notice Emitted when a new provider registers
    event ProviderRegistered(uint256 indexed providerId, address indexed owner, uint256 registeredAt);

    /// @notice Emitted when a service is updated or added
    event ServiceUpdated(uint256 indexed providerId, ProductType indexed productType, uint256 updatedAt);

    /// @notice Emitted when a product is added to an existing provider
    event ProductAdded(uint256 indexed providerId, ProductType indexed productType, uint256 addedAt);

    /// @notice Emitted when a product is removed from a provider
    event ProductRemoved(uint256 indexed providerId, ProductType indexed productType, uint256 removedAt);

    /// @notice Emitted when provider info is updated
    event ProviderInfoUpdated(uint256 indexed providerId, uint256 updatedAt);

    /// @notice Emitted when ownership is transferred
    event OwnershipTransferred(
        uint256 indexed providerId, address indexed previousOwner, address indexed newOwner, uint256 transferredAt
    );

    /// @notice Emitted when a provider is removed
    event ProviderRemoved(uint256 indexed providerId, uint256 removedAt);

    /// @notice Emitted when the contract is upgraded
    event ContractUpgraded(string version, address implementation);

    /// @notice Ensures the caller is the owner of the provider
    modifier onlyProviderOwner(uint256 providerId) {
        require(providers[providerId].owner == msg.sender, "Only provider owner can call this function");
        _;
    }

    /// @notice Ensures the provider exists
    modifier providerExists(uint256 providerId) {
        require(providerId > 0 && providerId < nextProviderId, "Provider does not exist");
        require(providers[providerId].owner != address(0), "Provider not found");
        _;
    }

    /// @notice Ensures the provider is active
    modifier providerActive(uint256 providerId) {
        require(providers[providerId].isActive, "Provider is not active");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice Constructor that disables initializers for the implementation contract
    /// @dev This ensures the implementation contract cannot be initialized directly
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the registry contract
    /// @dev Can only be called once during proxy deployment
    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __EIP712_init("ServiceProviderRegistry", "1");

        // Initialize the provider ID counter
        nextProviderId = 1;
    }

    /// @notice Register as a new service provider with a specific product type
    /// @param description Provider description (max 256 chars)
    /// @param productType The type of product to register
    /// @param productData The encoded product configuration data
    /// @param capabilityKeys Array of capability keys
    /// @param capabilityValues Array of capability values
    /// @return providerId The unique ID assigned to the provider
    function registerProvider(
        string calldata description,
        ProductType productType,
        bytes calldata productData,
        string[] calldata capabilityKeys,
        string[] calldata capabilityValues
    ) external payable returns (uint256 providerId) {
        // Only support PDP for now
        require(productType == ProductType.PDP, "Only PDP product type currently supported");

        // Check if address is already registered
        require(addressToProviderId[msg.sender] == 0, "Address already registered");

        // Check payment amount is exactly the registration fee
        require(msg.value == REGISTRATION_FEE, "Incorrect fee amount");

        // Validate description
        require(bytes(description).length <= MAX_DESCRIPTION_LENGTH, "Description too long");

        // Validate product data
        _validateProductData(productType, productData);

        // Validate capability k/v pairs
        _validateCapabilities(capabilityKeys, capabilityValues);

        // Assign provider ID
        providerId = nextProviderId++;

        // Store provider info
        providers[providerId] = ServiceProviderInfo({owner: msg.sender, description: description, isActive: true});

        // Store product
        providerProducts[providerId][productType] = ServiceProduct({
            productType: productType,
            productData: productData,
            capabilityKeys: capabilityKeys,
            capabilityValues: capabilityValues,
            isActive: true
        });

        // Update address mapping
        addressToProviderId[msg.sender] = providerId;

        // Emit events
        emit ProviderRegistered(providerId, msg.sender, block.number);
        emit ServiceUpdated(providerId, productType, block.number);

        // Burn the registration fee
        (bool burnSuccess,) = BURN_ACTOR.call{value: REGISTRATION_FEE}("");
        require(burnSuccess, "Burn failed");
    }

    /// @notice Add a new product to an existing provider
    /// @param productType The type of product to add
    /// @param productData The encoded product configuration data
    /// @param capabilityKeys Array of capability keys (max MAX_CAPABILITY_KEY_LENGTH chars each)
    /// @param capabilityValues Array of capability values (max MAX_CAPABILITY_VALUE_LENGTH chars each)
    function addProduct(
        ProductType productType,
        bytes calldata productData,
        string[] calldata capabilityKeys,
        string[] calldata capabilityValues
    ) external {
        // Only support PDP for now
        require(productType == ProductType.PDP, "Only PDP product type currently supported");

        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        _addProduct(providerId, productType, productData, capabilityKeys, capabilityValues);
    }

    /// @notice Internal function to add a product
    function _addProduct(
        uint256 providerId,
        ProductType productType,
        bytes memory productData,
        string[] memory capabilityKeys,
        string[] memory capabilityValues
    ) private providerExists(providerId) providerActive(providerId) onlyProviderOwner(providerId) {
        // Check product doesn't already exist
        require(!providerProducts[providerId][productType].isActive, "Product already exists for this provider");

        // Validate product data
        _validateProductData(productType, productData);

        // Validate capability k/v pairs
        _validateCapabilities(capabilityKeys, capabilityValues);

        // Add product
        providerProducts[providerId][productType] = ServiceProduct({
            productType: productType,
            productData: productData,
            capabilityKeys: capabilityKeys,
            capabilityValues: capabilityValues,
            isActive: true
        });

        // Emit event
        emit ProductAdded(providerId, productType, block.number);
    }

    /// @notice Update an existing product configuration
    /// @param productType The type of product to update
    /// @param productData The new encoded product configuration data
    /// @param capabilityKeys Array of capability keys (max MAX_CAPABILITY_KEY_LENGTH chars each)
    /// @param capabilityValues Array of capability values (max MAX_CAPABILITY_VALUE_LENGTH chars each)
    function updateProduct(
        ProductType productType,
        bytes calldata productData,
        string[] calldata capabilityKeys,
        string[] calldata capabilityValues
    ) external {
        // Only support PDP for now
        require(productType == ProductType.PDP, "Only PDP product type currently supported");

        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        _updateProduct(providerId, productType, productData, capabilityKeys, capabilityValues);
    }

    /// @notice Internal function to update a product
    function _updateProduct(
        uint256 providerId,
        ProductType productType,
        bytes memory productData,
        string[] memory capabilityKeys,
        string[] memory capabilityValues
    ) private providerExists(providerId) providerActive(providerId) onlyProviderOwner(providerId) {
        // Check product exists
        require(providerProducts[providerId][productType].isActive, "Product does not exist for this provider");

        // Validate product data
        _validateProductData(productType, productData);

        // Validate capability k/v pairs
        _validateCapabilities(capabilityKeys, capabilityValues);

        // Update product
        providerProducts[providerId][productType] = ServiceProduct({
            productType: productType,
            productData: productData,
            capabilityKeys: capabilityKeys,
            capabilityValues: capabilityValues,
            isActive: true
        });

        // Emit event
        emit ServiceUpdated(providerId, productType, block.number);
    }

    /// @notice Remove a product from a provider
    /// @param productType The type of product to remove
    function removeProduct(ProductType productType) external {
        // Only support PDP for now
        require(productType == ProductType.PDP, "Only PDP product type currently supported");

        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        _removeProduct(providerId, productType);
    }

    /// @notice Internal function to remove a product
    function _removeProduct(uint256 providerId, ProductType productType)
        private
        providerExists(providerId)
        providerActive(providerId)
        onlyProviderOwner(providerId)
    {
        // Check product exists
        require(providerProducts[providerId][productType].isActive, "Product does not exist for this provider");

        // Count active products
        uint256 activeProductCount = 0;
        // For now we only have PDP, but this is extensible
        if (providerProducts[providerId][ProductType.PDP].isActive) {
            activeProductCount++;
        }

        // Don't allow removing the last product
        require(activeProductCount > 1, "Cannot remove last product");

        // Mark product as inactive
        providerProducts[providerId][productType].isActive = false;

        // Emit event
        emit ProductRemoved(providerId, productType, block.number);
    }

    /// @notice Update PDP service configuration (legacy compatibility)
    /// @param pdpOffering The new PDP service configuration
    function updatePDPService(PDPOffering memory pdpOffering) external {
        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        bytes memory encodedData = _encodePDPOffering(pdpOffering);
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        _updateProduct(providerId, ProductType.PDP, encodedData, emptyKeys, emptyValues);
    }

    /// @notice Update PDP service configuration with capabilities
    /// @param pdpOffering The new PDP service configuration
    /// @param capabilityKeys Array of capability keys (max MAX_CAPABILITY_KEY_LENGTH chars each)
    /// @param capabilityValues Array of capability values (max MAX_CAPABILITY_VALUE_LENGTH chars each)
    function updatePDPServiceWithCapabilities(
        PDPOffering memory pdpOffering,
        string[] memory capabilityKeys,
        string[] memory capabilityValues
    ) external {
        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        bytes memory encodedData = _encodePDPOffering(pdpOffering);
        _updateProduct(providerId, ProductType.PDP, encodedData, capabilityKeys, capabilityValues);
    }

    /// @notice Update provider information
    /// @param description New provider description (max 256 chars)
    function updateProviderInfo(string calldata description) external {
        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");
        require(providerId > 0 && providerId < nextProviderId, "Provider does not exist");
        require(providers[providerId].owner != address(0), "Provider not found");
        require(providers[providerId].isActive, "Provider is not active");

        // Validate description
        require(bytes(description).length <= MAX_DESCRIPTION_LENGTH, "Description too long");

        // Update description
        providers[providerId].description = description;

        // Emit event
        emit ProviderInfoUpdated(providerId, block.number);
    }

    /// @notice Transfer provider ownership to a new address
    /// @param newOwner The address of the new owner
    function transferProviderOwnership(address newOwner) external {
        require(newOwner != address(0), "New owner cannot be zero address");

        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        _transferProviderOwnership(providerId, newOwner);
    }

    /// @notice Internal function to transfer ownership
    function _transferProviderOwnership(uint256 providerId, address newOwner)
        private
        providerExists(providerId)
        providerActive(providerId)
        onlyProviderOwner(providerId)
    {
        // Check new owner doesn't already have a provider
        require(addressToProviderId[newOwner] == 0, "New owner already has a provider");

        address previousOwner = providers[providerId].owner;

        // Update owner
        providers[providerId].owner = newOwner;

        // Update address mappings
        delete addressToProviderId[previousOwner];
        addressToProviderId[newOwner] = providerId;

        // Emit event
        emit OwnershipTransferred(providerId, previousOwner, newOwner, block.number);
    }

    /// @notice Remove provider registration (soft delete)
    function removeProvider() external {
        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        _removeProvider(providerId);
    }

    /// @notice Internal function to remove provider
    function _removeProvider(uint256 providerId)
        private
        providerExists(providerId)
        providerActive(providerId)
        onlyProviderOwner(providerId)
    {
        // Soft delete - mark as inactive
        providers[providerId].isActive = false;

        // Mark all products as inactive
        // For now just PDP, but this is extensible
        if (providerProducts[providerId][ProductType.PDP].productData.length > 0) {
            providerProducts[providerId][ProductType.PDP].isActive = false;
        }

        // Clear address mapping
        delete addressToProviderId[providers[providerId].owner];

        // Emit event
        emit ProviderRemoved(providerId, block.number);
    }

    /// @notice Get complete provider information
    /// @param providerId The ID of the provider
    /// @return info The provider information
    function getProvider(uint256 providerId)
        external
        view
        providerExists(providerId)
        returns (ServiceProviderInfo memory info)
    {
        return providers[providerId];
    }

    /// @notice Get product data for a specific product type
    /// @param providerId The ID of the provider
    /// @param productType The type of product to retrieve
    /// @return productData The encoded product data
    /// @return capabilityKeys Array of capability keys
    /// @return capabilityValues Array of capability values
    /// @return isActive Whether the product is active
    function getProduct(uint256 providerId, ProductType productType)
        external
        view
        providerExists(providerId)
        returns (
            bytes memory productData,
            string[] memory capabilityKeys,
            string[] memory capabilityValues,
            bool isActive
        )
    {
        ServiceProduct memory product = providerProducts[providerId][productType];
        return (product.productData, product.capabilityKeys, product.capabilityValues, product.isActive);
    }

    /// @notice Get PDP service configuration for a provider (convenience function)
    /// @param providerId The ID of the provider
    /// @return pdpOffering The decoded PDP service data
    /// @return capabilityKeys Array of capability keys
    /// @return capabilityValues Array of capability values
    /// @return isActive Whether the PDP service is active
    function getPDPService(uint256 providerId)
        external
        view
        providerExists(providerId)
        returns (
            PDPOffering memory pdpOffering,
            string[] memory capabilityKeys,
            string[] memory capabilityValues,
            bool isActive
        )
    {
        ServiceProduct memory product = providerProducts[providerId][ProductType.PDP];

        if (product.productData.length > 0) {
            pdpOffering = _decodePDPOffering(product.productData);
            capabilityKeys = product.capabilityKeys;
            capabilityValues = product.capabilityValues;
            isActive = product.isActive;
        }
    }

    /// @notice Get all providers that offer a specific product type
    /// @param productType The product type to filter by
    /// @return providerIds Array of provider IDs offering this product
    function getProvidersByProductType(ProductType productType) external view returns (uint256[] memory providerIds) {
        // Count providers with this product
        uint256 count = 0;
        for (uint256 i = 1; i < nextProviderId; i++) {
            if (providerProducts[i][productType].productData.length > 0) {
                count++;
            }
        }

        // Collect provider IDs
        providerIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i < nextProviderId; i++) {
            if (providerProducts[i][productType].productData.length > 0) {
                providerIds[index++] = i;
            }
        }
    }

    /// @notice Get all active providers that offer a specific product type
    /// @param productType The product type to filter by
    /// @return providerIds Array of active provider IDs offering this product
    function getActiveProvidersByProductType(ProductType productType)
        external
        view
        returns (uint256[] memory providerIds)
    {
        // Count active providers with this product
        uint256 count = 0;
        for (uint256 i = 1; i < nextProviderId; i++) {
            if (
                providers[i].isActive && providerProducts[i][productType].isActive
                    && providerProducts[i][productType].productData.length > 0
            ) {
                count++;
            }
        }

        // Collect provider IDs
        providerIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i < nextProviderId; i++) {
            if (
                providers[i].isActive && providerProducts[i][productType].isActive
                    && providerProducts[i][productType].productData.length > 0
            ) {
                providerIds[index++] = i;
            }
        }
    }

    /// @notice Check if a provider offers a specific product type
    /// @param providerId The ID of the provider
    /// @param productType The product type to check
    /// @return Whether the provider offers this product type
    function providerHasProduct(uint256 providerId, ProductType productType)
        external
        view
        providerExists(providerId)
        returns (bool)
    {
        return providerProducts[providerId][productType].isActive;
    }

    /// @notice Get provider ID by address
    /// @param providerAddress The address of the provider
    /// @return providerId The provider ID (0 if not registered)
    function getProviderByAddress(address providerAddress) external view returns (uint256) {
        return addressToProviderId[providerAddress];
    }

    /// @notice Check if a provider is active
    /// @param providerId The ID of the provider
    /// @return Whether the provider is active
    function isProviderActive(uint256 providerId) external view providerExists(providerId) returns (bool) {
        return providers[providerId].isActive;
    }

    /// @notice Get all active providers
    /// @return activeProviderIds Array of active provider IDs
    function getAllActiveProviders() external view returns (uint256[] memory activeProviderIds) {
        // Count active providers
        uint256 activeCount = 0;
        for (uint256 i = 1; i < nextProviderId; i++) {
            if (providers[i].isActive) {
                activeCount++;
            }
        }

        // Collect active provider IDs
        activeProviderIds = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 1; i < nextProviderId; i++) {
            if (providers[i].isActive) {
                activeProviderIds[index++] = i;
            }
        }
    }

    /// @notice Get total number of registered providers (including inactive)
    /// @return The total count of providers
    function getProviderCount() external view returns (uint256) {
        return nextProviderId - 1;
    }

    /// @notice Check if an address is a registered provider
    /// @param provider The address to check
    /// @return Whether the address is a registered provider
    function isRegisteredProvider(address provider) external view returns (bool) {
        uint256 providerId = addressToProviderId[provider];
        return providerId != 0 && providers[providerId].isActive;
    }

    /// @notice Returns the next available provider ID
    /// @return The next provider ID that will be assigned
    function getNextProviderId() external view returns (uint256) {
        return nextProviderId;
    }

    /// @notice Returns the registration fee amount
    /// @return The registration fee in attoFIL
    function getRegistrationFee() external pure returns (uint256) {
        return REGISTRATION_FEE;
    }

    /// @notice Validate product data based on product type
    /// @param productType The type of product
    /// @param productData The encoded product data
    function _validateProductData(ProductType productType, bytes memory productData) private pure {
        if (productType == ProductType.PDP) {
            PDPOffering memory pdpOffering = abi.decode(productData, (PDPOffering));
            _validatePDPOffering(pdpOffering);
        } else {
            revert("Unsupported product type");
        }
    }

    /// @notice Validate PDP offering
    function _validatePDPOffering(PDPOffering memory pdpOffering) private pure {
        require(bytes(pdpOffering.serviceURL).length > 0, "Service URL cannot be empty");
        require(bytes(pdpOffering.serviceURL).length <= MAX_SERVICE_URL_LENGTH, "Service URL too long");
        require(pdpOffering.minPieceSizeInBytes > 0, "Min piece size must be greater than 0");
        require(
            pdpOffering.maxPieceSizeInBytes >= pdpOffering.minPieceSizeInBytes,
            "Max piece size must be >= min piece size"
        );
    }

    /// @notice Validate capability key-value pairs
    /// @param keys Array of capability keys
    /// @param values Array of capability values
    function _validateCapabilities(string[] memory keys, string[] memory values) private pure {
        require(keys.length == values.length, "Keys and values arrays must have same length");

        for (uint256 i = 0; i < keys.length; i++) {
            require(bytes(keys[i]).length > 0, "Capability key cannot be empty");
            require(bytes(keys[i]).length <= MAX_CAPABILITY_KEY_LENGTH, "Capability key exceeds 12 characters");
            require(bytes(values[i]).length <= MAX_CAPABILITY_VALUE_LENGTH, "Capability value exceeds 64 characters");
        }
    }

    /// @notice Encode PDP offering to bytes
    function _encodePDPOffering(PDPOffering memory pdpOffering) private pure returns (bytes memory) {
        return abi.encode(pdpOffering);
    }

    /// @notice Decode PDP offering from bytes
    function _decodePDPOffering(bytes memory data) private pure returns (PDPOffering memory) {
        return abi.decode(data, (PDPOffering));
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Can only be called by the contract owner
    /// @param newImplementation Address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Authorization logic is handled by the onlyOwner modifier
    }

    /// @notice Migration function for contract upgrades
    /// @dev This function should be called during upgrades to emit version tracking events
    /// @param newVersion The version string for the new implementation
    function migrate(string memory newVersion) public onlyProxy reinitializer(2) {
        require(msg.sender == address(this), "Only self can call migrate");
        emit ContractUpgraded(newVersion, ERC1967Utils.getImplementation());
    }
}
