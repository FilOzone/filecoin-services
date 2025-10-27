// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {FVMPay} from "@fvm-solidity/FVMPay.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {BloomSet16} from "./lib/BloomSet.sol";
import {Errors} from "./Errors.sol";
import {ServiceProviderRegistryStorage} from "./ServiceProviderRegistryStorage.sol";

/// @dev Required PDP Keys (validated by REQUIRED_PDP_KEYS Bloom filter):
/// - serviceURL: the API endpoint
/// - minPieceSizeInBytes: minimum piece size in bytes
/// - maxPieceSizeInBytes: maximum piece size in bytes
/// - storagePricePerTibPerDay: Storage price per TiB per day (in token's smallest unit)
/// - minProvingPeriodInEpochs: Minimum proving period in epochs
/// - location: Geographic location of the service provider
/// - paymentTokenAddress: Token contract for payment (IERC20(address(0)) for FIL)
/// Optional PDP keys (not validated by Bloom filter):
/// - ipniPiece: Supports IPNI piece CID indexing
/// - ipniIpfs: Supports IPNI IPFS CID indexing
/// - ipniPeerId: IPNI peer ID

// Bloom filter representing the required keys for PDP
uint256 constant REQUIRED_PDP_KEYS = 0x5b6a06f24dd05729018c808802020eb60947d813531db3c45b14504401400102;

