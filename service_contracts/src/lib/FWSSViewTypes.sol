// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

/// @dev Data set information returned by the FWSS view getters.
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
