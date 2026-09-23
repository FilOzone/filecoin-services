// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {Errors} from "../Errors.sol";
import {LibConfig} from "./LibConfig.sol";
import {Rails} from "./Rails.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";

/// @title LibStoragePayments
/// @notice Shared payment operations for FWSS modules.
library LibStoragePayments {
    using Rails for FilecoinPayV1;

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

    /// @notice Updates a data set's storage payment rate and reserve balance.
    function updatePaymentRates(
        uint256 dataSetId,
        FWSSStorage.DataSetInfo storage info,
        uint256 leafCount,
        uint96 pending,
        uint96 reserveBalance,
        bool immediateTermination
    ) internal {
        uint256 pdpRailId = info.pdpRailId;
        require(pdpRailId != 0, Errors.NoPDPPaymentRail(dataSetId));

        info.lifecycleReserveBalance = FilecoinPayV1(LibConfig.config().paymentsContractAddress)
            .updateStorageRates(
                dataSetId, pdpRailId, leafCount, pending, reserveBalance, info.pdpEndEpoch, immediateTermination
            );
        info.pendingOneTimePayments = 0;
    }
}
