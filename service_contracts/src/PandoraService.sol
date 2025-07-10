// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {PDPVerifier, PDPListener} from "@pdp/PDPVerifier.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Payments, IArbiter} from "@fws-payments/Payments.sol";

/// @title PandoraService
/// @notice An implementation of PDP Listener with payment integration.
/// @dev This contract extends SimplePDPService by adding payment functionality
/// using the Payments contract. It creates payment rails for storage providers
/// and adjusts payment rates based on storage size. Also implements arbitration
/// to reduce payments for faulted epochs.
contract PandoraService is PDPListener, IArbiter, Initializable, UUPSUpgradeable, OwnableUpgradeable, EIP712Upgradeable {

    event FaultRecord(uint256 indexed proofSetId, uint256 periodsFaulted, uint256 deadline);
    event ProofSetRailsCreated(uint256 indexed proofSetId, uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId, address payer, address payee, bool withCDN);
    event RailRateUpdated(uint256 indexed proofSetId, uint256 railId, uint256 newRate);
    event RootMetadataAdded(uint256 indexed proofSetId, uint256 rootId, string metadata);

    // Constants
    uint256 public constant NO_CHALLENGE_SCHEDULED = 0;
    uint256 public constant NO_PROVING_DEADLINE = 0;
    uint256 public constant MIB_IN_BYTES = 1024 * 1024; // 1 MiB in bytes
    uint256 public constant BYTES_PER_LEAF = 32; // Each leaf is 32 bytes
    uint256 public constant COMMISSION_MAX_BPS = 10000; // 100% in basis points
    uint256 public constant DEFAULT_LOCKUP_PERIOD = 2880 * 10; // 10 days in epochs
    uint256 public constant GIB_IN_BYTES = MIB_IN_BYTES * 1024; // 1 GiB in bytes
    uint256 public constant TIB_IN_BYTES = GIB_IN_BYTES * 1024; // 1 TiB in bytes
    uint256 public constant EPOCHS_PER_MONTH = 2880 * 30;
    
    // Pricing constants
    uint256 public constant PRICE_PER_TIB_PER_MONTH_NO_CDN = 2; // 2 USDFC per TiB per month without CDN
    uint256 public constant PRICE_PER_TIB_PER_MONTH_WITH_CDN = 3; // 3 USDFC per TiB per month with CDN

    // Dynamic fee values based on token decimals
    uint256 public PROOFSET_CREATION_FEE; // 0.1 USDFC with correct decimals

    // Token decimals
    uint8 public tokenDecimals;

    // External contract addresses
    address public pdpVerifierAddress;
    address public paymentsContractAddress;
    address public usdfcTokenAddress;
    address public filCdnAddress;

    // Commission rate in basis points (100 = 1%)
    uint256 public operatorCommissionBps;
    
    // Commission rates for different service types
    uint256 public basicServiceCommissionBps;    // 0% for basic service (no CDN add-on)
    uint256 public cdnServiceCommissionBps;      // 40% for CDN service

    // Mapping from client address to clientDataSetId
    mapping(address => uint256) public clientDataSetIDs;
    // Mapping from proof set ID to root ID to metadata
    mapping(uint256 => mapping(uint256 => string)) public proofSetRootMetadata;

    // Storage for proof set payment information
    struct ProofSetInfo {
        uint256 pdpRailId; // ID of the pdp payment rail
        uint256 cacheMissRailId; // ID of the cache miss payment rail (for CDN add-on)
        uint256 cdnRailId; // ID of the CDN payment rail (for CDN add-on)
        address payer; // Address paying for storage
        address payee; // SP's beneficiary address
        uint256 commissionBps; // Commission rate for this proof set (dynamic based on whether the client purchases CDN add-on)
        string metadata; // General metadata for the proof set
        string[] rootMetadata; // Array of metadata for each root
        uint256 clientDataSetId; // ClientDataSetID
        bool withCDN; // Whether the proof set is registered for CDN add-on
    }

    // Decode structure for proof set creation extra data
    struct ProofSetCreateData {
        string metadata;
        address payer;
        bool withCDN;
        bytes signature; // Authentication signature
    }

    // Structure for service pricing information
    struct ServicePricing {
        uint256 pricePerTiBPerMonthNoCDN;  // Price without CDN add-on (2 USDFC per TiB per month)
        uint256 pricePerTiBPerMonthWithCDN; // Price with CDN add-on (3 USDFC per TiB per month)
        address tokenAddress;               // Address of the USDFC token
        uint256 epochsPerMonth;             // Number of epochs in a month
    }

    // Mappings
    mapping(uint256 => uint256) public provingDeadlines;
    mapping(uint256 => bool) public provenThisPeriod;
    mapping(uint256 => ProofSetInfo) public proofSetInfo;
    mapping(address => uint256[]) public clientProofSets;

    // Mapping from rail ID to proof set ID for arbitration
    mapping(uint256 => uint256) public railToProofSet;

    // Event for arbitration
    event PaymentArbitrated(
        uint256 railId, uint256 proofSetId, uint256 originalAmount, uint256 modifiedAmount, uint256 faultedEpochs
    );
    

    // Track which proving periods have valid proofs (proofSetId => periodId => isProven)
    mapping(uint256 => mapping(uint256 => bool)) public provenPeriods;

    // Track when proving was first activated for each proof set
    mapping(uint256 => uint256) public provingActivationEpoch;

    // ========== Storage Provider Registry State ==========
    
    uint256 public nextServiceProviderId = 1;
        
    struct ApprovedProviderInfo {
        address owner;
        string pdpUrl;
        string pieceRetrievalUrl;
        uint256 registeredAt; 
        uint256 approvedAt;   
    }
    
    struct PendingProviderInfo {
        string pdpUrl;
        string pieceRetrievalUrl;
        uint256 registeredAt; 
    }
    
    mapping(uint256 => ApprovedProviderInfo) public approvedProviders;
    
    mapping(address => bool) public approvedProvidersMap;
    
    mapping(address => PendingProviderInfo) public pendingProviders;
    
    mapping(address => uint256) public providerToId;
    
    // Proving period constants - set during initialization (added at end for upgrade compatibility)
    uint64 public maxProvingPeriod;
    uint256 public challengeWindowSize;
    
    // Events for SP registry
    event ProviderRegistered(address indexed provider, string pdpUrl, string pieceRetrievalUrl);
    event ProviderApproved(address indexed provider, uint256 indexed providerId);
    event ProviderRejected(address indexed provider);
    event ProviderRemoved(address indexed provider, uint256 indexed providerId);

    // EIP-712 Type hashes
    bytes32 private constant CREATE_PROOFSET_TYPEHASH = keccak256(
        "CreateProofSet(uint256 clientDataSetId,bool withCDN,address payee)"
    );
    
    bytes32 private constant CID_TYPEHASH = keccak256(
        "Cid(bytes data)"
    );

    bytes32 private constant ROOTDATA_TYPEHASH = keccak256(
        "RootData(Cid root,uint256 rawSize)Cid(bytes data)"
    );

    bytes32 private constant ADD_ROOTS_TYPEHASH = keccak256(
        "AddRoots(uint256 clientDataSetId,uint256 firstAdded,RootData[] rootData)Cid(bytes data)RootData(Cid root,uint256 rawSize)"
    );
    
    bytes32 private constant SCHEDULE_REMOVALS_TYPEHASH = keccak256(
        "ScheduleRemovals(uint256 clientDataSetId,uint256[] rootIds)"
    );
    
    bytes32 private constant DELETE_PROOFSET_TYPEHASH = keccak256(
        "DeleteProofSet(uint256 clientDataSetId)"
    );

    // Modifier to ensure only the PDP verifier contract can call certain functions
    modifier onlyPDPVerifier() {
        require(msg.sender == pdpVerifierAddress, "Caller is not the PDP verifier");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _pdpVerifierAddress,
        address _paymentsContractAddress,
        address _usdfcTokenAddress,
        address _filCdnAddress,
        uint256 _initialOperatorCommissionBps,
        uint64 _maxProvingPeriod,
        uint256 _challengeWindowSize
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __EIP712_init("PandoraService", "1");

        require(_pdpVerifierAddress != address(0), "PDP verifier address cannot be zero");
        require(_paymentsContractAddress != address(0), "Payments contract address cannot be zero");
        require(_usdfcTokenAddress != address(0), "USDFC token address cannot be zero");
        require(_initialOperatorCommissionBps <= COMMISSION_MAX_BPS, "Commission exceeds maximum");
        require(_maxProvingPeriod > 0, "Max proving period must be greater than zero");
        require(_challengeWindowSize > 0 && _challengeWindowSize < _maxProvingPeriod, "Invalid challenge window size");

        pdpVerifierAddress = _pdpVerifierAddress;
        paymentsContractAddress = _paymentsContractAddress;
        usdfcTokenAddress = _usdfcTokenAddress;
        operatorCommissionBps = _initialOperatorCommissionBps;
        maxProvingPeriod = _maxProvingPeriod;
        challengeWindowSize = _challengeWindowSize;
        filCdnAddress = _filCdnAddress;
        
        // Set commission rates: 0% for basic, 40% for service w/ CDN add-on
        basicServiceCommissionBps = 0;   // 0%
        cdnServiceCommissionBps = 4000;   // 40%

        // Read token decimals from the USDFC token contract
        tokenDecimals = IERC20Metadata(_usdfcTokenAddress).decimals();

        // Initialize the fee constants based on the actual token decimals
        PROOFSET_CREATION_FEE = (1 * 10 ** tokenDecimals) / 10; // 0.1 USDFC
        nextServiceProviderId = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Initializes the new proving period parameters for contract upgrade
     * @dev This function should be called after upgrading to set the new proving period constants
     * @param _maxProvingPeriod Maximum number of epochs between two consecutive proofs
     * @param _challengeWindowSize Number of epochs for the challenge window
     */
    function initializeV2(
        uint64 _maxProvingPeriod,
        uint256 _challengeWindowSize
    ) public reinitializer(2) {
        require(_maxProvingPeriod > 0, "Max proving period must be greater than zero");
        require(_challengeWindowSize > 0 && _challengeWindowSize < _maxProvingPeriod, "Invalid challenge window size");
        
        maxProvingPeriod = _maxProvingPeriod;
        challengeWindowSize = _challengeWindowSize;
    }

    /**
     * @notice Updates the service commission rates
     * @dev Only callable by the contract owner
     * @param newBasicCommissionBps New commission rate for basic service (no CDN) in basis points
     * @param newCdnCommissionBps New commission rate for CDN service in basis points
     */
    function updateServiceCommission(uint256 newBasicCommissionBps, uint256 newCdnCommissionBps) external onlyOwner {
        require(newBasicCommissionBps <= COMMISSION_MAX_BPS, "Basic commission exceeds maximum");
        require(newCdnCommissionBps <= COMMISSION_MAX_BPS, "CDN commission exceeds maximum");
        basicServiceCommissionBps = newBasicCommissionBps;
        cdnServiceCommissionBps = newCdnCommissionBps;
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
            revert("Proving period not yet initialized");
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
    function nextChallengeWindowStart(uint256 setId) public view returns (uint256) {
        if (provingDeadlines[setId] == NO_PROVING_DEADLINE) {
            revert("Proving period not yet initialized");
        }
        // If the current period is open this is the next period's challenge window
        if (block.number <= provingDeadlines[setId]) {
            return thisChallengeWindowStart(setId) + getMaxProvingPeriod();
        }
        // If the current period is not yet open this is the current period's challenge window
        return thisChallengeWindowStart(setId);
    }

    // Challenges / merkle inclusion proofs provided per proof set
    function getChallengesPerProof() public pure returns (uint64) {
        return 5;
    }
    
    // Getters
    function getAllApprovedProviders() external view returns (ApprovedProviderInfo[] memory) {
        // Handle edge case: no providers have been registered
        if (nextServiceProviderId == 1) {
            return new ApprovedProviderInfo[](0);
        }
        
        // First pass: Count non-empty providers (those with non-zero owner address)
        uint256 activeCount = 0;
        for (uint256 i = 1; i < nextServiceProviderId; i++) {
            if (approvedProviders[i].owner != address(0)) {
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
            if (approvedProviders[i].owner != address(0)) {
                providers[currentIndex] = approvedProviders[i];
                currentIndex++;
            }
        }
        
        return providers;
    }
    // Listener interface methods
    /**
     * @notice Handles proof set creation by creating a payment rail
     * @dev Called by the PDPVerifier contract when a new proof set is created
     * @param proofSetId The ID of the newly created proof set
     * @param creator The address that created the proof set and will receive payments
     * @param extraData Encoded data containing metadata, payer information, and signature
     */
    function proofSetCreated(uint256 proofSetId, address creator, bytes calldata extraData) external onlyPDPVerifier {
        // Decode the extra data to get the metadata, payer address, and signature
        require(extraData.length > 0, "Extra data required for proof set creation");
        ProofSetCreateData memory createData = decodeProofSetCreateData(extraData);

        // Validate the addresses
        require(createData.payer != address(0), "Payer address cannot be zero");
        require(creator != address(0), "Creator address cannot be zero");
        
        // Check if the storage provider is whitelisted
        require(approvedProvidersMap[creator], "Storage provider not approved");
        
        // Update client state 
        uint256 clientDataSetId = clientDataSetIDs[createData.payer]++;
        clientProofSets[createData.payer].push(proofSetId);
        
        // Verify the client's signature
        require(
            verifyCreateProofSetSignature(
                createData.payer,
                clientDataSetId,
                creator,
                createData.withCDN,
                createData.signature
            ),
            "Invalid signature for proof set creation"
        );
        // Initialize the ProofSetInfo struct
        ProofSetInfo storage info = proofSetInfo[proofSetId];
        info.payer = createData.payer;
        info.payee = creator; // Using creator as the payee
        info.metadata = createData.metadata;
        info.commissionBps = createData.withCDN ? cdnServiceCommissionBps : basicServiceCommissionBps;
        info.clientDataSetId = clientDataSetId;
        info.withCDN = createData.withCDN;


        // Note: The payer must have pre-approved this contract to spend USDFC tokens before creating the proof set

        // Create the payment rail using the Payments contract
        Payments payments = Payments(paymentsContractAddress);
        uint256 pdpRailId = payments.createRail(
            usdfcTokenAddress, // token address
            createData.payer, // from (payer)
            creator, // proofset creator, SPs in  most cases
            address(this), // this contract acts as the arbiter
            info.commissionBps // commission rate based on CDN usage
        );

        // Store the rail ID
        info.pdpRailId = pdpRailId;

        // Store reverse mapping from rail ID to proof set ID for arbitration
        railToProofSet[pdpRailId] = proofSetId;

        // First, set a lockupFixed value that's at least equal to the one-time payment
        // This is necessary because modifyRailPayment requires that lockupFixed >= oneTimePayment
        payments.modifyRailLockup(
            pdpRailId,
            DEFAULT_LOCKUP_PERIOD,
            PROOFSET_CREATION_FEE // lockupFixed equal to the one-time payment amount
        );

        // Charge the one-time proof set creation fee
        // This is a payment from payer to proofset creator of a fixed amount
        payments.modifyRailPayment(
            pdpRailId,
            0, // Initial rate is 0, will be updated when roots are added
            PROOFSET_CREATION_FEE // One-time payment amount
        );

        uint256 cacheMissRailId = 0;
        uint256 cdnRailId = 0;

        if (createData.withCDN == true) {
            cacheMissRailId = payments.createRail(
                usdfcTokenAddress, // token address
                createData.payer, // from (payer)
                creator, // proofset creator, SPs in most cases
                address(this), // this contract acts as the arbiter
                0 // no service commission
            );
            info.cacheMissRailId = cacheMissRailId;
            railToProofSet[cacheMissRailId] = proofSetId; // TODO

            // TODO
            // First, set a lockupFixed value that's at least equal to the one-time payment
            // This is necessary because modifyRailPayment requires that lockupFixed >= oneTimePayment
            payments.modifyRailLockup(
                cacheMissRailId,
                DEFAULT_LOCKUP_PERIOD,
                PROOFSET_CREATION_FEE // lockupFixed equal to the one-time payment amount
            );

            // TODO
            // Charge the one-time proof set creation fee
            // This is a payment from payer to proofset creator of a fixed amount
            payments.modifyRailPayment(
                cacheMissRailId,
                0, // Initial rate is 0, will be updated when roots are added
                PROOFSET_CREATION_FEE // One-time payment amount
            );

            cdnRailId = payments.createRail(
                usdfcTokenAddress, // token address
                createData.payer, // from (payer)
                filCdnAddress,
                address(this), // this contract acts as the arbiter
                0 // no service commission
            );
            info.cdnRailId = cdnRailId;
            railToProofSet[cdnRailId] = proofSetId; // TODO

            // TODO
            // First, set a lockupFixed value that's at least equal to the one-time payment
            // This is necessary because modifyRailPayment requires that lockupFixed >= oneTimePayment
            payments.modifyRailLockup(
                cdnRailId,
                DEFAULT_LOCKUP_PERIOD,
                PROOFSET_CREATION_FEE // lockupFixed equal to the one-time payment amount
            );

            // TODO
            // Charge the one-time proof set creation fee
            // This is a payment from payer to proofset creator of a fixed amount
            payments.modifyRailPayment(
                cdnRailId,
                0, // Initial rate is 0, will be updated when roots are added
                PROOFSET_CREATION_FEE // One-time payment amount
            );
        }

        // Emit event for tracking
        emit ProofSetRailsCreated(proofSetId, pdpRailId, cacheMissRailId, cdnRailId, createData.payer, creator, createData.withCDN);
    }

    /**
     * @notice Handles proof set deletion and terminates the payment rail
     * @dev Called by the PDPVerifier contract when a proof set is deleted
     * @param proofSetId The ID of the proof set being deleted
     * @param extraData Signature for authentication
     */
    function proofSetDeleted(
        uint256 proofSetId,
        uint256,// deletedLeafCount, - not used 
        bytes calldata extraData
    ) external onlyPDPVerifier {
        // Verify the proof set exists in our mapping
        ProofSetInfo storage info = proofSetInfo[proofSetId];
        require(
            info.pdpRailId != 0,
            "Proof set not registered with payment system"
        );
        (bytes memory signature) = abi.decode(extraData, (bytes));
        
        // Get the payer address for this proof set
        address payer = proofSetInfo[proofSetId].payer;
        
        // Verify the client's signature
        require(
            verifyDeleteProofSetSignature(
                payer,
                info.clientDataSetId,
                signature
            ),
            "Not authorized to delete proof set"
        );
        // TODO Proofset deletion logic         
    }

    /**
     * @notice Handles roots being added to a proof set and stores associated metadata
     * @dev Called by the PDPVerifier contract when roots are added to a proof set
     * @param proofSetId The ID of the proof set
     * @param firstAdded The ID of the first root added
     * @param rootData Array of root data objects
     * @param extraData Encoded metadata, and signature
     */
    function rootsAdded(
        uint256 proofSetId,
        uint256 firstAdded,
        PDPVerifier.RootData[] memory rootData,
        bytes calldata extraData
    ) external onlyPDPVerifier {
        // Verify the proof set exists in our mapping
        ProofSetInfo storage info = proofSetInfo[proofSetId];
        require(info.pdpRailId != 0, "Proof set not registered with payment system");
        
        // Get the payer address for this proof set
        address payer = info.payer;
        require(extraData.length > 0, "Extra data required for adding roots");
        // Decode the extra data
        (bytes memory signature, string memory metadata) =  abi.decode(extraData, (bytes, string));
        
        // Verify the signature
        require(
            verifyAddRootsSignature(
                payer,
                info.clientDataSetId,
                rootData,
                firstAdded,
                signature
            ),
            "Invalid signature for adding roots"
        );

        // Store metadata for each new root
        for (uint256 i = 0; i < rootData.length; i++) {
            uint256 rootId = firstAdded + i;
            proofSetRootMetadata[proofSetId][rootId] = metadata;
            emit RootMetadataAdded(proofSetId, rootId, metadata);
        }
    }

    function rootsScheduledRemove(uint256 proofSetId, uint256[] memory rootIds, bytes calldata extraData)
        external
        onlyPDPVerifier
    {
        // Verify the proof set exists in our mapping   
        ProofSetInfo storage info = proofSetInfo[proofSetId];
        require(
            info.pdpRailId != 0,
            "Proof set not registered with payment system"
        );
        
        // Get the payer address for this proof set
        address payer = info.payer;
        
        // Decode the signature from extraData
        require(extraData.length > 0, "Extra data required for scheduling removals");
        bytes memory signature = abi.decode(extraData, (bytes));
        
        // Verify the signature
        require(
            verifyScheduleRemovalsSignature(
                payer,
                info.clientDataSetId,
                rootIds,
                signature
            ),
            "Invalid signature for scheduling root removals"
        );
        
        // Additional logic for scheduling removals can be added here
    }

    // possession proven checks for correct challenge count and reverts if too low
    // it also checks that proofs are not late and emits a fault record if so
    function possessionProven(
        uint256 proofSetId,
        uint256, /*challengedLeafCount*/
        uint256, /*seed*/
        uint256 challengeCount
    ) external onlyPDPVerifier {
        if (provenThisPeriod[proofSetId]) {
            revert("Only one proof of possession allowed per proving period. Open a new proving period.");
        }
        if (challengeCount < getChallengesPerProof()) {
            revert("Invalid challenge count < 5");
        }
        if (provingDeadlines[proofSetId] == NO_PROVING_DEADLINE) {
            revert("Proving not yet started");
        }
        // check for proof outside of challenge window
        if (provingDeadlines[proofSetId] < block.number) {
            revert("Current proving period passed. Open a new proving period.");
        }

        if (provingDeadlines[proofSetId] - challengeWindow() > block.number) {
            revert("Too early. Wait for challenge window to open");
        }
        provenThisPeriod[proofSetId] = true;
        uint256 currentPeriod = getProvingPeriodForEpoch(proofSetId, block.number);
        provenPeriods[proofSetId][currentPeriod] = true;
    }

    // nextProvingPeriod checks for unsubmitted proof in which case it emits a fault event
    // Additionally it enforces constraints on the update of its state:
    // 1. One update per proving period.
    // 2. Next challenge epoch must fall within the challenge window in the last challengeWindow()
    //    epochs of the proving period.
    //
    // In the payment version, it also updates the payment rate based on the current storage size.
    function nextProvingPeriod(uint256 proofSetId, uint256 challengeEpoch, uint256 leafCount, bytes calldata)
        external
        onlyPDPVerifier
    {
        // initialize state for new proofset
        if (provingDeadlines[proofSetId] == NO_PROVING_DEADLINE) {
            uint256 firstDeadline = block.number + getMaxProvingPeriod();
            if (challengeEpoch < firstDeadline - challengeWindow() || challengeEpoch > firstDeadline) {
                revert("Next challenge epoch must fall within the next challenge window");
            }
            provingDeadlines[proofSetId] = firstDeadline;
            provenThisPeriod[proofSetId] = false;

            // Initialize the activation epoch when proving first starts
            // This marks when the proof set became active for proving
            provingActivationEpoch[proofSetId] = block.number;

            // Update the payment rate
            updateRailPaymentRate(proofSetId, leafCount);

            return;
        }

        // Revert when proving period not yet open
        // Can only get here if calling nextProvingPeriod multiple times within the same proving period
        uint256 prevDeadline = provingDeadlines[proofSetId] - getMaxProvingPeriod();
        if (block.number <= prevDeadline) {
            revert("One call to nextProvingPeriod allowed per proving period");
        }

        uint256 periodsSkipped;
        // Proving period is open 0 skipped periods
        if (block.number <= provingDeadlines[proofSetId]) {
            periodsSkipped = 0;
        } else {
            // Proving period has closed possibly some skipped periods
            periodsSkipped = (block.number - (provingDeadlines[proofSetId] + 1)) / getMaxProvingPeriod();
        }

        uint256 nextDeadline;
        // the proofset has become empty and provingDeadline is set inactive
        if (challengeEpoch == NO_CHALLENGE_SCHEDULED) {
            nextDeadline = NO_PROVING_DEADLINE;
        } else {
            nextDeadline = provingDeadlines[proofSetId] + getMaxProvingPeriod() * (periodsSkipped + 1);
            if (challengeEpoch < nextDeadline - challengeWindow() || challengeEpoch > nextDeadline) {
                revert("Next challenge epoch must fall within the next challenge window");
            }
        }
        uint256 faultPeriods = periodsSkipped;
        if (!provenThisPeriod[proofSetId]) {
            // include previous unproven period
            faultPeriods += 1;
        }
        if (faultPeriods > 0) {
            emit FaultRecord(proofSetId, faultPeriods, provingDeadlines[proofSetId]);
        }

        // Record the status of the current/previous proving period that's ending
        if (provingDeadlines[proofSetId] != NO_PROVING_DEADLINE) {
            // Determine the period ID that just completed
            uint256 completedPeriodId = getProvingPeriodForEpoch(proofSetId, provingDeadlines[proofSetId] - 1);

            // Record whether this period was proven
            provenPeriods[proofSetId][completedPeriodId] = provenThisPeriod[proofSetId];
        }

        provingDeadlines[proofSetId] = nextDeadline;
        provenThisPeriod[proofSetId] = false;

        // Update the payment rate based on current proof set size
        updateRailPaymentRate(proofSetId, leafCount);
    }

    function updateRailPaymentRate(uint256 proofSetId, uint256 leafCount) internal {
        // Revert if no payment rail is configured for this proof set
        require(proofSetInfo[proofSetId].pdpRailId != 0, "No payment rail configured");

        uint256 newRatePerEpoch = 0; // Default to 0 for empty proof sets

        uint256 totalBytes = getProofSetSizeInBytes(leafCount);
        // Get the withCDN flag from the proof set info
        bool withCDN = proofSetInfo[proofSetId].withCDN;
        newRatePerEpoch = calculateStorageRatePerEpoch(totalBytes, withCDN);

        // Update the rail payment rate
        Payments payments = Payments(paymentsContractAddress);
        uint256 railId = proofSetInfo[proofSetId].pdpRailId;

        // Call modifyRailPayment with the new rate and no one-time payment
        payments.modifyRailPayment(
            railId,
            newRatePerEpoch,
            0 // No one-time payment during rate update
        );

        emit RailRateUpdated(proofSetId, railId, newRatePerEpoch);
    }

    /**
     * @notice Determines which proving period an epoch belongs to
     * @dev For a given epoch, calculates the period ID based on activation time
     * @param proofSetId The ID of the proof set
     * @param epoch The epoch to check
     * @return The period ID this epoch belongs to, or type(uint256).max if before activation
     */
    function getProvingPeriodForEpoch(uint256 proofSetId, uint256 epoch) public view returns (uint256) {
        uint256 activationEpoch = provingActivationEpoch[proofSetId];

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
     * @param proofSetId The ID of the proof set to check
     * @param epoch The epoch to check
     * @return True if the epoch has been proven, false otherwise
     */
    function isEpochProven(uint256 proofSetId, uint256 epoch) public view returns (bool) {
        // Check if proof set is active
        if (provingActivationEpoch[proofSetId] == 0) {
            return false;
        }

        // Check if this epoch is before activation
        if (epoch < provingActivationEpoch[proofSetId]) {
            return false;
        }

        // Check if this epoch is in the future (beyond current block)
        if (epoch > block.number) {
            return false;
        }

        // Get the period this epoch belongs to
        uint256 periodId = getProvingPeriodForEpoch(proofSetId, epoch);

        // Special case: current ongoing proving period
        uint256 currentPeriod = getProvingPeriodForEpoch(proofSetId, block.number);
        if (periodId == currentPeriod) {
            // For the current period, check if it has been proven already
            return provenThisPeriod[proofSetId];
        }

        // For past periods, check the provenPeriods mapping
        return provenPeriods[proofSetId][periodId];
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice Calculate the per-epoch rate based on total storage size and CDN usage
     * @dev Rate is 2 USDFC per TiB per month without CDN, 3 USDFC per TiB per month with CDN.
     * @param totalBytes Total size of the stored data in bytes
     * @param withCDN Whether CDN is enabled for the proof set
     * @return ratePerEpoch The calculated rate per epoch in the token's smallest unit
     */
    function calculateStorageRatePerEpoch(uint256 totalBytes, bool withCDN) public view returns (uint256) {
        // Determine the rate based on CDN usage using constants
        uint256 ratePerTiBPerMonth = withCDN ? PRICE_PER_TIB_PER_MONTH_WITH_CDN : PRICE_PER_TIB_PER_MONTH_NO_CDN;
        
        uint256 numerator = totalBytes * ratePerTiBPerMonth * (10 ** uint256(tokenDecimals));
        uint256 denominator = TIB_IN_BYTES * EPOCHS_PER_MONTH;

        // Ensure denominator is not zero (shouldn't happen with constants)
        require(denominator > 0, "Denominator cannot be zero");

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
     * @notice Decode extra data for proof set creation
     * @param extraData The encoded extra data from PDPVerifier
     * @return decoded The decoded ProofSetCreateData struct
     */
    function decodeProofSetCreateData(bytes calldata extraData) internal pure returns (ProofSetCreateData memory) {
         (string memory metadata, address payer, bool withCDN, bytes memory signature) = 
        abi.decode(extraData, (string, address, bool, bytes));

        return ProofSetCreateData({
            metadata: metadata,
            payer: payer,
            withCDN: withCDN,
            signature: signature
        });
    }

    /**
     * @notice Get the total size of a proof set in bytes
     * @param leafCount Number of leaves in the proof set
     * @return totalBytes Total size in bytes
     */
    function getProofSetSizeInBytes(uint256 leafCount) public pure returns (uint256) {
        return leafCount * BYTES_PER_LEAF;
    }

    // --- Public getter functions ---

    /**
     * @notice Get proof set information by ID
     * @param proofSetId The ID of the proof set
     * @return The proof set information struct
     */
    function getProofSet(uint256 proofSetId) external view returns (ProofSetInfo memory) {
        return proofSetInfo[proofSetId];
    }

    /**
     * @notice Get the payment rail ID for a proof set
     * @param proofSetId The ID of the proof set
     * @return The payment rail ID, or 0 if not found
     */
    function getProofSetPdpRailId(uint256 proofSetId) external view returns (uint256) {
        return proofSetInfo[proofSetId].pdpRailId;
    }

    /**
     * @notice Get payer and payee addresses for a proof set
     * @param proofSetId The ID of the proof set
     * @return payer The address paying for storage
     * @return payee The address receiving payments (SP beneficiary)
     */
    function getProofSetParties(uint256 proofSetId) external view returns (address payer, address payee) {
        ProofSetInfo storage info = proofSetInfo[proofSetId];
        return (info.payer, info.payee);
    }

    /**
     * @notice Get the metadata for a proof set
     * @param proofSetId The ID of the proof set
     * @return The metadata string
     */
    function getProofSetMetadata(uint256 proofSetId) external view returns (string memory) {
        return proofSetInfo[proofSetId].metadata;
    }

    /**
     * @notice Get CDN enabled for a proof set
     * @param proofSetId The ID of the proof set
     * @return CDN enabled
     */
    function getProofSetWithCDN(uint256 proofSetId) external view returns (bool) {
        return proofSetInfo[proofSetId].withCDN;
    }

    /**
     * @notice Get the metadata for a specific root
     * @param proofSetId The ID of the proof set
     * @param rootId The ID of the root
     * @return The metadata string for the root
     */
    function getRootMetadata(uint256 proofSetId, uint256 rootId) external view returns (string memory) {
        return proofSetRootMetadata[proofSetId][rootId];
    }

    /**
     * @notice Get the service pricing information
     * @return pricing A struct containing pricing details for both CDN and non-CDN storage
     */
    function getServicePrice() external view returns (ServicePricing memory pricing) {
        pricing = ServicePricing({
            pricePerTiBPerMonthNoCDN: PRICE_PER_TIB_PER_MONTH_NO_CDN * (10 ** uint256(tokenDecimals)),
            pricePerTiBPerMonthWithCDN: PRICE_PER_TIB_PER_MONTH_WITH_CDN * (10 ** uint256(tokenDecimals)),
            tokenAddress: usdfcTokenAddress,
            epochsPerMonth: EPOCHS_PER_MONTH
        });
    }
    
    /**
     * @notice Get the effective rates after commission for both service types
     * @return basicServiceFee Service fee for basic service (per TiB per month)
     * @return spPaymentBasic SP payment for basic service (per TiB per month)
     * @return cdnServiceFee Service fee with CDN service (per TiB per month)
     * @return spPaymentWithCDN SP payment with CDN service (per TiB per month)
     */
    function getEffectiveRates() external view returns (
        uint256 basicServiceFee,
        uint256 spPaymentBasic, 
        uint256 cdnServiceFee,
        uint256 spPaymentWithCDN
    ) {
        uint256 basicTotal = PRICE_PER_TIB_PER_MONTH_NO_CDN * (10 ** uint256(tokenDecimals));
        uint256 cdnTotal = PRICE_PER_TIB_PER_MONTH_WITH_CDN * (10 ** uint256(tokenDecimals));
        
        // Basic service (5% commission = 0.1 USDFC service, 1.9 USDFC to SP)
        basicServiceFee = (basicTotal * basicServiceCommissionBps) / COMMISSION_MAX_BPS;
        spPaymentBasic = basicTotal - basicServiceFee;
        
        // CDN service (40% commission = 1.2 USDFC service, 1.8 USDFC to SP)
        cdnServiceFee = (cdnTotal * cdnServiceCommissionBps) / COMMISSION_MAX_BPS;
        spPaymentWithCDN = cdnTotal - cdnServiceFee;
    }

    /**
     * @notice Verifies a signature for the CreateProofSet operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The unique ID for the client's dataset
     * @param signature The signature bytes (v, r, s)
     * @return True if the signature is valid, false otherwise
     */
    function verifyCreateProofSetSignature(
        address payer,
        uint256 clientDataSetId,
        address payee,
        bool withCDN,
        bytes memory signature
    ) internal view returns (bool) {
        // Prepare the message hash that was signed
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_PROOFSET_TYPEHASH,
                clientDataSetId,                       
                withCDN,                                
                payee
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        
        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);
        
        // Check if the recovered signer matches the expected payer
        return recoveredSigner == payer;
    }
    
    /**
     * @notice Verifies a signature for the AddRoots operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The ID of the proof set
     * @param rootDataArray Array of RootSignatureData structures
     * @param signature The signature bytes (v, r, s)
     * @return True if the signature is valid, false otherwise
     */
    function verifyAddRootsSignature(
        address payer,
        uint256 clientDataSetId,
        PDPVerifier.RootData[] memory rootDataArray,
        uint256 firstAdded,
        bytes memory signature
    ) internal view returns (bool) {
        // Hash each RootData struct
        bytes32[] memory rootDataHashes = new bytes32[](rootDataArray.length);
        for (uint256 i = 0; i < rootDataArray.length; i++) {
            // Hash the Cid struct
            bytes32 cidHash = keccak256(
                abi.encode(
                    CID_TYPEHASH,
                    keccak256(rootDataArray[i].root.data)
                )
            );
            // Hash the RootData struct
            rootDataHashes[i] = keccak256(
                abi.encode(
                    ROOTDATA_TYPEHASH,
                    cidHash,
                    rootDataArray[i].rawSize
                )
            );
        }

        bytes32 structHash = keccak256(abi.encode(
            ADD_ROOTS_TYPEHASH,
            clientDataSetId,
            firstAdded,
            keccak256(abi.encodePacked(rootDataHashes))
        ));

        // Create the message hash
        bytes32 digest = _hashTypedDataV4(structHash);
        
        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);
        
        // Check if the recovered signer matches the expected payer
        return recoveredSigner == payer;
    }
    
    /**
     * @notice Verifies a signature for the ScheduleRemovals operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The ID of the proof set
     * @param rootIds Array of root IDs to be removed
     * @param signature The signature bytes (v, r, s)
     * @return True if the signature is valid, false otherwise
     */
    function verifyScheduleRemovalsSignature(
        address payer,
        uint256 clientDataSetId,
        uint256[] memory rootIds,
        bytes memory signature
    ) internal view returns (bool) {

        // Prepare the message hash that was signed
        bytes32 structHash = keccak256(
            abi.encode(
                SCHEDULE_REMOVALS_TYPEHASH,
                clientDataSetId,                        
                keccak256(abi.encodePacked(rootIds))                           
            )
        );
        
        bytes32 digest = _hashTypedDataV4(structHash);

        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);
        
        // Check if the recovered signer matches the expected payer
        return recoveredSigner == payer;
    }
    
    /**
     * @notice Verifies a signature for the DeleteProofSet operation
     * @param payer The address of the payer who should have signed the message
     * @param clientDataSetId The ID of the proof set
     * @param signature The signature bytes (v, r, s)
     * @return True if the signature is valid, false otherwise
     */
    function verifyDeleteProofSetSignature(
        address payer,
        uint256 clientDataSetId,
        bytes memory signature
    ) internal view returns (bool) {
        // Prepare the message hash that was signed
        bytes32 structHash = keccak256(
            abi.encode(
                DELETE_PROOFSET_TYPEHASH,
                clientDataSetId                        
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        
        // Recover signer address from the signature
        address recoveredSigner = recoverSigner(digest, signature);
        
        // Check if the recovered signer matches the expected payer
        return recoveredSigner == payer;
    }
    
    /**
     * @notice Recover the signer address from a signature
     * @param messageHash The signed message hash
     * @param signature The signature bytes (v, r, s)
     * @return The address that signed the message
     */
    function recoverSigner(
        bytes32 messageHash,
        bytes memory signature
    ) internal pure returns (address) {
        require(signature.length == 65, "Invalid signature length");
        
        bytes32 r;
        bytes32 s;
        uint8 v;
        
        // Extract r, s, v from the signature
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        
        // If v is not 27 or 28, adjust it (for some wallets)
        if (v < 27) {
            v += 27;
        }
        
        require(v == 27 || v == 28, "Unsupported signature 'v' value, we don't handle rare wrapped case");
        
        // Recover and return the address
        return ecrecover(messageHash, v, r, s);
    }
    
    /**
     * @notice Register as a service provider
     * @dev SPs call this to register their URLs before approval
     * @param pdpUrl The URL for PDP services
     * @param pieceRetrievalUrl The URL for piece retrieval services
     */
    function registerServiceProvider(string calldata pdpUrl, string calldata pieceRetrievalUrl) external {
        require(!approvedProvidersMap[msg.sender], "Provider already approved");
        
        // Check if registration is already pending
        require(pendingProviders[msg.sender].registeredAt == 0, "Registration already pending");
        
        // Store pending registration
        pendingProviders[msg.sender] = PendingProviderInfo({
            pdpUrl: pdpUrl,
            pieceRetrievalUrl: pieceRetrievalUrl,
            registeredAt: block.number
        });
        
        emit ProviderRegistered(msg.sender, pdpUrl, pieceRetrievalUrl);
    }
    
    /**
     * @notice Approve a pending service provider
     * @dev Only owner can approve providers
     * @param provider The address of the provider to approve
     */
    function approveServiceProvider(address provider) external onlyOwner {
        // Check if not already approved
        require(!approvedProvidersMap[provider], "Provider already approved");
        // Check if registration exists
        require(pendingProviders[provider].registeredAt > 0, "No pending registration found");
        
        // Get pending registration data
        PendingProviderInfo memory pending = pendingProviders[provider];
        
        // Assign ID and store provider info
        uint256 providerId = nextServiceProviderId++;
        approvedProviders[providerId] = ApprovedProviderInfo({
            owner: provider,
            pdpUrl: pending.pdpUrl,
            pieceRetrievalUrl: pending.pieceRetrievalUrl,
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
        require(pendingProviders[provider].registeredAt > 0, "No pending registration found");
        require(!approvedProvidersMap[provider], "Provider already approved");
        
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
        require(providerId > 0 && providerId < nextServiceProviderId, "Invalid provider ID");
        
        // Get provider info
        ApprovedProviderInfo memory providerInfo = approvedProviders[providerId];
        address providerAddress = providerInfo.owner;
        require(providerAddress != address(0), "Provider not found");
        
        // Check if provider is currently approved
        require(approvedProvidersMap[providerAddress], "Provider not approved");
        
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
        require(providerId > 0 && providerId < nextServiceProviderId, "Invalid provider ID");
        ApprovedProviderInfo memory provider = approvedProviders[providerId];
        require(provider.owner != address(0), "Provider not found");
        return provider;
    }
    
    /**
     * @notice Check if a provider is approved
     * @param provider The address to check
     * @return True if approved, false otherwise
     */
    function isProviderApproved(address provider) external view returns (bool) {
        return approvedProvidersMap[provider];
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
    
    /**
     * @notice Add a service provider directly without registration process
     * @dev Only owner can add providers directly. This bypasses the register+approve flow.
     * @param provider The address of the provider to add
     * @param pdpUrl The URL for PDP services
     * @param pieceRetrievalUrl The URL for piece retrieval services
     */
    function addServiceProvider(address provider, string calldata pdpUrl, string calldata pieceRetrievalUrl) external onlyOwner {
        require(provider != address(0), "Provider address cannot be zero");
        require(!approvedProvidersMap[provider], "Provider already approved");
        
        // Assign ID and store provider info
        uint256 providerId = nextServiceProviderId++;
        approvedProviders[providerId] = ApprovedProviderInfo({
            owner: provider,
            pdpUrl: pdpUrl,
            pieceRetrievalUrl: pieceRetrievalUrl,
            registeredAt: block.number,
            approvedAt: block.number
        });
        
        approvedProvidersMap[provider] = true;
        providerToId[provider] = providerId;
        
        // Clear any pending registration if it exists
        if (pendingProviders[provider].registeredAt > 0) {
            delete pendingProviders[provider];
        }
        
        emit ProviderApproved(provider, providerId);
    }

    function getClientProofSets(address client) public view returns (ProofSetInfo[] memory) {
        uint256[] memory proofSetIds = clientProofSets[client];
   
        ProofSetInfo[] memory proofSets = new ProofSetInfo[](proofSetIds.length);
        for (uint256 i = 0; i < proofSetIds.length; i++) {
            uint256 proofSetId = proofSetIds[i];
            ProofSetInfo storage storageInfo = proofSetInfo[proofSetId];
            // Create a memory copy of the struct (excluding any mappings)
            proofSets[i] = ProofSetInfo({
                pdpRailId: storageInfo.pdpRailId,
                cacheMissRailId: storageInfo.cacheMissRailId,
                cdnRailId: storageInfo.cdnRailId,
                payer: storageInfo.payer,
                payee: storageInfo.payee,
                commissionBps: storageInfo.commissionBps,
                metadata: storageInfo.metadata,
                rootMetadata: storageInfo.rootMetadata,
                clientDataSetId: storageInfo.clientDataSetId,
                withCDN: storageInfo.withCDN
            });
        }
        return proofSets;
    }

    /**
     * @notice Arbitrates payment based on faults in the given epoch range
     * @dev Implements the IArbiter interface function

     * @param railId ID of the payment rail
     * @param proposedAmount The originally proposed payment amount
     * @param fromEpoch Starting epoch (exclusive)
     * @param toEpoch Ending epoch (inclusive)
     * @return result The arbitration result with modified amount and settlement information
     */
    function arbitratePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 /* rate */)
        external
        override
        returns (ArbitrationResult memory result)
    {
        // Get the proof set ID associated with this rail
        uint256 proofSetId = railToProofSet[railId];
        require(proofSetId != 0, "Rail not associated with any proof set");

        // Calculate the total number of epochs in the requested range
        uint256 totalEpochsRequested = toEpoch - fromEpoch;
        require(totalEpochsRequested > 0, "Invalid epoch range");

        // If proving wasn't ever activated for this proof set, don't pay anything
        if (provingActivationEpoch[proofSetId] == 0) {
            return ArbitrationResult({
                modifiedAmount: 0,
                settleUpto: fromEpoch,
                note: "Proving never activated for this proof set"
            });
        }

        // Count proven epochs and find the last proven epoch
        uint256 provenEpochCount = 0;
        uint256 lastProvenEpoch = fromEpoch;

        // Check each epoch in the range
        for (uint256 epoch = fromEpoch + 1; epoch <= toEpoch; epoch++) {
            bool isProven = isEpochProven(proofSetId, epoch);

            if (isProven) {
                provenEpochCount++;
                lastProvenEpoch = epoch;
            }
        }

        // If no epochs are proven, we can't settle anything
        if (provenEpochCount == 0) {
            return ArbitrationResult({
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
        emit PaymentArbitrated(railId, proofSetId, proposedAmount, modifiedAmount, faultedEpochs);

        return ArbitrationResult({
            modifiedAmount: modifiedAmount,
            settleUpto: lastProvenEpoch, // Settle up to the last proven epoch
            note: ""
        });
    }
}
