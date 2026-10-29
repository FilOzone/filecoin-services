// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {Errors} from "../Errors.sol";
import {LibRails} from "./LibRails.sol";
import {STORAGE_PRICE_PER_TIB_PER_MONTH, TOKEN_DECIMALS} from "./PriceListUSDFC.sol";
import {StorageTermsRecord} from "./StorageTerms.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";
import {FWSSStorageTerms} from "../storage/FWSSStorageTerms.sol";

/// @title LibStoragePayments
/// @notice Shared payment operations for FWSS modules.
library LibStoragePayments {
    using LibRails for FilecoinPayV1;

    /// @notice Terminates CDN rails (cacheMiss + CDN), deletes withCDN metadata, and emits event.
    /// @dev Uses try/catch because CDN rails may have been terminated externally via FilecoinPay.
    /// ⚠️ WARNING: Catch-all error handling will silently suppress ALL errors from terminateRail(),
    /// not just "already terminated/finalized" errors. This could mask legitimate failures.
    /// Ideally we would catch only specific error types, but contract size constraint prevents
    /// us from implementing error handling.
    function terminateCDNRails(uint256 dataSetId, FWSSStorage.DataSetInfo storage info, FilecoinPayV1 payments)
        internal
    {
        payments.terminateCDNRails(dataSetId, info.cacheMissRailId, info.cdnRailId);
    }

    /// @notice The token decimals of a data set's storage terms.
    /// @dev A stored ID of zero is the legacy terms. Disabling terms never affects existing data sets, so
    ///      `enabled` is not consulted.
    function tokenDecimals(FWSSStorage.DataSetInfo storage info) internal view returns (uint8) {
        bytes32 storageTermsId = info.storageTermsId;
        if (storageTermsId == bytes32(0)) return uint8(TOKEN_DECIMALS);
        return FWSSStorageTerms.get().storageTerms[storageTermsId].tokenDecimals;
    }

    /// @notice The token decimals and storage price of a data set's storage terms.
    function pricing(FWSSStorage.DataSetInfo storage info)
        internal
        view
        returns (uint8 decimals, uint96 pricePerTiBPerMonth)
    {
        bytes32 storageTermsId = info.storageTermsId;
        if (storageTermsId == bytes32(0)) {
            return (uint8(TOKEN_DECIMALS), uint96(STORAGE_PRICE_PER_TIB_PER_MONTH));
        }
        StorageTermsRecord storage record = FWSSStorageTerms.get().storageTerms[storageTermsId];
        return (record.tokenDecimals, record.pricePerTiBPerMonth);
    }

    /// @notice Updates a data set's storage payment rate and reserve balance at its storage terms' price.
    /// @param payments The FilecoinPay contract holding the data set's payment rails.
    function updatePaymentRates(
        uint256 dataSetId,
        FWSSStorage.DataSetInfo storage info,
        uint256 leafCount,
        uint96 pending,
        uint96 reserveBalance,
        bool immediateTermination,
        FilecoinPayV1 payments
    ) internal {
        uint256 pdpRailId = info.pdpRailId;
        require(pdpRailId != 0, Errors.NoPDPPaymentRail(dataSetId));

        (uint8 decimals, uint96 pricePerTiBPerMonth) = pricing(info);
        info.lifecycleReserveBalance = payments.updateStorageRates(
            dataSetId,
            pdpRailId,
            leafCount,
            pending,
            reserveBalance,
            info.pdpEndEpoch,
            immediateTermination,
            decimals,
            pricePerTiBPerMonth
        );
        info.pendingOneTimePayments = 0;
    }
}
