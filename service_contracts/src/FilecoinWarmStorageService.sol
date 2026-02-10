// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {PDPListener} from "@pdp/PDPVerifier.sol";
import {IPDPVerifier} from "@pdp/interfaces/IPDPVerifier.sol";
import {Cids} from "@pdp/Cids.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {Errors} from "./Errors.sol";

import {ServiceProviderRegistry} from "./ServiceProviderRegistry.sol";

import {Extsload} from "./Extsload.sol";

import {SignatureVerificationLib} from "./lib/SignatureVerificationLib.sol";

uint256 constant NO_PROVING_DEADLINE = 0;
uint256 constant BYTES_PER_LEAF = 32; // Each leaf is 32 bytes
uint64 constant CHALLENGES_PER_PROOF = 5;
uint256 constant COMMISSION_MAX_BPS = 10000; // 100% in basis points

/*
* Maximum extraData for createDataSet
* Supports: 10 metadata entries with max sizes
*/
uint256 constant MAX_CREATE_DATA_SET_EXTRA_DATA_SIZE = 4096; // 4 KiB

/*
* Maximum extraData for addPieces
* Supports: 5 pieces with full metadata, or 61 pieces with no metadata
*/
uint256 constant MAX_ADD_PIECES_EXTRA_DATA_SIZE = 8192; // 8 KiB

/*
* Maximum extraData for schedulePieceRemovals
* Supports: signature (160 bytes needed)
*/
uint256 constant MAX_SCHEDULE_PIECE_REMOVALS_EXTRA_DATA_SIZE = 256; // 256 bytes

