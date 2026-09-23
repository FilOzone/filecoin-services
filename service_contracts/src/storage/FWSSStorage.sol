// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

/// @dev Legacy slots 0-23. Preserve field order, types and packing in every inheriting module.
abstract contract FWSSStorage {
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

    struct PlannedUpgrade {
        // Address of the new implementation contract
        address nextImplementation;
        // Upgrade will not occur until at least this epoch
        uint96 afterEpoch;
    }

    // =========================================================================
    // Storage variables
    //
    // Each one of these variables is stored in its own storage slot and
    // corresponds to the layout defined in
    // FilecoinWarmStorageServiceLayout.sol.
    // Storage layout should never change to ensure upgradability!

    // Proving period constants - set during initialization
    uint64 internal maxProvingPeriod;
    uint256 internal challengeWindowSize;

    // Commission rate
    uint256 internal deprecatedServiceCommissionBps;

    // Track which proving periods have valid proofs with bitmap
    mapping(uint256 dataSetId => mapping(uint256 periodId => uint256)) internal provenPeriods;
    // Track when proving was first activated for each data set
    mapping(uint256 dataSetId => uint256) internal provingActivationEpoch;

    mapping(uint256 dataSetId => uint256) internal provingDeadlines;
    mapping(uint256 dataSetId => bool) internal provenThisPeriod;

    mapping(uint256 dataSetId => DataSetInfo) internal dataSetInfo;

    // Replay protection: tracks used nonces for both CreateDataSet and AddPieces operations.
    // Stores packed data: upper 128 bits = cumulative piece count after AddPieces or 0 for CreateDataSet,
    // lower 128 bits = dataSetId. For AddPieces, stores (firstAdded + pieceData.length) which is the
    // next piece ID that would be assigned, providing historical data about dataset state after the operation.
    mapping(address payer => mapping(uint256 nonce => uint256)) internal clientNonces;

    mapping(address payer => uint256[]) internal clientDataSets;
    mapping(uint256 pdpRailId => uint256) internal railToDataSet;

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
    address internal filBeamControllerAddress;

    // Pending upgrade announcement
    PlannedUpgrade internal nextUpgrade;

    // Pricing rates (mutable for future adjustments)
    uint256 internal deprecatedStoragePricePerTibPerMonth;
    uint256 internal deprecatedMinimumStorageRatePerMonth;

    // Piece IDs awaiting metadata cleanup; cleared each nextProvingPeriod call
    mapping(uint256 dataSetId => uint256[] pieceIds) internal scheduledPieceMetadataRemovals;

    // Optional per-data-set authorizer (address(0) = default payer/session-key behavior).
    mapping(uint256 dataSetId => address authorizer) internal dataSetAuthorizer;
}
