// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Cids} from "@pdp/Cids.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibStorageTerms} from "./LibStorageTerms.sol";
import {StorageTermsRecord} from "./StorageTerms.sol";
import {
    calculateStorageRate as legacyStorageRate,
    DATASET_FEE_PER_MONTH,
    EPOCHS_PER_MONTH,
    TIB_IN_BYTES
} from "./PriceListUSDFC.sol";

/// @notice Prices storage and lifecycle charges in the selected token's smallest unit.
library StoragePricing {
    /// @notice Converts an amount denominated at 18 decimals to the token's precision.
    function scaleAmount(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return amount / (10 ** (18 - decimals));
    }

    function calculateStorageRate(uint256 leafCount, bytes32 storageTermsId) internal view returns (uint256) {
        if (leafCount == 0) return 0;
        // Keep the original separate flooring operations for legacy data sets.
        if (storageTermsId == bytes32(0)) return legacyStorageRate(leafCount);
        StorageTermsRecord storage terms = LibStorageTerms.getRecord(storageTermsId);
        uint256 monthlyStorage =
            Math.mulDiv(Cids.leafCountToRawSize(leafCount), terms.pricePerTiBPerMonth, TIB_IN_BYTES);
        return (monthlyStorage + scaleAmount(DATASET_FEE_PER_MONTH, terms.tokenDecimals)) / EPOCHS_PER_MONTH;
    }
}
