// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

/// @title StoragePricing
/// @notice Storage rates and fees in the units of a data set's storage terms token.
library StoragePricing {
    function scaleAmount(uint256, uint8) internal pure returns (uint256) {
        revert("StoragePricing: not implemented");
    }

    function calculateStorageRate(uint256, uint8, uint96) internal pure returns (uint256) {
        revert("StoragePricing: not implemented");
    }
}
