// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {StorageTermsRecord} from "../lib/StorageTerms.sol";

/// @dev Shared catalogue storage for FWSS and its future dispatcher modules.
abstract contract FWSSStorageTerms {
    /// @custom:storage-location erc7201:filecoin.FWSS.StorageTerms
    struct StorageTermsStorage {
        mapping(bytes32 storageTermsId => StorageTermsRecord) storageTerms;
    }

    // keccak256(abi.encode(uint256(keccak256("filecoin.FWSS.StorageTerms")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_TERMS_STORAGE_LOCATION =
        0xffe2107a587f9a58b0aaa87110a43c1dc6de9e3d39b63f9be37b80538b60ff00;

    function _getStorageTermsStorage() internal pure returns (StorageTermsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := STORAGE_TERMS_STORAGE_LOCATION
        }
    }
}
