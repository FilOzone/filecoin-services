// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {PDPVerifier, PDPListener} from "@pdp/PDPVerifier.sol";
import {IPDPTypes} from "@pdp/interfaces/IPDPTypes.sol";
import {Cids} from "@pdp/Cids.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Payments, IValidator} from "@fws-payments/Payments.sol";
import {Errors} from "./Errors.sol";

import {ServiceProviderRegistry} from "./ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "./ServiceProviderRegistryStorage.sol";

import {Extsload} from "./Extsload.sol";

uint256 constant NO_PROVING_DEADLINE = 0;
uint256 constant BYTES_PER_LEAF = 32; // Each leaf is 32 bytes
uint64 constant CHALLENGES_PER_PROOF = 5;
uint256 constant COMMISSION_MAX_BPS = 10000; // 100% in basis points

/// @title FilecoinWarmStorageService
/// @notice An implementation of PDP Listener with payment integration.
/// @dev This contract extends SimplePDPService by adding payment functionality
/// using the Payments contract. It creates payment rails for service providers
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
    string private constant VERSION = "0.1.0";

    // Events
    event ContractUpgraded(string version, address implementation);
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
        address payee,
        string[] metadataKeys,
        string[] metadataValues
    );
    event RailRateUpdated(uint256 indexed dataSetId, uint256 railId, uint256 newRate);
    event PieceAdded(uint256 indexed dataSetId, uint256 indexed pieceId, string[] keys, string[] values);

    event ServiceTerminated(
        address indexed caller, uint256 indexed dataSetId, uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId
    );

    event CDNServiceTerminated(
        address indexed caller, uint256 indexed dataSetId, uint256 cacheMissRailId, uint256 cdnRailId
    );

    event PDPPaymentTerminated(uint256 indexed dataSetId, uint256 endEpoch, uint256 pdpRailId);

    event CDNPaymentTerminated(uint256 indexed dataSetId, uint256 endEpoch, uint256 cacheMissRailId, uint256 cdnRailId);

    event ViewContractSet(address indexed viewContract);

    // Constants
    uint256 private constant NO_CHALLENGE_SCHEDULED = 0;
    uint256 private constant MIB_IN_BYTES = 1024 * 1024; // 1 MiB in bytes
    uint256 private constant DEFAULT_LOCKUP_PERIOD = 2880 * 10; // 10 days in epochs
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

    // Pricing constants
    uint256 private immutable STORAGE_PRICE_PER_TIB_PER_MONTH; // 5 USDFC per TiB per month without CDN with correct decimals
    uint256 private immutable CACHE_MISS_PRICE_PER_TIB_PER_MONTH; // .5 USDFC per TiB per month for CDN with correct decimals
    uint256 private immutable CDN_PRICE_PER_TIB_PER_MONTH; // .5 USDFC per TiB per month for CDN with correct decimals

    // Burn Address
    address payable private constant BURN_ADDRESS = payable(0xff00000000000000000000000000000000000063);

    // Dynamic fee values based on token decimals
    uint256 private immutable DATA_SET_CREATION_FEE; // 0.1 USDFC with correct decimals

    // Token decimals
    uint8 private immutable tokenDecimals;

    // External contract addresses
    address public immutable pdpVerifierAddress;
    address public immutable paymentsContractAddress;
    address public immutable usdfcTokenAddress;
    address public immutable filCDNControllerAddress;
    address public immutable filCDNBeneficiaryAddress;
    ServiceProviderRegistry public immutable serviceProviderRegistry;
    SessionKeyRegistry public immutable sessionKeyRegistry;

    // Commission rates
    uint256 public serviceCommissionBps;

    // Events for provider management
    event ProviderApproved(uint256 indexed providerId);
    event ProviderUnapproved(uint256 indexed providerId);

    // Mapping from client address to clientDataSetId
    mapping(address => uint256) private clientDataSetIds;

    // Mapping from data set ID to key value pair metadata
    // dataSetId => (key => value)
    mapping(uint256 dataSetId => mapping(string key => string value)) internal dataSetMetadata;
    // dataSetId => array of keys
    mapping(uint256 dataSetId => string[] keys) internal dataSetMetadataKeys;

    // Mapping from data set ID and piece ID to key value pair metadata
    // dataSetId => PieceId => (key => value)
    mapping(uint256 dataSetId => mapping(uint256 pieceId => mapping(string key => string value))) internal
        dataSetPieceMetadata;
    // dataSetId => PieceId => array of keys
    mapping(uint256 dataSetId => mapping(uint256 pieceId => string[] keys)) internal dataSetPieceMetadataKeys;

    // Storage for data set payment information
    struct DataSetInfo {
        uint256 pdpRailId; // ID of the PDP payment rail
        uint256 cacheMissRailId; // For CDN add-on: ID of the cache miss payment rail, which rewards the SP for serving data to the CDN when it doesn't already have it cached
        uint256 cdnRailId; // For CDN add-on: ID of the CDN payment rail, which rewards the CDN for serving data to clients
        address payer; // Address paying for storage
        address payee; // SP's beneficiary address
        uint256 commissionBps; // Commission rate for this data set (dynamic based on whether the client purchases CDN add-on)
        uint256 clientDataSetId; // ClientDataSetID
        uint256 pdpEndEpoch; // 0 if PDP rail are not terminated
        uint256 providerId; // Provider ID from the ServiceProviderRegistry
        uint256 cdnEndEpoch; // 0 if CDN rails are not terminated
    }

    // Decode structure for data set creation extra data
    struct DataSetCreateData {
        address payer;
        string[] metadataKeys;
        string[] metadataValues;
        bytes signature; // Authentication signature
    }

    // Structure for service pricing information
    struct ServicePricing {
        uint256 pricePerTiBPerMonthNoCDN; // Price without CDN add-on (5 USDFC per TiB per month)
        uint256 pricePerTiBPerMonthWithCDN; // Price with CDN add-on (3 USDFC per TiB per month)
        address tokenAddress; // Address of the USDFC token
        uint256 epochsPerMonth; // Number of epochs in a month
    }

    // Mappings
    mapping(uint256 => uint256) private provingDeadlines;
    mapping(uint256 => bool) private provenThisPeriod;
    mapping(uint256 => DataSetInfo) private dataSetInfo;
    mapping(address => uint256[]) private clientDataSets;

    // Mapping from rail ID to data set ID for validation
    mapping(uint256 => uint256) private railToDataSet;

    // Event for validation
    event PaymentArbitrated(
        uint256 railId, uint256 dataSetId, uint256 originalAmount, uint256 modifiedAmount, uint256 faultedEpochs
    );

    // Track which proving periods have valid proofs
    mapping(uint256 dataSetId => mapping(uint256 periodId => bool)) private provenPeriods;

    // Track when proving was first activated for each data set
    mapping(uint256 dataSetId => uint256) private provingActivationEpoch;

    // Proving period constants - set during initialization
    uint64 private maxProvingPeriod;
    uint256 private challengeWindowSize;

    // View contract for read-only operations
    // @dev For smart contract integrations, consider using FilecoinWarmStorageServiceStateLibrary
    // directly instead of going through the view contract for more efficient gas usage.
    address public viewContractAddress;

    // Approved provider list
    mapping(uint256 => bool) internal approvedProviders;

    // Array to track all approved provider IDs for enumeration
    uint256[] internal approvedProviderIds;

    // EIP-712 Type hashes
    // EIP-712 type definitions with metadata support
    bytes32 private constant METADATA_ENTRY_TYPEHASH = keccak256("MetadataEntry(string key,string value)");

    bytes32 private constant CREATE_DATA_SET_TYPEHASH = keccak256(
        "CreateDataSet(uint256 clientDataSetId,address payee,MetadataEntry[] metadata)MetadataEntry(string key,string value)"
    );

    bytes32 private constant CID_TYPEHASH = keccak256("Cid(bytes data)");

    bytes32 private constant PIECE_METADATA_TYPEHASH =
        keccak256("PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)MetadataEntry(string key,string value)");

    bytes32 private constant ADD_PIECES_TYPEHASH = keccak256(
        "AddPieces(uint256 clientDataSetId,uint256 firstAdded,Cid[] pieceData,PieceMetadata[] pieceMetadata)"
        "Cid(bytes data)" "MetadataEntry(string key,string value)"
        "PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)"
    );

    bytes32 private constant SCHEDULE_PIECE_REMOVALS_TYPEHASH =
        keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)");

    bytes32 private constant DELETE_DATA_SET_TYPEHASH = keccak256("DeleteDataSet(uint256 clientDataSetId)");

    // Modifier to ensure only the PDP verifier contract can call certain functions

    modifier onlyPDPVerifier() {
        require(msg.sender == pdpVerifierAddress, Errors.OnlyPDPVerifierAllowed(pdpVerifierAddress, msg.sender));
        _;
    }

    modifier onlyFilCDNController() {
        require(
            msg.sender == filCDNControllerAddress,
            Errors.OnlyFilCDNControllerAllowed(filCDNControllerAddress, msg.sender)
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow cstructor
    constructor(
        address _pdpVerifierAddress,
        address _paymentsContractAddress,
        address _usdfcTokenAddress,
        address _filCDNControllerAddress,
        address _filCDNBeneficiaryAddress,
        ServiceProviderRegistry _serviceProviderRegistry,
        SessionKeyRegistry _sessionKeyRegistry
    ) {
        _disableInitializers();

        require(_pdpVerifierAddress != address(0), Errors.ZeroAddress(Errors.AddressField.PDPVerifier));
        pdpVerifierAddress = _pdpVerifierAddress;

        require(_paymentsContractAddress != address(0), Errors.ZeroAddress(Errors.AddressField.Payments));
        paymentsContractAddress = _paymentsContractAddress;

        require(_usdfcTokenAddress != address(0), Errors.ZeroAddress(Errors.AddressField.USDFC));
        usdfcTokenAddress = _usdfcTokenAddress;

        require(_filCDNControllerAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilCDNController));
        filCDNControllerAddress = _filCDNControllerAddress;

        require(_filCDNBeneficiaryAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilCDNBeneficiary));
        filCDNBeneficiaryAddress = _filCDNBeneficiaryAddress;

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
        tokenDecimals = IERC20Metadata(_usdfcTokenAddress).decimals();

        // Initialize the fee constants based on the actual token decimals
        STORAGE_PRICE_PER_TIB_PER_MONTH = (5 * 10 ** tokenDecimals); // 5 USDFC
        DATA_SET_CREATION_FEE = (1 * 10 ** tokenDecimals) / 10; // 0.1 USDFC
        CACHE_MISS_PRICE_PER_TIB_PER_MONTH = (1 * 10 ** tokenDecimals) / 2; // 0.5 USDFC
        CDN_PRICE_PER_TIB_PER_MONTH = (1 * 10 ** tokenDecimals) / 2; // 0.5 USDFC
    }

    /**
     * @notice Initialize the contract with PDP proving period parameters
     * @param _maxProvingPeriod Maximum number of epochs between two consecutive proofs
     * @param _challengeWindowSize Number of epochs for the challenge window
     */
    function initialize(uint64 _maxProvingPeriod, uint256 _challengeWindowSize) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __EIP712_init("FilecoinWarmStorageService", "1");

        require(_maxProvingPeriod > 0, Errors.MaxProvingPeriodZero());
        require(
            _challengeWindowSize > 0 && _challengeWindowSize < _maxProvingPeriod,
            Errors.InvalidChallengeWindowSize(_challengeWindowSize, _maxProvingPeriod)
        );

        maxProvingPeriod = _maxProvingPeriod;
        challengeWindowSize = _challengeWindowSize;

        // Set commission rate
        serviceCommissionBps = 0; // 0%
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

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
    function migrate(address _viewContract) public onlyProxy reinitializer(4) {
        require(msg.sender == address(this), Errors.OnlySelf(address(this), msg.sender));

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
        require(_viewContract != address(0), "Invalid view contract address");
        require(viewContractAddress == address(0), "View contract already set");
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
     * @param creator The address that created the data set and will receive payments
     * @param extraData Encoded data containing metadata, payer information, and signature
     */
    function dataSetCreated(uint256 dataSetId, address creator, bytes calldata extraData) external onlyPDPVerifier {
        // Decode the extra data to get the metadata, payer address, and signature
        require(extraData.length > 0, Errors.ExtraDataRequired());
        DataSetCreateData memory createData = decodeDataSetCreateData(extraData);

        // Validate the addresses
        require(createData.payer != address(0), Errors.ZeroAddress(Errors.AddressField.Payer));
        require(creator != address(0), Errors.ZeroAddress(Errors.AddressField.Creator));

        // Validate provider is registered and approved
        uint256 providerId = serviceProviderRegistry.getProviderIdByAddress(creator);

        // Check if provider is registered
        require(providerId != 0, Errors.ProviderNotRegistered(creator));

        // Check if provider is approved
        require(approvedProviders[providerId], Errors.ProviderNotApproved(creator, providerId));

        // Update client state
        uint256 clientDataSetId = clientDataSetIds[createData.payer]++;
        clientDataSets[createData.payer].push(dataSetId);

        // Verify the client's signature
        verifyCreateDataSetSignature(
            createData.payer,
            clientDataSetId,
            creator,
            createData.metadataKeys,
            createData.metadataValues,
            createData.signature
        );

        // Initialize the DataSetInfo struct
        DataSetInfo storage info = dataSetInfo[dataSetId];
        info.payer = createData.payer;
        info.payee = creator; // Using creator as the payee
        info.commissionBps = serviceCommissionBps;
        info.clientDataSetId = clientDataSetId;
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

        // Create the payment rails using the Payments contract
        Payments payments = Payments(paymentsContractAddress);
        uint256 pdpRailId = payments.createRail(
            usdfcTokenAddress, // token address
            createData.payer, // from (payer)
            creator, // data set creator, SPs in  most cases
            address(this), // this contract acts as the validator
            info.commissionBps, // commission rate based on CDN usage
            address(this)
        );

        // Store the rail ID
        info.pdpRailId = pdpRailId;

        // Store reverse mapping from rail ID to data set ID for validation
        railToDataSet[pdpRailId] = dataSetId;

        // First, set a lockupFixed value that's at least equal to the one-time payment
        // This is necessary because modifyRailPayment requires that lockupFixed >= oneTimePayment
        payments.modifyRailLockup(
            pdpRailId,
            DEFAULT_LOCKUP_PERIOD,
            DATA_SET_CREATION_FEE // lockupFixed equal to the one-time payment amount
        );

        // Charge the one-time data set creation fee
        // This is a payment from payer to data set creator of a fixed amount
        payments.modifyRailPayment(
            pdpRailId,
            0, // Initial rate is 0, will be updated when roots are added
            DATA_SET_CREATION_FEE // One-time payment amount
        );

        uint256 cacheMissRailId = 0;
        uint256 cdnRailId = 0;

        if (hasMetadataKey(createData.metadataKeys, METADATA_KEY_WITH_CDN)) {
            cacheMissRailId = payments.createRail(
                usdfcTokenAddress, // token address
                createData.payer, // from (payer)
                creator, // data set creator, SPs in most cases
                address(this), // this contract acts as the arbiter
                0, // no service commission
                address(this)
            );
            info.cacheMissRailId = cacheMissRailId;
            railToDataSet[cacheMissRailId] = dataSetId;
            payments.modifyRailLockup(cacheMissRailId, DEFAULT_LOCKUP_PERIOD, 0);

            cdnRailId = payments.createRail(
                usdfcTokenAddress, // token address
                createData.payer, // from (payer)
                filCDNBeneficiaryAddress, // to FilCDN beneficiary
                address(this), // this contract acts as the arbiter
                0, // no service commission
                address(this)
            );
            info.cdnRailId = cdnRailId;
            railToDataSet[cdnRailId] = dataSetId;
            payments.modifyRailLockup(cdnRailId, DEFAULT_LOCKUP_PERIOD, 0);
        }

        // Emit event for tracking
        emit DataSetCreated(
            dataSetId,
            providerId,
            pdpRailId,
            cacheMissRailId,
            cdnRailId,
            createData.payer,
            creator,
            createData.metadataKeys,
            createData.metadataValues
        );
    }

    /**
     * @notice Handles data set deletion and terminates the payment rail
     * @dev Called by the PDPVerifier contract when a data set is deleted
     * @param dataSetId The ID of the data set being deleted
     * @param extraData Signature for authentication
     */
    function dataSetDeleted(
        uint256 dataSetId,
        uint256, // deletedLeafCount, - not used
        bytes calldata extraData
    ) external onlyPDPVerifier {
        // Verify the data set exists in our mapping
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));
        (bytes memory signature) = abi.decode(extraData, (bytes));

        // Get the payer address for this data set
        address payer = dataSetInfo[dataSetId].payer;

        // Verify the client's signature
        verifyDeleteDataSetSignature(payer, info.clientDataSetId, signature);

        // TODO Data set deletion logic
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
            emit PieceAdded(dataSetId, pieceId, pieceKeys, pieceValues);
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
        provenPeriods[dataSetId][currentPeriod] = true;
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
        if (provingDeadlines[dataSetId] != NO_PROVING_DEADLINE) {
            // Determine the period ID that just completed
            uint256 completedPeriodId = getProvingPeriodForEpoch(dataSetId, provingDeadlines[dataSetId] - 1);

            // Record whether this period was proven
            provenPeriods[dataSetId][completedPeriodId] = provenThisPeriod[dataSetId];
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
            info.payee == oldServiceProvider,
            Errors.OldServiceProviderMismatch(dataSetId, info.payee, oldServiceProvider)
        );
        require(newServiceProvider != address(0), Errors.ZeroAddress(Errors.AddressField.ServiceProvider));

        // Update the data set payee (service provider)
        info.payee = newServiceProvider;

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
            msg.sender == info.payer || msg.sender == info.payee,
            Errors.CallerNotPayerOrPayee(dataSetId, info.payer, info.payee, msg.sender)
        );

        Payments payments = Payments(paymentsContractAddress);

        payments.terminateRail(info.pdpRailId);

        if (hasMetadataKey(dataSetMetadataKeys[dataSetId], METADATA_KEY_WITH_CDN)) {
            payments.terminateRail(info.cacheMissRailId);
            payments.terminateRail(info.cdnRailId);
        }

        emit ServiceTerminated(msg.sender, dataSetId, info.pdpRailId, info.cacheMissRailId, info.cdnRailId);
    }

    function terminateCDNService(uint256 dataSetId) external onlyFilCDNController {
        // Check if already terminated
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.cdnEndEpoch == 0, Errors.FilCDNPaymentAlreadyTerminated(dataSetId));

        // Check if CDN service is configured
        require(
            hasMetadataKey(dataSetMetadataKeys[dataSetId], METADATA_KEY_WITH_CDN),
            Errors.FilCDNServiceNotConfigured(dataSetId)
        );

        // Check if cache miss and CDN rails are configured
        require(info.cacheMissRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.cdnRailId != 0, Errors.InvalidDataSetId(dataSetId));

        Payments payments = Payments(paymentsContractAddress);
        payments.terminateRail(info.cacheMissRailId);
        payments.terminateRail(info.cdnRailId);

        // Delete withCDN flag from metadata to prevent further CDN operations
        dataSetMetadataKeys[dataSetId] = deleteMetadataKey(dataSetMetadataKeys[dataSetId], METADATA_KEY_WITH_CDN);
        delete dataSetMetadata[dataSetId][METADATA_KEY_WITH_CDN];

        emit CDNServiceTerminated(msg.sender, dataSetId, info.cacheMissRailId, info.cdnRailId);
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
        Payments payments = Payments(paymentsContractAddress);

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
        if (hasMetadataKey(dataSetMetadataKeys[dataSetId], METADATA_KEY_WITH_CDN)) {
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

    /**
     * @notice Checks if a specific epoch has been proven
     * @dev Returns true only if the epoch belongs to a proven proving period
     * @param dataSetId The ID of the data set to check
     * @param epoch The epoch to check
     * @return True if the epoch has been proven, false otherwise
     */
    function isEpochProven(uint256 dataSetId, uint256 epoch) public view returns (bool) {
        // Check if data set is active
        if (provingActivationEpoch[dataSetId] == 0) {
            return false;
        }

        // Check if this epoch is before activation
        if (epoch < provingActivationEpoch[dataSetId]) {
            return false;
        }

        // Check if this epoch is in the future (beyond current block)
        if (epoch > block.number) {
            return false;
        }

        // Get the period this epoch belongs to
        uint256 periodId = getProvingPeriodForEpoch(dataSetId, epoch);

        // Special case: current ongoing proving period
        uint256 currentPeriod = getProvingPeriodForEpoch(dataSetId, block.number);
        if (periodId == currentPeriod) {
            // For the current period, check if it has been proven already
            return provenThisPeriod[dataSetId];
        }

        // For past periods, check the provenPeriods mapping
        return provenPeriods[dataSetId][periodId];
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
            uint256 minRate = (1 * 10 ** uint256(tokenDecimals)) / 100000;
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
        (address payer, string[] memory keys, string[] memory values, bytes memory signature) =
            abi.decode(extraData, (address, string[], string[], bytes));

        return DataSetCreateData({payer: payer, metadataKeys: keys, metadataValues: values, signature: signature});
    }

    /**
     * @notice Returns true if `key` exists in `metadataKeys`.
     * @param metadataKeys The array of metadata keys
     * @param key The metadata key to look up
     * @return True if key exists; false otherwise.
     */
    function hasMetadataKey(string[] memory metadataKeys, string memory key) internal pure returns (bool) {
        bytes memory keyBytes = bytes(key);
        uint256 keyLength = keyBytes.length;
        bytes32 keyHash = keccak256(keyBytes);

        for (uint256 i = 0; i < metadataKeys.length; i++) {
            bytes memory currentKeyBytes = bytes(metadataKeys[i]);
            if (currentKeyBytes.length == keyLength && keccak256(currentKeyBytes) == keyHash) {
                return true;
            }
        }

        // Key absence means disabled
        return false;
    }

    /**
     * @notice Deletes `key` if it exists in `metadataKeys`.
     * @param metadataKeys The array of metadata keys
     * @param key The metadata key to delete
     * @return Modified array of metadata keys
     */
    function deleteMetadataKey(string[] memory metadataKeys, string memory key)
        internal
        pure
        returns (string[] memory)
    {
        bytes memory keyBytes = bytes(key);
        uint256 keyLength = keyBytes.length;
        bytes32 keyHash = keccak256(keyBytes);

        uint256 len = metadataKeys.length;
        for (uint256 i = 0; i < len; i++) {
            bytes memory currentKeyBytes = bytes(metadataKeys[i]);
            if (currentKeyBytes.length == keyLength && keccak256(currentKeyBytes) == keyHash) {
                // Shift elements left to fill the gap
                for (uint256 j = i; j < len - 1; j++) {
                    metadataKeys[j] = metadataKeys[j + 1];
                }

                delete metadataKeys[len - 1];
                assembly {
                    mstore(metadataKeys, sub(len, 1))
                }
                break;
            }
        }
        return metadataKeys;
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
     * @notice Hashes a single metadata entry for EIP-712 signing
     * @param key The metadata key
     * @param value The metadata value
     * @return Hash of the metadata entry struct
     */
    function hashMetadataEntry(string memory key, string memory value) internal pure returns (bytes32) {
        return keccak256(abi.encode(METADATA_ENTRY_TYPEHASH, keccak256(bytes(key)), keccak256(bytes(value))));
    }

    /**
     * @notice Hashes an array of metadata entries
     * @param keys Array of metadata keys
     * @param values Array of metadata values
     * @return Hash of all metadata entries
     */
    function hashMetadataEntries(string[] memory keys, string[] memory values) internal pure returns (bytes32) {
        require(keys.length == values.length, Errors.MetadataKeyAndValueLengthMismatch(keys.length, values.length));

        bytes32[] memory entryHashes = new bytes32[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            entryHashes[i] = hashMetadataEntry(keys[i], values[i]);
        }
        return keccak256(abi.encodePacked(entryHashes));
    }

    /**
     * @notice Hashes piece metadata for a specific piece index
     * @param pieceIndex The index of the piece
     * @param keys Array of metadata keys for this piece
     * @param values Array of metadata values for this piece
     * @return Hash of the piece metadata struct
     */
    function hashPieceMetadata(uint256 pieceIndex, string[] memory keys, string[] memory values)
        internal
        pure
        returns (bytes32)
    {
        bytes32 metadataHash = hashMetadataEntries(keys, values);
        return keccak256(abi.encode(PIECE_METADATA_TYPEHASH, pieceIndex, metadataHash));
    }

    /**
     * @notice Hashes all piece metadata for multiple pieces
     * @param allKeys 2D array where allKeys[i] contains keys for piece i
     * @param allValues 2D array where allValues[i] contains values for piece i
     * @return Hash of all piece metadata
     */
    function hashAllPieceMetadata(string[][] memory allKeys, string[][] memory allValues)
        internal
        pure
        returns (bytes32)
    {
        require(allKeys.length == allValues.length, "Keys/values array length mismatch");

        bytes32[] memory pieceHashes = new bytes32[](allKeys.length);
        for (uint256 i = 0; i < allKeys.length; i++) {
            pieceHashes[i] = hashPieceMetadata(i, allKeys[i], allValues[i]);
        }
        return keccak256(abi.encodePacked(pieceHashes));
    }

    // ============ Signature Verification Functions ============

    /**
     * @notice Verifies a signature for the CreateDataSet operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The unique ID for the client's data set
     * @param payee The service provider address
     * @param metadataKeys Array of metadata keys
     * @param metadataValues Array of metadata values
     * @param signature The signature bytes (v, r, s)
     */
    function verifyCreateDataSetSignature(
        address payer,
        uint256 clientDataSetId,
        address payee,
        string[] memory metadataKeys,
        string[] memory metadataValues,
        bytes memory signature
    ) internal view {
        // Hash the metadata entries
        bytes32 metadataHash = hashMetadataEntries(metadataKeys, metadataValues);

        // Prepare the message hash that was signed
        bytes32 structHash = keccak256(abi.encode(CREATE_DATA_SET_TYPEHASH, clientDataSetId, payee, metadataHash));
        bytes32 digest = _hashTypedDataV4(structHash);

        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);

        if (payer == recoveredSigner) {
            return;
        }
        require(
            sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, CREATE_DATA_SET_TYPEHASH) >= block.timestamp,
            Errors.InvalidSignature(payer, recoveredSigner)
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
        // Hash each PieceData struct
        bytes32[] memory cidHashes = new bytes32[](pieceDataArray.length);
        for (uint256 i = 0; i < pieceDataArray.length; i++) {
            // Hash the PieceCid struct
            cidHashes[i] = keccak256(abi.encode(CID_TYPEHASH, keccak256(pieceDataArray[i].data)));
        }

        // Hash all piece metadata
        bytes32 pieceMetadataHash = hashAllPieceMetadata(allKeys, allValues);

        bytes32 structHash = keccak256(
            abi.encode(
                ADD_PIECES_TYPEHASH,
                clientDataSetId,
                firstAdded,
                keccak256(abi.encodePacked(cidHashes)),
                pieceMetadataHash
            )
        );

        // Create the message hash
        bytes32 digest = _hashTypedDataV4(structHash);

        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);

        if (payer == recoveredSigner) {
            return;
        }
        require(
            sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, ADD_PIECES_TYPEHASH) >= block.timestamp,
            Errors.InvalidSignature(payer, recoveredSigner)
        );
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
        // Prepare the message hash that was signed
        bytes32 structHash = keccak256(
            abi.encode(SCHEDULE_PIECE_REMOVALS_TYPEHASH, clientDataSetId, keccak256(abi.encodePacked(pieceIds)))
        );

        bytes32 digest = _hashTypedDataV4(structHash);

        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);

        if (payer == recoveredSigner) {
            return;
        }
        require(
            sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, SCHEDULE_PIECE_REMOVALS_TYPEHASH)
                >= block.timestamp,
            Errors.InvalidSignature(payer, recoveredSigner)
        );
    }

    /**
     * @notice Verifies a signature for the DeleteDataSet operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The ID of the data set
     * @param signature The signature bytes (v, r, s)
     */
    function verifyDeleteDataSetSignature(address payer, uint256 clientDataSetId, bytes memory signature)
        internal
        view
    {
        // Prepare the message hash that was signed
        bytes32 structHash = keccak256(abi.encode(DELETE_DATA_SET_TYPEHASH, clientDataSetId));
        bytes32 digest = _hashTypedDataV4(structHash);

        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);

        if (payer == recoveredSigner) {
            return;
        }
        require(
            sessionKeyRegistry.authorizationExpiry(payer, recoveredSigner, DELETE_DATA_SET_TYPEHASH) >= block.timestamp,
            Errors.InvalidSignature(payer, recoveredSigner)
        );
    }

    /**
     * @notice Recover the signer address from a signature
     * @param messageHash The signed message hash
     * @param signature The signature bytes (v, r, s)
     * @return The address that signed the message
     */
    function recoverSigner(bytes32 messageHash, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, Errors.InvalidSignatureLength(65, signature.length));

        bytes32 r;
        bytes32 s;
        uint8 v;

        // Extract r, s, v from the signature
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        uint8 originalV = v;

        // If v is not 27 or 28, adjust it (for some wallets)
        if (v < 27) {
            v += 27;
        }

        require(v == 27 || v == 28, Errors.UnsupportedSignatureV(originalV));

        // Recover and return the address
        return ecrecover(messageHash, v, r, s);
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

        // Check each epoch in the range
        for (uint256 epoch = fromEpoch + 1; epoch <= toEpoch; epoch++) {
            bool isProven = isEpochProven(dataSetId, epoch);

            if (isProven) {
                provenEpochCount++;
                lastProvenEpoch = epoch;
            }
        }

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
        } else if (info.cdnEndEpoch == 0 && (railId == info.cdnRailId || railId == info.cacheMissRailId)) {
            info.cdnEndEpoch = endEpoch;
            emit CDNPaymentTerminated(dataSetId, endEpoch, info.cacheMissRailId, info.cdnRailId);
        }
    }
}
