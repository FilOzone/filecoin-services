// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {
    DATASET_FEE_PER_MONTH,
    EPOCHS_PER_MONTH,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    TIB_IN_BYTES
} from "../../src/lib/PriceListUSDFC.sol";

function _combinedMonthlyStorageRate(uint256 totalBytes) pure returns (uint256) {
    uint256 monthlyStorage = (totalBytes * STORAGE_PRICE_PER_TIB_PER_MONTH) / TIB_IN_BYTES;
    return (monthlyStorage + DATASET_FEE_PER_MONTH) / EPOCHS_PER_MONTH;
}
