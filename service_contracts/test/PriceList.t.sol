// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {FilecoinWarmStorageServiceTest} from "./FilecoinWarmStorageService.t.sol";
import {PriceList} from "../src/lib/PriceList.sol";
import {
    ADD_PIECES_BASE_FEE,
    ADD_PIECES_PER_PIECE_FEE,
    CACHE_MISS_EGRESS_PRICE_PER_TIB,
    CDN_EGRESS_PRICE_PER_TIB,
    CDN_LOCKUP_PERIOD,
    CREATE_DATA_SET_FEE,
    DATASET_FEE_PER_MONTH,
    DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
    DEFAULT_CDN_LOCKUP_AMOUNT,
    DEFAULT_LOCKUP_PERIOD,
    LIFECYCLE_RESERVE_TARGET,
    REPLENISH_THRESHOLD,
    SCHEDULE_PIECE_REMOVALS_FEE,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    TERMINATE_FEE
} from "../src/lib/PriceListUSDFC.sol";

/// @notice Round-trip the on-chain getPriceList() against the underlying constants.
/// @dev If this test fails, the assembler in PriceListUSDFC.sol drifted from the constants —
///      every constant should be wired through the struct exactly once.
contract PriceListTest is FilecoinWarmStorageServiceTest {
    function test_getPriceList_token() public view {
        PriceList memory list = viewContract.getPriceList();
        assertEq(address(list.token), address(mockUSDFC), "token should equal FWSS usdfcTokenAddress");
    }

    function test_getPriceList_rates() public view {
        PriceList memory list = viewContract.getPriceList();
        assertEq(list.rates.storagePerTibPerMonth, STORAGE_PRICE_PER_TIB_PER_MONTH, "storagePerTibPerMonth");
        assertEq(list.rates.datasetFeePerMonth, DATASET_FEE_PER_MONTH, "datasetFeePerMonth");
        assertEq(list.rates.cdnEgressPerTib, CDN_EGRESS_PRICE_PER_TIB, "cdnEgressPerTib");
        assertEq(list.rates.cacheMissEgressPerTib, CACHE_MISS_EGRESS_PRICE_PER_TIB, "cacheMissEgressPerTib");
    }

    function test_getPriceList_fees() public view {
        PriceList memory list = viewContract.getPriceList();
        assertEq(list.fees.createDataSetFee, CREATE_DATA_SET_FEE, "createDataSetFee");
        assertEq(list.fees.addPiecesBaseFee, ADD_PIECES_BASE_FEE, "addPiecesBaseFee");
        assertEq(list.fees.addPiecesPerPieceFee, ADD_PIECES_PER_PIECE_FEE, "addPiecesPerPieceFee");
        assertEq(list.fees.schedulePieceRemovalsFee, SCHEDULE_PIECE_REMOVALS_FEE, "schedulePieceRemovalsFee");
        assertEq(list.fees.terminateFee, TERMINATE_FEE, "terminateFee");
    }

    function test_getPriceList_lockups() public view {
        PriceList memory list = viewContract.getPriceList();
        assertEq(list.lockups.lifecycleReserveTarget, LIFECYCLE_RESERVE_TARGET, "lifecycleReserveTarget");
        assertEq(list.lockups.replenishThreshold, REPLENISH_THRESHOLD, "replenishThreshold");
        assertEq(list.lockups.defaultLockupPeriod, DEFAULT_LOCKUP_PERIOD, "defaultLockupPeriod");
        assertEq(list.lockups.cdnLockupAmount, DEFAULT_CDN_LOCKUP_AMOUNT, "cdnLockupAmount");
        assertEq(list.lockups.cacheMissLockupAmount, DEFAULT_CACHE_MISS_LOCKUP_AMOUNT, "cacheMissLockupAmount");
        assertEq(list.lockups.cdnLockupPeriod, CDN_LOCKUP_PERIOD, "cdnLockupPeriod");
    }
}
