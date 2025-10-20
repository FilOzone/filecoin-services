// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

/// @notice Bloom Filter with fixed params:
/// @notice k = 16 bits per item
/// @notice m = 256 bits per set
/// @dev probability of false positives by number of items: (via https://hur.st/bloomfilter/?m=256&k=32)
/// @dev  7: 0.000000062
/// @dev  8: 0.00000033
/// @dev  9: 0.000001377
/// @dev 10: 0.000004735
/// @dev 11: 0.000013933
/// @dev 12: 0.000036084
/// @dev 13: 0.000084014
/// @dev 14: 0.000178789
/// @dev 15: 0.000352341
library BloomSet16 {
    function compressed(string memory uncompressed) internal pure returns (uint256 item) {
        uint256 hash;
        assembly ("memory-safe") {
            hash := keccak256(add(32, uncompressed), mload(uncompressed))
            item := 0
        }
        for (uint256 i = 0; i < 16; i++) {
            item |= 1 << (hash & 0xff);
            hash >>= 16;
        }
    }

    /// @notice Checks if set probably contains the items
    /// @return false when the set is definitely missing at least one of the items
    function mayContain(uint256 set, uint256 items) internal pure returns (bool) {
        return set & items == items;
    }
}
