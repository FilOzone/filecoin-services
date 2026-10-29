// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {
    CREATE_DATA_SET_FEE,
    DATASET_FEE_PER_EPOCH,
    LIFECYCLE_RESERVE_TARGET,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    calculateStorageRate
} from "../src/lib/PriceListUSDFC.sol";
import {StoragePricing} from "../src/lib/StoragePricing.sol";

contract StoragePricingTest is Test {
    /// @dev The legacy terms must price every data set exactly as before storage terms.
    function testFuzzLegacyRateBitIdentical(uint256 leafCount) public pure {
        // Up to 2^50 leaves, 32 PiB of raw data in one data set
        leafCount = bound(leafCount, 0, 1 << 50);
        assertEq(
            StoragePricing.calculateStorageRate(leafCount, 18, uint96(STORAGE_PRICE_PER_TIB_PER_MONTH)),
            calculateStorageRate(leafCount)
        );
    }

    function testLegacyRateAtKnownSizes() public pure {
        uint96 price = uint96(STORAGE_PRICE_PER_TIB_PER_MONTH);
        assertEq(StoragePricing.calculateStorageRate(0, 18, price), 0);
        assertEq(StoragePricing.calculateStorageRate(1 << 35, 18, price), 30_098_017_939_813);
    }

    function testSixDecimalRate() public pure {
        assertEq(StoragePricing.calculateStorageRate(0, 6, 5e6), 0);
        // A 16-leaf piece: the size component truncates to zero, leaving the one-unit dataset fee
        assertEq(StoragePricing.calculateStorageRate(16, 6, 5e6), 1);
        assertEq(StoragePricing.calculateStorageRate(1 << 35, 6, 5e6), 58);
    }

    function testScaleAmount() public pure {
        assertEq(StoragePricing.scaleAmount(CREATE_DATA_SET_FEE, 18), CREATE_DATA_SET_FEE);
        assertEq(StoragePricing.scaleAmount(CREATE_DATA_SET_FEE, 6), 25000);
        assertEq(StoragePricing.scaleAmount(LIFECYCLE_RESERVE_TARGET, 6), 500000);
        assertEq(StoragePricing.scaleAmount(DATASET_FEE_PER_EPOCH, 6), 1);
        // Truncation: below one whole unit scales to zero
        assertEq(StoragePricing.scaleAmount(CREATE_DATA_SET_FEE, 0), 0);
        assertEq(StoragePricing.scaleAmount(LIFECYCLE_RESERVE_TARGET, 0), 0);
        assertEq(StoragePricing.scaleAmount(STORAGE_PRICE_PER_TIB_PER_MONTH, 0), 2);
    }
}
