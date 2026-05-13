// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Cids} from "@pdp/Cids.sol";

uint256 constant MIB_IN_BYTES = 1024 * 1024; // 1 MiB in bytes
uint256 constant GIB_IN_BYTES = MIB_IN_BYTES * 1024; // 1 GiB in bytes
uint256 constant TIB_IN_BYTES = GIB_IN_BYTES * 1024; // 1 TiB in bytes

uint256 constant TOKEN_DECIMALS = 18;
uint256 constant DEFAULT_LOCKUP_PERIOD = 2880 * 30; // 1 month (30 days) in epochs
uint256 constant EPOCHS_PER_MONTH = 2880 * 30;

// USDFC has 18 decimals, so $1 = 10**18 (a.k.a. ether)
uint256 constant SYBIL_FEE = 0.1 ether;
uint256 constant STORAGE_PRICE_PER_TIB_PER_MONTH = (5 * 10 ** TOKEN_DECIMALS) / 2; // 2.5 USDFC
uint256 constant MINIMUM_STORAGE_RATE_PER_MONTH = (6 * 10 ** TOKEN_DECIMALS) / 100; // 0.06 USDFC
uint256 constant MINIMUM_STORAGE_RATE_PER_EPOCH = MINIMUM_STORAGE_RATE_PER_MONTH / EPOCHS_PER_MONTH;

/**
 * @notice Calculate a per-epoch rate based on total storage size
 * @param totalBytes Total size of the stored data in bytes
 * @return ratePerEpoch The calculated rate per epoch in the token's smallest unit
 */
function calculateStorageSizeBasedRatePerEpoch(uint256 totalBytes) pure returns (uint256 ratePerEpoch) {
    uint256 numerator = totalBytes * STORAGE_PRICE_PER_TIB_PER_MONTH;
    uint256 denominator = TIB_IN_BYTES * EPOCHS_PER_MONTH;

    ratePerEpoch = numerator / denominator;

    // Return whichever is higher: natural rate or minimum rate
    return ratePerEpoch > MINIMUM_STORAGE_RATE_PER_EPOCH ? ratePerEpoch : MINIMUM_STORAGE_RATE_PER_EPOCH;
}

/**
 * @notice Calculate the storage rate per epoch (internal use)
 * @dev Implements minimum pricing floor and returns the higher of the natural size-based rate or the minimum rate.
 * @param leafCount the count of the 32b leaves in the FRC-0069 tree
 * @return storageRatePerEpoch The storage rate per epoch
 */
function calculateStorageRate(uint256 leafCount) pure returns (uint256 storageRatePerEpoch) {
    return calculateStorageSizeBasedRatePerEpoch(Cids.leafCountToRawSize(leafCount));
}