/// @title ServiceProviderRegistry
/// @notice A registry contract for managing service providers across the Filecoin Services ecosystem
contract ServiceProviderRegistry is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    EIP712Upgradeable,
    ServiceProviderRegistryStorage
{
    /// @notice Provider information for API returns
    struct ServiceProviderInfoView {
        uint256 providerId; // Provider ID
        ServiceProviderInfo info; // Nested provider information
    }

    /// @notice Version of the contract implementation
    string public constant VERSION = "0.3.0";

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
    uint256 public constant MAX_CAPABILITIES = 24;

    /// @notice Maximum length for location field
    uint256 private constant MAX_LOCATION_LENGTH = 128;

    /// @notice Registration fee in attoFIL (5 FIL = 5 * 10^18 attoFIL)
    uint256 public constant REGISTRATION_FEE = 5e18;

    /// @notice Emitted when a new provider registers
    event ProviderRegistered(uint256 indexed providerId, address indexed serviceProvider, address indexed payee);

    /// @notice Emitted when a product is updated or added
    event ProductUpdated(
        uint256 indexed providerId,
        ProductType indexed productType,
        address serviceProvider,
        string[] capabilityKeys,
        bytes[] capabilityValues
    );

    /// @notice Emitted when a product is added to an existing provider
    event ProductAdded(
        uint256 indexed providerId,
        ProductType indexed productType,
        address serviceProvider,
        string[] capabilityKeys,
        bytes[] capabilityValues
    );

    /// @notice Emitted when a product is removed from a provider
    event ProductRemoved(uint256 indexed providerId, ProductType indexed productType);

    /// @notice Emitted when provider info is updated
    event ProviderInfoUpdated(uint256 indexed providerId);

    /// @notice Emitted when a provider is removed
    event ProviderRemoved(uint256 indexed providerId);

    /// @notice Emitted when the contract is upgraded
    event ContractUpgraded(string version, address implementation);

    /// @notice Ensures the caller is the service provider
    modifier onlyServiceProvider(uint256 providerId) {
        require(providers[providerId].serviceProvider == msg.sender, "Only service provider can call this function");
        _;
    }

    /// @notice Ensures the provider exists
    modifier providerExists(uint256 providerId) {
        require(providerId > 0 && providerId <= numProviders, "Provider does not exist");
        require(providers[providerId].serviceProvider != address(0), "Provider not found");
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
    /// @param payee Address that will receive payments (cannot be changed after registration)
    /// @param name Provider name (optional, max 128 chars)
    /// @param description Provider description (max 256 chars)
    /// @param productType The type of product to register
    /// @param capabilityKeys Array of capability keys
    /// @param capabilityValues Array of capability values
    /// @return providerId The unique ID assigned to the provider
    function registerProvider(
        address payee,
        string calldata name,
        string calldata description,
        ProductType productType,
        string[] calldata capabilityKeys,
        bytes[] calldata capabilityValues
    ) external payable returns (uint256 providerId) {
        // Only support PDP for now
        require(productType == ProductType.PDP, "Only PDP product type currently supported");

        // Validate payee address
        require(payee != address(0), "Payee cannot be zero address");

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
        providers[providerId] = ServiceProviderInfo({
            serviceProvider: msg.sender,
            payee: payee,
            name: name,
            description: description,
            isActive: true
        });

        // Update address mapping
        addressToProviderId[msg.sender] = providerId;

        activeProviderCount++;

        // Emit provider registration event
        emit ProviderRegistered(providerId, msg.sender, payee);

        // Add the initial product using shared logic
        _validateAndStoreProduct(providerId, productType, capabilityKeys, capabilityValues);

        // msg.sender is also providers[providerId].serviceProvider
        emit ProductAdded(providerId, productType, msg.sender, capabilityKeys, capabilityValues);

        // Burn the registration fee
        require(FVMPay.burn(REGISTRATION_FEE), "Burn failed");
    }

    /// @notice Add a new product to an existing provider
    /// @param productType The type of product to add
    /// @param capabilityKeys Array of capability keys (max 32 chars each, max 10 keys)
    /// @param capabilityValues Array of capability values (max 128 chars each, max 10 values)
    function addProduct(ProductType productType, string[] calldata capabilityKeys, bytes[] calldata capabilityValues)
        external
    {
        // Only support PDP for now
        require(productType == ProductType.PDP, "Only PDP product type currently supported");

        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        _addProduct(providerId, productType, capabilityKeys, capabilityValues);
    }

    /// @notice Internal function to add a product with validation
    function _addProduct(
        uint256 providerId,
        ProductType productType,
        string[] memory capabilityKeys,
        bytes[] calldata capabilityValues
    ) private providerExists(providerId) providerActive(providerId) onlyServiceProvider(providerId) {
        // Check product doesn't already exist
        require(!providerProducts[providerId][productType].isActive, "Product already exists for this provider");

        // Validate and store product
        _validateAndStoreProduct(providerId, productType, capabilityKeys, capabilityValues);

        // msg.sender is providers[providerId].serviceProvider, because onlyServiceProvider
        emit ProductAdded(providerId, productType, msg.sender, capabilityKeys, capabilityValues);
    }

    /// @notice Internal function to validate and store a product (used by both register and add)
    function _validateAndStoreProduct(
        uint256 providerId,
        ProductType productType,
        string[] memory capabilityKeys,
        bytes[] calldata capabilityValues
    ) private {
        // Validate capability k/v pairs
        _validateCapabilities(capabilityKeys, capabilityValues);

        // Validate product data
        _validateProductKeys(productType, capabilityKeys);

        // Store product
        providerProducts[providerId][productType] =
            ServiceProduct({productType: productType, capabilityKeys: capabilityKeys, isActive: true});

        // Store capability values in mapping
        mapping(string => bytes) storage capabilities = productCapabilities[providerId][productType];
        for (uint256 i = 0; i < capabilityKeys.length; i++) {
            capabilities[capabilityKeys[i]] = capabilityValues[i];
        }

        // Increment product type provider counts
        productTypeProviderCount[productType]++;
        activeProductTypeProviderCount[productType]++;
    }

    /// @notice Update an existing product configuration
    /// @param productType The type of product to update
    /// @param capabilityKeys Array of capability keys (max 32 chars each, max 10 keys)
    /// @param capabilityValues Array of capability values (max 128 chars each, max 10 values)
    function updateProduct(ProductType productType, string[] calldata capabilityKeys, bytes[] calldata capabilityValues)
        external
    {
        // Only support PDP for now
        require(productType == ProductType.PDP, "Only PDP product type currently supported");

        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");

        _updateProduct(providerId, productType, capabilityKeys, capabilityValues);
    }

    /// @notice Internal function to update a product
    function _updateProduct(
        uint256 providerId,
        ProductType productType,
        string[] memory capabilityKeys,
        bytes[] calldata capabilityValues
    ) private providerExists(providerId) providerActive(providerId) onlyServiceProvider(providerId) {
        // Cache product storage reference
        ServiceProduct storage product = providerProducts[providerId][productType];

        // Check product exists
        require(product.isActive, "Product does not exist for this provider");

        // Validate product data
        _validateProductKeys(productType, capabilityKeys);

        // Validate capability k/v pairs
        _validateCapabilities(capabilityKeys, capabilityValues);

        // Clear old capabilities from mapping
        mapping(string => bytes) storage capabilities = productCapabilities[providerId][productType];
        for (uint256 i = 0; i < product.capabilityKeys.length; i++) {
            delete capabilities[product.capabilityKeys[i]];
        }

        // Update product
        product.productType = productType;
        product.capabilityKeys = capabilityKeys;
        product.isActive = true;

        // Store new capability values in mapping
        for (uint256 i = 0; i < capabilityKeys.length; i++) {
            capabilities[capabilityKeys[i]] = capabilityValues[i];
        }

        // msg.sender is also providers[providerId].serviceProvider, because onlyServiceProvider
        emit ProductUpdated(providerId, productType, msg.sender, capabilityKeys, capabilityValues);
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
        onlyServiceProvider(providerId)
    {
        // Check product exists
        require(providerProducts[providerId][productType].isActive, "Product does not exist for this provider");

        // Clear capabilities from mapping
        ServiceProduct storage product = providerProducts[providerId][productType];
        mapping(string => bytes) storage capabilities = productCapabilities[providerId][productType];
        for (uint256 i = 0; i < product.capabilityKeys.length; i++) {
            delete capabilities[product.capabilityKeys[i]];
        }

        // Mark product as inactive
        providerProducts[providerId][productType].isActive = false;

        // Decrement active product type provider count
        activeProductTypeProviderCount[productType]--;

        delete providerProducts[providerId][productType];

        // Emit event
        emit ProductRemoved(providerId, productType);
    }

    /// @notice Update provider information
    /// @param name New provider name (optional, max 128 chars)
    /// @param description New provider description (max 256 chars)
    function updateProviderInfo(string calldata name, string calldata description) external {
        uint256 providerId = addressToProviderId[msg.sender];
        require(providerId != 0, "Provider not registered");
        require(providerId > 0 && providerId <= numProviders, "Provider does not exist");
        require(providers[providerId].serviceProvider != address(0), "Provider not found");
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
        onlyServiceProvider(providerId)
    {
        // Soft delete - mark as inactive
        providers[providerId].isActive = false;

        activeProviderCount--;

        // Mark all products as inactive and clear capabilities
        // For now just PDP, but this is extensible
        ServiceProduct storage product = providerProducts[providerId][ProductType.PDP];
        if (product.isActive) {
            // Decrement active count if product was active
            activeProductTypeProviderCount[ProductType.PDP]--;

            // Clear capabilities from mapping
            mapping(string => bytes) storage capabilities = productCapabilities[providerId][ProductType.PDP];
            for (uint256 i = 0; i < product.capabilityKeys.length; i++) {
                delete capabilities[product.capabilityKeys[i]];
            }
            delete product.productType;
            delete product.capabilityKeys;
            delete product.isActive;
        }

        // Clear address mapping
        delete addressToProviderId[providers[providerId].serviceProvider];

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
        returns (ServiceProviderInfoView memory info)
    {
        ServiceProviderInfo storage provider = providers[providerId];
        return ServiceProviderInfoView({providerId: providerId, info: provider});
    }

    /// @notice Get only the payee address for a provider
    /// @param providerId The ID of the provider
    /// @return payee The payee address
    function getProviderPayee(uint256 providerId) external view providerExists(providerId) returns (address payee) {
        return providers[providerId].payee;
    }

    /// @notice Get complete provider and product information
    /// @param providerId The ID of the provider
    /// @param productType The type of product to retrieve
    /// @return Complete provider with product information
    function getProviderWithProduct(uint256 providerId, ProductType productType)
        external
        view
        providerExists(providerId)
        returns (ProviderWithProduct memory)
    {
        ServiceProviderInfo storage provider = providers[providerId];
        ServiceProduct storage product = providerProducts[providerId][productType];

        return ProviderWithProduct({
            providerId: providerId,
            providerInfo: provider,
            product: product,
            productCapabilityValues: getProductCapabilities(providerId, productType, product.capabilityKeys)
        });
    }

    /// @notice Get providers that offer a specific product type with pagination
    /// @param productType The product type to filter by
    /// @param onlyActive If true, return only active providers with active products
    /// @param offset Starting index for pagination (0-based)
    /// @param limit Maximum number of results to return
    /// @return result Paginated result containing provider details and hasMore flag
    function getProvidersByProductType(ProductType productType, bool onlyActive, uint256 offset, uint256 limit)
        external
        view
        returns (PaginatedProviders memory result)
    {
        uint256 totalCount =
            onlyActive ? activeProductTypeProviderCount[productType] : productTypeProviderCount[productType];

        // Handle edge cases
        if (offset >= totalCount || limit == 0) {
            result.providers = new ProviderWithProduct[](0);
            result.hasMore = false;
            return result;
        }

        // Calculate actual items to return
        if (offset + limit > totalCount) {
            limit = totalCount - offset;
        }

        result.providers = new ProviderWithProduct[](limit);
        result.hasMore = (offset + limit) < totalCount;

        // Collect providers
        uint256 currentIndex = 0;
        uint256 resultIndex = 0;

        for (uint256 i = 1; i <= numProviders && resultIndex < limit; i++) {
            bool matches = onlyActive
                ? (providers[i].isActive && providerProducts[i][productType].isActive)
                : providerProducts[i][productType].isActive;

            if (matches) {
                if (currentIndex >= offset && currentIndex < offset + limit) {
                    ServiceProviderInfo storage provider = providers[i];
                    ServiceProduct storage product = providerProducts[i][productType];
                    result.providers[resultIndex] = ProviderWithProduct({
                        providerId: i,
                        providerInfo: provider,
                        product: product,
                        productCapabilityValues: getProductCapabilities(i, productType, product.capabilityKeys)
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
    /// @param providerAddress The address of the service provider
    /// @return info The provider information (empty struct if not registered)
    function getProviderByAddress(address providerAddress)
        external
        view
        returns (ServiceProviderInfoView memory info)
    {
        uint256 providerId = addressToProviderId[providerAddress];
        if (providerId == 0) {
            return _getEmptyProviderInfoView();
        }

        ServiceProviderInfo storage provider = providers[providerId];
        return ServiceProviderInfoView({providerId: providerId, info: provider});
    }

    /// @notice Get provider ID by address
    /// @param providerAddress The address of the service provider
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

    /// @notice Get all active providers with pagination
    /// @param offset Starting index for pagination (0-based)
    /// @param limit Maximum number of results to return
    /// @return providerIds Array of active provider IDs
    /// @return hasMore Whether there are more results after this page
    function getAllActiveProviders(uint256 offset, uint256 limit)
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

        if (offset + limit > totalCount) {
            limit = totalCount - offset;
        }

        providerIds = new uint256[](limit);
        hasMore = (offset + limit) < totalCount;

        uint256 currentIndex = 0;
        uint256 resultIndex = 0;

        for (uint256 i = 1; i <= numProviders && resultIndex < limit; i++) {
            if (providers[i].isActive) {
                if (currentIndex >= offset && currentIndex < offset + limit) {
                    providerIds[resultIndex++] = i;
                }
                currentIndex++;
            }
        }
    }

    /// @notice Get multiple providers by their IDs
    /// @param providerIds Array of provider IDs to retrieve
    /// @return providerInfos Array of provider information corresponding to the input IDs
    /// @return validIds Array of booleans indicating whether each ID is valid (exists and is active)
    /// @dev Returns empty ServiceProviderInfoView structs for invalid IDs, with corresponding validIds[i] = false
    function getProvidersByIds(uint256[] calldata providerIds)
        external
        view
        returns (ServiceProviderInfoView[] memory providerInfos, bool[] memory validIds)
    {
        uint256 length = providerIds.length;
        providerInfos = new ServiceProviderInfoView[](length);
        validIds = new bool[](length);

        uint256 _numProviders = numProviders;

        for (uint256 i = 0; i < length; i++) {
            uint256 providerId = providerIds[i];

            if (providerId > 0 && providerId <= _numProviders) {
                ServiceProviderInfo storage provider = providers[providerId];
                if (provider.serviceProvider != address(0) && provider.isActive) {
                    providerInfos[i] = ServiceProviderInfoView({providerId: providerId, info: provider});
                    validIds[i] = true;
                } else {
                    providerInfos[i] = _getEmptyProviderInfoView();
                    validIds[i] = false;
                }
            } else {
                providerInfos[i] = _getEmptyProviderInfoView();
                validIds[i] = false;
            }
        }
    }

    /// @notice Get multiple providers with product information by their IDs
    /// @param providerIds Array of provider IDs to retrieve
    /// @param productType The type of product to include in the response
    /// @return providersWithProducts Array of provider and product information corresponding to the input IDs
    /// @return validIds Array of booleans indicating whether each ID is valid (exists, is active, and has the product)
    /// @dev Returns empty ProviderWithProduct structs for invalid IDs, with corresponding validIds[i] = false
    function getProvidersWithProductByIds(uint256[] calldata providerIds, ProductType productType)
        external
        view
        returns (ProviderWithProduct[] memory providersWithProducts, bool[] memory validIds)
    {
        uint256 length = providerIds.length;
        providersWithProducts = new ProviderWithProduct[](length);
        validIds = new bool[](length);

        uint256 _numProviders = numProviders;

        for (uint256 i = 0; i < length; i++) {
            uint256 providerId = providerIds[i];

            if (providerId > 0 && providerId <= _numProviders) {
                ServiceProviderInfo storage provider = providers[providerId];
                ServiceProduct storage product = providerProducts[providerId][productType];

                if (provider.serviceProvider != address(0) && provider.isActive && product.isActive) {
                    providersWithProducts[i] = ProviderWithProduct({
                        providerId: providerId,
                        providerInfo: provider,
                        product: product,
                        productCapabilityValues: getProductCapabilities(providerId, productType, product.capabilityKeys)
                    });
                    validIds[i] = true;
                } else {
                    providersWithProducts[i] = _getEmptyProviderWithProduct();
                    validIds[i] = false;
                }
            } else {
                providersWithProducts[i] = _getEmptyProviderWithProduct();
                validIds[i] = false;
            }
        }
    }

    /// @notice Internal helper to create an empty ProviderWithProduct
    /// @return Empty ProviderWithProduct struct
    function _getEmptyProviderWithProduct() internal pure returns (ProviderWithProduct memory) {
        return ProviderWithProduct({
            providerId: 0,
            providerInfo: ServiceProviderInfo({
                serviceProvider: address(0),
                payee: address(0),
                name: "",
                description: "",
                isActive: false
            }),
            product: ServiceProduct({productType: ProductType.PDP, capabilityKeys: new string[](0), isActive: false}),
            productCapabilityValues: new bytes[](0)
        });
    }

    /// @notice Internal helper to create an empty ServiceProviderInfoView
    /// @return Empty ServiceProviderInfoView struct
    function _getEmptyProviderInfoView() internal pure returns (ServiceProviderInfoView memory) {
        return ServiceProviderInfoView({
            providerId: 0,
            info: ServiceProviderInfo({
                serviceProvider: address(0),
                payee: address(0),
                name: "",
                description: "",
                isActive: false
            })
        });
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
    /// @return values Array of capability values corresponding to the keys (empty string for non-existent keys)
    function getProductCapabilities(uint256 providerId, ProductType productType, string[] memory keys)
        public
        view
        providerExists(providerId)
        returns (bytes[] memory values)
    {
        values = new bytes[](keys.length);

        // Cache the mapping reference
        mapping(string => bytes) storage capabilities = productCapabilities[providerId][productType];

        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = capabilities[keys[i]];
        }
    }

    /// @notice Get all capability keys and values for a product
    /// @param providerId The ID of the provider
    /// @param productType The type of product
    /// @return isActive Whether the product is active
    /// @return keys Array of all capability keys of the product
    /// @return values Array of capability values corresponding to the keys
    function getAllProductCapabilities(uint256 providerId, ProductType productType)
        external
        view
        providerExists(providerId)
        returns (bool isActive, string[] memory keys, bytes[] memory values)
    {
        ServiceProduct storage product = providerProducts[providerId][productType];
        isActive = product.isActive;
        keys = product.capabilityKeys;
        values = new bytes[](keys.length);

        mapping(string => bytes) storage capabilities = productCapabilities[providerId][productType];
        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = capabilities[keys[i]];
        }
    }

    /// @notice Validate product data based on product type
    /// @param productType The type of product
    function _validateProductKeys(ProductType productType, string[] memory capabilityKeys) private pure {
        uint256 requiredKeys;
        if (productType == ProductType.PDP) {
            requiredKeys = REQUIRED_PDP_KEYS;
        } else {
            revert("Unsupported product type");
        }
        uint256 foundKeys = BloomSet16.EMPTY;
        for (uint256 i = 0; i < capabilityKeys.length; i++) {
            uint256 key = BloomSet16.compressed(capabilityKeys[i]);
            if (BloomSet16.mayContain(requiredKeys, key)) {
                foundKeys |= key;
            }
        }
        // Enforce minimum schema
        require(BloomSet16.mayContain(foundKeys, requiredKeys), Errors.InsufficientCapabilitiesForProduct(productType));
    }

    /// @notice Validate capability key-value pairs
    /// @param keys Array of capability keys
    /// @param values Array of capability values
    function _validateCapabilities(string[] memory keys, bytes[] calldata values) private pure {
        require(keys.length == values.length, "Keys and values arrays must have same length");
        require(keys.length <= MAX_CAPABILITIES, "Too many capabilities");

        for (uint256 i = 0; i < keys.length; i++) {
            require(bytes(keys[i]).length > 0, "Capability key cannot be empty");
            require(bytes(keys[i]).length <= MAX_CAPABILITY_KEY_LENGTH, "Capability key too long");
            require(values[i].length > 0, "Capability value cannot be empty");
            require(values[i].length <= MAX_CAPABILITY_VALUE_LENGTH, "Capability value too long");
        }
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
