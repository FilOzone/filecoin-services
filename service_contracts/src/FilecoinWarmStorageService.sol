// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PDPVerifier, PDPListener} from "@pdp/PDPVerifier.sol";
import {IPDPTypes} from "@pdp/interfaces/IPDPTypes.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Payments, IValidator} from "@fws-payments/Payments.sol";
import {Errors} from "./Errors.sol";

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
    event DataSetRailsCreated(
        uint256 indexed dataSetId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId,
        address payer,
        address controller,
        bool withCDN
    );

    // Emitted when a data set's beneficiary is set or resolved
    event DataSetBeneficiaryResolved(uint256 indexed dataSetId, address indexed beneficiary);
    event RailRateUpdated(uint256 indexed dataSetId, uint256 railId, uint256 newRate);
    event PieceMetadataAdded(uint256 indexed dataSetId, uint256 pieceId, string metadata);

    // Constants
    uint256 private constant NO_CHALLENGE_SCHEDULED = 0;
    uint256 private constant CHALLENGES_PER_PROOF = 5;
    uint256 private constant NO_PROVING_DEADLINE = 0;
    uint256 private constant MIB_IN_BYTES = 1024 * 1024; // 1 MiB in bytes
    uint256 private constant BYTES_PER_LEAF = 32; // Each leaf is 32 bytes
    uint256 private constant COMMISSION_MAX_BPS = 10000; // 100% in basis points
    uint256 private constant DEFAULT_LOCKUP_PERIOD = 2880 * 10; // 10 days in epochs
    uint256 private constant GIB_IN_BYTES = MIB_IN_BYTES * 1024; // 1 GiB in bytes
    uint256 private constant TIB_IN_BYTES = GIB_IN_BYTES * 1024; // 1 TiB in bytes
    uint256 private constant EPOCHS_PER_MONTH = 2880 * 30;

    // Pricing constants
    uint256 private immutable STORAGE_PRICE_PER_TIB_PER_MONTH; // 2 USDFC per TiB per month without CDN with correct decimals
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
    address public immutable filCDNAddress;

    // Commission rates
    uint256 public serviceCommissionBps;

    // Mapping from client address to clientDataSetId
    mapping(address => uint256) public clientDataSetIDs;
    // Mapping from data set ID to piece ID to metadata
    mapping(uint256 => mapping(uint256 => string)) private dataSetPieceMetadata;

    // Storage for data set payment information
    struct DataSetInfo {
        uint256 pdpRailId; // ID of the PDP payment rail
        uint256 cacheMissRailId; // For CDN add-on: ID of the cache miss payment rail, which rewards the SP for serving data to the CDN when it doesn't already have it cached
        uint256 cdnRailId; // For CDN add-on: ID of the CDN payment rail, which rewards the CDN for serving data to clients
        address payer; // Address paying for storage
        address controller; // SP's control address (hot key)
        address beneficiary; // SP's payment address (cold key)
        uint256 commissionBps; // Commission rate for this data set (dynamic based on whether the client purchases CDN add-on)
        string metadata; // General metadata for the data set
        string[] pieceMetadata; // Array of metadata for each piece
        uint256 clientDataSetId; // ClientDataSetID
        bool withCDN; // Whether the data set is registered for CDN add-on
        uint256 paymentEndEpoch; // 0 if payment is not terminated
    }

    // Decode structure for data set creation extra data
    struct DataSetCreateData {
        string metadata;
        address payer;
        bool withCDN;
        address beneficiary;
        bytes signature; // Authentication signature
    }

    // Structure for service pricing information
    struct ServicePricing {
        uint256 pricePerTiBPerMonthNoCDN; // Price without CDN add-on (2 USDFC per TiB per month)
        uint256 pricePerTiBPerMonthWithCDN; // Price with CDN add-on (3 USDFC per TiB per month)
        address tokenAddress; // Address of the USDFC token
        uint256 epochsPerMonth; // Number of epochs in a month
    }

    // Mappings
    mapping(uint256 => uint256) public provingDeadlines;
    mapping(uint256 => bool) public provenThisPeriod;
    mapping(uint256 => DataSetInfo) public dataSetInfo;
    mapping(address => uint256[]) public clientDataSets;

    // Mapping from rail ID to data set ID for validation
    mapping(uint256 => uint256) public railToDataSet;

    // Event for validation
    event PaymentArbitrated(
        uint256 railId, uint256 dataSetId, uint256 originalAmount, uint256 modifiedAmount, uint256 faultedEpochs
    );

    // Track which proving periods have valid proofs (dataSetId => periodId => isProven)
    mapping(uint256 => mapping(uint256 => bool)) public provenPeriods;

    // Track when proving was first activated for each data set
    mapping(uint256 => uint256) public provingActivationEpoch;

    // ========== Service Provider Registry State ==========

    uint256 private nextServiceProviderId = 1;

    struct ApprovedProviderInfo {
        address serviceProvider;
        string serviceURL; // HTTP server URL for provider services; TODO: Standard API endpoints:{serviceURL}/api/upload / {serviceURL}/api/info
        bytes peerId; // libp2p peer ID (optional - empty bytes if not provided)
        uint256 registeredAt;
        uint256 approvedAt;
    }

    struct PendingProviderInfo {
        string serviceURL; // HTTP server URL for provider services; TODO: Standard API endpoints:{serviceURL}/api/upload / {serviceURL}/api/info
        bytes peerId; //libp2p peer ID (optional - empty bytes if not provided)
        uint256 registeredAt;
    }

    mapping(uint256 => ApprovedProviderInfo) public approvedProviders;

    mapping(address => bool) public approvedProvidersMap;

    mapping(address => PendingProviderInfo) public pendingProviders;

    mapping(address => uint256) public providerToId;

    // Proving period constants - set during initialization (added at end for upgrade compatibility)
    uint64 private maxProvingPeriod;
    uint256 private challengeWindowSize;

    // Events for SP registry
    event ProviderRegistered(address indexed provider, string serviceURL, bytes peerId);
    event ProviderApproved(address indexed provider, uint256 indexed providerId);
    event ProviderRejected(address indexed provider);
    event ProviderRemoved(address indexed provider, uint256 indexed providerId);

    // EIP-712 Type hashes
    bytes32 private constant CREATE_DATA_SET_TYPEHASH =
        keccak256("CreateDataSet(uint256 clientDataSetId,bool withCDN,address controller,address beneficiary)");

    bytes32 private constant PIECE_CID_TYPEHASH = keccak256("PieceCid(bytes data)");

    bytes32 private constant PIECE_DATA_TYPEHASH =
        keccak256("PieceData(PieceCid piece,uint256 rawSize)PieceCid(bytes data)");

    bytes32 private constant ADD_PIECES_TYPEHASH = keccak256(
        "AddPieces(uint256 clientDataSetId,uint256 firstAdded,PieceData[] pieceData)PieceCid(bytes data)PieceData(PieceCid piece,uint256 rawSize)"
    );

    bytes32 private constant SCHEDULE_PIECE_REMOVALS_TYPEHASH =
        keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)");

    bytes32 private constant DELETE_DATA_SET_TYPEHASH = keccak256("DeleteDataSet(uint256 clientDataSetId)");

    /// @notice Registration fee required for service providers (1 FIL)
    /// @dev This fee is burned to prevent spam registrations
    uint256 private constant SP_REGISTRATION_FEE = 1 ether;
    // Modifier to ensure only the PDP verifier contract can call certain functions

    modifier onlyPDPVerifier() {
        require(msg.sender == pdpVerifierAddress, Errors.OnlyPDPVerifierAllowed(pdpVerifierAddress, msg.sender));
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _pdpVerifierAddress,
        address _paymentsContractAddress,
        address _usdfcTokenAddress,
        address _filCDNAddress
    ) {
        _disableInitializers();

        require(_usdfcTokenAddress != address(0), "USDFC token address cannot be zero");
        usdfcTokenAddress = _usdfcTokenAddress;

        require(_filCDNAddress != address(0), "Filecoin CDN address cannot be zero");
        filCDNAddress = _filCDNAddress;

        require(_pdpVerifierAddress != address(0), Errors.ZeroAddress(Errors.AddressField.PDPVerifier));
        require(_paymentsContractAddress != address(0), Errors.ZeroAddress(Errors.AddressField.Payments));
        require(_usdfcTokenAddress != address(0), Errors.ZeroAddress(Errors.AddressField.USDFC));
        require(_filCDNAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilecoinCDN));

        pdpVerifierAddress = _pdpVerifierAddress;

        require(_paymentsContractAddress != address(0), "Payments contract address cannot be zero");
        paymentsContractAddress = _paymentsContractAddress;

        // Read token decimals from the USDFC token contract
        tokenDecimals = IERC20Metadata(_usdfcTokenAddress).decimals();

        // Initialize the fee constants based on the actual token decimals
        STORAGE_PRICE_PER_TIB_PER_MONTH = (2 * 10 ** tokenDecimals); // 2 USDFC
        DATA_SET_CREATION_FEE = (1 * 10 ** tokenDecimals) / 10; // 0.1 USDFC
        CACHE_MISS_PRICE_PER_TIB_PER_MONTH = (1 * 10 ** tokenDecimals) / 2; // 0.5 USDFC
        CDN_PRICE_PER_TIB_PER_MONTH = (1 * 10 ** tokenDecimals) / 2; // 0.5 USDFC
    }

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

        nextServiceProviderId = 1;
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
     */
    function migrate() public onlyProxy reinitializer(3) {
        require(msg.sender == address(this), Errors.OnlySelf(address(this), msg.sender));
        emit ContractUpgraded(VERSION, ERC1967Utils.getImplementation());
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

    // SLA specification functions setting values for PDP service providers
    // Max number of epochs between two consecutive proofs
    function getMaxProvingPeriod() public view returns (uint64) {
        return maxProvingPeriod;
    }

    // Number of epochs at the end of a proving period during which a
    // proof of possession can be submitted
    function challengeWindow() public view returns (uint256) {
        return challengeWindowSize;
    }

    // Initial value for challenge window start
    // Can be used for first call to nextProvingPeriod
    function initChallengeWindowStart() public view returns (uint256) {
        return block.number + getMaxProvingPeriod() - challengeWindow();
    }

    // The start of the challenge window for the current proving period
    function thisChallengeWindowStart(uint256 setId) public view returns (uint256) {
        if (provingDeadlines[setId] == NO_PROVING_DEADLINE) {
            revert Errors.ProvingPeriodNotInitialized(setId);
        }

        uint256 periodsSkipped;
        // Proving period is open 0 skipped periods
        if (block.number <= provingDeadlines[setId]) {
            periodsSkipped = 0;
        } else {
            // Proving period has closed possibly some skipped periods
            periodsSkipped = 1 + (block.number - (provingDeadlines[setId] + 1)) / getMaxProvingPeriod();
        }
        return provingDeadlines[setId] + periodsSkipped * getMaxProvingPeriod() - challengeWindow();
    }

    // The start of the NEXT OPEN proving period's challenge window
    // Useful for querying before nextProvingPeriod to determine challengeEpoch to submit for nextProvingPeriod
    function nextChallengeWindowStart(uint256 setId) external view returns (uint256) {
        if (provingDeadlines[setId] == NO_PROVING_DEADLINE) {
            revert Errors.ProvingPeriodNotInitialized(setId);
        }
        // If the current period is open this is the next period's challenge window
        if (block.number <= provingDeadlines[setId]) {
            return thisChallengeWindowStart(setId) + getMaxProvingPeriod();
        }
        // If the current period is not yet open this is the current period's challenge window
        return thisChallengeWindowStart(setId);
    }

    // Getters
    function getAllApprovedProviders() external view returns (ApprovedProviderInfo[] memory) {
        // Handle edge case: no providers have been registered
        if (nextServiceProviderId == 1) {
            return new ApprovedProviderInfo[](0);
        }

        // First pass: Count non-empty providers (those with non-zero service provider address)
        uint256 activeCount = 0;
        for (uint256 i = 1; i < nextServiceProviderId; i++) {
            if (approvedProviders[i].serviceProvider != address(0)) {
                activeCount++;
            }
        }

        // Handle edge case: all providers have been removed
        if (activeCount == 0) {
            return new ApprovedProviderInfo[](0);
        }

        // Create correctly-sized array
        ApprovedProviderInfo[] memory providers = new ApprovedProviderInfo[](activeCount);

        // Second pass: Fill array with only active providers
        uint256 currentIndex = 0;
        for (uint256 i = 1; i < nextServiceProviderId; i++) {
            if (approvedProviders[i].serviceProvider != address(0)) {
                providers[currentIndex] = approvedProviders[i];
                currentIndex++;
            }
        }

        return providers;
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
        (DataSetCreateData memory createData) = decodeDataSetCreateData(extraData);
        require(createData.beneficiary != address(0), Errors.ZeroAddress(Errors.AddressField.Beneficiary));
        address actualBeneficiary = createData.beneficiary;

        // Validate the addresses
        require(createData.payer != address(0), Errors.ZeroAddress(Errors.AddressField.Payer));
        require(creator != address(0), Errors.ZeroAddress(Errors.AddressField.Creator));

        // Check if the service provider is whitelisted
        require(approvedProvidersMap[creator], Errors.ServiceProviderNotApproved(creator));

        // Update client state
        uint256 clientDataSetId = clientDataSetIDs[createData.payer]++;
        clientDataSets[createData.payer].push(dataSetId);

        // Verify the client's signature
        verifyCreateDataSetSignature(
            createData.payer, clientDataSetId, creator, createData.withCDN, actualBeneficiary, createData.signature
        );

        // Initialize the DataSetInfo struct
        DataSetInfo storage info = dataSetInfo[dataSetId];
        info.payer = createData.payer;
        info.controller = creator;
        info.beneficiary = actualBeneficiary;
        info.metadata = createData.metadata;
        info.commissionBps = serviceCommissionBps;
        info.clientDataSetId = clientDataSetId;
        info.withCDN = createData.withCDN;

        // Note: The payer must have pre-approved this contract to spend USDFC tokens before creating the data set

        // Create the payment rails using the Payments contract
        Payments payments = Payments(paymentsContractAddress);
        uint256 pdpRailId = payments.createRail(
            usdfcTokenAddress, // token address
            createData.payer, // from (payer)
            actualBeneficiary, // to (beneficiary)
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

        if (createData.withCDN == true) {
            cacheMissRailId = payments.createRail(
                usdfcTokenAddress, // token address
                createData.payer, // from (payer)
                actualBeneficiary,
                address(this), // arbiter
                0, // no service commission
                address(this)
            );
            info.cacheMissRailId = cacheMissRailId;
            railToDataSet[cacheMissRailId] = dataSetId;
            payments.modifyRailLockup(cacheMissRailId, DEFAULT_LOCKUP_PERIOD, 0);

            cdnRailId = payments.createRail(
                usdfcTokenAddress, // token address
                createData.payer, // from (payer)
                filCDNAddress,
                address(this), // arbiter
                0, // no service commission
                address(this)
            );
            info.cdnRailId = cdnRailId;
            railToDataSet[cdnRailId] = dataSetId;
            payments.modifyRailLockup(cdnRailId, DEFAULT_LOCKUP_PERIOD, 0);
        }

        // Emit events for tracking
        emit DataSetRailsCreated(
            dataSetId, pdpRailId, cacheMissRailId, cdnRailId, createData.payer, creator, createData.withCDN
        );

        emit DataSetBeneficiaryResolved(dataSetId, actualBeneficiary);
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
    function piecesAdded(
        uint256 dataSetId,
        uint256 firstAdded,
        IPDPTypes.PieceData[] memory pieceData,
        bytes calldata extraData
    ) external onlyPDPVerifier {
        requirePaymentNotTerminated(dataSetId);
        // Verify the data set exists in our mapping
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));

        // Get the payer address for this data set
        address payer = info.payer;
        require(extraData.length > 0, Errors.ExtraDataRequired());
        // Decode the extra data
        (bytes memory signature, string memory metadata) = abi.decode(extraData, (bytes, string));

        // Verify the signature
        verifyAddPiecesSignature(payer, info.clientDataSetId, pieceData, firstAdded, signature);

        // Store metadata for each new piece
        for (uint256 i = 0; i < pieceData.length; i++) {
            uint256 pieceId = firstAdded + i;
            dataSetPieceMetadata[dataSetId][pieceId] = metadata;
            emit PieceMetadataAdded(dataSetId, pieceId, metadata);
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

        uint256 windowStart = provingDeadlines[dataSetId] - challengeWindow();
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
            uint256 firstDeadline = block.number + getMaxProvingPeriod();
            uint256 minWindow = firstDeadline - challengeWindow();
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
        uint256 prevDeadline = provingDeadlines[dataSetId] - getMaxProvingPeriod();
        if (block.number <= prevDeadline) {
            revert Errors.NextProvingPeriodAlreadyCalled(dataSetId, prevDeadline, block.number);
        }

        uint256 periodsSkipped;
        // Proving period is open 0 skipped periods
        if (block.number <= provingDeadlines[dataSetId]) {
            periodsSkipped = 0;
        } else {
            // Proving period has closed possibly some skipped periods
            periodsSkipped = (block.number - (provingDeadlines[dataSetId] + 1)) / getMaxProvingPeriod();
        }

        uint256 nextDeadline;
        // the data set has become empty and provingDeadline is set inactive
        if (challengeEpoch == NO_CHALLENGE_SCHEDULED) {
            nextDeadline = NO_PROVING_DEADLINE;
        } else {
            nextDeadline = provingDeadlines[dataSetId] + getMaxProvingPeriod() * (periodsSkipped + 1);
            uint256 windowStart = nextDeadline - challengeWindow();
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
     * @param extraData Additional data (not used)
     */
    function storageProviderChanged(
        uint256 dataSetId,
        address oldServiceProvider,
        address newServiceProvider,
        bytes calldata extraData
    ) external override onlyPDPVerifier {
        // Verify the data set exists and validate the old service provider
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(
            info.controller == oldServiceProvider,
            Errors.OldServiceProviderMismatch(dataSetId, info.controller, oldServiceProvider)
        );
        require(newServiceProvider != address(0), Errors.ZeroAddress(Errors.AddressField.ServiceProvider));
        // New service provider must be an approved provider
        require(approvedProvidersMap[newServiceProvider], Errors.NewServiceProviderNotApproved(newServiceProvider));

        // Update the data set controller (Service Provider)
        // Beneficiary is independent and should not auto-follow controller changes
        info.controller = newServiceProvider;

        emit DataSetServiceProviderChanged(dataSetId, oldServiceProvider, newServiceProvider);
    }

    function terminateDataSetPayment(uint256 dataSetId) external {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));

        // Check if already terminated
        require(info.paymentEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));

        // Check authorization
        require(
            msg.sender == info.payer || msg.sender == info.controller || msg.sender == info.beneficiary,
            Errors.CallerNotPayerOrPayee(dataSetId, info.payer, info.controller, msg.sender)
        );

        Payments payments = Payments(paymentsContractAddress);

        payments.terminateRail(info.pdpRailId);

        if (info.withCDN) {
            payments.terminateRail(info.cacheMissRailId);
            payments.terminateRail(info.cdnRailId);
        }
    }

    function requirePaymentNotTerminated(uint256 dataSetId) internal view {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.paymentEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));
    }

    function requirePaymentNotBeyondEndEpoch(uint256 dataSetId) internal view {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        if (info.paymentEndEpoch != 0) {
            require(
                block.number <= info.paymentEndEpoch,
                Errors.DataSetPaymentBeyondEndEpoch(dataSetId, info.paymentEndEpoch, block.number)
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
        if (dataSetInfo[dataSetId].withCDN) {
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
        return (epoch - activationEpoch) / getMaxProvingPeriod();
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
     * @notice Decode extra data for data set creation with format detection
     * @param extraData The encoded extra data from PDPVerifier
     * @return createData The decoded DataSetCreateData struct
     */
    function decodeDataSetCreateData(bytes calldata extraData)
        internal
        pure
        returns (DataSetCreateData memory createData)
    {
        require(extraData.length > 0, Errors.ExtraDataRequired());
        (string memory metadata, address payer, bool withCDN, address beneficiary, bytes memory signature) =
            abi.decode(extraData, (string, address, bool, address, bytes));
        return DataSetCreateData({
            metadata: metadata,
            payer: payer,
            withCDN: withCDN,
            beneficiary: beneficiary,
            signature: signature
        });
    }

    /**
     * @notice Get the total size of a data set in bytes
     * @param leafCount Number of leaves in the data set
     * @return totalBytes Total size in bytes
     */
    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256) {
        return leafCount * BYTES_PER_LEAF;
    }

    // --- Public getter functions ---
    /**
     * @notice Resolves the beneficiary address for a data set
     * @dev Returns controller if beneficiary is not set (legacy data sets)
     * @param dataSetId The ID of the data set
     * @return The beneficiary address
     */
    function resolveBeneficiary(uint256 dataSetId) public view returns (address) {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));

        address b = info.beneficiary;
        if (b == address(0)) {
            return info.controller; // Legacy fallback
        }
        return b;
    }

    /**
     * @notice Get data set information by ID
     * @param dataSetId The ID of the data set
     * @return The data set information struct
     */
    function getDataSet(uint256 dataSetId) external view returns (DataSetInfo memory) {
        return dataSetInfo[dataSetId];
    }

    /**
     * @notice Get payer and payment recipient for a data set (backward compatible)
     * @dev Returns the payment recipient which could be beneficiary or controller
     * @param dataSetId The ID of the data set
     * @return payer The address paying for storage
     * @return payee The address receiving payments (beneficiary if set, otherwise payee)
     */
    function getDataSetParties(uint256 dataSetId) external view returns (address payer, address payee) {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        return (info.payer, resolveBeneficiary(dataSetId));
    }

    /**
     * @notice Get all party addresses for a data set including beneficiary
     * @dev New function that returns all three addresses
     * @param dataSetId The ID of the data set
     * @return payer The address paying for storage
     * @return payee The SP's control address (hot key)
     * @return beneficiary The SP's payment address (cold key)
     */
    function getDataSetPartiesExtended(uint256 dataSetId)
        external
        view
        returns (address payer, address payee, address beneficiary)
    {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.DataSetNotRegistered(dataSetId));
        return (info.payer, info.controller, resolveBeneficiary(dataSetId));
    }

    /**
     * @notice Get the metadata for a specific piece
     * @param dataSetId The ID of the data set
     * @param pieceId The ID of the piece
     * @return The metadata string for the piece
     */
    function getPieceMetadata(uint256 dataSetId, uint256 pieceId) external view returns (string memory) {
        return dataSetPieceMetadata[dataSetId][pieceId];
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

    /**
     * @notice Verifies a signature for the CreateDataSet operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The unique ID for the client's data set
     * @param signature The signature bytes (v, r, s)
     */
    function verifyCreateDataSetSignature(
        address payer,
        uint256 clientDataSetId,
        address controller,
        bool withCDN,
        address beneficiary,
        bytes memory signature
    ) internal view {
        bytes32 structHash =
            keccak256(abi.encode(CREATE_DATA_SET_TYPEHASH, clientDataSetId, withCDN, controller, beneficiary));
        bytes32 digest = _hashTypedDataV4(structHash);

        address recoveredSigner = recoverSigner(digest, signature);
        require(payer == recoveredSigner, Errors.InvalidSignature(payer, recoveredSigner));
    }

    /**
     * @notice Verifies a signature for the AddPieces operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The ID of the data set
     * @param pieceDataArray Array of PieceSignatureData structures
     * @param signature The signature bytes (v, r, s)
     */
    function verifyAddPiecesSignature(
        address payer,
        uint256 clientDataSetId,
        IPDPTypes.PieceData[] memory pieceDataArray,
        uint256 firstAdded,
        bytes memory signature
    ) internal view {
        // Hash each PieceData struct
        bytes32[] memory pieceDataHashes = new bytes32[](pieceDataArray.length);
        for (uint256 i = 0; i < pieceDataArray.length; i++) {
            // Hash the PieceCid struct
            bytes32 cidHash = keccak256(abi.encode(PIECE_CID_TYPEHASH, keccak256(pieceDataArray[i].piece.data)));
            // Hash the PieceData struct
            pieceDataHashes[i] = keccak256(abi.encode(PIECE_DATA_TYPEHASH, cidHash, pieceDataArray[i].rawSize));
        }

        bytes32 structHash = keccak256(
            abi.encode(ADD_PIECES_TYPEHASH, clientDataSetId, firstAdded, keccak256(abi.encodePacked(pieceDataHashes)))
        );

        // Create the message hash
        bytes32 digest = _hashTypedDataV4(structHash);

        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);

        require(payer == recoveredSigner, Errors.InvalidSignature(payer, recoveredSigner));
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

        require(payer == recoveredSigner, Errors.InvalidSignature(payer, recoveredSigner));
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

        require(payer == recoveredSigner, Errors.InvalidSignature(payer, recoveredSigner));
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
     * @notice Register as a service provider
     * @dev SPs call this to register their service URL and optionally peer ID before approval
     * @param serviceURL The HTTP server URL for provider services
     * @param peerId The IPFS/libp2p peer ID for the provider (optional - pass empty bytes if not available)
     * @dev Requires exact payment of SP_REGISTRATION_FEE which is burned to f099
     */
    function registerServiceProvider(string calldata serviceURL, bytes calldata peerId) external payable {
        require(!approvedProvidersMap[msg.sender], Errors.ProviderAlreadyApproved(msg.sender));
        require(bytes(serviceURL).length > 0, Errors.ServiceURLEmpty());
        require(bytes(serviceURL).length <= 256, Errors.ServiceURLTooLong(bytes(serviceURL).length, 256));
        require(peerId.length <= 64, Errors.PeerIdTooLong(peerId.length, 64));

        // Check if registration is already pending
        require(pendingProviders[msg.sender].registeredAt == 0, Errors.RegistrationAlreadyPending(msg.sender));

        // Burn one-time fee to register
        require(msg.value == SP_REGISTRATION_FEE, Errors.IncorrectRegistrationFee(SP_REGISTRATION_FEE, msg.value));
        (bool sent,) = BURN_ADDRESS.call{value: msg.value}("");
        require(sent, Errors.BurnFailed());

        // Store pending registration
        pendingProviders[msg.sender] = PendingProviderInfo({
            serviceURL: serviceURL,
            peerId: peerId, // Can be empty bytes
            registeredAt: block.number
        });

        emit ProviderRegistered(msg.sender, serviceURL, peerId);
    }

    /**
     * @notice Approve a pending service provider
     * @dev Only owner can approve providers
     * @param provider The address of the provider to approve
     */
    function approveServiceProvider(address provider) external onlyOwner {
        // Check if not already approved
        require(!approvedProvidersMap[provider], Errors.ProviderAlreadyApproved(provider));
        // Check if registration exists
        require(pendingProviders[provider].registeredAt > 0, Errors.NoPendingRegistrationFound(provider));

        // Get pending registration data
        PendingProviderInfo memory pending = pendingProviders[provider];

        // Assign ID and store provider info
        uint256 providerId = nextServiceProviderId++;
        approvedProviders[providerId] = ApprovedProviderInfo({
            serviceProvider: provider,
            serviceURL: pending.serviceURL,
            peerId: pending.peerId,
            registeredAt: pending.registeredAt,
            approvedAt: block.number
        });

        approvedProvidersMap[provider] = true;
        providerToId[provider] = providerId;

        // Clear pending registration
        delete pendingProviders[provider];

        emit ProviderApproved(provider, providerId);
    }

    /**
     * @notice Reject a pending service provider
     * @dev Only owner can reject providers
     * @param provider The address of the provider to reject
     */
    function rejectServiceProvider(address provider) external onlyOwner {
        // Check if registration exists
        require(pendingProviders[provider].registeredAt > 0, Errors.NoPendingRegistrationFound(provider));
        require(!approvedProvidersMap[provider], Errors.ProviderAlreadyApproved(provider));

        // Update mappings
        approvedProvidersMap[provider] = false;
        providerToId[provider] = 0;

        // Clear pending registration
        delete pendingProviders[provider];

        emit ProviderRejected(provider);
    }

    /**
     * @notice Remove an already approved service provider by ID
     * @dev Only owner can remove providers. This revokes their approved status.
     * @param providerId The ID of the provider to remove
     */
    function removeServiceProvider(uint256 providerId) external onlyOwner {
        // Validate provider ID
        require(
            providerId > 0 && providerId < nextServiceProviderId,
            Errors.InvalidProviderId(nextServiceProviderId, providerId)
        );

        // Get provider info
        ApprovedProviderInfo memory providerInfo = approvedProviders[providerId];
        address providerAddress = providerInfo.serviceProvider;
        require(providerAddress != address(0), Errors.ProviderNotFound(providerId));

        // Check if provider is currently approved
        require(approvedProvidersMap[providerAddress], Errors.ProviderNotApproved(providerAddress));

        // Remove from approved mapping
        approvedProvidersMap[providerAddress] = false;

        // Remove the provider ID mapping
        delete providerToId[providerAddress];

        // Delete the provider info
        delete approvedProviders[providerId];

        emit ProviderRemoved(providerAddress, providerId);
    }

    /**
     * @notice Get service provider information by ID
     * @dev Only returns info for approved providers
     * @param providerId The ID of the service provider
     * @return The service provider information
     */
    function getApprovedProvider(uint256 providerId) external view returns (ApprovedProviderInfo memory) {
        require(
            providerId > 0 && providerId < nextServiceProviderId,
            Errors.InvalidProviderId(nextServiceProviderId, providerId)
        );
        ApprovedProviderInfo memory provider = approvedProviders[providerId];
        require(provider.serviceProvider != address(0), Errors.ProviderNotFound(providerId));
        return provider;
    }

    /**
     * @notice Get pending registration information
     * @param provider The address of the provider
     * @return The pending registration info
     */
    function getPendingProvider(address provider) external view returns (PendingProviderInfo memory) {
        return pendingProviders[provider];
    }

    /**
     * @notice Get the provider ID for a given address
     * @param provider The address of the provider
     * @return The provider ID (0 if not approved)
     */
    function getProviderIdByAddress(address provider) external view returns (uint256) {
        return providerToId[provider];
    }

    function getClientDataSets(address client) external view returns (DataSetInfo[] memory) {
        uint256[] memory dataSetIds = clientDataSets[client];

        DataSetInfo[] memory dataSets = new DataSetInfo[](dataSetIds.length);
        for (uint256 i = 0; i < dataSetIds.length; i++) {
            uint256 dataSetId = dataSetIds[i];
            DataSetInfo storage storageInfo = dataSetInfo[dataSetId];
            // Create a memory copy of the struct (excluding any mappings)
            dataSets[i] = DataSetInfo({
                pdpRailId: storageInfo.pdpRailId,
                cacheMissRailId: storageInfo.cacheMissRailId,
                cdnRailId: storageInfo.cdnRailId,
                payer: storageInfo.payer,
                controller: storageInfo.controller,
                beneficiary: storageInfo.beneficiary,
                commissionBps: storageInfo.commissionBps,
                metadata: storageInfo.metadata,
                pieceMetadata: storageInfo.pieceMetadata,
                clientDataSetId: storageInfo.clientDataSetId,
                withCDN: storageInfo.withCDN,
                paymentEndEpoch: storageInfo.paymentEndEpoch
            });
        }
        return dataSets;
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
        if (info.paymentEndEpoch == 0) {
            info.paymentEndEpoch = endEpoch;
        }
    }
}
