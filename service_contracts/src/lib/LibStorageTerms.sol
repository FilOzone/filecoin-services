// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {PAY_VERSION_FILECOIN_PAY_V1, StorageTerms, StorageTermsRecord} from "./StorageTerms.sol";
import {STORAGE_PRICE_PER_TIB_PER_MONTH, TOKEN_DECIMALS} from "./PriceListUSDFC.sol";

library LibStorageTerms {
    // ERC-7201 namespace: filecoin.FWSS.StorageTerms
    // keccak256(abi.encode(uint256(keccak256("filecoin.FWSS.StorageTerms")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0xffe2107a587f9a58b0aaa87110a43c1dc6de9e3d39b63f9be37b80538b60ff00;
    bytes32 internal constant STORAGE_TERMS_TYPEHASH = keccak256("filecoin.FWSS.StorageTerms.v1");
    bytes32 internal constant STORAGE_TERMS_WITH_PAY_VERSION_TYPEHASH = keccak256("filecoin.FWSS.StorageTerms.v2");

    /// @custom:storage-location erc7201:filecoin.FWSS.StorageTerms
    struct Storage {
        mapping(bytes32 id => StorageTermsRecord) records;
    }

    error UnknownStorageTerms(bytes32 id);
    error CannotDisableLegacyStorageTerms();

    function initialize(address usdfc) internal {
        StorageTermsRecord storage record = _storage().records[bytes32(0)];
        if (record.version != 0) return;

        record.token = usdfc;
        record.tokenDecimals = uint8(TOKEN_DECIMALS);
        record.version = 1;
        record.enabled = true;
        record.pricePerTiBPerMonth = uint96(STORAGE_PRICE_PER_TIB_PER_MONTH);
    }

    function getStorageTermsId(StorageTerms calldata terms) internal pure returns (bytes32 id) {
        // FilecoinPayV1 terms keep the five-word hash they had before payVersion existed, so their ids do not move.
        bool withPayVersion = terms.payVersion != PAY_VERSION_FILECOIN_PAY_V1;
        bytes32 typeHash = withPayVersion ? STORAGE_TERMS_WITH_PAY_VERSION_TYPEHASH : STORAGE_TERMS_TYPEHASH;
        // Hash the ABI words without allocating an encoded bytes array.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), and(calldataload(terms), 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(ptr, 0x40), and(calldataload(add(terms, 0x20)), 0xff))
            mstore(add(ptr, 0x60), calldataload(add(terms, 0x40)))
            mstore(add(ptr, 0x80), and(calldataload(add(terms, 0x60)), 0xffffffffffffffffffffffff))
            mstore(add(ptr, 0xa0), and(calldataload(add(terms, 0x80)), 0xff))
            id := keccak256(ptr, add(0xa0, mul(withPayVersion, 0x20)))
        }
    }

    function get(bytes32 id) internal view returns (StorageTerms memory terms, bool enabled) {
        StorageTermsRecord storage record = getRecord(id);
        terms = StorageTerms({
            token: record.token,
            tokenDecimals: record.tokenDecimals,
            salt: record.salt,
            pricePerTiBPerMonth: record.pricePerTiBPerMonth,
            payVersion: record.payVersion
        });
        enabled = record.enabled;
    }

    function getRecord(bytes32 id) internal view returns (StorageTermsRecord storage record) {
        record = _storage().records[id];
        if (record.version == 0) revert UnknownStorageTerms(id);
    }

    function register(StorageTerms calldata terms) internal returns (bytes32 id) {
        id = getStorageTermsId(terms);
        StorageTermsRecord storage record = _storage().records[id];
        if (record.version == 0) {
            record.token = terms.token;
            record.tokenDecimals = terms.tokenDecimals;
            record.version = 1;
            record.salt = terms.salt;
            record.pricePerTiBPerMonth = terms.pricePerTiBPerMonth;
            record.payVersion = terms.payVersion;
        }
        record.enabled = true;
    }

    function disable(bytes32 id) internal {
        // A future upgrade migration can disable record zero by writing its enabled flag directly.
        if (id == bytes32(0)) revert CannotDisableLegacyStorageTerms();
        StorageTermsRecord storage record = getRecord(id);
        record.enabled = false;
    }

    function _storage() private pure returns (Storage storage $) {
        assembly ("memory-safe") {
            $.slot := STORAGE_LOCATION
        }
    }
}
