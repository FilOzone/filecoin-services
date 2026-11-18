// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Errors} from "../Errors.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {StoragePricing} from "./StoragePricing.sol";
import {
    CDN_LOCKUP_PERIOD,
    DEFAULT_LOCKUP_PERIOD,
    LIFECYCLE_RESERVE_TARGET,
    REPLENISH_THRESHOLD
} from "./PriceListUSDFC.sol";

event CDNPaymentRailsToppedUp(
    uint256 indexed dataSetId,
    uint256 cdnAmountAdded,
    uint256 totalCdnLockup,
    uint256 cacheMissAmountAdded,
    uint256 totalCacheMissLockup
);

event CDNServiceTerminated(
    address indexed caller, uint256 indexed dataSetId, uint256 cacheMissRailId, uint256 cdnRailId
);

event DataSetAbandoned(uint256 indexed dataSetId, uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId);

event RailRateUpdated(uint256 indexed dataSetId, uint256 railId, uint256 newRate);

/// @title LibRails
/// @notice Payment rail operations inlined into the FWSS modules.
library LibRails {
    function terminateCDNRails(FilecoinPayV1 payments, uint256 dataSetId, uint256 cacheMissRailId, uint256 cdnRailId)
        internal
    {
        try payments.terminateRail(cacheMissRailId) {} catch {}
        try payments.terminateRail(cdnRailId) {} catch {}
        emit CDNServiceTerminated(msg.sender, dataSetId, cacheMissRailId, cdnRailId);
    }

    /// @notice Tears down all rails for an abandoned data set.
    /// @dev SP forfeits pending op-fees; lifecycle reserve returns to the payer.
    ///      For well-funded payers the rail is terminated with no lockup period, releasing the
    ///      reserve immediately.
    ///      For underfunded payers the PDP rail remains for DEFAULT_LOCKUP_PERIOD; the payer's
    ///      streaming lockup tail isn't released until that period elapses, though every proven epoch is paid
    ///      out first.
    ///      CDN rails are best-effort, may have been terminated externally.
    function abandonRails(
        FilecoinPayV1 payments,
        mapping(uint256 dataSetId => uint256 activationEpoch) storage provingActivationEpoch,
        uint256 dataSetId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId
    ) internal {
        payments.settleRail(pdpRailId, block.number);

        // Try to zero the lockup period before termination.
        // For underfunded payers the period change will fail.
        bool reserveRemaining = false;
        try payments.modifyRailLockup(pdpRailId, 0, 0) {}
        catch {
            reserveRemaining = true;
        }

        if (cdnRailId != 0) {
            _teardownCDNRail(payments, cacheMissRailId);
            _teardownCDNRail(payments, cdnRailId);
            emit CDNServiceTerminated(msg.sender, dataSetId, cacheMissRailId, cdnRailId);
        }

        // clearing this allows settling remaining epochs with zero payment
        delete provingActivationEpoch[dataSetId];

        payments.terminateRail(pdpRailId);
        if (reserveRemaining) {
            // release the fixed reserve
            payments.modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, 0);
        }
        payments.settleRail(pdpRailId, block.number);
        emit DataSetAbandoned(dataSetId, pdpRailId, cacheMissRailId, cdnRailId);
    }

    /// @notice Tears down one CDN rail.
    /// @dev Each step may revert if the rail was independently terminated or finalised by the
    ///      payer or FilBeam controller (CDN rails have no validator). Best-effort so abandonment
    ///      completes regardless.
    function _teardownCDNRail(FilecoinPayV1 payments, uint256 railId) internal {
        try payments.modifyRailLockup(railId, 0, 0) {} catch {}
        try payments.terminateRail(railId) {} catch {}
        try payments.settleRail(railId, block.number) {} catch {}
    }

    function topUpCDNRails(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        uint256 cacheMissRailId,
        uint256 cdnRailId,
        uint256 cacheMissAmountToAdd,
        uint256 cdnAmountToAdd
    ) internal {
        // Both rails must be active for any top-up operation
        FilecoinPayV1.RailView memory cdnRail = payments.getRail(cdnRailId);
        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(cacheMissRailId);

        require(cdnRail.endEpoch == 0, Errors.CDNPaymentAlreadyTerminated(dataSetId));
        require(cacheMissRail.endEpoch == 0, Errors.CacheMissPaymentAlreadyTerminated(dataSetId));

        // Require at least one amount to be non-zero
        if (cdnAmountToAdd == 0 && cacheMissAmountToAdd == 0) {
            revert Errors.InvalidTopUpAmount(dataSetId);
        }

        // Calculate total lockup amounts
        uint256 totalCdnLockup = cdnRail.lockupFixed + cdnAmountToAdd;
        uint256 totalCacheMissLockup = cacheMissRail.lockupFixed + cacheMissAmountToAdd;

        // Only modify rails if amounts are being added
        payments.modifyRailLockup(cdnRailId, CDN_LOCKUP_PERIOD, totalCdnLockup);
        payments.modifyRailLockup(cacheMissRailId, CDN_LOCKUP_PERIOD, totalCacheMissLockup);
        emit CDNPaymentRailsToppedUp(
            dataSetId, cdnAmountToAdd, totalCdnLockup, cacheMissAmountToAdd, totalCacheMissLockup
        );
    }

    function settleCDNRails(
        FilecoinPayV1 payments,
        uint256 cdnRailId,
        uint256 cacheMissRailId,
        uint256 cdnAmount,
        uint256 cacheMissAmount
    ) internal {
        if (cdnAmount > 0) {
            payments.modifyRailPayment(cdnRailId, 0, cdnAmount);
        }

        if (cacheMissAmount > 0) {
            payments.modifyRailPayment(cacheMissRailId, 0, cacheMissAmount);
        }
    }

    // Replenishes the rail's fixed lockup when the reserve would drop below REPLENISH_THRESHOLD
    // after paying pending. Returns the new lockupFixed value (mirrors lifecycleReserveBalance).
    // Skipped for terminated rails (pdpEndEpoch != 0): modifyRailLockup forbids increases there.
    function replenishReserveIfNeeded(
        FilecoinPayV1 payments,
        uint256 pdpRailId,
        uint256 pdpEndEpoch,
        uint96 reserveBalance,
        uint96 pending,
        uint8 tokenDecimals
    ) internal returns (uint96) {
        uint256 replenishThreshold = StoragePricing.scaleAmount(REPLENISH_THRESHOLD, tokenDecimals);
        if (pdpEndEpoch == 0 && reserveBalance < uint256(pending) + replenishThreshold) {
            uint256 newLockup = StoragePricing.scaleAmount(LIFECYCLE_RESERVE_TARGET, tokenDecimals) + pending;
            require(newLockup <= type(uint96).max);
            payments.modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, newLockup);
            return uint96(newLockup);
        }
        return reserveBalance;
    }

    function updateStorageRates(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        uint256 pdpRailId,
        uint256 newStorageRatePerEpoch,
        uint96 pending,
        uint96 reserveBalance,
        uint256 pdpEndEpoch,
        bool immediateTermination,
        uint8 tokenDecimals
    ) internal returns (uint96 newReserveBalance) {
        if (immediateTermination) {
            // No try/catch: the payer consented, and insufficient funds must revert.
            payments.modifyRailLockup(pdpRailId, 0, pending);
            newReserveBalance = 0;
        } else {
            uint96 replenished =
                replenishReserveIfNeeded(payments, pdpRailId, pdpEndEpoch, reserveBalance, pending, tokenDecimals);
            if (replenished < pending) {
                pending = replenished;
            }
            newReserveBalance = replenished - pending;
        }
        payments.modifyRailPayment(pdpRailId, newStorageRatePerEpoch, pending);
        emit RailRateUpdated(dataSetId, pdpRailId, newStorageRatePerEpoch);
    }
}
