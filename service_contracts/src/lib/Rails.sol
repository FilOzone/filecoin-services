// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    CDN_LOCKUP_PERIOD,
    DATASET_FEE_PER_EPOCH,
    DATASET_FEE_PER_MONTH,
    DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
    DEFAULT_CDN_LOCKUP_AMOUNT,
    DEFAULT_LOCKUP_PERIOD,
    EPOCHS_PER_MONTH,
    LIFECYCLE_RESERVE_TARGET,
    REPLENISH_THRESHOLD,
    SERVICE_COMMISSION_BPS,
    calculateStorageRate
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

library Rails {
    /// @notice Validates the payer is set up to add pieces, not just create the dataset.
    /// @dev    The lifecycle reserve is consumed at creation; the per-dataset fee headroom is only
    ///         consumed once pieces are added. Empty datasets leave it as approved headroom.
    ///         Required up front intentionally: creation assumes pieces will follow.
    /// @param payments The FilecoinPayV1 contract instance
    /// @param usdfcTokenAddress The USDFC token used for deposits and operator approvals
    /// @param payer The address of the payer
    /// @param includeCDN Whether to include fixed CDN/cache-miss lockups in the requirement checks
    function validatePayerOperatorApprovalAndFunds(
        FilecoinPayV1 payments,
        IERC20 usdfcTokenAddress,
        address payer,
        bool includeCDN
    ) internal view {
        // Required capacity: lifecycle reserve plus per-dataset fee lockup at the default period.
        // Multiply-first preserves the exact monthly value for cleaner error messages; slightly
        // more conservative than the actual rail lockup (truncated per-epoch), within 0.0001%
        // and always in the user's favor.
        uint256 requiredLockup =
            (DATASET_FEE_PER_MONTH * DEFAULT_LOCKUP_PERIOD) / EPOCHS_PER_MONTH + LIFECYCLE_RESERVE_TARGET;

        // If CDN is enabled, include the fixed cache-miss and CDN lockup amounts
        if (includeCDN) {
            requiredLockup += DEFAULT_CACHE_MISS_LOCKUP_AMOUNT + DEFAULT_CDN_LOCKUP_AMOUNT;
        }

        // Check that payer has sufficient available funds
        (,, uint256 availableFunds,) = payments.getAccountInfoIfSettled(usdfcTokenAddress, payer);
        require(availableFunds >= requiredLockup, Errors.InsufficientLockupFunds(payer, requiredLockup, availableFunds));

        // Check operator approval settings
        (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        ) = payments.operatorApprovals(usdfcTokenAddress, payer, address(this));

        // Verify operator is approved
        require(isApproved, Errors.OperatorNotApproved(payer, address(this)));

        // Rate-allowance headroom for the per-dataset fee rate: the floor of any non-empty
        // dataset's rate (size-proportional component sits on top). Empty datasets never consume
        // it; required up front for the dataset to be eligible to receive pieces.
        require(
            rateAllowance >= rateUsage + DATASET_FEE_PER_EPOCH,
            Errors.InsufficientRateAllowance(payer, address(this), rateAllowance, rateUsage, DATASET_FEE_PER_EPOCH)
        );

        // Verify lockup allowance is sufficient
        require(
            lockupAllowance >= lockupUsage + requiredLockup,
            Errors.InsufficientLockupAllowance(payer, address(this), lockupAllowance, lockupUsage, requiredLockup)
        );

        // Verify max lockup period is sufficient
        require(
            maxLockupPeriod >= DEFAULT_LOCKUP_PERIOD,
            Errors.InsufficientMaxLockupPeriod(payer, address(this), maxLockupPeriod, DEFAULT_LOCKUP_PERIOD)
        );
    }

    function createRails(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        IERC20 usdfcTokenAddress,
        address payer,
        address payee,
        address filBeamBeneficiaryAddress
    ) public returns (uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId) {
        bool hasCDN = filBeamBeneficiaryAddress != address(0);
        // Validate payer has sufficient funds and operator approvals to cover the required lockup
        // If CDN is enabled, validation must account for the additional fixed lockup amounts
        validatePayerOperatorApprovalAndFunds(payments, usdfcTokenAddress, payer, hasCDN);

        pdpRailId = payments.createRail(
            usdfcTokenAddress, // token address
            payer, // from (payer)
            payee, // payee address from registry
            address(this), // this contract acts as the validator
            SERVICE_COMMISSION_BPS, // commission rate based on CDN usage
            address(this)
        );

        // Set lockup period and seed the lifecycle reserve
        payments.modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, LIFECYCLE_RESERVE_TARGET);

        cacheMissRailId = 0;
        cdnRailId = 0;

        if (hasCDN) {
            cacheMissRailId = payments.createRail(
                usdfcTokenAddress, // token address
                payer, // from (payer)
                payee, // payee address from registry
                address(0), // no validator
                0, // no service commission
                address(this) // controller
            );
            payments.modifyRailLockup(cacheMissRailId, CDN_LOCKUP_PERIOD, DEFAULT_CACHE_MISS_LOCKUP_AMOUNT);

            cdnRailId = payments.createRail(
                usdfcTokenAddress, // token address
                payer, // from (payer)
                filBeamBeneficiaryAddress, // to FilBeam beneficiary
                address(0), // no validator
                0, // no service commission
                address(this) // controller
            );
            payments.modifyRailLockup(cdnRailId, CDN_LOCKUP_PERIOD, DEFAULT_CDN_LOCKUP_AMOUNT);

            emit CDNPaymentRailsToppedUp(
                dataSetId,
                DEFAULT_CDN_LOCKUP_AMOUNT,
                DEFAULT_CDN_LOCKUP_AMOUNT,
                DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
                DEFAULT_CACHE_MISS_LOCKUP_AMOUNT
            );
        }
    }

    function terminateCDNRails(FilecoinPayV1 payments, uint256 dataSetId, uint256 cacheMissRailId, uint256 cdnRailId)
        public
    {
        try payments.terminateRail(cacheMissRailId) {} catch {}
        try payments.terminateRail(cdnRailId) {} catch {}
        emit CDNServiceTerminated(msg.sender, dataSetId, cacheMissRailId, cdnRailId);
    }

    /// @notice Abandonment teardown, leg 1: pays proven epochs, releases reserve + buffer to payer.
    /// @dev Pairs with `finalizeAbandonedRails`. Caller wipes `provingActivationEpoch` between
    ///      legs so the finalize settle can advance past the open proving period.
    function settleAbandonedRail(FilecoinPayV1 payments, uint256 pdpRailId) public {
        payments.settleRail(pdpRailId, block.number);
        payments.modifyRailLockup(pdpRailId, 0, 0);
    }

    /// @notice Abandonment teardown, leg 2: tears down CDN rails, terminates and finalises PDP rail.
    /// @dev Requires the validator to have cleared activation for this data set so the
    ///      post-terminate settle advances past the open proving period. CDN teardown is
    ///      best-effort; rails may already be terminated externally.
    function finalizeAbandonedRails(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId
    ) public {
        if (cdnRailId != 0) {
            _teardownCDNRail(payments, cacheMissRailId);
            _teardownCDNRail(payments, cdnRailId);
            emit CDNServiceTerminated(msg.sender, dataSetId, cacheMissRailId, cdnRailId);
        }

        payments.terminateRail(pdpRailId);
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
    ) public {
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
    ) public {
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
        uint96 pending
    ) internal returns (uint96) {
        if (pdpEndEpoch == 0 && reserveBalance < pending + uint96(REPLENISH_THRESHOLD)) {
            uint96 newLockup = uint96(LIFECYCLE_RESERVE_TARGET) + pending;
            payments.modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, newLockup);
            return newLockup;
        }
        return reserveBalance;
    }

    function updateStorageRates(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        uint256 pdpRailId,
        uint256 leafCount,
        uint96 pending,
        uint96 reserveBalance,
        uint256 pdpEndEpoch,
        bool immediateTermination
    ) public returns (uint96 newReserveBalance) {
        uint256 newStorageRatePerEpoch = calculateStorageRate(leafCount);
        if (immediateTermination) {
            payments.modifyRailLockup(pdpRailId, 0, pending);
            newReserveBalance = 0;
        } else {
            newReserveBalance =
                replenishReserveIfNeeded(payments, pdpRailId, pdpEndEpoch, reserveBalance, pending) - pending;
        }
        payments.modifyRailPayment(pdpRailId, newStorageRatePerEpoch, pending);
        emit RailRateUpdated(dataSetId, pdpRailId, newStorageRatePerEpoch);
    }
}
