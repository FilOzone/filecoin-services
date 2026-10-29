// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {STORAGE_PRICE_PER_TIB_PER_MONTH, TOKEN_DECIMALS} from "./PriceListUSDFC.sol";

/// @notice Immutable, selectable conditions under which a data set's storage is provided.
/// @dev Fees and lockups are the 18-decimal USDFC constants, scaled to `tokenDecimals` by truncation.
struct StorageTerms {
    // Payment token for every rail of the data set; address(0) is native FIL
    address token;
    // Decimals of `token`, checked against the token at registration
    uint8 tokenDecimals;
    // Storage price per TiB per month in `token` units
    uint96 pricePerTiBPerMonth;
    // Distinguishes otherwise identical terms
    bytes32 salt;
}

/// @notice Stored form of registered StorageTerms.
/// @dev Slot 0 packs token, tokenDecimals, version and enabled; slot 1 holds the price; slot 2 the salt.
struct StorageTermsRecord {
    address token;
    uint8 tokenDecimals;
    // 0 = never registered, 1 = registered under STORAGE_TERMS_V1_DOMAIN
    uint8 version;
    bool enabled;
    uint96 pricePerTiBPerMonth;
    bytes32 salt;
}

uint8 constant STORAGE_TERMS_VERSION = 1;

/// @dev Domain separator of the V1 storage terms ID.
bytes32 constant STORAGE_TERMS_V1_DOMAIN = keccak256("filecoin.FWSS.StorageTerms.v1");

/// @notice The storage terms ID: a hash of the terms' definition, excluding availability.
function computeStorageTermsId(StorageTerms memory terms) pure returns (bytes32) {
    return keccak256(
        abi.encode(STORAGE_TERMS_V1_DOMAIN, terms.token, terms.tokenDecimals, terms.pricePerTiBPerMonth, terms.salt)
    );
}

/// @notice The code-defined terms of data sets created before storage terms or with the legacy extraData format.
/// @param usdfc The deployment's USDFC token
function legacyStorageTerms(address usdfc) pure returns (StorageTerms memory) {
    return StorageTerms({
        token: usdfc,
        tokenDecimals: uint8(TOKEN_DECIMALS),
        pricePerTiBPerMonth: uint96(STORAGE_PRICE_PER_TIB_PER_MONTH),
        salt: bytes32(0)
    });
}
