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

event CDNSubscriptionJoined(uint256 indexed dataSetId, uint256 indexed cdnRailId, uint256 cacheMissRailId);

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
    /// @param includeCacheMiss Whether to include the fixed cache-miss lockup in the requirement checks
    /// @param includeBandwidth Whether to include the fixed CDN bandwidth lockup. False when the data set
    ///        joins an existing shared bandwidth rail, the bandwidth lockup was paid by the first member.
    function validatePayerOperatorApprovalAndFunds(
        FilecoinPayV1 payments,
        IERC20 usdfcTokenAddress,
        address payer,
        bool includeCacheMiss,
        bool includeBandwidth
    ) internal view {
        // Required capacity: lifecycle reserve plus per-dataset fee lockup at the default period.
        // Multiply-first preserves the exact monthly value for cleaner error messages; slightly
        // more conservative than the actual rail lockup (truncated per-epoch), within 0.0001%
        // and always in the user's favor.
        uint256 requiredLockup =
            (DATASET_FEE_PER_MONTH * DEFAULT_LOCKUP_PERIOD) / EPOCHS_PER_MONTH + LIFECYCLE_RESERVE_TARGET;

        // The cache-miss rail is always per data set (its payee is this data set's SP).
        if (includeCacheMiss) {
            requiredLockup += DEFAULT_CACHE_MISS_LOCKUP_AMOUNT;
        }
        // The bandwidth rail is shared across a subscription, only its first member locks it.
        if (includeBandwidth) {
            requiredLockup += DEFAULT_CDN_LOCKUP_AMOUNT;
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

    /// @notice Creates the PDP rail and, when CDN is enabled, a per-data-set cache-miss rail plus a
    ///         CDN bandwidth rail.
    /// @dev The bandwidth rail (payer -> FilBeam beneficiary) is shared across a CDN subscription:
    ///      when `cdnGroupKey` is non-zero and an active rail already exists for that key, the new
    ///      data set joins it instead of creating (and paying for) a second one. The cache-miss rail
    ///      is always per data set because its payee is this data set's SP, which differs per copy.
    ///      `cdnGroupRail` maps a subscription key to its shared bandwidth rail, `cdnRailRefCount`
    ///      counts the data sets referencing each bandwidth rail so it is torn down only at zero.
    function createRails(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        IERC20 usdfcTokenAddress,
        address payer,
        address payee,
        address filBeamBeneficiaryAddress,
        bytes32 cdnGroupKey,
        mapping(bytes32 cdnGroupKey => uint256 cdnRailId) storage cdnGroupRail,
        mapping(uint256 cdnRailId => uint256 refCount) storage cdnRailRefCount
    ) public returns (uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId) {
        bool hasCDN = filBeamBeneficiaryAddress != address(0);

        // Resolve whether an active shared bandwidth rail can be reused before validating funds,
        // so a joiner is not asked to lock the bandwidth amount again.
        uint256 sharedCdnRailId = 0;
        if (hasCDN && cdnGroupKey != bytes32(0)) {
            uint256 existing = cdnGroupRail[cdnGroupKey];
            if (existing != 0 && _railIsActive(payments, existing)) {
                sharedCdnRailId = existing;
            }
        }
        bool createBandwidthRail = hasCDN && sharedCdnRailId == 0;

        // Validate payer has sufficient funds and operator approvals to cover the required lockup.
        validatePayerOperatorApprovalAndFunds(payments, usdfcTokenAddress, payer, hasCDN, createBandwidthRail);

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

            if (createBandwidthRail) {
                cdnRailId = payments.createRail(
                    usdfcTokenAddress, // token address
                    payer, // from (payer)
                    filBeamBeneficiaryAddress, // to FilBeam beneficiary
                    address(0), // no validator
                    0, // no service commission
                    address(this) // controller
                );
                payments.modifyRailLockup(cdnRailId, CDN_LOCKUP_PERIOD, DEFAULT_CDN_LOCKUP_AMOUNT);

                // Register the freshly created rail as the subscription's shared bandwidth rail.
                if (cdnGroupKey != bytes32(0)) {
                    cdnGroupRail[cdnGroupKey] = cdnRailId;
                }

                emit CDNPaymentRailsToppedUp(
                    dataSetId,
                    DEFAULT_CDN_LOCKUP_AMOUNT,
                    DEFAULT_CDN_LOCKUP_AMOUNT,
                    DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
                    DEFAULT_CACHE_MISS_LOCKUP_AMOUNT
                );
            } else {
                // Join the existing shared bandwidth rail, no second bandwidth lockup is charged.
                cdnRailId = sharedCdnRailId;
                emit CDNSubscriptionJoined(dataSetId, cdnRailId, cacheMissRailId);
            }

            cdnRailRefCount[cdnRailId] += 1;
        }
    }

    /// @notice Returns true if a rail exists and has not been terminated (endEpoch == 0).
    /// @dev getRail reverts on a finalized (zeroed) rail, treated as inactive.
    function _railIsActive(FilecoinPayV1 payments, uint256 railId) internal view returns (bool) {
        try payments.getRail(railId) returns (FilecoinPayV1.RailView memory rail) {
            return rail.endEpoch == 0;
        } catch {
            return false;
        }
    }

    /// @notice Terminates a data set's cache-miss rail and, when supplied, its shared bandwidth rail.
    /// @dev The caller passes `cdnRailId == 0` when the shared bandwidth rail is still referenced by
    ///      sibling data sets, so only the last member tears the bandwidth rail down.
    function terminateCDNRails(FilecoinPayV1 payments, uint256 dataSetId, uint256 cacheMissRailId, uint256 cdnRailId)
        public
    {
        try payments.terminateRail(cacheMissRailId) {} catch {}
        if (cdnRailId != 0) {
            try payments.terminateRail(cdnRailId) {} catch {}
        }
        emit CDNServiceTerminated(msg.sender, dataSetId, cacheMissRailId, cdnRailId);
    }

    /// @notice Tears down all rails for an abandoned data set.
    /// @dev SP forfeits pending op-fees; lifecycle reserve and streaming buffer return to the
    ///      payer. Intentional: abandonment means the SP walked away.
    ///      PDP rail flow: settle to pay any proven epochs and advance settledUpTo; zero the
    ///      lockup to release buffer+reserve to the payer; terminate (endEpoch = block.number
    ///      since period is 0); settle again so settledUpTo >= endEpoch finalises the rail.
    ///      CDN rails are best-effort, may have been terminated externally.
    function abandonRails(
        FilecoinPayV1 payments,
        mapping(uint256 dataSetId => uint256 activationEpoch) storage provingActivationEpoch,
        uint256 dataSetId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId
    ) public {
        payments.settleRail(pdpRailId, block.number);
        payments.modifyRailLockup(pdpRailId, 0, 0);

        // Cache-miss is per data set, the (possibly shared) bandwidth rail is supplied non-zero only
        // when this is its last referencing data set.
        if (cacheMissRailId != 0) {
            _teardownCDNRail(payments, cacheMissRailId);
        }
        if (cdnRailId != 0) {
            _teardownCDNRail(payments, cdnRailId);
        }
        if (cacheMissRailId != 0 || cdnRailId != 0) {
            emit CDNServiceTerminated(msg.sender, dataSetId, cacheMissRailId, cdnRailId);
        }

        // clearing this allows settling up to block.number
        delete provingActivationEpoch[dataSetId];

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
            uint96 replenished = replenishReserveIfNeeded(payments, pdpRailId, pdpEndEpoch, reserveBalance, pending);
            if (replenished < pending) {
                pending = replenished;
            }
            newReserveBalance = replenished - pending;
        }
        payments.modifyRailPayment(pdpRailId, newStorageRatePerEpoch, pending);
        emit RailRateUpdated(dataSetId, pdpRailId, newStorageRatePerEpoch);
    }
}
