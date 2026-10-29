// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Errors} from "../Errors.sol";
import {FWSSOwnable} from "../lib/FWSSOwnable.sol";
import {STORAGE_PRICE_PER_TIB_PER_MONTH, TOKEN_DECIMALS} from "../lib/PriceListUSDFC.sol";
import {
    STORAGE_TERMS_VERSION,
    StorageTerms,
    StorageTermsRecord,
    computeStorageTermsId,
    legacyStorageTerms
} from "../lib/StorageTerms.sol";
import {FWSSStorageTerms} from "../storage/FWSSStorageTerms.sol";

/// @title FWSSStorageTermsModule
/// @notice Registers and disables the storage terms new data sets may select.
/// @dev Terms are immutable once registered: their ID is the hash of their definition. Disabling only stops new
///      data sets from selecting them; data sets created under them keep their token and price. The legacy terms
///      are code-defined, always selectable, and cannot be disabled. Reads live in FWSSViewModule.
contract FWSSStorageTermsModule is FWSSOwnable {
    bytes32 private immutable legacyStorageTermsId;

    /// @notice Emitted on first registration and on every re-registration, which re-enables the terms.
    event StorageTermsRegistered(
        bytes32 indexed storageTermsId, address token, uint8 tokenDecimals, uint96 pricePerTiBPerMonth, bytes32 salt
    );

    /// @notice Emitted when the terms stop being selectable by new data sets.
    event StorageTermsDisabled(bytes32 indexed storageTermsId);

    /// @param _usdfc The USDFC token of the legacy storage terms.
    constructor(IERC20Metadata _usdfc) {
        require(_usdfc != IERC20Metadata(address(0)), Errors.ZeroAddress(Errors.AddressField.USDFC));
        require(TOKEN_DECIMALS == _usdfc.decimals());
        legacyStorageTermsId = computeStorageTermsId(legacyStorageTerms(address(_usdfc)));
    }

    /**
     * @notice Registers storage terms, or re-enables them when already registered.
     * @dev `token == address(0)` is native FIL with 18 decimals. Other tokens must report `tokenDecimals`.
     *      The price may not undercut the legacy price normalized to the token's decimals.
     * @param terms The storage terms to register
     * @return storageTermsId The ID new data sets use to select the terms
     */
    function registerStorageTerms(StorageTerms calldata terms) external onlyOwner returns (bytes32 storageTermsId) {
        uint8 tokenDecimals = terms.tokenDecimals;
        require(tokenDecimals <= TOKEN_DECIMALS, Errors.UnsupportedTokenDecimals(tokenDecimals));
        uint8 actualDecimals =
            terms.token == address(0) ? uint8(TOKEN_DECIMALS) : IERC20Metadata(terms.token).decimals();
        require(
            actualDecimals == tokenDecimals, Errors.TokenDecimalsMismatch(terms.token, tokenDecimals, actualDecimals)
        );

        uint256 scale = 10 ** (TOKEN_DECIMALS - tokenDecimals);
        uint256 minimumPrice = (STORAGE_PRICE_PER_TIB_PER_MONTH + scale - 1) / scale;
        require(
            terms.pricePerTiBPerMonth >= minimumPrice,
            Errors.StoragePriceBelowDefault(terms.pricePerTiBPerMonth, minimumPrice)
        );

        storageTermsId = computeStorageTermsId(terms);
        require(storageTermsId != bytes32(0), Errors.InvalidStorageTermsId(storageTermsId));

        StorageTermsRecord storage record = FWSSStorageTerms.get().storageTerms[storageTermsId];
        if (record.version == 0) {
            record.token = terms.token;
            record.tokenDecimals = tokenDecimals;
            record.version = STORAGE_TERMS_VERSION;
            record.pricePerTiBPerMonth = terms.pricePerTiBPerMonth;
            record.salt = terms.salt;
        }
        record.enabled = true;

        emit StorageTermsRegistered(storageTermsId, terms.token, tokenDecimals, terms.pricePerTiBPerMonth, terms.salt);
    }

    /**
     * @notice Stops new data sets from selecting the storage terms.
     * @dev Existing data sets are unaffected. Registering the same terms again re-enables them.
     * @param storageTermsId The ID of registered, non-legacy storage terms
     */
    function disableStorageTerms(bytes32 storageTermsId) external onlyOwner {
        require(storageTermsId != legacyStorageTermsId, Errors.LegacyStorageTermsCannotBeDisabled());
        StorageTermsRecord storage record = FWSSStorageTerms.get().storageTerms[storageTermsId];
        require(record.version != 0, Errors.UnknownStorageTerms(storageTermsId));
        record.enabled = false;
        emit StorageTermsDisabled(storageTermsId);
    }
}
