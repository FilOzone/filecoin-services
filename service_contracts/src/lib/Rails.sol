// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPOCHS_PER_MONTH, PriceList, storageRatePerEpoch} from "./PriceList.sol";
import {SERVICE_COMMISSION_BPS, priceList as priceListUSDFC} from "./PriceListUSDFC.sol";
import {priceListUSDC} from "./PriceListUSDC.sol";

// Metadata key selecting the rail token at data set creation; the value is signed by the payer
// along with the rest of the metadata. Absent means USDFC.
uint256 constant METADATA_KEY_PAYMENT_TOKEN_SIZE = 12;
bytes32 constant METADATA_KEY_PAYMENT_TOKEN_HASH = keccak256("paymentToken");
bytes32 constant PAYMENT_TOKEN_VALUE_USDC_HASH = keccak256("USDC");
bytes32 constant PAYMENT_TOKEN_VALUE_USDFC_HASH = keccak256("USDFC");

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
    /// @notice Returns the price list applying to `token` for this deployment.
    /// @dev Token-keyed dispatch: the USDC list when `token` is the deployment's configured USDC
    ///      instance, the USDFC list otherwise. Lives here (external library) to keep the per-token
    ///      price constants out of the main contract's code size. `pl.token` is populated with
    ///      `token`.
    function priceListFor(IERC20 token, IERC20 usdc) public pure returns (PriceList memory pl) {
        if (address(usdc) != address(0) && token == usdc) {
            pl = priceListUSDC();
        } else {
            pl = priceListUSDFC();
        }
        pl.token = token;
    }

    /// @notice Resolves the rail token, commission, and commission recipient from data set
    ///         creation metadata. An absent `paymentToken` key (or explicit "USDFC") selects
    ///         USDFC with the base commission; "USDC" selects the configured USDC instance
    ///         carrying the network value-accrual fee, routed to the ValueAccrualRouter. Any
    ///         other value reverts.
    /// @param metadataKeys The data set creation metadata keys (payer-signed)
    /// @param metadataValues The data set creation metadata values (payer-signed)
    /// @param usdfc The deployment's USDFC instance
    /// @param usdc The deployment's USDC instance (zero address when disabled)
    /// @param usdcCommissionBps The NVAF to lock into USDC rails
    /// @param valueAccrualRouter Receives USDC-rail commission (burned for FIL)
    /// @param usdfcFeeRecipient Commission recipient on USDFC rails (unused while base
    ///        commission is zero)
    function resolvePaymentToken(
        string[] memory metadataKeys,
        string[] memory metadataValues,
        IERC20 usdfc,
        IERC20 usdc,
        uint256 usdcCommissionBps,
        address valueAccrualRouter,
        address usdfcFeeRecipient
    ) public pure returns (IERC20 token, uint256 commissionBps, address serviceFeeRecipient) {
        for (uint256 i = 0; i < metadataKeys.length; i++) {
            bytes memory keyBytes = bytes(metadataKeys[i]);
            if (
                keyBytes.length == METADATA_KEY_PAYMENT_TOKEN_SIZE
                    && keccak256(keyBytes) == METADATA_KEY_PAYMENT_TOKEN_HASH
            ) {
                bytes32 valueHash = keccak256(bytes(metadataValues[i]));
                if (valueHash == PAYMENT_TOKEN_VALUE_USDC_HASH) {
                    if (address(usdc) == address(0)) {
                        revert Errors.UnsupportedPaymentToken(metadataValues[i]);
                    }
                    return (usdc, usdcCommissionBps, valueAccrualRouter);
                }
                if (valueHash != PAYMENT_TOKEN_VALUE_USDFC_HASH) {
                    revert Errors.UnsupportedPaymentToken(metadataValues[i]);
                }
                break; // explicit "USDFC" selects the default
            }
        }
        return (usdfc, SERVICE_COMMISSION_BPS, usdfcFeeRecipient);
    }

    /// @notice The one-time fees and lifecycle reserve target for `token`, as flat words.
    /// @dev Leaner for the main contract to decode than the full PriceList struct (code size).
    function oneTimeFees(IERC20 token, IERC20 usdc)
        public
        pure
        returns (
            uint256 createDataSetFee,
            uint256 addPiecesBaseFee,
            uint256 addPiecesPerPieceFee,
            uint256 schedulePieceRemovalsFee,
            uint256 terminateFee,
            uint256 lifecycleReserveTarget
        )
    {
        PriceList memory pl = priceListFor(token, usdc);
        return (
            pl.fees.createDataSetFee,
            pl.fees.addPiecesBaseFee,
            pl.fees.addPiecesPerPieceFee,
            pl.fees.schedulePieceRemovalsFee,
            pl.fees.terminateFee,
            pl.lockups.lifecycleReserveTarget
        );
    }

    /// @notice Validates the payer is set up to add pieces, not just create the dataset.
    /// @dev    The lifecycle reserve is consumed at creation; the per-dataset fee headroom is only
    ///         consumed once pieces are added. Empty datasets leave it as approved headroom.
    ///         Required up front intentionally: creation assumes pieces will follow.
    /// @param payments The FilecoinPayV1 contract instance
    /// @param token The rail token used for deposits and operator approvals
    /// @param payer The address of the payer
    /// @param includeCDN Whether to include fixed CDN/cache-miss lockups in the requirement checks
    /// @param pl The price list applying to `token`
    function validatePayerOperatorApprovalAndFunds(
        FilecoinPayV1 payments,
        IERC20 token,
        address payer,
        bool includeCDN,
        PriceList memory pl
    ) internal view {
        // Required capacity: lifecycle reserve plus per-dataset fee lockup at the default period.
        // Multiply-first preserves the exact monthly value for cleaner error messages; slightly
        // more conservative than the actual rail lockup (truncated per-epoch), within 0.0001%
        // and always in the user's favor.
        uint256 requiredLockup = (pl.rates.datasetFeePerMonth * pl.lockups.defaultLockupPeriod) / EPOCHS_PER_MONTH
            + pl.lockups.lifecycleReserveTarget;

        // If CDN is enabled, include the fixed cache-miss and CDN lockup amounts
        if (includeCDN) {
            requiredLockup += pl.lockups.cacheMissLockupAmount + pl.lockups.cdnLockupAmount;
        }

        // Check that payer has sufficient available funds
        (,, uint256 availableFunds,) = payments.getAccountInfoIfSettled(token, payer);
        require(availableFunds >= requiredLockup, Errors.InsufficientLockupFunds(payer, requiredLockup, availableFunds));

        // Check operator approval settings
        (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        ) = payments.operatorApprovals(token, payer, address(this));

        // Verify operator is approved
        require(isApproved, Errors.OperatorNotApproved(payer, address(this)));

        // Rate-allowance headroom for the per-dataset fee rate: the floor of any non-empty
        // dataset's rate (size-proportional component sits on top). Empty datasets never consume
        // it; required up front for the dataset to be eligible to receive pieces.
        uint256 datasetFeePerEpoch = pl.rates.datasetFeePerMonth / EPOCHS_PER_MONTH;
        require(
            rateAllowance >= rateUsage + datasetFeePerEpoch,
            Errors.InsufficientRateAllowance(payer, address(this), rateAllowance, rateUsage, datasetFeePerEpoch)
        );

        // Verify lockup allowance is sufficient
        require(
            lockupAllowance >= lockupUsage + requiredLockup,
            Errors.InsufficientLockupAllowance(payer, address(this), lockupAllowance, lockupUsage, requiredLockup)
        );

        // Verify max lockup period is sufficient
        require(
            maxLockupPeriod >= pl.lockups.defaultLockupPeriod,
            Errors.InsufficientMaxLockupPeriod(payer, address(this), maxLockupPeriod, pl.lockups.defaultLockupPeriod)
        );
    }

    function createRails(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        IERC20 token,
        address payer,
        address payee,
        address filBeamBeneficiaryAddress,
        uint256 commissionBps,
        address serviceFeeRecipient,
        IERC20 usdc
    )
        public
        returns (
            uint256 pdpRailId,
            uint256 cacheMissRailId,
            uint256 cdnRailId,
            uint256 createDataSetFee,
            uint256 lifecycleReserveTarget
        )
    {
        PriceList memory pl = priceListFor(token, usdc);
        createDataSetFee = pl.fees.createDataSetFee;
        lifecycleReserveTarget = pl.lockups.lifecycleReserveTarget;
        bool hasCDN = filBeamBeneficiaryAddress != address(0);
        // Validate payer has sufficient funds and operator approvals to cover the required lockup
        // If CDN is enabled, validation must account for the additional fixed lockup amounts
        validatePayerOperatorApprovalAndFunds(payments, token, payer, hasCDN, pl);

        pdpRailId = payments.createRail(
            token, // token address
            payer, // from (payer)
            payee, // payee address from registry
            address(this), // this contract acts as the validator
            commissionBps, // commission carries the network value-accrual fee on USDC rails
            serviceFeeRecipient
        );

        // Set lockup period and seed the lifecycle reserve
        payments.modifyRailLockup(pdpRailId, pl.lockups.defaultLockupPeriod, pl.lockups.lifecycleReserveTarget);

        cacheMissRailId = 0;
        cdnRailId = 0;

        if (hasCDN) {
            cacheMissRailId = payments.createRail(
                token, // token address
                payer, // from (payer)
                payee, // payee address from registry
                address(0), // no validator
                commissionBps, // same per-token commission as the PDP rail
                serviceFeeRecipient
            );
            payments.modifyRailLockup(cacheMissRailId, pl.lockups.cdnLockupPeriod, pl.lockups.cacheMissLockupAmount);

            cdnRailId = payments.createRail(
                token, // token address
                payer, // from (payer)
                filBeamBeneficiaryAddress, // to FilBeam beneficiary
                address(0), // no validator
                commissionBps, // same per-token commission as the PDP rail
                serviceFeeRecipient
            );
            payments.modifyRailLockup(cdnRailId, pl.lockups.cdnLockupPeriod, pl.lockups.cdnLockupAmount);

            emit CDNPaymentRailsToppedUp(
                dataSetId,
                pl.lockups.cdnLockupAmount,
                pl.lockups.cdnLockupAmount,
                pl.lockups.cacheMissLockupAmount,
                pl.lockups.cacheMissLockupAmount
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

        if (cdnRailId != 0) {
            _teardownCDNRail(payments, cacheMissRailId);
            _teardownCDNRail(payments, cdnRailId);
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
        uint256 cdnAmountToAdd,
        IERC20 token,
        IERC20 usdc
    ) public {
        PriceList memory pl = priceListFor(token, usdc);
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
        payments.modifyRailLockup(cdnRailId, pl.lockups.cdnLockupPeriod, totalCdnLockup);
        payments.modifyRailLockup(cacheMissRailId, pl.lockups.cdnLockupPeriod, totalCacheMissLockup);
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

    // Replenishes the rail's fixed lockup when the reserve would drop below the replenish
    // threshold after paying pending. Returns the new lockupFixed value (mirrors
    // lifecycleReserveBalance). Skipped for terminated rails (pdpEndEpoch != 0):
    // modifyRailLockup forbids increases there.
    function replenishReserveIfNeeded(
        FilecoinPayV1 payments,
        uint256 pdpRailId,
        uint256 pdpEndEpoch,
        uint96 reserveBalance,
        uint96 pending,
        PriceList memory pl
    ) internal returns (uint96) {
        if (pdpEndEpoch == 0 && reserveBalance < pending + uint96(pl.lockups.replenishThreshold)) {
            uint96 newLockup = uint96(pl.lockups.lifecycleReserveTarget) + pending;
            payments.modifyRailLockup(pdpRailId, pl.lockups.defaultLockupPeriod, newLockup);
            return newLockup;
        }
        return reserveBalance;
    }

    /// @notice Public entry point for {replenishReserveIfNeeded}, resolving the price list from
    ///         the rail token. The internal variant stays inlined into in-library callers.
    function replenishReserve(
        FilecoinPayV1 payments,
        uint256 pdpRailId,
        uint256 pdpEndEpoch,
        uint96 reserveBalance,
        uint96 pending,
        IERC20 token,
        IERC20 usdc
    ) public returns (uint96) {
        return replenishReserveIfNeeded(
            payments, pdpRailId, pdpEndEpoch, reserveBalance, pending, priceListFor(token, usdc)
        );
    }

    function updateStorageRates(
        FilecoinPayV1 payments,
        uint256 dataSetId,
        uint256 pdpRailId,
        uint256 leafCount,
        uint96 pending,
        uint96 reserveBalance,
        uint256 pdpEndEpoch,
        bool immediateTermination,
        IERC20 token,
        IERC20 usdc
    ) public returns (uint96 newReserveBalance) {
        PriceList memory pl = priceListFor(token, usdc);
        uint256 newStorageRatePerEpoch = storageRatePerEpoch(pl, leafCount);
        if (immediateTermination) {
            payments.modifyRailLockup(pdpRailId, 0, pending);
            newReserveBalance = 0;
        } else {
            uint96 replenished = replenishReserveIfNeeded(payments, pdpRailId, pdpEndEpoch, reserveBalance, pending, pl);
            if (replenished < pending) {
                pending = replenished;
            }
            newReserveBalance = replenished - pending;
        }
        payments.modifyRailPayment(pdpRailId, newStorageRatePerEpoch, pending);
        emit RailRateUpdated(dataSetId, pdpRailId, newStorageRatePerEpoch);
    }
}
