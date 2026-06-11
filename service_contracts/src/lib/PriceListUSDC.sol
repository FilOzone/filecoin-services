// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    EPOCHS_PER_MONTH,
    CDN_LOCKUP_PERIOD,
    DEFAULT_LOCKUP_PERIOD,
    PriceList,
    PriceListFees,
    PriceListLockups,
    PriceListRates
} from "./PriceList.sol";

// Price list for USDC-denominated (bridged axlUSDC) data sets.
//
// Three deliberate differences from the USDFC list:
//
// 1. Storage price base. USDC storage is priced from a $5.00/TiB/month base — double the USDFC
//    list's $2.50 — so providers net $5 per TiB-month on USDC rails. Every other amount keeps
//    the USDFC-equivalent base.
//
// 2. Gross-up. USDC rails carry a network value-accrual fee (NVAF) as the rail's operator
//    commission, routed to the ValueAccrualRouter and burned. All SP-bound amounts below are
//    grossed up by 1/(1 - 2%) — rounded up — so the SP nets the base amount after the
//    commission; the customer bears the NVAF as a posted-price difference. (The 0.5% Filecoin
//    Pay network fee applies identically on both tokens, so it does not enter the gross-up.)
//
// 3. Quantization floor. USDC has 6 decimals, and rails pay per epoch: any monthly amount below
//    EPOCHS_PER_MONTH units ($0.0864) streams as zero. The per-dataset fee is therefore set at
//    exactly 1 unit per epoch ($0.0864/month) — the smallest non-zero rate — rather than the
//    USDFC list's $0.024/month. Size-proportional storage rates for very small data sets still
//    truncate toward zero; the dataset fee floor keeps every active data set paying a non-zero
//    stream.

uint256 constant USDC_TOKEN_DECIMALS = 6;

// axlUSDC has 6 decimals, so $1 = 10**6
uint256 constant USDC_STORAGE_PRICE_PER_TIB_PER_MONTH = 5_102_041; // 5.00 / 0.98, ceil
uint256 constant USDC_DATASET_FEE_PER_MONTH = EPOCHS_PER_MONTH; // 1 unit/epoch quantization floor
uint256 constant USDC_DATASET_FEE_PER_EPOCH = USDC_DATASET_FEE_PER_MONTH / EPOCHS_PER_MONTH;

uint256 constant USDC_CDN_EGRESS_PRICE_PER_TIB = 7_142_858; // 7 / 0.98 per TiB, ceil
uint256 constant USDC_CACHE_MISS_EGRESS_PRICE_PER_TIB = 7_142_858; // 7 / 0.98 per TiB, ceil

uint256 constant USDC_DEFAULT_CDN_LOCKUP_AMOUNT = 714_286; // 0.7 / 0.98, ceil
uint256 constant USDC_DEFAULT_CACHE_MISS_LOCKUP_AMOUNT = 306_123; // 0.3 / 0.98, ceil

// Default NVAF carried as operator commission on USDC rails; owner-adjustable up to the cap.
// The cap deliberately equals the gross-up (200 bps) so the SP-parity guarantee holds for every
// permitted setting: any commission at or below the cap leaves the SP netting at least the
// list's base amounts. Raising the NVAF beyond 2% requires a contract upgrade that also revises
// the grossed-up prices — keeping the two coupled by construction.
uint256 constant USDC_SERVICE_COMMISSION_BPS = 200;
uint256 constant MAX_USDC_SERVICE_COMMISSION_BPS = 200;

// Operation fees (one-time, paid from the lifecycle reserve on the PDP rail), grossed up
uint256 constant USDC_CREATE_DATA_SET_FEE = 25_511; // $0.025 / 0.98 per dataset created
uint256 constant USDC_ADD_PIECES_BASE_FEE = 511; // $0.0005 / 0.98 base per addPieces call
uint256 constant USDC_ADD_PIECES_PER_PIECE_FEE = 307; // $0.0003 / 0.98 per piece added
uint256 constant USDC_SCHEDULE_PIECE_REMOVALS_FEE = 2_041; // $0.002 / 0.98 per schedulePieceRemovals call
uint256 constant USDC_TERMINATE_FEE = 1_143; // $0.00112 / 0.98 per user-initiated termination

// Lifecycle reserve: payer-side buffer, not SP revenue — no gross-up
uint256 constant USDC_LIFECYCLE_RESERVE_TARGET = 100_000; // $0.10
uint256 constant USDC_REPLENISH_THRESHOLD = 5_000; // $0.005

/**
 * @notice Assemble the full PriceList from the USDC constants.
 * @dev `token` returns as the zero address; the caller populates it with the deployment's
 *      USDC instance address (FWSS holds it as an immutable).
 */
function priceListUSDC() pure returns (PriceList memory) {
    return PriceList({
        token: IERC20(address(0)),
        rates: PriceListRates({
            storagePerTibPerMonth: USDC_STORAGE_PRICE_PER_TIB_PER_MONTH,
            datasetFeePerMonth: USDC_DATASET_FEE_PER_MONTH,
            cdnEgressPerTib: USDC_CDN_EGRESS_PRICE_PER_TIB,
            cacheMissEgressPerTib: USDC_CACHE_MISS_EGRESS_PRICE_PER_TIB
        }),
        fees: PriceListFees({
            createDataSetFee: USDC_CREATE_DATA_SET_FEE,
            addPiecesBaseFee: USDC_ADD_PIECES_BASE_FEE,
            addPiecesPerPieceFee: USDC_ADD_PIECES_PER_PIECE_FEE,
            schedulePieceRemovalsFee: USDC_SCHEDULE_PIECE_REMOVALS_FEE,
            terminateFee: USDC_TERMINATE_FEE
        }),
        lockups: PriceListLockups({
            lifecycleReserveTarget: USDC_LIFECYCLE_RESERVE_TARGET,
            replenishThreshold: USDC_REPLENISH_THRESHOLD,
            defaultLockupPeriod: DEFAULT_LOCKUP_PERIOD,
            cdnLockupAmount: USDC_DEFAULT_CDN_LOCKUP_AMOUNT,
            cacheMissLockupAmount: USDC_DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
            cdnLockupPeriod: CDN_LOCKUP_PERIOD
        })
    });
}
