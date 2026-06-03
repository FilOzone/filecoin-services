// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
