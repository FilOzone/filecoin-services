// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Cids} from "@pdp/Cids.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    CDN_LOCKUP_PERIOD,
    DEFAULT_LOCKUP_PERIOD,
    EPOCHS_PER_MONTH,
    PriceList,
    PriceListFees,
    PriceListLockups,
    PriceListRates,
    TIB_IN_BYTES
} from "./PriceList.sol";

uint256 constant TOKEN_DECIMALS = 18;

// USDFC has 18 decimals, so $1 = 10**18 (a.k.a. ether)
uint256 constant STORAGE_PRICE_PER_TIB_PER_MONTH = (5 * 10 ** TOKEN_DECIMALS) / 2; // 2.5 USDFC
uint256 constant DATASET_FEE_PER_MONTH = (24 * 10 ** TOKEN_DECIMALS) / 1000; // 0.024 USDFC
uint256 constant DATASET_FEE_PER_EPOCH = DATASET_FEE_PER_MONTH / EPOCHS_PER_MONTH;

uint256 constant CDN_EGRESS_PRICE_PER_TIB = 7 * 10 ** TOKEN_DECIMALS; // 7 USDFC per TiB
uint256 constant CACHE_MISS_EGRESS_PRICE_PER_TIB = 7 * 10 ** TOKEN_DECIMALS; // 7 USDFC per TiB

uint256 constant DEFAULT_CDN_LOCKUP_AMOUNT = (7 * 10 ** TOKEN_DECIMALS) / 10; // 0.7 USDFC
uint256 constant DEFAULT_CACHE_MISS_LOCKUP_AMOUNT = (3 * 10 ** TOKEN_DECIMALS) / 10; // 0.3 USDFC

uint256 constant SERVICE_COMMISSION_BPS = 0;

// Operation fees (one-time, paid from the lifecycle reserve on the PDP rail)
uint256 constant CREATE_DATA_SET_FEE = (25 * 10 ** TOKEN_DECIMALS) / 1000; // $0.025 per dataset created
uint256 constant ADD_PIECES_BASE_FEE = (5 * 10 ** TOKEN_DECIMALS) / 10000; // $0.0005 base per addPieces call
uint256 constant ADD_PIECES_PER_PIECE_FEE = (3 * 10 ** TOKEN_DECIMALS) / 10000; // $0.0003 per piece added
uint256 constant SCHEDULE_PIECE_REMOVALS_FEE = (2 * 10 ** TOKEN_DECIMALS) / 1000; // $0.002 per schedulePieceRemovals call
uint256 constant TERMINATE_FEE = (112 * 10 ** TOKEN_DECIMALS) / 100000; // $0.00112 per user-initiated termination

// Lifecycle reserve: fixed lockup on the PDP rail covering per-op fees during wind-down
uint256 constant LIFECYCLE_RESERVE_TARGET = (10 * 10 ** TOKEN_DECIMALS) / 100; // $0.10
// Replenish when reserve drops below this; ~25 ops of headroom before we top up again
uint256 constant REPLENISH_THRESHOLD = (5 * 10 ** TOKEN_DECIMALS) / 1000; // $0.005

/**
 * @notice Calculate a per-epoch rate based on total storage size
 * @dev Adds a fixed per-dataset fee to the size-proportional rate.
 * @param totalBytes Total size of the stored data in bytes
 * @return ratePerEpoch The calculated rate per epoch in the token's smallest unit
 */
function calculateStorageSizeBasedRatePerEpoch(uint256 totalBytes) pure returns (uint256 ratePerEpoch) {
    uint256 numerator = totalBytes * STORAGE_PRICE_PER_TIB_PER_MONTH;
    uint256 denominator = TIB_IN_BYTES * EPOCHS_PER_MONTH;

    return numerator / denominator + DATASET_FEE_PER_EPOCH;
}

/**
 * @notice Calculate the storage rate per epoch (internal use)
 * @param leafCount the count of the 32b leaves in the FRC-0069 tree
 * @return storageRatePerEpoch The storage rate per epoch
 */
function calculateStorageRate(uint256 leafCount) pure returns (uint256 storageRatePerEpoch) {
    if (leafCount == 0) return 0;
    return calculateStorageSizeBasedRatePerEpoch(Cids.leafCountToRawSize(leafCount));
}

/**
 * @notice Assemble the full PriceList from the USDFC constants.
 * @dev `token` returns as the zero address; the caller populates it with the deployment's
 *      USDFC instance address (FWSS holds it as an immutable).
 */
function priceList() pure returns (PriceList memory) {
    return PriceList({
        token: IERC20(address(0)),
        rates: PriceListRates({
            storagePerTibPerMonth: STORAGE_PRICE_PER_TIB_PER_MONTH,
            datasetFeePerMonth: DATASET_FEE_PER_MONTH,
            cdnEgressPerTib: CDN_EGRESS_PRICE_PER_TIB,
            cacheMissEgressPerTib: CACHE_MISS_EGRESS_PRICE_PER_TIB
        }),
        fees: PriceListFees({
            createDataSetFee: CREATE_DATA_SET_FEE,
            addPiecesBaseFee: ADD_PIECES_BASE_FEE,
            addPiecesPerPieceFee: ADD_PIECES_PER_PIECE_FEE,
            schedulePieceRemovalsFee: SCHEDULE_PIECE_REMOVALS_FEE,
            terminateFee: TERMINATE_FEE
        }),
        lockups: PriceListLockups({
            lifecycleReserveTarget: LIFECYCLE_RESERVE_TARGET,
            replenishThreshold: REPLENISH_THRESHOLD,
            defaultLockupPeriod: DEFAULT_LOCKUP_PERIOD,
            cdnLockupAmount: DEFAULT_CDN_LOCKUP_AMOUNT,
            cacheMissLockupAmount: DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
            cdnLockupPeriod: CDN_LOCKUP_PERIOD
        })
    });
}
