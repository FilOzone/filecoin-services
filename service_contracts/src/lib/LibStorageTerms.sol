// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {StorageTerms, StorageTermsRecord} from "./StorageTerms.sol";
import {STORAGE_PRICE_PER_TIB_PER_MONTH, TOKEN_DECIMALS} from "./PriceListUSDFC.sol";

library LibStorageTerms {
    bytes32 internal constant STORAGE_LOCATION = 0xffe2107a587f9a58b0aaa87110a43c1dc6de9e3d39b63f9be37b80538b60ff00;
    bytes32 internal constant STORAGE_TERMS_TYPEHASH = keccak256("filecoin.FWSS.StorageTerms.v1");

    /// @custom:storage-location erc7201:filecoin.FWSS.StorageTerms
    struct Storage {
        mapping(bytes32 id => StorageTermsRecord) records;
    }

    error UnknownStorageTerms(bytes32 id);

    function initialize(address usdfc) internal {
        StorageTermsRecord storage record = _storage().records[bytes32(0)];
        if (record.version != 0) return;

        record.token = usdfc;
        record.tokenDecimals = uint8(TOKEN_DECIMALS);
        record.version = 1;
        record.enabled = true;
        record.pricePerTiBPerMonth = uint96(STORAGE_PRICE_PER_TIB_PER_MONTH);
    }

    function getStorageTermsId(StorageTerms calldata terms, address usdfc) internal pure returns (bytes32) {
        if (
            terms.token == usdfc && terms.tokenDecimals == TOKEN_DECIMALS && terms.salt == bytes32(0)
                && terms.pricePerTiBPerMonth == STORAGE_PRICE_PER_TIB_PER_MONTH
        ) return bytes32(0);
        return keccak256(
            abi.encode(
                STORAGE_TERMS_TYPEHASH, terms.token, terms.tokenDecimals, terms.salt, uint96(terms.pricePerTiBPerMonth)
            )
        );
    }

    function get(bytes32 id) internal view returns (StorageTerms memory terms, bool enabled) {
        StorageTermsRecord storage record = getRecord(id);
        terms = StorageTerms({
            token: record.token,
            tokenDecimals: record.tokenDecimals,
            salt: record.salt,
            pricePerTiBPerMonth: record.pricePerTiBPerMonth
        });
        enabled = record.enabled;
    }

    function getRecord(bytes32 id) internal view returns (StorageTermsRecord storage record) {
        record = _storage().records[id];
        if (record.version == 0) revert UnknownStorageTerms(id);
    }

    function register(StorageTerms calldata terms, address usdfc) internal returns (bytes32 id) {
        id = getStorageTermsId(terms, usdfc);
        StorageTermsRecord storage record = _storage().records[id];
        if (record.version == 0) {
            record.token = terms.token;
            record.tokenDecimals = terms.tokenDecimals;
            record.version = 1;
            record.salt = terms.salt;
            record.pricePerTiBPerMonth = terms.pricePerTiBPerMonth;
        }
        record.enabled = true;
    }

    function disable(bytes32 id) internal {
        StorageTermsRecord storage record = getRecord(id);
        record.enabled = false;
    }

    function _storage() private pure returns (Storage storage $) {
        assembly ("memory-safe") {
            $.slot := STORAGE_LOCATION
        }
    }
}
