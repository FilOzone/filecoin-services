// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Cids} from "@pdp/Cids.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DATASET_FEE_PER_EPOCH, EPOCHS_PER_MONTH, TIB_IN_BYTES} from "./PriceListUSDFC.sol";

/// @title StoragePricing
/// @notice Storage rates and fees in the units of a data set's storage terms token.
/// @dev The fee and lockup constants in PriceListUSDFC carry 18 decimals. Terms in a token with fewer decimals
///      receive them truncated toward zero.
library StoragePricing {
    /// @notice Converts an 18-decimal amount to `tokenDecimals` units, truncating.
    /// @param amount The amount with 18 decimals
    /// @param tokenDecimals The decimals of the target token, at most 18
    function scaleAmount(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        return amount / 10 ** (18 - tokenDecimals);
    }

    /// @notice The per-epoch storage rate of a data set: the size-proportional price plus the per-dataset fee.
    /// @dev For the legacy terms (18 decimals, 2.5e18) this equals PriceListUSDFC's calculateStorageRate.
    /// @param leafCount The count of the 32-byte leaves in the FRC-0069 tree
    /// @param tokenDecimals The decimals of the terms token
    /// @param pricePerTiBPerMonth The terms' storage price in token units
    function calculateStorageRate(uint256 leafCount, uint8 tokenDecimals, uint96 pricePerTiBPerMonth)
        internal
        pure
        returns (uint256)
    {
        if (leafCount == 0) return 0;
        return Math.mulDiv(Cids.leafCountToRawSize(leafCount), pricePerTiBPerMonth, TIB_IN_BYTES * EPOCHS_PER_MONTH)
            + scaleAmount(DATASET_FEE_PER_EPOCH, tokenDecimals);
    }
}
