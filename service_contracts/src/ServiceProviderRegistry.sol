// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Errors} from "./Errors.sol";
import {ServiceProviderRegistryStorage} from "./ServiceProviderRegistryStorage.sol";

/// @title ServiceProviderRegistry
/// @notice A registry contract for managing service providers across the Filecoin Services ecosystem
contract ServiceProviderRegistry is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    EIP712Upgradeable,
    ServiceProviderRegistryStorage
{
    /// @notice Version of the contract implementation
    string public constant VERSION = "0.0.1";

    /// @notice Maximum length for service URL
    uint256 private constant MAX_SERVICE_URL_LENGTH = 256;

    /// @notice Maximum length for provider description
    uint256 private constant MAX_DESCRIPTION_LENGTH = 256;

    /// @notice Maximum length for provider name
    uint256 private constant MAX_NAME_LENGTH = 128;

    /// @notice Maximum length for capability keys
    uint256 public constant MAX_CAPABILITY_KEY_LENGTH = 32;

    /// @notice Maximum length for capability values
    uint256 public constant MAX_CAPABILITY_VALUE_LENGTH = 128;

    /// @notice Maximum number of capability key-value pairs per product
    uint256 public constant MAX_CAPABILITIES = 10;

    /// @notice Maximum length for location field
    uint256 private constant MAX_LOCATION_LENGTH = 128;

    /// @notice Burn actor address for burning FIL
    address public constant BURN_ACTOR = 0xff00000000000000000000000000000000000063;

    /// @notice Registration fee in attoFIL (5 FIL = 5 * 10^18 attoFIL)
    uint256 public constant REGISTRATION_FEE = 5e18;

    /// @notice Emitted when a new provider registers
    event ProviderRegistered(uint256 indexed providerId, address indexed beneficiary);

    /// @notice Emitted when a product is updated or added
    event ProductUpdated(
        uint256 indexed providerId,
        ProductType indexed productType,
        string serviceUrl,
        address beneficiary,
        string[] capabilityKeys,
        string[] capabilityValues
    );

    /// @notice Emitted when a product is added to an existing provider
    event ProductAdded(
        uint256 indexed providerId,
        ProductType indexed productType,
        string serviceUrl,
        address beneficiary,
        string[] capabilityKeys,
        string[] capabilityValues
    );

    /// @notice Emitted when a product is removed from a provider
    event ProductRemoved(uint256 indexed providerId, ProductType indexed productType);

    /// @notice Emitted when provider info is updated
    event ProviderInfoUpdated(uint256 indexed providerId);

    /// @notice Emitted when beneficiary is transferred
    event BeneficiaryTransferred(
        uint256 indexed providerId, address indexed previousBeneficiary, address indexed newBeneficiary
    );

    /// @notice Emitted when a provider is removed
    event ProviderRemoved(uint256 indexed providerId);

    /// @notice Emitted when the contract is upgraded
    event ContractUpgraded(string version, address implementation);

    /// @notice Ensures the caller is the beneficiary of the provider
    modifier onlyProviderBeneficiary(uint256 providerId) {
        require(providers[providerId].beneficiary == msg.sender, "Only provider beneficiary can call this function");
        _;
    }

    /// @notice Ensures the provider exists
    modifier providerExists(uint256 providerId) {
        require(providerId > 0 && providerId <= numProviders, "Provider does not exist");
        require(providers[providerId].beneficiary != address(0), "Provider not found");
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
    }

    /// @notice Register as a new service provider with a specific product type
    /// @param name Provider name (optional, max 128 chars)
    /// @param description Provider description (max 256 chars)
    /// @param productType The type of product to register
    /// @param productData The encoded product configuration data
    /// @param capabilityKeys Array of capability keys
    /// @param capabilityValues Array of capability values
    /// @return providerId The unique ID assigned to the provider
    function registerProvider(
        string calldata name,
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

        // Validate name (optional, so empty is allowed)
        require(bytes(name).length <= MAX_NAME_LENGTH, "Name too long");

        // Validate description
        require(bytes(description).length <= MAX_DESCRIPTION_LENGTH, "Description too long");

        // Assign provider ID
        providerId = ++numProviders;

        // Store provider info
        providers[providerId] =
            ServiceProviderInfo({beneficiary: msg.sender, name: name, description: description, isActive: true});

        // Update address mapping
        addressToProviderId[msg.sender] = providerId;

        activeProviderCount++;

        // Emit provider registration event
        emit ProviderRegistered(providerId, msg.sender);

        // Add the initial product using shared logic
        _validateAndStoreProduct(providerId, productType, productData, capabilityKeys, capabilityValues);

        // Extract serviceUrl for event
        string memory serviceUrl = "";
        if (productType == ProductType.PDP) {
            PDPOffering memory pdpOffering = abi.decode(productData, (PDPOffering));
            serviceUrl = pdpOffering.serviceURL;
        }

        emit ProductAdded(providerId, productType, serviceUrl, msg.sender, capabilityKeys, capabilityValues);

        // Burn the registration fee
        (bool burnSuccess,) = BURN_ACTOR.call{value: REGISTRATION_FEE}("");
        require(burnSuccess, "Burn failed");
    }

    /// @notice Add a new product to an existing provider
    /// @param productType The type of product to add
    /// @param productData The encoded product configuration data
    /// @param capabilityKeys Array of capability keys (max 32 chars each, max 10 keys)
    /// @param capabilityValues Array of capability values (max 128 chars each, max 10 values)
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

    /// @notice Internal function to add a product with validation
    function _addProduct(
        uint256 providerId,
        ProductType productType,
        bytes memory productData,
        string[] memory capabilityKeys,
        string[] memory capabilityValues
    ) private providerExists(providerId) providerActive(providerId) onlyProviderBeneficiary(providerId) {
        // Check product doesn't already exist
        require(!providerProducts[providerId][productType].isActive, "Product already exists for this provider");

        // Validate and store product
        _validateAndStoreProduct(providerId, productType, productData, capabilityKeys, capabilityValues);

        // Extract serviceUrl for event
        string memory serviceUrl = "";
        if (productType == ProductType.PDP) {
            PDPOffering memory pdpOffering = abi.decode(productData, (PDPOffering));
            serviceUrl = pdpOffering.serviceURL;
        }

        // Emit event
        emit ProductAdded(
            providerId, productType, serviceUrl, providers[providerId].beneficiary, capabilityKeys, capabilityValues
        );
    }

    /// @notice Internal function to validate and store a product (used by both register and add)
    function _validateAndStoreProduct(
        uint256 providerId,
        ProductType productType,
        bytes memory productData,
        string[] memory capabilityKeys,
        string[] memory capabilityValues
    ) private {
        // Validate product data
        _validateProductData(productType, productData);

        // Validate capability k/v pairs
        _validateCapabilities(capabilityKeys, capabilityValues);

        // Store product
        providerProducts[providerId][productType] = ServiceProduct({
            productType: productType,
            productData: productData,
            capabilityKeys: capabilityKeys,
            isActive: true
        });

        // Store capability values in mapping
        mapping(string => string) storage capabilities = productCapabilities[providerId][productType];
        for (uint256 i = 0; i < capabilityKeys.length; i++) {
            capabilities[capabilityKeys[i]] = capabilityValues[i];
        }

        // Increment product type provider counts
        productTypeProviderCount[productType]++;
        activeProductTypeProviderCount[productType]++;
    }

    /// @notice Update an existing product configuration
    /// @param productType The type of product to update
    /// @param productData The new encoded product configuration data
    /// @param capabilityKeys Array of capability keys (max 32 chars each, max 10 keys)
    /// @param capabilityValues Array of capability values (max 128 chars each, max 10 values)
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
    ) private providerExists(providerId) providerActive(providerId) onlyProviderBeneficiary(providerId) {
        // Cache product storage reference
        ServiceProduct storage product = providerProducts[providerId][productType];

        // Check product exists
        require(product.isActive, "Product does not exist for this provider");

        // Validate product data
        _validateProductData(productType, productData);

        // Validate capability k/v pairs
        _validateCapabilities(capabilityKeys, capabilityValues);

        // Clear old capabilities from mapping
        mapping(string => string) storage capabilities = productCapabilities[providerId][productType];
        for (uint256 i = 0; i < product.capabilityKeys.length; i++) {
            delete capabilities[product.capabilityKeys[i]];
        }

        // Update product
        product.productType = productType;
        product.productData = productData;
        product.capabilityKeys = capabilityKeys;
        product.isActive = true;

        // Store new capability values in mapping
        for (uint256 i = 0; i < capabilityKeys.length; i++) {
            capabilities[capabilityKeys[i]] = capabilityValues[i];
        }

        // Extract serviceUrl for event
        string memory serviceUrl = "";
        if (productType == ProductType.PDP) {
            PDPOffering memory pdpOffering = abi.decode(productData, (PDPOffering));
            serviceUrl = pdpOffering.serviceURL;
        }

        // Emit event
        emit ProductUpdated(
            providerId, productType, serviceUrl, providers[providerId].beneficiary, capabilityKeys, capabilityValues
        );
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
        onlyProviderBeneficiary(providerId)
    {
        // Check product exists
        require(providerProducts[providerId][productType].isActive, "Product does not exist for this provider");

        // Clear capabilities from mapping
        ServiceProduct storage product = providerProducts[providerId][productType];
        mapping(string => string) storage capabilities = productCapabilities[providerId][productType];
        for (uint256 i = 0; i < product.capabilityKeys.length; i++) {
            delete capabilities[product.capabilityKeys[i]];
        }

        // Mark product as inactive
        providerProducts[providerId][productType].isActive = false;

        // Decrement active product type provider count
        activeProductTypeProviderCount[productType]--;

        // Emit event
        emit ProductRemoved(providerId, productType);
    }

    /// @notice Update PDP service configuration with capabilities
    /// @param pdpOffering The new PDP service configuration
    /// @param capabilityKeys Array of capability keys (max 32 chars each, max 10 keys)
    /// @param capabilityValues Array of capability values (max 128 chars each, max 10 values)
    function updatePDPServiceWithCapabilities(
        PDPOffering memory pdpOffering,
        string[] memory capabilityKeys,
        string[] memory capabilityValues
    ) external {
        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        bytes memory encodedData = encodePDPOffering(pdpOffering);
        _updateProduct(providerId, ProductType.PDP, encodedData, capabilityKeys, capabilityValues);
    }

    /// @notice Update provider information
    /// @param name New provider name (optional, max 128 chars)
    /// @param description New provider description (max 256 chars)
    function updateProviderInfo(string calldata name, string calldata description) external {
        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");
        require(providerId > 0 && providerId <= numProviders, "Provider does not exist");
        require(providers[providerId].beneficiary != address(0), "Provider not found");
        require(providers[providerId].isActive, "Provider is not active");

        // Validate name (optional, so empty is allowed)
        require(bytes(name).length <= MAX_NAME_LENGTH, "Name too long");

        // Validate description
        require(bytes(description).length <= MAX_DESCRIPTION_LENGTH, "Description too long");

        // Update name and description
        providers[providerId].name = name;
        providers[providerId].description = description;

        // Emit event
        emit ProviderInfoUpdated(providerId);
    }

    /// @notice Transfer provider beneficiary to a new address
    /// @param newBeneficiary The address of the new beneficiary
    function transferProviderBeneficiary(address newBeneficiary) external {
        require(newBeneficiary != address(0), "New beneficiary cannot be zero address");

        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        _transferProviderBeneficiary(providerId, newBeneficiary);
    }

    /// @notice Internal function to transfer beneficiary
    function _transferProviderBeneficiary(uint256 providerId, address newBeneficiary)
        private
        providerExists(providerId)
        providerActive(providerId)
        onlyProviderBeneficiary(providerId)
    {
        // Check new beneficiary doesn't already have a provider
        require(addressToProviderId[newBeneficiary] == 0, "New beneficiary already has a provider");

        address previousBeneficiary = providers[providerId].beneficiary;

        // Update beneficiary
        providers[providerId].beneficiary = newBeneficiary;

        // Update address mappings
        delete addressToProviderId[previousBeneficiary];
        addressToProviderId[newBeneficiary] = providerId;

        // Emit event
        emit BeneficiaryTransferred(providerId, previousBeneficiary, newBeneficiary);
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
        onlyProviderBeneficiary(providerId)
    {
        // Soft delete - mark as inactive
        providers[providerId].isActive = false;

        activeProviderCount--;

        // Mark all products as inactive and clear capabilities
        // For now just PDP, but this is extensible
        if (providerProducts[providerId][ProductType.PDP].productData.length > 0) {
            ServiceProduct storage product = providerProducts[providerId][ProductType.PDP];

            // Decrement active count if product was active
            if (product.isActive) {
                activeProductTypeProviderCount[ProductType.PDP]--;
            }

            // Clear capabilities from mapping
            mapping(string => string) storage capabilities = productCapabilities[providerId][ProductType.PDP];
            for (uint256 i = 0; i < product.capabilityKeys.length; i++) {
                delete capabilities[product.capabilityKeys[i]];
            }
            product.isActive = false;
        }

        // Clear address mapping
        delete addressToProviderId[providers[providerId].beneficiary];

        // Emit event
        emit ProviderRemoved(providerId);
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
    /// @return isActive Whether the product is active
    function getProduct(uint256 providerId, ProductType productType)
        external
        view
        providerExists(providerId)
        returns (bytes memory productData, string[] memory capabilityKeys, bool isActive)
    {
        ServiceProduct memory product = providerProducts[providerId][productType];
        return (product.productData, product.capabilityKeys, product.isActive);
    }

    /// @notice Get PDP service configuration for a provider (convenience function)
    /// @param providerId The ID of the provider
    /// @return pdpOffering The decoded PDP service data
    /// @return capabilityKeys Array of capability keys
    /// @return isActive Whether the PDP service is active
    function getPDPService(uint256 providerId)
        external
        view
        providerExists(providerId)
        returns (PDPOffering memory pdpOffering, string[] memory capabilityKeys, bool isActive)
    {
        ServiceProduct memory product = providerProducts[providerId][ProductType.PDP];

        if (product.productData.length > 0) {
            pdpOffering = decodePDPOffering(product.productData);
            capabilityKeys = product.capabilityKeys;
            isActive = product.isActive;
        }
    }

    /// @notice Get all providers that offer a specific product type with pagination
    /// @param productType The product type to filter by
    /// @param offset Starting index for pagination (0-based)
    /// @param limit Maximum number of results to return
    /// @return result Paginated result containing provider details and hasMore flag
    function getProvidersByProductType(ProductType productType, uint256 offset, uint256 limit)
        external
        view
        returns (PaginatedProviders memory result)
    {
        uint256 totalCount = productTypeProviderCount[productType];

        // Handle edge cases
        if (offset >= totalCount || limit == 0) {
            result.providers = new ProviderWithProduct[](0);
            result.hasMore = false;
            return result;
        }

        // Calculate actual items to return
        uint256 itemsToReturn = limit;
        if (offset + limit > totalCount) {
            itemsToReturn = totalCount - offset;
        }

        result.providers = new ProviderWithProduct[](itemsToReturn);
        result.hasMore = (offset + itemsToReturn) < totalCount;

        // Collect providers
        uint256 currentIndex = 0;
        uint256 resultIndex = 0;

        for (uint256 i = 1; i <= numProviders && resultIndex < itemsToReturn; i++) {
            if (providerProducts[i][productType].productData.length > 0) {
                if (currentIndex >= offset && currentIndex < offset + limit) {
                    result.providers[resultIndex] = ProviderWithProduct({
                        providerId: i,
                        providerInfo: providers[i],
                        product: providerProducts[i][productType]
                    });
                    resultIndex++;
                }
                currentIndex++;
            }
        }
    }

    /// @notice Get all active providers that offer a specific product type with pagination
    /// @param productType The product type to filter by
    /// @param offset Starting index for pagination (0-based)
    /// @param limit Maximum number of results to return
    /// @return result Paginated result containing provider details and hasMore flag
    function getActiveProvidersByProductType(ProductType productType, uint256 offset, uint256 limit)
        external
        view
        returns (PaginatedProviders memory result)
    {
        uint256 totalCount = activeProductTypeProviderCount[productType];

        // Handle edge cases
        if (offset >= totalCount || limit == 0) {
            result.providers = new ProviderWithProduct[](0);
            result.hasMore = false;
            return result;
        }

        // Calculate actual items to return
        uint256 itemsToReturn = limit;
        if (offset + limit > totalCount) {
            itemsToReturn = totalCount - offset;
        }

        result.providers = new ProviderWithProduct[](itemsToReturn);
        result.hasMore = (offset + itemsToReturn) < totalCount;

        // Collect active providers
        uint256 currentIndex = 0;
        uint256 resultIndex = 0;

        for (uint256 i = 1; i <= numProviders && resultIndex < itemsToReturn; i++) {
            if (
                providers[i].isActive && providerProducts[i][productType].isActive
                    && providerProducts[i][productType].productData.length > 0
            ) {
                if (currentIndex >= offset && currentIndex < offset + limit) {
                    result.providers[resultIndex] = ProviderWithProduct({
                        providerId: i,
                        providerInfo: providers[i],
                        product: providerProducts[i][productType]
                    });
                    resultIndex++;
                }
                currentIndex++;
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

    /// @notice Get provider info by address
    /// @param providerAddress The address of the provider
    /// @return info The provider information (empty struct if not registered)
    function getProviderByAddress(address providerAddress) external view returns (ServiceProviderInfo memory info) {
        uint256 providerId = addressToProviderId[providerAddress];
        return providers[providerId];
    }

    /// @notice Get provider ID by address
    /// @param providerAddress The address of the provider
    /// @return providerId The provider ID (0 if not registered)
    function getProviderIdByAddress(address providerAddress) external view returns (uint256) {
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
        uint256 activeCount = activeProviderCount;

        // Collect active provider IDs
        activeProviderIds = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 1; i <= numProviders && index < activeCount; i++) {
            if (providers[i].isActive) {
                activeProviderIds[index++] = i;
            }
        }
    }

    /// @notice Get all active providers with pagination
    /// @param offset Starting index for pagination (0-based)
    /// @param limit Maximum number of results to return
    /// @return providerIds Array of active provider IDs
    /// @return hasMore Whether there are more results after this page
    function getAllActiveProvidersPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory providerIds, bool hasMore)
    {
        uint256 totalCount = activeProviderCount;

        if (offset >= totalCount || limit == 0) {
            providerIds = new uint256[](0);
            hasMore = false;
            return (providerIds, hasMore);
        }

        uint256 itemsToReturn = limit;
        if (offset + limit > totalCount) {
            itemsToReturn = totalCount - offset;
        }

        providerIds = new uint256[](itemsToReturn);
        hasMore = (offset + itemsToReturn) < totalCount;

        uint256 currentIndex = 0;
        uint256 resultIndex = 0;

        for (uint256 i = 1; i <= numProviders && resultIndex < itemsToReturn; i++) {
            if (providers[i].isActive) {
                if (currentIndex >= offset && currentIndex < offset + limit) {
                    providerIds[resultIndex++] = i;
                }
                currentIndex++;
            }
        }
    }

    /// @notice Get total number of registered providers (including inactive)
    /// @return The total count of providers
    function getProviderCount() external view returns (uint256) {
        return numProviders;
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
        return numProviders + 1;
    }

    /// @notice Get multiple capability values for a product
    /// @param providerId The ID of the provider
    /// @param productType The type of product
    /// @param keys Array of capability keys to query
    /// @return exists Array of booleans indicating whether each key exists
    /// @return values Array of capability values corresponding to the keys (empty string for non-existent keys)
    function getProductCapabilities(uint256 providerId, ProductType productType, string[] calldata keys)
        external
        view
        providerExists(providerId)
        returns (bool[] memory exists, string[] memory values)
    {
        exists = new bool[](keys.length);
        values = new string[](keys.length);

        // Cache the mapping reference
        mapping(string => string) storage capabilities = productCapabilities[providerId][productType];

        for (uint256 i = 0; i < keys.length; i++) {
            string memory value = capabilities[keys[i]];
            if (bytes(value).length > 0) {
                exists[i] = true;
                values[i] = value;
            }
        }
    }

    /// @notice Get a single capability value for a product
    /// @param providerId The ID of the provider
    /// @param productType The type of product
    /// @param key The capability key to query
    /// @return exists Whether the capability key exists
    /// @return value The capability value (empty string if key doesn't exist)
    function getProductCapability(uint256 providerId, ProductType productType, string calldata key)
        external
        view
        providerExists(providerId)
        returns (bool exists, string memory value)
    {
        // Directly check the mapping
        value = productCapabilities[providerId][productType][key];
        exists = bytes(value).length > 0;
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
        // Validate new fields
        require(pdpOffering.minProvingPeriodInEpochs > 0, "Min proving period must be greater than 0");
        require(bytes(pdpOffering.location).length > 0, "Location cannot be empty");
        require(bytes(pdpOffering.location).length <= MAX_LOCATION_LENGTH, "Location too long");
    }

    /// @notice Validate capability key-value pairs
    /// @param keys Array of capability keys
    /// @param values Array of capability values
    function _validateCapabilities(string[] memory keys, string[] memory values) private pure {
        require(keys.length == values.length, "Keys and values arrays must have same length");
        require(keys.length <= MAX_CAPABILITIES, "Too many capabilities");

        for (uint256 i = 0; i < keys.length; i++) {
            require(bytes(keys[i]).length > 0, "Capability key cannot be empty");
            require(bytes(keys[i]).length <= MAX_CAPABILITY_KEY_LENGTH, "Capability key too long");
            require(bytes(values[i]).length <= MAX_CAPABILITY_VALUE_LENGTH, "Capability value too long");
        }
    }

    /// @notice Encode PDP offering to bytes
    function encodePDPOffering(PDPOffering memory pdpOffering) public pure returns (bytes memory) {
        return abi.encode(pdpOffering);
    }

    /// @notice Decode PDP offering from bytes
    function decodePDPOffering(bytes memory data) public pure returns (PDPOffering memory) {
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
