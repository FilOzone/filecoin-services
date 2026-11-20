// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

// Records registered before payVersion existed read zero, so zero is FilecoinPayV1.
uint8 constant PAY_VERSION_FILECOIN_PAY_V1 = 0;
uint8 constant PAY_VERSION_FILECOIN_PAY_V2 = 1;

struct StorageTerms {
    address token;
    uint8 tokenDecimals;
    bytes32 salt;
    uint96 pricePerTiBPerMonth;
    uint8 payVersion;
}

struct StorageTermsRecord {
    address token;
    uint8 tokenDecimals;
    uint8 version;
    bool enabled;
    uint8 payVersion;
    bytes32 salt;
    uint96 pricePerTiBPerMonth;
}
