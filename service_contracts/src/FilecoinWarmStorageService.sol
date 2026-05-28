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

import {
    CACHE_MISS_EGRESS_PRICE_PER_TIB,
    ADD_PIECES_BASE_FEE,
    ADD_PIECES_PER_PIECE_FEE,
    CREATE_DATA_SET_FEE,
    CDN_EGRESS_PRICE_PER_TIB,
    DATASET_FEE_PER_MONTH,
    DEFAULT_LOCKUP_PERIOD,
    EPOCHS_PER_MONTH,
    LIFECYCLE_RESERVE_TARGET,
    SCHEDULE_PIECE_REMOVALS_FEE,
    SERVICE_COMMISSION_BPS,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    TERMINATE_FEE,
    TOKEN_DECIMALS
} from "./lib/PriceListUSDFC.sol";
import {Rails} from "./lib/Rails.sol";
import {SignatureVerificationLib} from "./lib/SignatureVerificationLib.sol";

uint256 constant NO_PROVING_DEADLINE = 0;
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

/*
* Maximum extraData for terminateService
* Supports: signature (160 bytes needed)
*/
uint256 constant MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE = 256; // 256 bytes

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
    string public constant VERSION = "1.2.0";

    using Rails for FilecoinPayV1;

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
    event PieceAdded(
        uint256 indexed dataSetId, uint256 indexed pieceId, Cids.Cid pieceCid, string[] keys, string[] values
    );

    /// @notice Emitted when a service is terminated.
    /// @param approver The address that authorized termination: the payer, one of the payer's
    ///   session keys (SessionKeyRegistry), or the service provider. Cross-reference with
    ///   `DataSetCreated` to classify: `approver == serviceProvider` is provider-initiated;
    ///   otherwise the payer (or their session key) authorized it. Mutual termination — payer
    ///   signed off-chain while the provider submitted the tx — is indistinguishable from
    ///   payer-initiated using this event alone; inspect the call trace to detect it.
    event ServiceTerminated(
        address indexed approver,
        uint256 indexed dataSetId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId
    );

    event PDPPaymentTerminated(uint256 indexed dataSetId, uint256 endEpoch, uint256 pdpRailId);

    event CDNPaymentTerminated(uint256 indexed dataSetId, uint256 endEpoch, uint256 cacheMissRailId, uint256 cdnRailId);

    event FilBeamControllerChanged(address oldController, address newController);

    event ViewContractSet(address indexed viewContract);

    // Events for provider management
    event ProviderApproved(uint256 indexed providerId);
    event ProviderUnapproved(uint256 indexed providerId);

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
        uint96 pendingOneTimePayments; // fees accumulated since last flush via updateStorageRates
        uint96 lifecycleReserveBalance; // local mirror of rail's lockupFixed; decremented on flush
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
        uint96 pendingOneTimePayments; // fees accumulated since last flush via updateStorageRates
        uint96 lifecycleReserveBalance; // local mirror of rail's lockupFixed; decremented on flush
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
        uint256 datasetFeePerMonth; // Per-dataset additive monthly fee (0.024 USDFC)
    }

    // Used for announcing upgrades, packed into one slot
    struct PlannedUpgrade {
        // Address of the new implementation contract
        address nextImplementation;
        // Upgrade will not occur until at least this epoch
        uint96 afterEpoch;
    }

    // Constants

    uint256 private constant NO_CHALLENGE_SCHEDULED = 0;

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
    uint256 private deprecatedServiceCommissionBps;

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
    uint256 private deprecatedStoragePricePerTibPerMonth;
    uint256 private deprecatedMinimumStorageRatePerMonth;

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

        // Verify token decimals from the USDFC token contract
        require(TOKEN_DECIMALS == _usdfc.decimals());
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

        require(approvedProviderIds[index] == providerId, Errors.ProviderIdMismatchAtIndex(index, providerId));

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
        info.commissionBps = SERVICE_COMMISSION_BPS;
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

        (uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId) = payments.createRails(
            dataSetId, usdfcTokenAddress, createData.payer, payee, hasCDN ? filBeamBeneficiaryAddress : address(0)
        );

        railToDataSet[pdpRailId] = dataSetId;
        info.pdpRailId = pdpRailId;
        info.lifecycleReserveBalance = uint96(LIFECYCLE_RESERVE_TARGET);
        info.pendingOneTimePayments = uint96(CREATE_DATA_SET_FEE);
        if (hasCDN) {
            info.cacheMissRailId = cacheMissRailId;
            info.cdnRailId = cdnRailId;
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

        uint96 pending =
            info.pendingOneTimePayments + uint96(ADD_PIECES_BASE_FEE + pieceData.length * ADD_PIECES_PER_PIECE_FEE);
        uint96 reserveBalance = info.lifecycleReserveBalance;

        // Validate lockup for the new data set size (fail-fast if client has insufficient funds)
        uint256 currentLeafCount = IPDPVerifier(pdpVerifierAddress).getDataSetLeafCount(dataSetId);
        updatePaymentRates(dataSetId, info, currentLeafCount, pending, reserveBalance);

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

        info.pendingOneTimePayments += uint96(SCHEDULE_PIECE_REMOVALS_FEE);

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

        DataSetInfo storage info = dataSetInfo[dataSetId];
        uint96 pending = info.pendingOneTimePayments;
        uint96 reserveBalance = info.lifecycleReserveBalance;

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

            // Rate was already set in piecesAdded; only update if pieces were removed or fees are pending
            if (processScheduledPieceMetadataRemovals(dataSetId) || pending > 0) {
                updatePaymentRates(dataSetId, info, leafCount, pending, reserveBalance);
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

        // Additions update rate immediately in piecesAdded; update here if pieces were removed or fees are pending
        bool hadRemovals = processScheduledPieceMetadataRemovals(dataSetId);
        if (hadRemovals || pending > 0) {
            updatePaymentRates(dataSetId, info, leafCount, pending, reserveBalance);
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
        revert Errors.StorageProviderChangesNotSupported();
    }

    function terminateService(uint256 dataSetId, bytes calldata extraData) external {
        _terminateService(dataSetId, extraData);
    }

    /// @custom:deprecated Use terminateService(uint256,bytes) instead
    function terminateService(uint256 dataSetId) public {
        _terminateService(dataSetId, "");
    }

    function _terminateService(uint256 dataSetId, bytes memory extraData) private {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.pdpEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));

        address approver;
        if (extraData.length > 0) {
            require(
                extraData.length <= MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE,
                Errors.ExtraDataTooLarge(extraData.length, MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE)
            );
            bytes memory signature = abi.decode(extraData, (bytes));
            approver = _verifyTerminateServiceSignature(info.payer, dataSetId, signature);
            if (msg.sender == info.serviceProvider) {
                // TODO termination can be immediate
                info.pendingOneTimePayments += uint96(TERMINATE_FEE);
            }
        } else {
            require(
                msg.sender == info.payer || msg.sender == info.serviceProvider,
                Errors.CallerNotPayerOrPayee(dataSetId, info.payer, info.serviceProvider, msg.sender)
            );
            approver = msg.sender;
        }

        FilecoinPayV1 payments = FilecoinPayV1(paymentsContractAddress);

        uint96 pending = info.pendingOneTimePayments;
        if (pending > 0) {
            uint256 leafCount = IPDPVerifier(pdpVerifierAddress).getDataSetLeafCount(dataSetId);
            updatePaymentRates(dataSetId, info, leafCount, pending, info.lifecycleReserveBalance);
        }

        payments.terminateRail(info.pdpRailId);

        if (deleteCDNMetadataKey(dataSetMetadataKeys[dataSetId])) {
            _terminateCDNRails(dataSetId, info, payments);
        }

        emit ServiceTerminated(approver, dataSetId, info.pdpRailId, info.cacheMissRailId, info.cdnRailId);
    }

    /**
     * @notice Pre-funds the lifecycle reserve beyond the automatic target
     * @dev Useful before scheduling many piece removals or before terminating.
     *      Cannot be called after termination; FilecoinPay forbids raising lockupFixed on a terminated rail.
     * @param dataSetId The ID of the data set
     * @param amount Additional amount to add to the lifecycle reserve
     */
    function topUpLifecycleReserve(uint256 dataSetId, uint256 amount) external {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(msg.sender == info.payer, Errors.CallerNotPayer(dataSetId, info.payer, msg.sender));

        uint256 pdpRailId = info.pdpRailId;
        uint96 newBalance = info.lifecycleReserveBalance + uint96(amount);
        FilecoinPayV1(paymentsContractAddress).modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, newBalance);
        info.lifecycleReserveBalance = newBalance;
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

        // Check if CDN rails are configured (presence of rails indicates CDN was set up)
        require(info.cdnRailId != 0 && info.cacheMissRailId != 0, Errors.InvalidDataSetId(dataSetId));

        FilecoinPayV1(paymentsContractAddress).settleCDNRails(
            info.cdnRailId, info.cacheMissRailId, cdnAmount, cacheMissAmount
        );
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

        FilecoinPayV1(paymentsContractAddress).topUpCDNRails(
            dataSetId, info.cacheMissRailId, info.cdnRailId, cacheMissAmountToAdd, cdnAmountToAdd
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

        _terminateCDNRails(dataSetId, info, payments);
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

    /// @notice Terminates CDN rails (cacheMiss + CDN), deletes withCDN metadata, and emits event.
    /// @dev Uses try/catch because CDN rails may have been terminated externally via FilecoinPay.
    /// ⚠️ WARNING: Catch-all error handling will silently suppress ALL errors from terminateRail(),
    /// not just "already terminated/finalized" errors. This could mask legitimate failures.
    /// Ideally we would catch only specific error types, but contract size constraint prevents
    /// us from implementing error handling.
    function _terminateCDNRails(uint256 dataSetId, DataSetInfo storage info, FilecoinPayV1 payments) internal {
        payments.terminateCDNRails(dataSetId, info.cacheMissRailId, info.cdnRailId);
        delete dataSetMetadata[dataSetId][METADATA_KEY_WITH_CDN];
    }

    function updatePaymentRates(
        uint256 dataSetId,
        DataSetInfo storage info,
        uint256 leafCount,
        uint96 pending,
        uint96 reserveBalance
    ) internal {
        uint256 pdpRailId = info.pdpRailId;
        require(pdpRailId != 0, Errors.NoPDPPaymentRail(dataSetId));

        info.lifecycleReserveBalance = FilecoinPayV1(paymentsContractAddress).updateStorageRates(
            dataSetId, pdpRailId, leafCount, pending, reserveBalance
        );
        info.pendingOneTimePayments = 0;
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
        return _provingPeriodForEpoch(provingActivationEpoch[dataSetId], epoch, maxProvingPeriod);
    }

    /// @dev Maps an epoch to its proving period ID using exclusive-inclusive ranges.
    ///
    /// Proving periods use (start, end] ranges where the original activation epoch is a
    /// boundary marker (and not included in the first period).
    ///
    /// With activation at A and period length M:
    ///
    ///   Period 0: epochs (A, A+M]     i.e. A+1 through A+M
    ///   Period 1: epochs (A+M, A+2M]  i.e. A+M+1 through A+2M
    ///   Period N: epochs (A+N*M, A+(N+1)*M]
    ///
    /// The deadline for period N (the last epoch at which a proof can be submitted)
    /// is A + (N+1)*M, this also the last epoch counted in the period.
    ///
    /// Example with A=1000, M=2880:
    ///   Period 0: epochs 1001-3880, deadline 3880
    ///   Period 1: epochs 3881-6760, deadline 6760
    function _provingPeriodForEpoch(uint256 activationEpoch, uint256 epoch, uint256 provingPeriodLength)
        internal
        pure
        returns (uint256)
    {
        if (activationEpoch == 0 || epoch <= activationEpoch) {
            return type(uint256).max; // Invalid period
        }
        // -1 converts from inclusive-exclusive to exclusive-inclusive ranges,
        // where the deadline epoch belongs to its own period rather than the next
        return (epoch - activationEpoch - 1) / provingPeriodLength;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
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
            pricePerTiBPerMonthNoCDN: STORAGE_PRICE_PER_TIB_PER_MONTH,
            pricePerTiBCdnEgress: CDN_EGRESS_PRICE_PER_TIB,
            pricePerTiBCacheMissEgress: CACHE_MISS_EGRESS_PRICE_PER_TIB,
            tokenAddress: usdfcTokenAddress,
            epochsPerMonth: EPOCHS_PER_MONTH,
            datasetFeePerMonth: DATASET_FEE_PER_MONTH
        });
    }

    /**
     * @notice Get the effective rates after commission for both service types
     * @return serviceFee Service fee (per TiB per month)
     * @return spPayment SP payment (per TiB per month)
     */
    function getEffectiveRates() external pure returns (uint256 serviceFee, uint256 spPayment) {
        uint256 total = STORAGE_PRICE_PER_TIB_PER_MONTH;

        serviceFee = (total * SERVICE_COMMISSION_BPS) / COMMISSION_MAX_BPS;
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

    function _verifyTerminateServiceSignature(address payer, uint256 dataSetId, bytes memory signature)
        internal
        view
        returns (address signer)
    {
        bytes32 structHash = keccak256(abi.encode(SignatureVerificationLib.TERMINATE_SERVICE_TYPEHASH, dataSetId));
        bytes32 digest = _hashTypedDataV4(structHash);
        return SignatureVerificationLib.verifyTerminateServiceSignature(payer, signature, digest, sessionKeyRegistry);
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

    /// @dev Counts proven epochs and determines how far settlement can advance.
    ///
    /// Called by validatePayment() to arbitrate how much a provider should be paid for
    /// a given epoch range. Returns two values:
    ///   - provenEpochCount: number of epochs with valid proofs (determines payment)
    ///   - settleUpTo: the epoch up to which settlement can advance (may exceed proven range)
    ///
    /// These are deliberately decoupled: settlement can advance past faulted periods with zero
    /// payment, allowing the rail to eventually be fully settled and finalised even if the
    /// provider missed proofs.
    ///
    /// Iterates through each proving period that overlaps the range (fromEpoch, toEpoch].
    /// Partial periods at the start and end are handled by clamping each period's contribution
    /// to [max(periodStart, fromEpoch), min(toEpoch, deadline)].
    ///
    /// For each period, one of three rules applies:
    ///
    ///   Proven:  Period has a valid proof. Count epochs toward payment, advance settleUpTo.
    ///   Faulted: Deadline has passed with no proof. Advance settleUpTo (zero payment).
    ///   Open:    Deadline has not yet passed. Don't update settleUpTo, blocking settlement
    ///            at wherever the previous period left it. Note: only the last period in
    ///            the range can be open (toEpoch <= block.number guarantees earlier deadlines
    ///            have passed).
    ///
    /// Partial-period requests arise when FilecoinPay settles each rate segment independently
    /// (see _settleWithRateChanges). If the rate changed mid-period (e.g. pieces were added),
    /// toEpoch will fall within a period rather than on a boundary.
    function _findProvenEpochs(uint256 dataSetId, uint256 fromEpoch, uint256 toEpoch, uint256 activationEpoch)
        internal
        view
        returns (uint256 provenEpochCount, uint256 settleUpTo)
    {
        require(toEpoch >= activationEpoch && toEpoch <= block.number, Errors.InvalidEpochRange(fromEpoch, toEpoch));
        if (fromEpoch < activationEpoch) {
            fromEpoch = activationEpoch;
        }
        settleUpTo = fromEpoch;
        uint256 startingPeriod = _provingPeriodForEpoch(activationEpoch, fromEpoch + 1, maxProvingPeriod);
        uint256 endingPeriod = _provingPeriodForEpoch(activationEpoch, toEpoch, maxProvingPeriod);
        uint256 deadline = _calcPeriodDeadline(activationEpoch, startingPeriod);
        for (uint256 period = startingPeriod; period <= endingPeriod; period++) {
            if (_isPeriodProven(dataSetId, period)) {
                uint256 settleStart = max(deadline - maxProvingPeriod, fromEpoch);
                settleUpTo = min(toEpoch, deadline);
                provenEpochCount += settleUpTo - settleStart;
            } else if (deadline < block.number) {
                // Faulted: deadline passed, no proof, advance with zero payment
                settleUpTo = min(toEpoch, deadline);
            } //else { } // Open: deadline hasn't passed, proof may still arrive, block settlement
            deadline += maxProvingPeriod;
        }

        return (provenEpochCount, settleUpTo);
    }

    function _isPeriodProven(uint256 dataSetId, uint256 periodId) private view returns (bool) {
        uint256 isProven = provenPeriods[dataSetId][periodId >> 8] & (1 << (periodId & 255));
        return isProven != 0;
    }

    /// @dev Returns the deadline epoch for a proving period. The last epoch at which a
    /// proof can be submitted and the last epoch IN that period. For period N with
    /// activation A and period length M: deadline = A + (N+1)*M.
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
