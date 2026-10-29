// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Errors} from "../Errors.sol";
import {FWSSOwnable} from "../lib/FWSSOwnable.sol";
import {TOKEN_DECIMALS} from "../lib/PriceListUSDFC.sol";
import {StorageTerms, computeStorageTermsId, legacyStorageTerms} from "../lib/StorageTerms.sol";

/// @title FWSSStorageTermsModule
/// @notice Registers and disables the storage terms new data sets may select.
contract FWSSStorageTermsModule is FWSSOwnable {
    bytes32 private immutable legacyStorageTermsId;

    event StorageTermsRegistered(
        bytes32 indexed storageTermsId, address token, uint8 tokenDecimals, uint96 pricePerTiBPerMonth, bytes32 salt
    );
    event StorageTermsDisabled(bytes32 indexed storageTermsId);

    /// @param _usdfc The USDFC token of the legacy storage terms.
    constructor(IERC20Metadata _usdfc) {
        require(_usdfc != IERC20Metadata(address(0)), Errors.ZeroAddress(Errors.AddressField.USDFC));
        require(TOKEN_DECIMALS == _usdfc.decimals());
        legacyStorageTermsId = computeStorageTermsId(legacyStorageTerms(address(_usdfc)));
    }

    function registerStorageTerms(StorageTerms calldata) external view onlyOwner returns (bytes32) {
        revert("FWSSStorageTermsModule: not implemented");
    }

    function disableStorageTerms(bytes32) external view onlyOwner {
        revert("FWSSStorageTermsModule: not implemented");
    }
}
