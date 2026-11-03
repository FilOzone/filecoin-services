// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {StoragePricing} from "../src/lib/StoragePricing.sol";
import {LibStorageTerms} from "../src/lib/LibStorageTerms.sol";
import {STORAGE_PRICE_PER_TIB_PER_MONTH} from "../src/lib/PriceListUSDFC.sol";

contract StoragePricingTest is Test {
    bytes32 private constant STORAGE_TERMS_LOCATION =
        0xffe2107a587f9a58b0aaa87110a43c1dc6de9e3d39b63f9be37b80538b60ff00;

    function test_zeroAndHashedEquivalentTermsCombineMonthlyChargesBeforeEpochFloor() public {
        address token = address(0xBEEF);
        LibStorageTerms.initialize(token);

        bytes32 termsId = keccak256(
            abi.encode(
                keccak256("filecoin.FWSS.StorageTerms.v1"),
                token,
                uint8(18),
                bytes32(0),
                STORAGE_PRICE_PER_TIB_PER_MONTH
            )
        );
        bytes32 recordSlot = keccak256(abi.encode(termsId, STORAGE_TERMS_LOCATION));
        uint256 flags = uint256(uint160(token)) | (uint256(18) << 160) | (uint256(1) << 168) | (uint256(1) << 176);
        vm.store(address(this), recordSlot, bytes32(flags));
        vm.store(address(this), bytes32(uint256(recordSlot) + 1), bytes32(0));
        vm.store(address(this), bytes32(uint256(recordSlot) + 2), bytes32(STORAGE_PRICE_PER_TIB_PER_MONTH));

        // 1 << 35 leaves represent 127/128 TiB of raw data after Fr32 expansion is removed.
        uint256 oneTiBPaddedLeafCount = 1 << 35;
        assertEq(StoragePricing.calculateStorageRate(oneTiBPaddedLeafCount, bytes32(0)), 30_098_017_939_814);
        assertEq(StoragePricing.calculateStorageRate(oneTiBPaddedLeafCount, termsId), 30_098_017_939_814);
    }

    function test_sixDecimalTermsCombineMonthlyChargesBeforeEpochFloor() public {
        bytes32 termsId = keccak256("six-decimal");
        bytes32 recordSlot = keccak256(abi.encode(termsId, STORAGE_TERMS_LOCATION));
        uint256 flags =
            uint256(uint160(address(0xBEEF))) | (uint256(6) << 160) | (uint256(1) << 168) | (uint256(1) << 176);
        vm.store(address(this), recordSlot, bytes32(flags));
        vm.store(address(this), bytes32(uint256(recordSlot) + 1), bytes32(0));
        vm.store(address(this), bytes32(uint256(recordSlot) + 2), bytes32(uint256(2_500_000)));

        assertEq(StoragePricing.calculateStorageRate(1 << 35, termsId), 30);
    }

    function test_zeroLeavesHaveNoRate() public view {
        assertEq(StoragePricing.calculateStorageRate(0, bytes32(0)), 0);
    }
}
