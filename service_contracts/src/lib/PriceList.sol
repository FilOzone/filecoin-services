// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Cids} from "@pdp/Cids.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Token-independent size and time constants shared by every per-token price list.
uint256 constant MIB_IN_BYTES = 1024 * 1024; // 1 MiB in bytes
uint256 constant GIB_IN_BYTES = MIB_IN_BYTES * 1024; // 1 GiB in bytes
uint256 constant TIB_IN_BYTES = GIB_IN_BYTES * 1024; // 1 TiB in bytes

uint256 constant EPOCHS_PER_DAY = 2880;
uint256 constant EPOCHS_PER_MONTH = EPOCHS_PER_DAY * 30;
uint256 constant DEFAULT_LOCKUP_PERIOD = EPOCHS_PER_DAY * 30;
uint256 constant CDN_LOCKUP_PERIOD = EPOCHS_PER_DAY * 5; // shorter settle window for FilBeam

/// @notice Comprehensive price catalogue for an FWSS deployment. Returned by
///         `FilecoinWarmStorageServiceStateView.getPriceList()`. All amounts are denominated in
///         `token`'s smallest unit; rates are per-month (per-epoch values derived by dividing
///         by `EPOCHS_PER_MONTH = 86400`).
struct PriceList {
    IERC20 token;
    PriceListRates rates;
    PriceListFees fees;
    PriceListLockups lockups;
}

/// @notice Streaming rates. Storage and dataset fee accrue per epoch on the PDP rail when the
///         dataset is non-empty (zero leaves yield a zero rate). CDN and cache-miss egress are
///         usage-settled by FilBeam, not streamed.
struct PriceListRates {
    uint256 storagePerTibPerMonth;
    uint256 datasetFeePerMonth;
    uint256 cdnEgressPerTib;
    uint256 cacheMissEgressPerTib;
}

/// @notice One-time fees paid to the SP out of the lifecycle reserve. The add-pieces fee for an
///         n-piece batch is `addPiecesBaseFee + n * addPiecesPerPieceFee`. The terminate fee fires
///         only in the consent case (SP-initiated termination with a valid payer EIP-712 signature).
struct PriceListFees {
    uint256 createDataSetFee;
    uint256 addPiecesBaseFee;
    uint256 addPiecesPerPieceFee;
    uint256 schedulePieceRemovalsFee;
    uint256 terminateFee;
}

/// @notice Fixed-lockup amounts and lockup periods. The lifecycle reserve sits on the PDP rail and
///         is drawn down by fees; the replenish threshold triggers a top-up back to the target.
///         CDN and cache-miss lockups sit on their respective rails with a shorter settle window.
struct PriceListLockups {
    uint256 lifecycleReserveTarget;
    uint256 replenishThreshold;
    uint256 defaultLockupPeriod;
    uint256 cdnLockupAmount;
    uint256 cacheMissLockupAmount;
    uint256 cdnLockupPeriod;
}

/**
 * @notice Calculate a per-epoch rate from a price list based on total storage size
 * @dev Adds the per-dataset fee to the size-proportional rate. Token-generic equivalent of
 *      `PriceListUSDFC.calculateStorageSizeBasedRatePerEpoch`; for the USDFC price list the two
 *      produce identical results.
 * @param pl The price list whose rates apply (denominated in pl.token's smallest unit)
 * @param totalBytes Total size of the stored data in bytes
 * @return ratePerEpoch The calculated rate per epoch in the token's smallest unit
 */
function storageSizeBasedRatePerEpoch(PriceList memory pl, uint256 totalBytes) pure returns (uint256 ratePerEpoch) {
    uint256 numerator = totalBytes * pl.rates.storagePerTibPerMonth;
    uint256 denominator = TIB_IN_BYTES * EPOCHS_PER_MONTH;

    return numerator / denominator + pl.rates.datasetFeePerMonth / EPOCHS_PER_MONTH;
}

/**
 * @notice Calculate the storage rate per epoch for a leaf count (internal use)
 * @param pl The price list whose rates apply
 * @param leafCount the count of the 32b leaves in the FRC-0069 tree
 * @return storageRatePerEpoch The storage rate per epoch
 */
function storageRatePerEpoch(PriceList memory pl, uint256 leafCount) pure returns (uint256) {
    if (leafCount == 0) return 0;
    return storageSizeBasedRatePerEpoch(pl, Cids.leafCountToRawSize(leafCount));
}
