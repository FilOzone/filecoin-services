// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {PDPListener} from "@pdp/PDPVerifier.sol";
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
    string public constant VERSION = "0.3.0";

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

    // Event for validation
    event PaymentArbitrated(
        uint256 railId, uint256 dataSetId, uint256 originalAmount, uint256 modifiedAmount, uint256 faultedEpochs
    );

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
        // Data set doesn't yet exist or has been deleted
        NotFound,
        // Data set is active
        Active,
        // Data set is in the process of being terminated
        Terminating
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
        uint256 pricePerTiBPerMonthNoCDN; // Price without CDN add-on (5 USDFC per TiB per month)
        uint256 pricePerTiBPerMonthWithCDN; // Price with CDN add-on (3 USDFC per TiB per month)
        IERC20 tokenAddress; // Address of the USDFC token
        uint256 epochsPerMonth; // Number of epochs in a month
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

    // Pricing constants
    uint256 private immutable STORAGE_PRICE_PER_TIB_PER_MONTH; // 5 USDFC per TiB per month without CDN with correct decimals
    uint256 private immutable CACHE_MISS_PRICE_PER_TIB_PER_MONTH; // .5 USDFC per TiB per month for CDN with correct decimals
    uint256 private immutable CDN_PRICE_PER_TIB_PER_MONTH; // .5 USDFC per TiB per month for CDN with correct decimals

    // Fixed lockup amounts for CDN rails
    uint256 private immutable DEFAULT_CDN_LOCKUP_AMOUNT; // 0.7 USDFC
    uint256 private immutable DEFAULT_CACHE_MISS_LOCKUP_AMOUNT; // 0.3 USDFC

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
    mapping(address payer => mapping(uint256 clientDataSetId => uint256)) private clientDataSetIds;
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
        SessionKeyRegistry _sessionKeyRegistry
    ) {
        _disableInitializers();

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

        // Initialize the fee constants based on the actual token decimals
        STORAGE_PRICE_PER_TIB_PER_MONTH = (5 * 10 ** TOKEN_DECIMALS); // 5 USDFC
        CACHE_MISS_PRICE_PER_TIB_PER_MONTH = (1 * 10 ** TOKEN_DECIMALS) / 2; // 0.5 USDFC
        CDN_PRICE_PER_TIB_PER_MONTH = (1 * 10 ** TOKEN_DECIMALS) / 2; // 0.5 USDFC

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
    function migrate(address _viewContract) public onlyProxy onlyOwner reinitializer(4) {
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
        require(_viewContract != address(0), Errors.ZeroAddress(Errors.AddressField.View));
        require(viewContractAddress == address(0), Errors.AddressAlreadySet(Errors.AddressField.View));
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
        require(extraData.length > 0, Errors.ExtraDataRequired());
        DataSetCreateData memory createData = decodeDataSetCreateData(extraData);

        // Validate the addresses
        require(createData.payer != address(0), Errors.ZeroAddress(Errors.AddressField.Payer));
        require(serviceProvider != address(0), Errors.ZeroAddress(Errors.AddressField.ServiceProvider));

        uint256 providerId = serviceProviderRegistry.getProviderIdByAddress(serviceProvider);

        require(providerId != 0, Errors.ProviderNotRegistered(serviceProvider));

        // Check if provider is approved
        require(approvedProviders[providerId], Errors.ProviderNotApproved(serviceProvider, providerId));

        address payee = serviceProviderRegistry.getProviderPayee(providerId);

        require(
            clientDataSetIds[createData.payer][createData.clientDataSetId] == 0,
            Errors.ClientDataSetAlreadyRegistered(createData.clientDataSetId)
        );
        clientDataSetIds[createData.payer][createData.clientDataSetId] = dataSetId;
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

        if (hasCDNMetadataKey(createData.metadataKeys)) {
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

        // NOTE keep clientDataSetIds[payer][clientDataSetId] to prevent replay

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
     * @dev Called by the PDPVerifier contract when pieces are added to a data set
     * @param dataSetId The ID of the data set
     * @param firstAdded The ID of the first piece added
     * @param pieceData Array of piece data objects
     * @param extraData Encoded metadata, and signature
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
        require(extraData.length > 0, Errors.ExtraDataRequired());
        // Decode the extra data
        (bytes memory signature, string[][] memory metadataKeys, string[][] memory metadataValues) =
            abi.decode(extraData, (bytes, string[][], string[][]));

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
        verifyAddPiecesSignature(
            payer, info.clientDataSetId, pieceData, firstAdded, metadataKeys, metadataValues, signature
        );

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
        require(extraData.length > 0, Errors.ExtraDataRequired());
        bytes memory signature = abi.decode(extraData, (bytes));

        // Verify the signature
        verifySchedulePieceRemovalsSignature(payer, info.clientDataSetId, pieceIds, signature);

        // Additional logic for scheduling removals can be added here
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
            provenThisPeriod[dataSetId] = false;

            // Initialize the activation epoch when proving first starts
            // This marks when the data set became active for proving
            provingActivationEpoch[dataSetId] = block.number;

            // Update the payment rates
            updatePaymentRates(dataSetId, leafCount);

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

        // Record the status of the current/previous proving period that's ending
        if (provingDeadlines[dataSetId] != NO_PROVING_DEADLINE && provenThisPeriod[dataSetId]) {
            // Determine the period ID that just completed
            uint256 completedPeriodId = getProvingPeriodForEpoch(dataSetId, provingDeadlines[dataSetId] - 1);

            // Record whether this period was proven
            provenPeriods[dataSetId][completedPeriodId >> 8] |= 1 << (completedPeriodId & 255);
        }

        provingDeadlines[dataSetId] = nextDeadline;
        provenThisPeriod[dataSetId] = false;

        // Update the payment rates based on current data set size
        updatePaymentRates(dataSetId, leafCount);
    }

    /**
     * @notice Handles data set service provider changes by updating internal state only
     * @dev Called by the PDPVerifier contract when data set service provider is transferred.
     * NOTE: The PDPVerifier contract emits events and exposes methods in terms of "storage providers",
     * because its scope is specifically the Proof-of-Data-Possession for storage services.
     * In FilecoinWarmStorageService (and the broader service registry architecture), we use the term
     * "service provider" to support a future where multiple types of services may exist (not just storage).
     * As a result, some parameters and events reflect this terminology shift and this method represents
     * a transition point in the language, from PDPVerifier to FilecoinWarmStorageService.
     * @param dataSetId The ID of the data set whose service provider is changing
     * @param oldServiceProvider The previous service provider address
     * @param newServiceProvider The new service provider address (must be an approved provider)
     */
    function storageProviderChanged(
        uint256 dataSetId,
        address oldServiceProvider,
        address newServiceProvider,
        bytes calldata // extraData - not used
    ) external override onlyPDPVerifier {
        // Verify the data set exists and validate the old service provider
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(
            info.serviceProvider == oldServiceProvider,
            Errors.OldServiceProviderMismatch(dataSetId, info.serviceProvider, oldServiceProvider)
        );
        require(newServiceProvider != address(0), Errors.ZeroAddress(Errors.AddressField.ServiceProvider));

        // Verify new service provider is registered and approved
        uint256 newProviderId = serviceProviderRegistry.getProviderIdByAddress(newServiceProvider);

        // Check if provider is registered
        require(newProviderId != 0, Errors.ProviderNotRegistered(newServiceProvider));

        // Check if provider is approved
        require(approvedProviders[newProviderId], Errors.ProviderNotApproved(newServiceProvider, newProviderId));

        // Update the data set service provider
        info.serviceProvider = newServiceProvider;

        // Emit event for off-chain tracking
        emit DataSetServiceProviderChanged(dataSetId, oldServiceProvider, newServiceProvider);
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
            payments.terminateRail(info.cacheMissRailId);
            payments.terminateRail(info.cdnRailId);

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
        payments.terminateRail(info.cacheMissRailId);
        payments.terminateRail(info.cdnRailId);

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

    function updatePaymentRates(uint256 dataSetId, uint256 leafCount) internal {
        // Revert if no payment rail is configured for this data set
        require(dataSetInfo[dataSetId].pdpRailId != 0, Errors.NoPDPPaymentRail(dataSetId));

        uint256 totalBytes = leafCount * BYTES_PER_LEAF;
        FilecoinPayV1 payments = FilecoinPayV1(paymentsContractAddress);

        // Update the PDP rail payment rate with the new rate and no one-time
        // payment
        uint256 pdpRailId = dataSetInfo[dataSetId].pdpRailId;
        uint256 newStorageRatePerEpoch = _calculateStorageRate(totalBytes);
        payments.modifyRailPayment(
            pdpRailId,
            newStorageRatePerEpoch,
            0 // No one-time payment during rate update
        );
        emit RailRateUpdated(dataSetId, pdpRailId, newStorageRatePerEpoch);

        // Update the CDN rail payment rates, if applicable
        if (dataSetHasCDNMetadataKey(dataSetId)) {
            (uint256 newCacheMissRatePerEpoch, uint256 newCDNRatePerEpoch) = _calculateCDNRates(totalBytes);

            uint256 cacheMissRailId = dataSetInfo[dataSetId].cacheMissRailId;
            payments.modifyRailPayment(cacheMissRailId, newCacheMissRatePerEpoch, 0);
            emit RailRateUpdated(dataSetId, cacheMissRailId, newCacheMissRatePerEpoch);

            uint256 cdnRailId = dataSetInfo[dataSetId].cdnRailId;
            payments.modifyRailPayment(cdnRailId, newCDNRatePerEpoch, 0);
            emit RailRateUpdated(dataSetId, cdnRailId, newCDNRatePerEpoch);
        }
    }

    /**
     * @notice Determines which proving period an epoch belongs to
     * @dev For a given epoch, calculates the period ID based on activation time
     * @param dataSetId The ID of the data set
     * @param epoch The epoch to check
     * @return The period ID this epoch belongs to, or type(uint256).max if before activation
     */
    function getProvingPeriodForEpoch(uint256 dataSetId, uint256 epoch) public view returns (uint256) {
        uint256 activationEpoch = provingActivationEpoch[dataSetId];

        // If proving wasn't activated or epoch is before activation
        if (activationEpoch == 0 || epoch < activationEpoch) {
            return type(uint256).max; // Invalid period
        }

        // Calculate periods since activation
        // For example, if activation is at epoch 1000 and proving period is 2880:
        // - Epoch 1000-3879 is period 0
        // - Epoch 3880-6759 is period 1
        // and so on
        return (epoch - activationEpoch) / maxProvingPeriod;
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
     * @notice Calculate all per-epoch rates based on total storage size
     * @dev Returns storage, cache miss, and CDN rates per TiB per month
     * @param totalBytes Total size of the stored data in bytes
     * @return storageRate The PDP storage rate per epoch
     * @return cacheMissRate The cache miss rate per epoch
     * @return cdnRate The CDN rate per epoch
     */
    function calculateRatesPerEpoch(uint256 totalBytes)
        external
        view
        returns (uint256 storageRate, uint256 cacheMissRate, uint256 cdnRate)
    {
        storageRate = calculateStorageSizeBasedRatePerEpoch(totalBytes, STORAGE_PRICE_PER_TIB_PER_MONTH);
        cacheMissRate = calculateStorageSizeBasedRatePerEpoch(totalBytes, CACHE_MISS_PRICE_PER_TIB_PER_MONTH);
        cdnRate = calculateStorageSizeBasedRatePerEpoch(totalBytes, CDN_PRICE_PER_TIB_PER_MONTH);
    }

    /**
     * @notice Calculate the storage rate per epoch (internal use)
     * @param totalBytes Total size of the stored data in bytes
     * @return The storage rate per epoch
     */
    function _calculateStorageRate(uint256 totalBytes) internal view returns (uint256) {
        return calculateStorageSizeBasedRatePerEpoch(totalBytes, STORAGE_PRICE_PER_TIB_PER_MONTH);
    }

    /**
     * @notice Calculate the CDN rates per epoch (internal use)
     * @param totalBytes Total size of the stored data in bytes
     * @return cacheMissRate The cache miss rate per epoch
     * @return cdnRate The CDN rate per epoch
     */
    function _calculateCDNRates(uint256 totalBytes) internal view returns (uint256 cacheMissRate, uint256 cdnRate) {
        cacheMissRate = calculateStorageSizeBasedRatePerEpoch(totalBytes, CACHE_MISS_PRICE_PER_TIB_PER_MONTH);
        cdnRate = calculateStorageSizeBasedRatePerEpoch(totalBytes, CDN_PRICE_PER_TIB_PER_MONTH);
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
     * @return pricing A struct containing pricing details for both CDN and non-CDN storage
     */
    function getServicePrice() external view returns (ServicePricing memory pricing) {
        pricing = ServicePricing({
            pricePerTiBPerMonthNoCDN: STORAGE_PRICE_PER_TIB_PER_MONTH,
            pricePerTiBPerMonthWithCDN: STORAGE_PRICE_PER_TIB_PER_MONTH + CDN_PRICE_PER_TIB_PER_MONTH,
            tokenAddress: usdfcTokenAddress,
            epochsPerMonth: EPOCHS_PER_MONTH
        });
    }

    /**
     * @notice Get the effective rates after commission for both service types
     * @return serviceFee Service fee (per TiB per month)
     * @return spPayment SP payment (per TiB per month)
     */
    function getEffectiveRates() external view returns (uint256 serviceFee, uint256 spPayment) {
        uint256 total = STORAGE_PRICE_PER_TIB_PER_MONTH;

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
     * @param firstAdded The first piece ID being added
     * @param allKeys 2D array where allKeys[i] contains metadata keys for piece i
     * @param allValues 2D array where allValues[i] contains metadata values for piece i
     * @param signature The signature bytes (v, r, s)
     */
    function verifyAddPiecesSignature(
        address payer,
        uint256 clientDataSetId,
        Cids.Cid[] memory pieceDataArray,
        uint256 firstAdded,
        string[][] memory allKeys,
        string[][] memory allValues,
        bytes memory signature
    ) internal view {
        // Compute the EIP-712 digest
        bytes32 digest = _hashTypedDataV4(
            SignatureVerificationLib.addPiecesStructHash(
                clientDataSetId, firstAdded, pieceDataArray, allKeys, allValues
            )
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
    ) external override returns (ValidationResult memory result) {
        // Get the data set ID associated with this rail
        uint256 dataSetId = railToDataSet[railId];
        require(dataSetId != 0, Errors.RailNotAssociated(railId));

        // Calculate the total number of epochs in the requested range
        uint256 totalEpochsRequested = toEpoch - fromEpoch;
        require(totalEpochsRequested > 0, Errors.InvalidEpochRange(fromEpoch, toEpoch));

        // If proving wasn't ever activated for this data set, don't pay anything
        if (provingActivationEpoch[dataSetId] == 0) {
            return ValidationResult({
                modifiedAmount: 0,
                settleUpto: fromEpoch,
                note: "Proving never activated for this data set"
            });
        }

        // Count proven epochs and find the last proven epoch
        uint256 provenEpochCount = 0;
        uint256 lastProvenEpoch = fromEpoch;

        (provenEpochCount, lastProvenEpoch) = _findProvenEpochs(dataSetId, fromEpoch, toEpoch);

        // If no epochs are proven, we can't settle anything
        if (provenEpochCount == 0) {
            return ValidationResult({
                modifiedAmount: 0,
                settleUpto: fromEpoch,
                note: "No proven epochs in the requested range"
            });
        }

        // Calculate the modified amount based on proven epochs
        uint256 modifiedAmount = (proposedAmount * provenEpochCount) / totalEpochsRequested;

        // Calculate how many epochs were not proven (faulted)
        uint256 faultedEpochs = totalEpochsRequested - provenEpochCount;

        // Emit event for logging
        emit PaymentArbitrated(railId, dataSetId, proposedAmount, modifiedAmount, faultedEpochs);

        return ValidationResult({
            modifiedAmount: modifiedAmount,
            settleUpto: lastProvenEpoch, // Settle up to the last proven epoch
            note: ""
        });
    }

    function _findProvenEpochs(uint256 dataSetId, uint256 fromEpoch, uint256 toEpoch)
        internal
        view
        returns (uint256, uint256)
    {
        uint256 provenEpochCount = 0;
        uint256 lastProvenEpoch = fromEpoch;
        uint256 activationEpoch = provingActivationEpoch[dataSetId];
        uint256 currentPeriod = getProvingPeriodForEpoch(dataSetId, block.number);
        if (toEpoch >= activationEpoch && toEpoch < block.number) {
            // if `toEpoch` lies after activation, and `fromEpoch` lies before activation, then update the `fromEpoch`, as follows :
            if (fromEpoch < activationEpoch) {
                fromEpoch = activationEpoch - 1; // we have done -1 because starting epoch is considered as `fromEpoch + 1`
            }

            uint256 startingPeriod = getProvingPeriodForEpoch(dataSetId, fromEpoch + 1);
            uint256 endingPeriod = getProvingPeriodForEpoch(dataSetId, toEpoch);

            // lets handle first period separately
            uint256 startingPeriod_deadline = _calcPeriodDeadline(dataSetId, startingPeriod);

            if (toEpoch < startingPeriod_deadline) {
                // alternative way to check the same : `startingPeriod == endingPeriod`
                if (_isPeriodProven(dataSetId, startingPeriod, currentPeriod)) {
                    provenEpochCount = (toEpoch - fromEpoch);
                    lastProvenEpoch = toEpoch;
                }
            } else {
                if (_isPeriodProven(dataSetId, startingPeriod, currentPeriod)) {
                    provenEpochCount += (startingPeriod_deadline - fromEpoch);
                }

                // now loop through the proving periods between endingPeriod and startingPeriod.
                for (uint256 period = startingPeriod + 1; period <= endingPeriod - 1; period++) {
                    if (_isPeriodProven(dataSetId, period, currentPeriod)) {
                        provenEpochCount += maxProvingPeriod;
                        lastProvenEpoch = _calcPeriodDeadline(dataSetId, period);
                    }
                }

                // now handle the last period separately
                if (_isPeriodProven(dataSetId, endingPeriod, currentPeriod)) {
                    // then the epochs to add = `endingPeriod_starting` to `toEpoch`. But since `endingPeriod_starting` is simply the ending of its previous period, so
                    provenEpochCount += (toEpoch - _calcPeriodDeadline(dataSetId, endingPeriod - 1));
                    lastProvenEpoch = toEpoch;
                }
            }
        }

        return (provenEpochCount, lastProvenEpoch);
    }

    function _isPeriodProven(uint256 dataSetId, uint256 periodId, uint256 currentPeriod) private view returns (bool) {
        if (periodId == currentPeriod) {
            return provenThisPeriod[dataSetId];
        }
        // return provenPeriods[dataSetId][periodId];
        uint256 isProven = provenPeriods[dataSetId][periodId >> 8] & (1 << (periodId & 255));
        return isProven != 0;
    }

    function _calcPeriodDeadline(uint256 dataSetId, uint256 periodId) private view returns (uint256) {
        return provingActivationEpoch[dataSetId] + ((periodId + 1) * maxProvingPeriod); // we need to do `periodId + 1` since it starts from 0
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
