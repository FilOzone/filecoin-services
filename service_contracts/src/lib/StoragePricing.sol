// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Cids} from "@pdp/Cids.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DATASET_FEE_PER_EPOCH, EPOCHS_PER_MONTH, TIB_IN_BYTES} from "./PriceListUSDFC.sol";
import {StorageTerms} from "./StorageTerms.sol";

library StoragePricing {
    function scaleAmount(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return amount / 10 ** (18 - decimals);
    }

    function calculateStorageRate(uint256 leafCount, StorageTerms memory terms) internal pure returns (uint256) {
        if (leafCount == 0) return 0;

        uint256 totalBytes = Cids.leafCountToRawSize(leafCount);
        return Math.mulDiv(totalBytes, terms.pricePerTiBPerMonth, TIB_IN_BYTES * EPOCHS_PER_MONTH)
            + scaleAmount(DATASET_FEE_PER_EPOCH, terms.tokenDecimals);
    }
}
