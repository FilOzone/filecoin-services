// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FWSSOwnable} from "../lib/FWSSOwnable.sol";
import {STORAGE_PRICE_PER_TIB_PER_MONTH, TOKEN_DECIMALS} from "../lib/PriceListUSDFC.sol";
import {LibStorageTerms} from "../lib/LibStorageTerms.sol";
import {StorageTerms} from "../lib/StorageTerms.sol";

/// @notice Owns the immutable storage-terms catalogue used by newly created data sets.
contract FWSSStorageTermsModule is FWSSOwnable {
    address private immutable usdfc;

    event StorageTermsRegistered(bytes32 indexed storageTermsId, StorageTerms terms);
    event StorageTermsDisabled(bytes32 indexed storageTermsId);

    error InvalidTokenDecimals(uint8 tokenDecimals);
    error PriceBelowMinimum(uint96 pricePerTiBPerMonth, uint256 minimumPricePerTiBPerMonth);

    constructor(address _usdfc) {
        usdfc = _usdfc;
    }

    function registerStorageTerms(StorageTerms calldata terms) external onlyOwner returns (bytes32 storageTermsId) {
        _validate(terms);
        storageTermsId = LibStorageTerms.register(terms, usdfc);
        emit StorageTermsRegistered(storageTermsId, terms);
    }

    function disableStorageTerms(bytes32 storageTermsId) external onlyOwner {
        LibStorageTerms.disable(storageTermsId);
        emit StorageTermsDisabled(storageTermsId);
    }

    function getStorageTermsId(StorageTerms calldata terms) external view returns (bytes32) {
        return LibStorageTerms.getStorageTermsId(terms, usdfc);
    }

    function getStorageTerms(bytes32 storageTermsId) external view returns (StorageTerms memory terms, bool enabled) {
        return LibStorageTerms.get(storageTermsId);
    }

    function _validate(StorageTerms calldata terms) private view {
        uint8 tokenDecimals = terms.token == address(0) ? uint8(TOKEN_DECIMALS) : IERC20Metadata(terms.token).decimals();
        if (tokenDecimals != terms.tokenDecimals || tokenDecimals > TOKEN_DECIMALS) {
            revert InvalidTokenDecimals(terms.tokenDecimals);
        }
        uint256 minimumPrice =
            (STORAGE_PRICE_PER_TIB_PER_MONTH * 10 ** tokenDecimals + 10 ** TOKEN_DECIMALS - 1) / 10 ** TOKEN_DECIMALS;
        if (terms.pricePerTiBPerMonth < minimumPrice) {
            revert PriceBelowMinimum(terms.pricePerTiBPerMonth, minimumPrice);
        }
    }
}
