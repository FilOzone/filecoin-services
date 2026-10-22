// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

struct StorageTerms {
    address token;
    uint8 tokenDecimals;
    bytes32 salt;
    uint96 pricePerTiBPerMonth;
}

struct StorageTermsRecord {
    address token;
    uint8 tokenDecimals;
    uint8 version;
    bool enabled;
    bytes32 salt;
    uint96 pricePerTiBPerMonth;
}