/// @title FilecoinWarmStorageService
/// @notice An implementation of PDP Listener with payment integration.
/// @dev This contract extends SimplePDPService by adding payment functionality
/// using the FilecoinPayV1 contract. It creates payment rails for service providers
/// and adjusts payment rates based on storage size. Also implements validation
/// to reduce payments for faulted epochs.
contract FilecoinWarmStorageService is
    PDPListener,
    IValidator,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    Extsload,
    EIP712Upgradeable
{
    // Version tracking
    string public constant VERSION = "1.0.0";

    // =========================================================================
    // Events

    event ContractUpgraded(string version, address implementation);
    event FilecoinServiceDeployed(string name, string description);
    event DataSetServiceProviderChanged(
        uint256 indexed dataSetId, address indexed oldServiceProvider, address indexed newServiceProvider
    );
    event FaultRecord(uint256 indexed dataSetId, uint256 periodsFaulted, uint256 deadline);
    event DataSetCreated(
        uint256 indexed dataSetId,
        uint256 indexed providerId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId,
        address payer,
        address serviceProvider,
        address payee,
        string[] metadataKeys,
        string[] metadataValues
    );
    event RailRateUpdated(uint256 indexed dataSetId, uint256 railId, uint256 newRate);
    event PieceAdded(
        uint256 indexed dataSetId, uint256 indexed pieceId, Cids.Cid pieceCid, string[] keys, string[] values
    );

    event ServiceTerminated(
        address indexed caller, uint256 indexed dataSetId, uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId
    );

    event CDNServiceTerminated(
        address indexed caller, uint256 indexed dataSetId, uint256 cacheMissRailId, uint256 cdnRailId
    );

    event PDPPaymentTerminated(uint256 indexed dataSetId, uint256 endEpoch, uint256 pdpRailId);

    event CDNPaymentTerminated(uint256 indexed dataSetId, uint256 endEpoch, uint256 cacheMissRailId, uint256 cdnRailId);

    event FilBeamControllerChanged(address oldController, address newController);

    event ViewContractSet(address indexed viewContract);

    event CDNPaymentRailsToppedUp(
        uint256 indexed dataSetId,
        uint256 cdnAmountAdded,
        uint256 totalCdnLockup,
        uint256 cacheMissAmountAdded,
        uint256 totalCacheMissLockup
    );

    // Events for provider management
    event ProviderApproved(uint256 indexed providerId);
    event ProviderUnapproved(uint256 indexed providerId);

    event PricingUpdated(uint256 storagePrice, uint256 minimumRate);

    // =========================================================================
    // Structs

    // Storage for data set payment information
    struct DataSetInfo {
        uint256 pdpRailId; // ID of the PDP payment rail
        uint256 cacheMissRailId; // For CDN add-on: ID of the cache miss payment rail, which rewards the SP for serving data to the CDN when it doesn't already have it cached
        uint256 cdnRailId; // For CDN add-on: ID of the CDN payment rail, which rewards the CDN for serving data to clients
        address payer; // Address paying for storage
        address payee; // SP's beneficiary address
        address serviceProvider; // Current service provider of the dataset
        uint256 commissionBps; // Commission rate for this data set (dynamic based on whether the client purchases CDN add-on)
        uint256 clientDataSetId; // ClientDataSetID
        uint256 pdpEndEpoch; // 0 if PDP rail are not terminated
        uint256 providerId; // Provider ID from the ServiceProviderRegistry
    }

    // Storage for data set payment information with dataSetId
    struct DataSetInfoView {
        uint256 pdpRailId; // ID of the PDP payment rail
        uint256 cacheMissRailId; // For CDN add-on: ID of the cache miss payment rail, which rewards the SP for serving data to the CDN when it doesn't already have it cached
        uint256 cdnRailId; // For CDN add-on: ID of the CDN payment rail, which rewards the CDN for serving data to clients
        address payer; // Address paying for storage
        address payee; // SP's beneficiary address
        address serviceProvider; // Current service provider of the dataset
        uint256 commissionBps; // Commission rate for this data set (dynamic based on whether the client purchases CDN add-on)
        uint256 clientDataSetId; // ClientDataSetID
        uint256 pdpEndEpoch; // 0 if PDP rail are not terminated
        uint256 providerId; // Provider ID from the ServiceProviderRegistry
        uint256 dataSetId; // DataSet ID
    }

    enum DataSetStatus {
        // Dataset is inactive: non-existent (pdpRailId==0) or no pieces added yet (rate==0, no proving)
        Inactive,
        // Dataset has pieces and proving history (includes datasets in process of being terminated)
        // Note: Datasets being terminated remain Active - they become Inactive after deletion when data is wiped
        Active
    }

    // Decode structure for data set creation extra data
    struct DataSetCreateData {
        // The address of the payer who should have signed the message
        address payer;
        // the unique ID for the client's data set
        uint256 clientDataSetId;
        // Array of metadata keys
        string[] metadataKeys;
        // Array of metadata values
        string[] metadataValues;
        // The signature bytes (v, r, s)
        bytes signature;
    }

    // Structure for service pricing information
    struct ServicePricing {
        uint256 pricePerTiBPerMonthNoCDN; // Price without CDN add-on (2.5 USDFC per TiB per month)
        uint256 pricePerTiBCdnEgress; // CDN egress price per TiB (usage-based)
        uint256 pricePerTiBCacheMissEgress; // Cache miss egress price per TiB (usage-based)
        IERC20 tokenAddress; // Address of the USDFC token
        uint256 epochsPerMonth; // Number of epochs in a month
        uint256 minimumPricePerMonth; // Minimum monthly charge for any dataset size (0.06 USDFC)
    }

    // Used for announcing upgrades, packed into one slot
    struct PlannedUpgrade {
        // Address of the new implementation contract
        address nextImplementation;
        // Upgrade will not occur until at least this epoch
        uint96 afterEpoch;
    }

    // =========================================================================
    // Constants

    uint256 private constant NO_CHALLENGE_SCHEDULED = 0;
    uint256 private constant MIB_IN_BYTES = 1024 * 1024; // 1 MiB in bytes
    uint256 private constant DEFAULT_LOCKUP_PERIOD = 2880 * 30; // 1 month (30 days) in epochs
    uint256 private constant GIB_IN_BYTES = MIB_IN_BYTES * 1024; // 1 GiB in bytes
    uint256 private constant TIB_IN_BYTES = GIB_IN_BYTES * 1024; // 1 TiB in bytes
    uint256 private constant EPOCHS_PER_MONTH = 2880 * 30;

    // Metadata size and count limits
    uint256 private constant MAX_KEY_LENGTH = 32;
    uint256 private constant MAX_VALUE_LENGTH = 128;
    uint256 private constant MAX_KEYS_PER_DATASET = 10;
    uint256 private constant MAX_KEYS_PER_PIECE = 5;

    // Metadata key constants
    string private constant METADATA_KEY_WITH_CDN = "withCDN";
    uint256 private constant METADATA_KEY_WITH_CDN_SIZE = 7;
    bytes32 private constant METADATA_KEY_WITH_CDN_HASH = keccak256("withCDN");
    // solidity storage representation of string "withCDN"
    bytes32 private constant WITH_CDN_STRING_STORAGE_REPR =
        0x7769746843444e0000000000000000000000000000000000000000000000000e;

    // Upgrade sequence number, used by Initializable.reinitializer
    uint64 private immutable REINITIALIZER_VERSION;

    // Pricing constants (CDN egress pricing is immutable)
    uint256 private immutable CDN_EGRESS_PRICE_PER_TIB; // 7 USDFC per TiB of CDN egress
    uint256 private immutable CACHE_MISS_EGRESS_PRICE_PER_TIB; // 7 USDFC per TiB of cache miss egress

    // Fixed lockup amounts for CDN rails
    uint256 private immutable DEFAULT_CDN_LOCKUP_AMOUNT; // 0.7 USDFC
    uint256 private immutable DEFAULT_CACHE_MISS_LOCKUP_AMOUNT; // 0.3 USDFC

    // Maximum pricing bounds (4x initial values)
    uint256 private immutable MAX_STORAGE_PRICE_PER_TIB_PER_MONTH; // 10 USDFC (4x 2.5)
    uint256 private immutable MAX_MINIMUM_STORAGE_RATE_PER_MONTH; // 0.24 USDFC (4x 0.06)

    // Token decimals
    uint8 private immutable TOKEN_DECIMALS;

    // External contract addresses
    address public immutable pdpVerifierAddress;
    address public immutable paymentsContractAddress;
    IERC20Metadata public immutable usdfcTokenAddress;
    address public immutable filBeamBeneficiaryAddress;
    ServiceProviderRegistry public immutable serviceProviderRegistry;
    SessionKeyRegistry public immutable sessionKeyRegistry;

    // =========================================================================
    // Storage variables
    //
    // Each one of these variables is stored in its own storage slot and
    // corresponds to the layout defined in
    // FilecoinWarmStorageServiceLayout.sol.
    // Storage layout should never change to ensure upgradability!

    // Proving period constants - set during initialization
    uint64 private maxProvingPeriod;
    uint256 private challengeWindowSize;

    // Commission rate
    uint256 private serviceCommissionBps;

    // Track which proving periods have valid proofs with bitmap
    mapping(uint256 dataSetId => mapping(uint256 periodId => uint256)) private provenPeriods;
    // Track when proving was first activated for each data set
    mapping(uint256 dataSetId => uint256) private provingActivationEpoch;

    mapping(uint256 dataSetId => uint256) private provingDeadlines;
    mapping(uint256 dataSetId => bool) private provenThisPeriod;

    mapping(uint256 dataSetId => DataSetInfo) private dataSetInfo;

    // Replay protection: tracks used nonces for both CreateDataSet and AddPieces operations.
    // Stores packed data: upper 128 bits = cumulative piece count after AddPieces or 0 for CreateDataSet,
    // lower 128 bits = dataSetId. For AddPieces, stores (firstAdded + pieceData.length) which is the
    // next piece ID that would be assigned, providing historical data about dataset state after the operation.
    mapping(address payer => mapping(uint256 nonce => uint256)) private clientNonces;

    mapping(address payer => uint256[]) private clientDataSets;
    mapping(uint256 pdpRailId => uint256) private railToDataSet;

    // dataSetId => (key => value)
    mapping(uint256 dataSetId => mapping(string key => string value)) internal dataSetMetadata;
    // dataSetId => array of keys
    mapping(uint256 dataSetId => string[] keys) internal dataSetMetadataKeys;
    // dataSetId => PieceId => (key => value)
    mapping(uint256 dataSetId => mapping(uint256 pieceId => mapping(string key => string value))) internal
        dataSetPieceMetadata;
    // dataSetId => PieceId => array of keys
    mapping(uint256 dataSetId => mapping(uint256 pieceId => string[] keys)) internal dataSetPieceMetadataKeys;

    // Approved provider list
    mapping(uint256 providerId => bool) internal approvedProviders;
    uint256[] internal approvedProviderIds;

    // View contract for read-only operations
    // @dev For smart contract integrations, consider using FilecoinWarmStorageServiceStateLibrary
    // directly instead of going through the view contract for more efficient gas usage.
    address public viewContractAddress;

    // The address allowed to terminate CDN services
    address private filBeamControllerAddress;

    PlannedUpgrade private nextUpgrade;

    // Pricing rates (mutable for future adjustments)
    uint256 private storagePricePerTibPerMonth;
    uint256 private minimumStorageRatePerMonth;

    // Piece IDs awaiting metadata cleanup; cleared each nextProvingPeriod call
    mapping(uint256 dataSetId => uint256[] pieceIds) internal scheduledPieceMetadataRemovals;

    event UpgradeAnnounced(PlannedUpgrade plannedUpgrade);

    // =========================================================================

    // Modifier to ensure only the PDP verifier contract can call certain functions
    modifier onlyPDPVerifier() {
        require(msg.sender == pdpVerifierAddress, Errors.OnlyPDPVerifierAllowed(pdpVerifierAddress, msg.sender));
        _;
    }

    modifier onlyFilBeamController() {
        require(
            msg.sender == filBeamControllerAddress,
            Errors.OnlyFilBeamControllerAllowed(filBeamControllerAddress, msg.sender)
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow cstructor
    constructor(
        address _pdpVerifierAddress,
        address _paymentsContractAddress,
        IERC20Metadata _usdfc,
        address _filBeamBeneficiaryAddress,
        ServiceProviderRegistry _serviceProviderRegistry,
        SessionKeyRegistry _sessionKeyRegistry,
        uint64 _reinitializer_version
    ) {
        _disableInitializers();
        REINITIALIZER_VERSION = _reinitializer_version;

        require(_pdpVerifierAddress != address(0), Errors.ZeroAddress(Errors.AddressField.PDPVerifier));
        pdpVerifierAddress = _pdpVerifierAddress;

        require(_paymentsContractAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilecoinPayV1));
        paymentsContractAddress = _paymentsContractAddress;

        require(_usdfc != IERC20Metadata(address(0)), Errors.ZeroAddress(Errors.AddressField.USDFC));
        usdfcTokenAddress = _usdfc;

        require(_filBeamBeneficiaryAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilBeamBeneficiary));
        filBeamBeneficiaryAddress = _filBeamBeneficiaryAddress;

        require(
            _serviceProviderRegistry != ServiceProviderRegistry(address(0)),
            Errors.ZeroAddress(Errors.AddressField.ServiceProviderRegistry)
        );
        serviceProviderRegistry = ServiceProviderRegistry(_serviceProviderRegistry);

        require(
            _sessionKeyRegistry != SessionKeyRegistry(address(0)),
            Errors.ZeroAddress(Errors.AddressField.SessionKeyRegistry)
        );
        sessionKeyRegistry = _sessionKeyRegistry;

        // Read token decimals from the USDFC token contract
        TOKEN_DECIMALS = _usdfc.decimals();

        // Initialize the immutable pricing constants based on the actual token decimals
        CDN_EGRESS_PRICE_PER_TIB = 7 * 10 ** TOKEN_DECIMALS; // 7 USDFC per TiB
        CACHE_MISS_EGRESS_PRICE_PER_TIB = 7 * 10 ** TOKEN_DECIMALS; // 7 USDFC per TiB

        // Initialize maximum pricing bounds (4x initial values)
        MAX_STORAGE_PRICE_PER_TIB_PER_MONTH = 10 * 10 ** TOKEN_DECIMALS; // 10 USDFC (4x 2.5)
        MAX_MINIMUM_STORAGE_RATE_PER_MONTH = (24 * 10 ** TOKEN_DECIMALS) / 100; // 0.24 USDFC (4x 0.06)

        // Initialize the lockup constants based on the actual token decimals
        DEFAULT_CDN_LOCKUP_AMOUNT = (7 * 10 ** TOKEN_DECIMALS) / 10; // 0.7 USDFC
        DEFAULT_CACHE_MISS_LOCKUP_AMOUNT = (3 * 10 ** TOKEN_DECIMALS) / 10; // 0.3 USDFC
    }

    /**
     * @notice Initialize the contract with PDP proving period parameters
     * @param _maxProvingPeriod Maximum number of epochs between two consecutive proofs
     * @param _challengeWindowSize Number of epochs for the challenge window
     * @param _filBeamControllerAddress Address authorized to terminate CDN services
     * @param _name Service name (max 256 characters, cannot be empty)
     * @param _description Service description (max 256 characters, cannot be empty)
     */
    function initialize(
        uint64 _maxProvingPeriod,
        uint256 _challengeWindowSize,
        address _filBeamControllerAddress,
        string memory _name,
        string memory _description
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __EIP712_init("FilecoinWarmStorageService", "1");

        require(_maxProvingPeriod > 0, Errors.MaxProvingPeriodZero());
        require(
            _challengeWindowSize > 0 && _challengeWindowSize < _maxProvingPeriod,
            Errors.InvalidChallengeWindowSize(_challengeWindowSize, _maxProvingPeriod)
        );

        require(_filBeamControllerAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilBeamController));
        filBeamControllerAddress = _filBeamControllerAddress;

        uint256 serviceNameLength = bytes(_name).length;
        require(serviceNameLength > 0, Errors.InvalidServiceNameLength(serviceNameLength));
        require(serviceNameLength <= 256, Errors.InvalidServiceNameLength(serviceNameLength));

        uint256 serviceDescriptionLength = bytes(_description).length;
        require(serviceDescriptionLength > 0, Errors.InvalidServiceDescriptionLength(serviceDescriptionLength));
        require(serviceDescriptionLength <= 256, Errors.InvalidServiceDescriptionLength(serviceDescriptionLength));

        // Emit the FilecoinServiceDeployed event
        emit FilecoinServiceDeployed(_name, _description);

        maxProvingPeriod = _maxProvingPeriod;
        challengeWindowSize = _challengeWindowSize;

        // Set commission rate
        serviceCommissionBps = 0; // 0%

        // Initialize mutable pricing variables
        storagePricePerTibPerMonth = (5 * 10 ** TOKEN_DECIMALS) / 2; // 2.5 USDFC
        minimumStorageRatePerMonth = (6 * 10 ** TOKEN_DECIMALS) / 100; // 0.06 USDFC
    }

    function announcePlannedUpgrade(PlannedUpgrade calldata plannedUpgrade) external onlyOwner {
        require(plannedUpgrade.nextImplementation.code.length > 3000);
        require(plannedUpgrade.afterEpoch > block.number);
        nextUpgrade = plannedUpgrade;
        emit UpgradeAnnounced(plannedUpgrade);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // zero address already checked by ERC1967Utils._setImplementation
        require(newImplementation == nextUpgrade.nextImplementation);
        require(block.number >= nextUpgrade.afterEpoch);
        delete nextUpgrade;
    }

    /**
     * @notice Sets new proving period parameters
     * @param _maxProvingPeriod Maximum number of epochs between two consecutive proofs
     * @param _challengeWindowSize Number of epochs for the challenge window
     */
    function configureProvingPeriod(uint64 _maxProvingPeriod, uint256 _challengeWindowSize) external onlyOwner {
        require(_maxProvingPeriod > 0, Errors.MaxProvingPeriodZero());
        require(
            _challengeWindowSize > 0 && _challengeWindowSize < _maxProvingPeriod,
            Errors.InvalidChallengeWindowSize(_maxProvingPeriod, _challengeWindowSize)
        );

        maxProvingPeriod = _maxProvingPeriod;
        challengeWindowSize = _challengeWindowSize;
    }

    /**
     * @notice Migration function for contract upgrades
     * @dev This function should be called during upgrades to emit version tracking events
     * Only callable during proxy upgrade process
     * @param _viewContract Address of the view contract (optional, can be address(0))
     */
    function migrate(address _viewContract) public onlyProxy onlyOwner reinitializer(REINITIALIZER_VERSION) {
        // Set view contract if provided
        if (_viewContract != address(0)) {
            viewContractAddress = _viewContract;
            emit ViewContractSet(_viewContract);
        }

        emit ContractUpgraded(VERSION, ERC1967Utils.getImplementation());
    }

    /**
     * @notice Sets the view contract address (one-time setup)
     * @dev Only callable by the contract owner. This is intended to be called once after deployment
     * or during migration. The view contract should not be changed after initial setup as external
     * systems may cache this address. If a view contract upgrade is needed, deploy a new main
     * contract with the updated view contract reference.
     * @param _viewContract Address of the view contract
     */
    function setViewContract(address _viewContract) external onlyOwner {
        // Ensure the view contract address is not the zero address
        require(_viewContract != address(0), Errors.ZeroAddress(Errors.AddressField.View));

        // Require that the existing set address is still zero (one-time setup only)
        // NOTE: This check is commented out to allow setting the view contract easily during migrations prior to GA
        //       GH ISSUE: https://github.com/FilOzone/filecoin-services/issues/303
        //       This check needs to be re-enabled before mainnet deployment to prevent changing the view contract later.

        // require(viewContractAddress == address(0), Errors.AddressAlreadySet(Errors.AddressField.View));

        viewContractAddress = _viewContract;
        emit ViewContractSet(_viewContract);
    }

    /**
     * @notice Updates the service commission rates
     * @dev Only callable by the contract owner
     * @param newCommissionBps New commission rate in basis points
     */
    function updateServiceCommission(uint256 newCommissionBps) external onlyOwner {
        require(
            newCommissionBps <= COMMISSION_MAX_BPS,
            Errors.CommissionExceedsMaximum(Errors.CommissionType.Service, COMMISSION_MAX_BPS, newCommissionBps)
        );
        serviceCommissionBps = newCommissionBps;
    }

    /**
     * @notice Updates the pricing rates for storage services
     * @dev Only callable by the contract owner. Pass 0 to keep existing value unchanged.
     *      Price updates apply immediately to existing payment rails when they're recalculated
     *      (e.g., during piece additions/deletions or proving period updates).
     *      Maximum allowed values: 10 USDFC for storage, 0.24 USDFC for minimum rate.
     * @param newStoragePrice New storage price per TiB per month (0 = no change, max 10 USDFC)
     * @param newMinimumRate New minimum monthly storage rate (0 = no change, max 0.24 USDFC)
     */
    function updatePricing(uint256 newStoragePrice, uint256 newMinimumRate) external onlyOwner {
        require(newStoragePrice > 0 || newMinimumRate > 0, Errors.AtLeastOnePriceMustBeNonZero());

        if (newStoragePrice > 0) {
            require(
                newStoragePrice <= MAX_STORAGE_PRICE_PER_TIB_PER_MONTH,
                Errors.PriceExceedsMaximum(
                    Errors.PriceType.Storage, MAX_STORAGE_PRICE_PER_TIB_PER_MONTH, newStoragePrice
                )
            );
            storagePricePerTibPerMonth = newStoragePrice;
        }
        if (newMinimumRate > 0) {
            require(
                newMinimumRate <= MAX_MINIMUM_STORAGE_RATE_PER_MONTH,
                Errors.PriceExceedsMaximum(
                    Errors.PriceType.MinimumRate, MAX_MINIMUM_STORAGE_RATE_PER_MONTH, newMinimumRate
                )
            );
            minimumStorageRatePerMonth = newMinimumRate;
        }

        emit PricingUpdated(storagePricePerTibPerMonth, minimumStorageRatePerMonth);
    }

    /**
     * @notice Adds a provider ID to the approved list
     * @dev Only callable by the contract owner. Reverts if already approved.
     * @param providerId The provider ID to approve
     */
    function addApprovedProvider(uint256 providerId) external onlyOwner {
        if (approvedProviders[providerId]) {
            revert Errors.ProviderAlreadyApproved(providerId);
        }
        approvedProviders[providerId] = true;
        approvedProviderIds.push(providerId);
        emit ProviderApproved(providerId);
    }

    /**
     * @notice Removes a provider ID from the approved list
     * @dev Only callable by the contract owner. Reverts if not in list.
     * @param providerId The provider ID to remove
     * @param index The index of the provider ID in the approvedProviderIds array
     */
    function removeApprovedProvider(uint256 providerId, uint256 index) external onlyOwner {
        if (!approvedProviders[providerId]) {
            revert Errors.ProviderNotInApprovedList(providerId);
        }

        require(approvedProviderIds[index] == providerId, "Provider ID mismatch at index");

        approvedProviders[providerId] = false;

        // Remove from array using swap-and-pop pattern
        uint256 length = approvedProviderIds.length;
        if (index != length - 1) {
            approvedProviderIds[index] = approvedProviderIds[length - 1];
        }
        approvedProviderIds.pop();

        emit ProviderUnapproved(providerId);
    }

    // Listener interface methods
    /**
     * @notice Handles data set creation by creating a payment rail
     * @dev Called by the PDPVerifier contract when a new data set is created
     * @param dataSetId The ID of the newly created data set
     * @param serviceProvider The address that creates and owns the data set
     * @param extraData Encoded data containing metadata, payer information, and signature
     */
    function dataSetCreated(uint256 dataSetId, address serviceProvider, bytes calldata extraData)
        external
        onlyPDPVerifier
    {
        // Decode the extra data to get the metadata, payer address, and signature
        uint256 len = extraData.length;
        require(len > 0, Errors.ExtraDataRequired());
        require(
            len <= MAX_CREATE_DATA_SET_EXTRA_DATA_SIZE,
            Errors.ExtraDataTooLarge(len, MAX_CREATE_DATA_SET_EXTRA_DATA_SIZE)
        );
        DataSetCreateData memory createData = decodeDataSetCreateData(extraData);

        // Validate the addresses
        require(createData.payer != address(0), Errors.ZeroAddress(Errors.AddressField.Payer));
        require(serviceProvider != address(0), Errors.ZeroAddress(Errors.AddressField.ServiceProvider));

        uint256 providerId = serviceProviderRegistry.getProviderIdByAddress(serviceProvider);

        require(providerId != 0, Errors.ProviderNotRegistered(serviceProvider));

        address payee = serviceProviderRegistry.getProviderPayee(providerId);

        require(
            clientNonces[createData.payer][createData.clientDataSetId] == 0,
            Errors.ClientDataSetAlreadyRegistered(createData.clientDataSetId)
        );
        clientNonces[createData.payer][createData.clientDataSetId] = dataSetId;
        clientDataSets[createData.payer].push(dataSetId);

        // Verify the client's signature
        verifyCreateDataSetSignature(payee, createData);

        // Initialize the DataSetInfo struct
        DataSetInfo storage info = dataSetInfo[dataSetId];
        info.payer = createData.payer;
        info.payee = payee; // Using payee address from registry
        info.serviceProvider = serviceProvider; // Set the service provider
        info.commissionBps = serviceCommissionBps;
        info.clientDataSetId = createData.clientDataSetId;
        info.providerId = providerId;

        // Store each metadata key-value entry for this data set
        require(
            createData.metadataKeys.length == createData.metadataValues.length,
            Errors.MetadataKeyAndValueLengthMismatch(createData.metadataKeys.length, createData.metadataValues.length)
        );
        require(
            createData.metadataKeys.length <= MAX_KEYS_PER_DATASET,
            Errors.TooManyMetadataKeys(MAX_KEYS_PER_DATASET, createData.metadataKeys.length)
        );

        for (uint256 i = 0; i < createData.metadataKeys.length; i++) {
            string memory key = createData.metadataKeys[i];
            string memory value = createData.metadataValues[i];

            require(bytes(dataSetMetadata[dataSetId][key]).length == 0, Errors.DuplicateMetadataKey(dataSetId, key));
            require(
                bytes(key).length <= MAX_KEY_LENGTH,
                Errors.MetadataKeyExceedsMaxLength(i, MAX_KEY_LENGTH, bytes(key).length)
            );
            require(
                bytes(value).length <= MAX_VALUE_LENGTH,
                Errors.MetadataValueExceedsMaxLength(i, MAX_VALUE_LENGTH, bytes(value).length)
            );

            // Store the metadata key in the array for this data set
            dataSetMetadataKeys[dataSetId].push(key);

            // Store the metadata value directly
            dataSetMetadata[dataSetId][key] = value;
        }

        // Note: The payer must have pre-approved this contract to spend USDFC tokens before creating the data set

        // Create the payment rails using the FilecoinPayV1 contract
        FilecoinPayV1 payments = FilecoinPayV1(paymentsContractAddress);

        // Determine once whether CDN is enabled in metadata and reuse the result
        bool hasCDN = hasCDNMetadataKey(createData.metadataKeys);

        // Validate payer has sufficient funds and operator approvals for minimum pricing
        // If CDN is enabled, validation must account for the additional fixed lockup amounts
        validatePayerOperatorApprovalAndFunds(payments, createData.payer, hasCDN);

        uint256 pdpRailId = payments.createRail(
            usdfcTokenAddress, // token address
            createData.payer, // from (payer)
            payee, // payee address from registry
            address(this), // this contract acts as the validator
            info.commissionBps, // commission rate based on CDN usage
            address(this)
        );

        // Store the rail ID
        info.pdpRailId = pdpRailId;

        // Store reverse mapping from rail ID to data set ID for validation
        railToDataSet[pdpRailId] = dataSetId;

        // Set lockup period for the rail
        payments.modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, 0);

        uint256 cacheMissRailId = 0;
        uint256 cdnRailId = 0;

        if (hasCDN) {
            cacheMissRailId = payments.createRail(
                usdfcTokenAddress, // token address
                createData.payer, // from (payer)
                payee, // payee address from registry
                address(0), // no validator
                0, // no service commission
                address(this) // controller
            );
            info.cacheMissRailId = cacheMissRailId;
            payments.modifyRailLockup(cacheMissRailId, DEFAULT_LOCKUP_PERIOD, DEFAULT_CACHE_MISS_LOCKUP_AMOUNT);

            cdnRailId = payments.createRail(
                usdfcTokenAddress, // token address
                createData.payer, // from (payer)
                filBeamBeneficiaryAddress, // to FilBeam beneficiary
                address(0), // no validator
                0, // no service commission
                address(this) // controller
            );
            info.cdnRailId = cdnRailId;
            payments.modifyRailLockup(cdnRailId, DEFAULT_LOCKUP_PERIOD, DEFAULT_CDN_LOCKUP_AMOUNT);

            emit CDNPaymentRailsToppedUp(
                dataSetId,
                DEFAULT_CDN_LOCKUP_AMOUNT,
                DEFAULT_CDN_LOCKUP_AMOUNT,
                DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
                DEFAULT_CACHE_MISS_LOCKUP_AMOUNT
            );
        }

        // Emit event for tracking
        emit DataSetCreated(
            dataSetId,
            providerId,
            pdpRailId,
            cacheMissRailId,
            cdnRailId,
            createData.payer,
            serviceProvider,
            payee,
            createData.metadataKeys,
            createData.metadataValues
        );
    }

    /**
     * @notice Handles data set deletion after the payment rails were terminated
     * @dev Called by the PDPVerifier contract when a data set is deleted
     * @param dataSetId The ID of the data set being deleted
     */
    function dataSetDeleted(
        uint256 dataSetId,
        uint256, // deletedLeafCount, - not used
        bytes calldata // extraData, - not used
    ) external onlyPDPVerifier {
        // Verify the data set exists in our mapping
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));

        // Get the payer address for this data set
        address payer = dataSetInfo[dataSetId].payer;

        // Check if the data set's payment rails have finalized
        require(
            info.pdpEndEpoch != 0 && block.number > info.pdpEndEpoch,
            Errors.PaymentRailsNotFinalized(dataSetId, info.pdpEndEpoch)
        );

        // Check if the rail is fully settled before allowing deletion.
        // This ensures validatePayment() can still read dataset state during settlement.
        // If deleted before settlement, clients would be forced to use
        // settleTerminatedRailWithoutValidation() which pays full amount for unproven epochs.
        FilecoinPayV1 payments = FilecoinPayV1(paymentsContractAddress);
        try payments.getRail(info.pdpRailId) returns (FilecoinPayV1.RailView memory rail) {
            require(
                rail.settledUpTo >= rail.endEpoch,
                Errors.RailNotFullySettled(info.pdpRailId, rail.settledUpTo, rail.endEpoch)
            );
        } catch {
            // Rail is finalized (zeroed out), meaning it was already fully settled
        }

        // NOTE keep clientNonces[payer][clientDataSetId] to prevent replay

        // Remove from client's dataset list
        uint256[] storage clientDataSetList = clientDataSets[payer];
        for (uint256 i = 0; i < clientDataSetList.length; i++) {
            if (clientDataSetList[i] == dataSetId) {
                // Remove this dataset from the array
                clientDataSetList[i] = clientDataSetList[clientDataSetList.length - 1];
                clientDataSetList.pop();
                break;
            }
        }

        // Remove the dataset from all mappings

        // Clean up proving-related state
        delete provingDeadlines[dataSetId];
        delete provenThisPeriod[dataSetId];
        delete provingActivationEpoch[dataSetId];

        // Clean up rail mappings
        delete railToDataSet[info.pdpRailId];

        // Clean up metadata mappings
        string[] storage metadataKeys = dataSetMetadataKeys[dataSetId];
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            delete dataSetMetadata[dataSetId][metadataKeys[i]];
        }
        delete dataSetMetadataKeys[dataSetId];

        // Complete cleanup
        delete dataSetInfo[dataSetId];
    }

    /**
     * @notice Handles pieces being added to a data set and stores associated metadata
     * @dev Called by the PDPVerifier contract when pieces are added to a data set.
     * @param dataSetId The ID of the data set
     * @param firstAdded The ID of the first piece added (from PDPVerifier, used for piece ID assignment)
     * @param pieceData Array of piece data objects
     * @param extraData Encoded (nonce, metadata keys, metadata values, signature)
     */
    function piecesAdded(uint256 dataSetId, uint256 firstAdded, Cids.Cid[] memory pieceData, bytes calldata extraData)
        external
        onlyPDPVerifier
    {
        requirePaymentNotTerminated(dataSetId);
        // Verify the data set exists in our mapping
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));

        // Get the payer address for this data set
        address payer = info.payer;
        uint256 len = extraData.length;
        require(len > 0, Errors.ExtraDataRequired());
        require(len <= MAX_ADD_PIECES_EXTRA_DATA_SIZE, Errors.ExtraDataTooLarge(len, MAX_ADD_PIECES_EXTRA_DATA_SIZE));
        // Decode the extra data
        (uint256 nonce, string[][] memory metadataKeys, string[][] memory metadataValues, bytes memory signature) =
            abi.decode(extraData, (uint256, string[][], string[][], bytes));

        // Validate nonce hasn't been used (replay protection)
        require(clientNonces[payer][nonce] == 0, Errors.ClientDataSetAlreadyRegistered(nonce));
        // Mark nonce as used, storing cumulative piece count (next piece ID) in upper bits
        clientNonces[payer][nonce] = ((firstAdded + pieceData.length) << 128) | dataSetId;

        // Check that we have metadata arrays for each piece
        require(
            metadataKeys.length == pieceData.length,
            Errors.MetadataArrayCountMismatch(metadataKeys.length, pieceData.length)
        );
        require(
            metadataValues.length == pieceData.length,
            Errors.MetadataArrayCountMismatch(metadataValues.length, pieceData.length)
        );

        // Verify the signature
        verifyAddPiecesSignature(payer, info.clientDataSetId, pieceData, nonce, metadataKeys, metadataValues, signature);

        // Validate lockup for the new data set size (fail-fast if client has insufficient funds)
        uint256 currentLeafCount = IPDPVerifier(pdpVerifierAddress).getDataSetLeafCount(dataSetId);
        updatePaymentRates(dataSetId, currentLeafCount);

        // Store metadata for each new piece
        for (uint256 i = 0; i < pieceData.length; i++) {
            uint256 pieceId = firstAdded + i;
            string[] memory pieceKeys = metadataKeys[i];
            string[] memory pieceValues = metadataValues[i];

            // Check that number of metadata keys and values are equal for this piece
            require(
                pieceKeys.length == pieceValues.length,
                Errors.MetadataKeyAndValueLengthMismatch(pieceKeys.length, pieceValues.length)
            );

            require(
                pieceKeys.length <= MAX_KEYS_PER_PIECE, Errors.TooManyMetadataKeys(MAX_KEYS_PER_PIECE, pieceKeys.length)
            );

            for (uint256 k = 0; k < pieceKeys.length; k++) {
                string memory key = pieceKeys[k];
                string memory value = pieceValues[k];

                require(
                    bytes(dataSetPieceMetadata[dataSetId][pieceId][key]).length == 0,
                    Errors.DuplicateMetadataKey(dataSetId, key)
                );
                require(
                    bytes(key).length <= MAX_KEY_LENGTH,
                    Errors.MetadataKeyExceedsMaxLength(k, MAX_KEY_LENGTH, bytes(key).length)
                );
                require(
                    bytes(value).length <= MAX_VALUE_LENGTH,
                    Errors.MetadataValueExceedsMaxLength(k, MAX_VALUE_LENGTH, bytes(value).length)
                );
                dataSetPieceMetadata[dataSetId][pieceId][key] = string(value);
                dataSetPieceMetadataKeys[dataSetId][pieceId].push(key);
            }
            emit PieceAdded(dataSetId, pieceId, pieceData[i], pieceKeys, pieceValues);
        }
    }

    function piecesScheduledRemove(uint256 dataSetId, uint256[] memory pieceIds, bytes calldata extraData)
        external
        onlyPDPVerifier
    {
        requirePaymentNotBeyondEndEpoch(dataSetId);
        // Verify the data set exists in our mapping
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));

        // Get the payer address for this data set
        address payer = info.payer;

        // Decode the signature from extraData
        uint256 len = extraData.length;
        require(len > 0, Errors.ExtraDataRequired());
        require(
            len <= MAX_SCHEDULE_PIECE_REMOVALS_EXTRA_DATA_SIZE,
            Errors.ExtraDataTooLarge(len, MAX_SCHEDULE_PIECE_REMOVALS_EXTRA_DATA_SIZE)
        );
        bytes memory signature = abi.decode(extraData, (bytes));

        // Verify the signature
        verifySchedulePieceRemovalsSignature(payer, info.clientDataSetId, pieceIds, signature);

        // Queue piece IDs for metadata cleanup at nextProvingPeriod
        uint256[] storage scheduled = scheduledPieceMetadataRemovals[dataSetId];
        for (uint256 i = 0; i < pieceIds.length; i++) {
            scheduled.push(pieceIds[i]);
        }
    }

    // possession proven checks for correct challenge count and reverts if too low
    // it also checks that proofs are not late and emits a fault record if so
    function possessionProven(
        uint256 dataSetId,
        uint256, /*challengedLeafCount*/
        uint256, /*seed*/
        uint256 challengeCount
    ) external onlyPDPVerifier {
        requirePaymentNotBeyondEndEpoch(dataSetId);

        if (provenThisPeriod[dataSetId]) {
            revert Errors.ProofAlreadySubmitted(dataSetId);
        }

        uint256 expectedChallengeCount = CHALLENGES_PER_PROOF;
        if (challengeCount < expectedChallengeCount) {
            revert Errors.InvalidChallengeCount(dataSetId, expectedChallengeCount, challengeCount);
        }

        if (provingDeadlines[dataSetId] == NO_PROVING_DEADLINE) {
            revert Errors.ProvingNotStarted(dataSetId);
        }

        // check for proof outside of challenge window
        if (provingDeadlines[dataSetId] < block.number) {
            revert Errors.ProvingPeriodPassed(dataSetId, provingDeadlines[dataSetId], block.number);
        }

        uint256 windowStart = provingDeadlines[dataSetId] - challengeWindowSize;
        if (windowStart > block.number) {
            revert Errors.ChallengeWindowTooEarly(dataSetId, windowStart, block.number);
        }
        provenThisPeriod[dataSetId] = true;
        uint256 currentPeriod = getProvingPeriodForEpoch(dataSetId, block.number);
        provenPeriods[dataSetId][currentPeriod >> 8] |= 1 << (currentPeriod & 255);
    }

    // nextProvingPeriod checks for unsubmitted proof in which case it emits a fault event
    // Additionally it enforces constraints on the update of its state:
    // 1. One update per proving period.
    // 2. Next challenge epoch must fall within the challenge window in the last challengeWindow()
    //    epochs of the proving period.
    //
    // In the payment version, it also updates the payment rate based on the current storage size.
    function nextProvingPeriod(uint256 dataSetId, uint256 challengeEpoch, uint256 leafCount, bytes calldata)
        external
        onlyPDPVerifier
    {
        requirePaymentNotBeyondEndEpoch(dataSetId);
        // initialize state for new data set
        if (provingDeadlines[dataSetId] == NO_PROVING_DEADLINE) {
            uint256 firstDeadline = block.number + maxProvingPeriod;
            uint256 minWindow = firstDeadline - challengeWindowSize;
            uint256 maxWindow = firstDeadline;
            if (challengeEpoch < minWindow || challengeEpoch > maxWindow) {
                revert Errors.InvalidChallengeEpoch(dataSetId, minWindow, maxWindow, challengeEpoch);
            }
            provingDeadlines[dataSetId] = firstDeadline;

            // Initialize the activation epoch when proving first starts
            // This marks when the data set became active for proving
            provingActivationEpoch[dataSetId] = block.number;

            // Rate was already set in piecesAdded; only update if pieces were removed
            if (processScheduledPieceMetadataRemovals(dataSetId)) {
                updatePaymentRates(dataSetId, leafCount);
            }

            return;
        }

        // Revert when proving period not yet open
        // Can only get here if calling nextProvingPeriod multiple times within the same proving period
        uint256 prevDeadline = provingDeadlines[dataSetId] - maxProvingPeriod;
        if (block.number <= prevDeadline) {
            revert Errors.NextProvingPeriodAlreadyCalled(dataSetId, prevDeadline, block.number);
        }

        uint256 periodsSkipped;
        // Proving period is open 0 skipped periods
        if (block.number <= provingDeadlines[dataSetId]) {
            periodsSkipped = 0;
        } else {
            // Proving period has closed possibly some skipped periods
            periodsSkipped = (block.number - (provingDeadlines[dataSetId] + 1)) / maxProvingPeriod;
        }

        uint256 nextDeadline;
        // the data set has become empty and provingDeadline is set inactive
        if (challengeEpoch == NO_CHALLENGE_SCHEDULED) {
            nextDeadline = NO_PROVING_DEADLINE;
        } else {
            nextDeadline = provingDeadlines[dataSetId] + maxProvingPeriod * (periodsSkipped + 1);
            uint256 windowStart = nextDeadline - challengeWindowSize;
            uint256 windowEnd = nextDeadline;

            if (challengeEpoch < windowStart || challengeEpoch > windowEnd) {
                revert Errors.InvalidChallengeEpoch(dataSetId, windowStart, windowEnd, challengeEpoch);
            }
        }
        uint256 faultPeriods = periodsSkipped;
        if (!provenThisPeriod[dataSetId]) {
            // include previous unproven period
            faultPeriods += 1;
        }
        if (faultPeriods > 0) {
            emit FaultRecord(dataSetId, faultPeriods, provingDeadlines[dataSetId]);
        }

        provingDeadlines[dataSetId] = nextDeadline;
        provenThisPeriod[dataSetId] = false;

        // Additions update rate immediately in piecesAdded; only update here if pieces were removed
        if (processScheduledPieceMetadataRemovals(dataSetId)) {
            updatePaymentRates(dataSetId, leafCount);
        }
    }

    /**
     * @notice Handles data set service provider changes (currently disabled for GA)
     * @dev Storage provider changes are disabled for GA. This will be re-enabled post-GA
     * with proper client authorization. See: https://github.com/FilOzone/filecoin-services/issues/203
     * Called by the PDPVerifier contract when data set service provider is transferred.
     */
    function storageProviderChanged(
        uint256, // dataSetId
        address, // oldServiceProvider
        address, // newServiceProvider
        bytes calldata // extraData - not used
    ) external override onlyPDPVerifier {
        revert("Storage provider changes are not yet supported");
    }

    function terminateService(uint256 dataSetId) external {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));

        // Check if already terminated
        require(info.pdpEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));

        // Check authorization
        require(
            msg.sender == info.payer || msg.sender == info.serviceProvider,
            Errors.CallerNotPayerOrPayee(dataSetId, info.payer, info.serviceProvider, msg.sender)
        );

        FilecoinPayV1 payments = FilecoinPayV1(paymentsContractAddress);

        payments.terminateRail(info.pdpRailId);

        if (deleteCDNMetadataKey(dataSetMetadataKeys[dataSetId])) {
            // CDN rails can be terminated externally via FilecoinPay. Ignore errors from
            // already-terminated or finalized rails.
            try payments.terminateRail(info.cacheMissRailId) {} catch {}
            try payments.terminateRail(info.cdnRailId) {} catch {}

            // Delete withCDN flag from metadata to prevent further CDN operations
            delete dataSetMetadata[dataSetId][METADATA_KEY_WITH_CDN];

            emit CDNServiceTerminated(msg.sender, dataSetId, info.cacheMissRailId, info.cdnRailId);
        }

        emit ServiceTerminated(msg.sender, dataSetId, info.pdpRailId, info.cacheMissRailId, info.cdnRailId);
    }

    /**
     * @notice Settles CDN payment rails with specified amounts
     * @dev Only callable by FilCDN (Operator) contract
     * @param dataSetId The ID of the data set
     * @param cdnAmount Amount to settle for CDN rail
     * @param cacheMissAmount Amount to settle for cache miss rail
     */
    function settleFilBeamPaymentRails(uint256 dataSetId, uint256 cdnAmount, uint256 cacheMissAmount)
        external
        onlyFilBeamController
    {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));

        // Check if CDN rails are configured (presence of rails indicates CDN was set up)
        require(info.cdnRailId != 0 && info.cacheMissRailId != 0, Errors.InvalidDataSetId(dataSetId));

        FilecoinPayV1 payments = FilecoinPayV1(paymentsContractAddress);

        if (cdnAmount > 0) {
            payments.modifyRailPayment(info.cdnRailId, 0, cdnAmount);
        }

        if (cacheMissAmount > 0) {
            payments.modifyRailPayment(info.cacheMissRailId, 0, cacheMissAmount);
        }
    }

    /**
     * @notice Allows users to add funds to their CDN-related payment rails
     * @param dataSetId The ID of the data set
     * @param cdnAmountToAdd Amount to add to CDN rail lockup
     * @param cacheMissAmountToAdd Amount to add to cache miss rail lockup
     */
    function topUpCDNPaymentRails(uint256 dataSetId, uint256 cdnAmountToAdd, uint256 cacheMissAmountToAdd) external {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));

        // Check authorization - only payer can top up
        require(msg.sender == info.payer, Errors.CallerNotPayer(dataSetId, info.payer, msg.sender));

        // Check if CDN service is configured
        require(dataSetHasCDNMetadataKey(dataSetId), Errors.FilBeamServiceNotConfigured(dataSetId));

        // Check if cache miss and CDN rails are configured
        require(info.cacheMissRailId != 0 && info.cdnRailId != 0, Errors.InvalidDataSetId(dataSetId));

        FilecoinPayV1 payments = FilecoinPayV1(paymentsContractAddress);

        // Both rails must be active for any top-up operation
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);

        require(cdnRail.endEpoch == 0, Errors.CDNPaymentAlreadyTerminated(dataSetId));
        require(cacheMissRail.endEpoch == 0, Errors.CacheMissPaymentAlreadyTerminated(dataSetId));

        // Require at least one amount to be non-zero
        if (cdnAmountToAdd == 0 && cacheMissAmountToAdd == 0) {
            revert Errors.InvalidTopUpAmount(dataSetId);
        }

        // Calculate total lockup amounts
        uint256 totalCdnLockup = cdnRail.lockupFixed + cdnAmountToAdd;
        uint256 totalCacheMissLockup = cacheMissRail.lockupFixed + cacheMissAmountToAdd;

        // Only modify rails if amounts are being added
        payments.modifyRailLockup(info.cdnRailId, DEFAULT_LOCKUP_PERIOD, totalCdnLockup);
        payments.modifyRailLockup(info.cacheMissRailId, DEFAULT_LOCKUP_PERIOD, totalCacheMissLockup);

        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnAmountToAdd, totalCdnLockup, cacheMissAmountToAdd, totalCacheMissLockup
        );
    }

    function terminateCDNService(uint256 dataSetId) external onlyFilBeamController {
        // Check if CDN service is configured
        require(deleteCDNMetadataKey(dataSetMetadataKeys[dataSetId]), Errors.FilBeamServiceNotConfigured(dataSetId));

        // Check if cache miss and CDN rails are configured
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.cacheMissRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.cdnRailId != 0, Errors.InvalidDataSetId(dataSetId));
        FilecoinPayV1 payments = FilecoinPayV1(paymentsContractAddress);

        // ⚠️ WARNING: Catch-all error handling will silently suppress ALL errors from terminateRail(),
        // not just "already terminated/finalized" errors. This could mask legitimate failures.
        // Ideally we would catch only specific error types, but contract size constraint prevents
        // us from implementing error handling.
        try payments.terminateRail(info.cacheMissRailId) {} catch {}
        try payments.terminateRail(info.cdnRailId) {} catch {}

        // Delete withCDN flag from metadata to prevent further CDN operations
        delete dataSetMetadata[dataSetId][METADATA_KEY_WITH_CDN];

        emit CDNServiceTerminated(msg.sender, dataSetId, info.cacheMissRailId, info.cdnRailId);
    }

    function transferFilBeamController(address newController) external onlyFilBeamController {
        require(newController != address(0), Errors.ZeroAddress(Errors.AddressField.FilBeamController));
        address oldController = filBeamControllerAddress;
        filBeamControllerAddress = newController;
        emit FilBeamControllerChanged(oldController, newController);
    }

    function requirePaymentNotTerminated(uint256 dataSetId) internal view {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.pdpEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));
    }

    function requirePaymentNotBeyondEndEpoch(uint256 dataSetId) internal view {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        if (info.pdpEndEpoch != 0) {
            require(
                block.number <= info.pdpEndEpoch,
                Errors.DataSetPaymentBeyondEndEpoch(dataSetId, info.pdpEndEpoch, block.number)
            );
        }
    }

    /// @notice Validates that the payer has sufficient funds and operator approvals for minimum pricing
    /// @param payments The FilecoinPayV1 contract instance
    /// @param payer The address of the payer
    function validatePayerOperatorApprovalAndFunds(FilecoinPayV1 payments, address payer, bool includeCDN)
        internal
        view
    {
        // Calculate required lockup for minimum pricing.
        // We use multiply-first here to preserve the exact monthly value for cleaner error messages
        // (a round number like the configured floor price, rather than a value with many trailing digits
        // from precision loss). This is slightly more conservative than the actual rail lockup (which
        // uses the truncated per-epoch rate), but the difference is under 0.0001% and always in the
        // user's favor - they are never required to have less than what the rail will actually lock.
        uint256 minimumLockupRequired = (minimumStorageRatePerMonth * DEFAULT_LOCKUP_PERIOD) / EPOCHS_PER_MONTH;

        // If CDN is enabled, include the fixed cache-miss and CDN lockup amounts
        if (includeCDN) {
            minimumLockupRequired += DEFAULT_CACHE_MISS_LOCKUP_AMOUNT + DEFAULT_CDN_LOCKUP_AMOUNT;
        }

        // Check that payer has sufficient available funds
        (,, uint256 availableFunds,) = payments.getAccountInfoIfSettled(usdfcTokenAddress, payer);
        require(
            availableFunds >= minimumLockupRequired,
            Errors.InsufficientLockupFunds(payer, minimumLockupRequired, availableFunds)
        );

        // Check operator approval settings
        (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        ) = payments.operatorApprovals(usdfcTokenAddress, payer, address(this));

        // Verify operator is approved
        require(isApproved, Errors.OperatorNotApproved(payer, address(this)));

        // Calculate minimum rate per epoch
        uint256 minimumRatePerEpoch = minimumStorageRatePerMonth / EPOCHS_PER_MONTH;

        // Verify rate allowance is sufficient
        require(
            rateAllowance >= rateUsage + minimumRatePerEpoch,
            Errors.InsufficientRateAllowance(payer, address(this), rateAllowance, rateUsage, minimumRatePerEpoch)
        );

        // Verify lockup allowance is sufficient (include CDN extras when applicable)
        require(
            lockupAllowance >= lockupUsage + minimumLockupRequired,
            Errors.InsufficientLockupAllowance(
                payer, address(this), lockupAllowance, lockupUsage, minimumLockupRequired
            )
        );

        // Verify max lockup period is sufficient
        require(
            maxLockupPeriod >= DEFAULT_LOCKUP_PERIOD,
            Errors.InsufficientMaxLockupPeriod(payer, address(this), maxLockupPeriod, DEFAULT_LOCKUP_PERIOD)
        );
    }

    function updatePaymentRates(uint256 dataSetId, uint256 leafCount) internal {
        // Revert if no payment rail is configured for this data set
        require(dataSetInfo[dataSetId].pdpRailId != 0, Errors.NoPDPPaymentRail(dataSetId));

        uint256 totalBytes = leafCount * BYTES_PER_LEAF;
        FilecoinPayV1 payments = FilecoinPayV1(paymentsContractAddress);

        // Update the PDP rail payment rate with the new rate and no one-time payment
        uint256 pdpRailId = dataSetInfo[dataSetId].pdpRailId;
        uint256 newStorageRatePerEpoch = _calculateStorageRate(totalBytes);
        payments.modifyRailPayment(
            pdpRailId,
            newStorageRatePerEpoch,
            0 // No one-time payment during rate update
        );
        emit RailRateUpdated(dataSetId, pdpRailId, newStorageRatePerEpoch);
    }

    function processScheduledPieceMetadataRemovals(uint256 dataSetId) internal returns (bool hadRemovals) {
        uint256[] storage pieceIds = scheduledPieceMetadataRemovals[dataSetId];
        uint256 len = pieceIds.length;
        if (len == 0) {
            return false;
        }

        mapping(uint256 => string[]) storage pieceMetadataKeys = dataSetPieceMetadataKeys[dataSetId];
        mapping(uint256 => mapping(string => string)) storage pieceMetadata = dataSetPieceMetadata[dataSetId];

        for (uint256 i = 0; i < len; i++) {
            uint256 pieceId = pieceIds[i];
            string[] storage metadataKeys = pieceMetadataKeys[pieceId];
            mapping(string => string) storage metadata = pieceMetadata[pieceId];
            uint256 keyLen = metadataKeys.length;
            for (uint256 j = 0; j < keyLen; j++) {
                delete metadata[metadataKeys[j]];
            }
            delete pieceMetadataKeys[pieceId];
        }

        delete scheduledPieceMetadataRemovals[dataSetId];
        return true;
    }

    /**
     * @notice Determines which proving period an epoch belongs to
     * @dev For a given epoch, calculates the period ID based on activation time
     * @param dataSetId The ID of the data set
     * @param epoch The epoch to check
     * @return The period ID this epoch belongs to, or type(uint256).max if before activation
     */
    function getProvingPeriodForEpoch(uint256 dataSetId, uint256 epoch) public view returns (uint256) {
        return _provingPeriodForEpoch(provingActivationEpoch[dataSetId], epoch);
    }

    function _provingPeriodForEpoch(uint256 activationEpoch, uint256 epoch) internal view returns (uint256) {
        // If proving wasn't activated or epoch is before activation
        if (activationEpoch == 0 || epoch < activationEpoch) {
            return type(uint256).max; // Invalid period
        }

        // Calculate periods since activation
        // For example, if activation is at epoch 1000 and proving period is 2880:
        // - Epoch 1001-3880 is period 0
        // - Epoch 3881-6760 is period 1
        // and so on
        return (epoch - activationEpoch - 1) / maxProvingPeriod;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice Calculate a per-epoch rate based on total storage size
     * @param totalBytes Total size of the stored data in bytes
     * @param ratePerTiBPerMonth The rate per TiB per month in the token's smallest unit
     * @return ratePerEpoch The calculated rate per epoch in the token's smallest unit
     */
    function calculateStorageSizeBasedRatePerEpoch(uint256 totalBytes, uint256 ratePerTiBPerMonth)
        internal
        view
        returns (uint256)
    {
        uint256 numerator = totalBytes * ratePerTiBPerMonth;
        uint256 denominator = TIB_IN_BYTES * EPOCHS_PER_MONTH;

        // Ensure denominator is not zero (shouldn't happen with constants)
        require(denominator > 0, Errors.DivisionByZero());

        uint256 ratePerEpoch = numerator / denominator;

        // Ensure minimum rate is 0.00001 USDFC if calculation results in 0 due to rounding.
        // This prevents charging 0 for very small sizes due to integer division.
        if (ratePerEpoch == 0 && totalBytes > 0) {
            uint256 minRate = (1 * 10 ** uint256(TOKEN_DECIMALS)) / 100000;
            return minRate;
        }

        return ratePerEpoch;
    }

    /**
     * @notice Calculate storage rate per epoch based on total storage size
     * @dev Returns storage rate per TiB per month with minimum pricing floor applied
     * @param totalBytes Total size of the stored data in bytes
     * @return storageRate The PDP storage rate per epoch
     */
    function calculateRatePerEpoch(uint256 totalBytes) external view returns (uint256 storageRate) {
        storageRate = _calculateStorageRate(totalBytes);
    }

    /**
     * @notice Calculate the storage rate per epoch (internal use)
     * @dev Implements minimum pricing floor and returns the higher of the natural size-based rate or the minimum rate.
     * @param totalBytes Total size of the stored data in bytes
     * @return The storage rate per epoch
     */
    function _calculateStorageRate(uint256 totalBytes) internal view returns (uint256) {
        // Calculate natural size-based rate
        uint256 naturalRate = calculateStorageSizeBasedRatePerEpoch(totalBytes, storagePricePerTibPerMonth);

        // Calculate minimum rate (floor price converted to per-epoch).
        // Integer division truncates, so (minimumRate × EPOCHS_PER_MONTH) yields slightly less than
        // minimumStorageRatePerMonth. For typical floor prices this precision loss is under 0.0001%.
        // The pre-flight lockup check in validatePayerOperatorApprovalAndFunds uses a multiply-first
        // formula that preserves the full monthly value, ensuring users always have sufficient funds.
        uint256 minimumRate = minimumStorageRatePerMonth / EPOCHS_PER_MONTH;

        // Return whichever is higher: natural rate or minimum rate
        return naturalRate > minimumRate ? naturalRate : minimumRate;
    }

    /**
     * @notice Decode extra data for data set creation
     * @param extraData The encoded extra data from PDPVerifier
     * @return decoded The decoded DataSetCreateData struct
     */
    function decodeDataSetCreateData(bytes calldata extraData) internal pure returns (DataSetCreateData memory) {
        (address payer, uint256 clientDataSetId, string[] memory keys, string[] memory values, bytes memory signature) =
            abi.decode(extraData, (address, uint256, string[], string[], bytes));

        return DataSetCreateData({
            payer: payer,
            clientDataSetId: clientDataSetId,
            metadataKeys: keys,
            metadataValues: values,
            signature: signature
        });
    }

    /**
     * @notice Returns true if key `withCDN` exists in `metadataKeys`.
     * @param metadataKeys The array of metadata keys
     * @return True if key exists; false otherwise.
     */
    function hasCDNMetadataKey(string[] memory metadataKeys) internal pure returns (bool) {
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            bytes memory currentKeyBytes = bytes(metadataKeys[i]);
            if (
                currentKeyBytes.length == METADATA_KEY_WITH_CDN_SIZE
                    && keccak256(currentKeyBytes) == METADATA_KEY_WITH_CDN_HASH
            ) {
                return true;
            }
        }

        // Key absence means disabled
        return false;
    }

    /**
     * @notice Returns true if key `withCDN` exists in the metadata keys of the data set.
     * @param dataSetId The sequential data set identifier
     * @return True if key exists; false otherwise.
     */
    function dataSetHasCDNMetadataKey(uint256 dataSetId) internal view returns (bool) {
        string[] storage metadataKeys = dataSetMetadataKeys[dataSetId];
        unchecked {
            uint256 len = metadataKeys.length;
            for (uint256 i = 0; i < len; i++) {
                string storage metadataKey = metadataKeys[i];
                bytes32 repr;
                assembly ("memory-safe") {
                    repr := sload(metadataKey.slot)
                }
                if (repr == WITH_CDN_STRING_STORAGE_REPR) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @notice Deletes key `withCDN` if it exists in `metadataKeys`.
     * @param metadataKeys The array of metadata keys to modify
     * @return found Whether the withCDN key was deleted
     */
    function deleteCDNMetadataKey(string[] storage metadataKeys) internal returns (bool found) {
        unchecked {
            uint256 len = metadataKeys.length;
            for (uint256 i = 0; i < len; i++) {
                string storage metadataKey = metadataKeys[i];
                bytes32 repr;
                assembly ("memory-safe") {
                    repr := sload(metadataKey.slot)
                }
                if (repr == WITH_CDN_STRING_STORAGE_REPR) {
                    metadataKeys[i] = metadataKeys[len - 1];
                    metadataKeys.pop();
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @notice Get the service pricing information
     * @return pricing A struct containing pricing details for storage and CDN/cache miss egress
     */
    function getServicePrice() external view returns (ServicePricing memory pricing) {
        pricing = ServicePricing({
            pricePerTiBPerMonthNoCDN: storagePricePerTibPerMonth,
            pricePerTiBCdnEgress: CDN_EGRESS_PRICE_PER_TIB,
            pricePerTiBCacheMissEgress: CACHE_MISS_EGRESS_PRICE_PER_TIB,
            tokenAddress: usdfcTokenAddress,
            epochsPerMonth: EPOCHS_PER_MONTH,
            minimumPricePerMonth: minimumStorageRatePerMonth
        });
    }

    /**
     * @notice Get the effective rates after commission for both service types
     * @return serviceFee Service fee (per TiB per month)
     * @return spPayment SP payment (per TiB per month)
     */
    function getEffectiveRates() external view returns (uint256 serviceFee, uint256 spPayment) {
        uint256 total = storagePricePerTibPerMonth;

        serviceFee = (total * serviceCommissionBps) / COMMISSION_MAX_BPS;
        spPayment = total - serviceFee;

        return (serviceFee, spPayment);
    }

    // ============ Metadata Hashing Functions ============

    /**
     * @notice Verifies a signature for the CreateDataSet operation
     * @param createData The decoded DataSetCreateData used to build the signature
     * @param payee The service provider address
     */
    function verifyCreateDataSetSignature(address payee, DataSetCreateData memory createData) internal view {
        // Compute the EIP-712 digest for the struct hash
        bytes32 digest = _hashTypedDataV4(
            SignatureVerificationLib.createDataSetStructHash(
                createData.clientDataSetId, payee, createData.metadataKeys, createData.metadataValues
            )
        );

        // Delegate to library for verification
        SignatureVerificationLib.verifyCreateDataSetSignature(
            createData.payer, createData.signature, digest, sessionKeyRegistry
        );
    }

    /**
     * @notice Verifies a signature for the AddPieces operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The ID of the data set
     * @param pieceDataArray Array of piece CID structures
     * @param nonce Client-chosen nonce for replay protection
     * @param allKeys 2D array where allKeys[i] contains metadata keys for piece i
     * @param allValues 2D array where allValues[i] contains metadata values for piece i
     * @param signature The signature bytes (v, r, s)
     */
    function verifyAddPiecesSignature(
        address payer,
        uint256 clientDataSetId,
        Cids.Cid[] memory pieceDataArray,
        uint256 nonce,
        string[][] memory allKeys,
        string[][] memory allValues,
        bytes memory signature
    ) internal view {
        // Compute the EIP-712 digest
        bytes32 digest = _hashTypedDataV4(
            SignatureVerificationLib.addPiecesStructHash(clientDataSetId, nonce, pieceDataArray, allKeys, allValues)
        );

        // Delegate to library for verification
        SignatureVerificationLib.verifyAddPiecesSignature(payer, signature, digest, sessionKeyRegistry);
    }

    /**
     * @notice Verifies a signature for the SchedulePieceRemovals operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The ID of the data set
     * @param pieceIds Array of piece IDs to be removed
     * @param signature The signature bytes (v, r, s)
     */
    function verifySchedulePieceRemovalsSignature(
        address payer,
        uint256 clientDataSetId,
        uint256[] memory pieceIds,
        bytes memory signature
    ) internal view {
        // Compute the EIP-712 digest
        bytes32 structHash = keccak256(
            abi.encode(
                SignatureVerificationLib.SCHEDULE_PIECE_REMOVALS_TYPEHASH,
                clientDataSetId,
                keccak256(abi.encodePacked(pieceIds))
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);

        // Delegate to library for verification
        SignatureVerificationLib.verifySchedulePieceRemovalsSignature(payer, signature, digest, sessionKeyRegistry);
    }

    /**
     * @notice Arbitrates payment based on faults in the given epoch range
     * @dev Implements the IValidator interface function
     *
     * @param railId ID of the payment rail
     * @param proposedAmount The originally proposed payment amount
     * @param fromEpoch Starting epoch (exclusive)
     * @param toEpoch Ending epoch (inclusive)
     * @return result The validation result with modified amount and settlement information
     */
    function validatePayment(
        uint256 railId,
        uint256 proposedAmount,
        uint256 fromEpoch,
        uint256 toEpoch,
        uint256 /* rate */
    ) external view override returns (ValidationResult memory result) {
        // Get the data set ID associated with this rail
        uint256 dataSetId = railToDataSet[railId];
        require(dataSetId != 0, Errors.RailNotAssociated(railId));

        // Calculate the total number of epochs in the requested range
        uint256 totalEpochsRequested = toEpoch - fromEpoch;
        require(totalEpochsRequested > 0, Errors.InvalidEpochRange(fromEpoch, toEpoch));

        // If proving wasn't ever activated for this data set, don't pay anything
        uint256 activationEpoch = provingActivationEpoch[dataSetId];
        if (activationEpoch == 0) {
            return ValidationResult({
                modifiedAmount: 0,
                settleUpto: fromEpoch,
                note: "Proving never activated for this data set"
            });
        }

        // Count proven epochs up to toEpoch, possibly stopping earlier if unresolved
        (uint256 provenEpochCount, uint256 settleUpTo) =
            _findProvenEpochs(dataSetId, fromEpoch, toEpoch, activationEpoch);

        // If no epochs are proven, no payment is due (but settlement may still advance)
        if (provenEpochCount == 0) {
            return ValidationResult({
                modifiedAmount: 0,
                settleUpto: settleUpTo,
                note: "No proven epochs in the requested range"
            });
        }

        // Calculate the modified amount based on proven epochs
        uint256 modifiedAmount = (proposedAmount * provenEpochCount) / totalEpochsRequested;

        return ValidationResult({modifiedAmount: modifiedAmount, settleUpto: settleUpTo, note: ""});
    }

    function _findProvenEpochs(uint256 dataSetId, uint256 fromEpoch, uint256 toEpoch, uint256 activationEpoch)
        internal
        view
        returns (uint256 provenEpochCount, uint256 settleUpTo)
    {
        require(toEpoch >= activationEpoch && toEpoch <= block.number, Errors.InvalidEpochRange(fromEpoch, toEpoch));
        if (fromEpoch < activationEpoch) {
            fromEpoch = activationEpoch;
        }

        uint256 startingPeriod = _provingPeriodForEpoch(activationEpoch, fromEpoch + 1);

        // handle first period separately; it may be partially settled already
        uint256 startingPeriodDeadline = _calcPeriodDeadline(activationEpoch, startingPeriod);

        if (toEpoch < startingPeriodDeadline) {
            if (_isPeriodProven(dataSetId, startingPeriod)) {
                provenEpochCount = toEpoch - fromEpoch;
                settleUpTo = toEpoch;
            } else if (block.number <= startingPeriodDeadline) {
                // do not partial-settle an unproven period which might later be proven
                settleUpTo = fromEpoch;
            } else {
                settleUpTo = toEpoch;
            }
        } else {
            if (_isPeriodProven(dataSetId, startingPeriod)) {
                provenEpochCount += (startingPeriodDeadline - fromEpoch);
            }

            uint256 endingPeriod = _provingPeriodForEpoch(activationEpoch, toEpoch);
            // loop through the proving periods between startingPeriod and endingPeriod
            for (uint256 period = startingPeriod + 1; period < endingPeriod; period++) {
                if (_isPeriodProven(dataSetId, period)) {
                    provenEpochCount += maxProvingPeriod;
                }
            }
            uint256 endingPeriodDeadline = _calcPeriodDeadline(activationEpoch, endingPeriod);
            settleUpTo = endingPeriodDeadline - maxProvingPeriod;

            // handle the last period separately
            if (_isPeriodProven(dataSetId, endingPeriod)) {
                provenEpochCount += (toEpoch - settleUpTo);
                settleUpTo = toEpoch;
            } else if (endingPeriodDeadline < block.number) {
                // Period deadline passed but unproven - advance settlement with zero payment
                settleUpTo = toEpoch;
            }
            // else: period still open - settlement blocked at previous settleUpTo
        }
        return (provenEpochCount, settleUpTo);
    }

    function _isPeriodProven(uint256 dataSetId, uint256 periodId) private view returns (bool) {
        uint256 isProven = provenPeriods[dataSetId][periodId >> 8] & (1 << (periodId & 255));
        return isProven != 0;
    }

    function _calcPeriodDeadline(uint256 activationEpoch, uint256 periodId) private view returns (uint256) {
        return activationEpoch + (periodId + 1) * maxProvingPeriod;
    }

    function railTerminated(uint256 railId, address terminator, uint256 endEpoch) external override {
        require(msg.sender == paymentsContractAddress, Errors.CallerNotPayments(paymentsContractAddress, msg.sender));

        if (terminator != address(this)) {
            revert Errors.ServiceContractMustTerminateRail();
        }

        uint256 dataSetId = railToDataSet[railId];
        require(dataSetId != 0, Errors.DataSetNotFoundForRail(railId));
        DataSetInfo storage info = dataSetInfo[dataSetId];
        if (info.pdpEndEpoch == 0 && railId == info.pdpRailId) {
            info.pdpEndEpoch = endEpoch;
            emit PDPPaymentTerminated(dataSetId, endEpoch, info.pdpRailId);
        }
    }
}
