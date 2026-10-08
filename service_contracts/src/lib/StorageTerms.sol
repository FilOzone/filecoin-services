// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

/// @notice Immutable, selectable conditions under which a dataset's storage is provided.
struct StorageTerms {
    address token;
    uint8 tokenDecimals;
    uint256 pricePerTiBPerMonth;
    bytes32 salt;
}

/// @dev Currency metadata, schema version and availability share one storage slot.
struct StorageTermsRecord {
    address token;
    uint8 tokenDecimals;
    uint8 version;
    bool enabled;
    uint256 pricePerTiBPerMonth;
    bytes32 salt;
}
