// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IPDPVerifier} from "@pdp/interfaces/IPDPVerifier.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FWSSEIP712} from "../lib/FWSSEIP712.sol";
import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {IFWSSConfig} from "../interfaces/IFWSSConfig.sol";
import {Errors} from "../Errors.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";
import {
    CACHE_MISS_EGRESS_PRICE_PER_TIB,
    CDN_EGRESS_PRICE_PER_TIB,
    DATASET_FEE_PER_MONTH,
    DEFAULT_LOCKUP_PERIOD,
    EPOCHS_PER_MONTH,
    SERVICE_COMMISSION_BPS,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    TERMINATE_FEE,
    TOKEN_DECIMALS
} from "../lib/PriceListUSDFC.sol";
import {LibStoragePayments} from "../lib/LibStoragePayments.sol";
import {LibProving} from "../lib/LibProving.sol";
import {LibSignatureVerification} from "../lib/LibSignatureVerification.sol";

uint256 constant COMMISSION_MAX_BPS = 10000; // 100% in basis points

/*
* Maximum extraData for terminateService
* Supports: legacy signature (160 bytes needed); or
*           1 Authorizer payload (perms + WebAuthn + P256 ~512 bytes)
*/
uint256 constant MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE = 1024; // 1KiB

/// @title FWSSPaymentModule
/// @notice Validates storage payments, manages lifecycle reserves and terminates PDP service.
contract FWSSPaymentModule is IValidator, FWSSEIP712, FWSSStorage {
    // Events

    /// @notice Emitted when a service is terminated.
    /// @param approver The address that authorized termination: the payer, one of the payer's
    ///   session keys (SessionKeyRegistry), or the service provider. Cross-reference with
    ///   `DataSetCreated` to classify: `approver == serviceProvider` is provider-initiated;
    ///   otherwise the payer (or their session key) authorized it. Mutual termination — payer
    ///   signed off-chain while the provider submitted the tx — is indistinguishable from
    ///   payer-initiated using this event alone; inspect the call trace to detect it.
    event ServiceTerminated(
        address indexed approver,
        uint256 indexed dataSetId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId
    );

    event PDPPaymentTerminated(uint256 indexed dataSetId, uint256 endEpoch, uint256 pdpRailId);

    // =========================================================================
    // Structs

    // Structure for service pricing information
    struct ServicePricing {
        uint256 pricePerTiBPerMonthNoCDN; // Price without CDN add-on (2.5 USDFC per TiB per month)
        uint256 pricePerTiBCdnEgress; // CDN egress price per TiB (usage-based)
        uint256 pricePerTiBCacheMissEgress; // Cache miss egress price per TiB (usage-based)
        IERC20 tokenAddress; // Address of the USDFC token
        uint256 epochsPerMonth; // Number of epochs in a month
        uint256 datasetFeePerMonth; // Per-dataset additive monthly fee (0.024 USDFC)
    }

    // External contract addresses
    IERC20Metadata private immutable usdfcTokenAddress;
    SessionKeyRegistry private immutable sessionKeyRegistry;

    /// @notice Configures the immutable dependencies used by payment operations.
    /// @dev These retain the implementation-bound configuration of FWSS without adding storage or getters.
    constructor(IERC20Metadata _usdfc, SessionKeyRegistry _sessionKeyRegistry) {
        require(_usdfc != IERC20Metadata(address(0)), Errors.ZeroAddress(Errors.AddressField.USDFC));
        usdfcTokenAddress = _usdfc;

        require(
            _sessionKeyRegistry != SessionKeyRegistry(address(0)),
            Errors.ZeroAddress(Errors.AddressField.SessionKeyRegistry)
        );
        sessionKeyRegistry = _sessionKeyRegistry;

        // Verify token decimals from the USDFC token contract
        require(TOKEN_DECIMALS == _usdfc.decimals());
    }

    // =========================================================================

    function terminateService(uint256 dataSetId, bytes calldata extraData) external {
        _terminateService(dataSetId, extraData);
    }

    /// @custom:deprecated Use terminateService(uint256,bytes) instead
    function terminateService(uint256 dataSetId) public {
        _terminateService(dataSetId, "");
    }

    function _terminateService(uint256 dataSetId, bytes memory extraData) private {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        require(info.pdpRailId != 0, Errors.InvalidDataSetId(dataSetId));
        require(info.pdpEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));

        address approver;
        bool immediateTermination = false;
        if (extraData.length > 0) {
            require(
                msg.sender == info.serviceProvider,
                Errors.CallerNotServiceProvider(dataSetId, info.serviceProvider, msg.sender)
            );
            require(
                extraData.length <= MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE,
                Errors.ExtraDataTooLarge(extraData.length, MAX_TERMINATE_SERVICE_EXTRA_DATA_SIZE)
            );
            bytes memory signature = abi.decode(extraData, (bytes));
            approver = _verifyTerminateServiceSignature(info.payer, dataSetId, signature);
            immediateTermination = true;
            info.pendingOneTimePayments += uint96(TERMINATE_FEE);
        } else {
            require(
                msg.sender == info.payer || msg.sender == info.serviceProvider,
                Errors.CallerNotPayerOrPayee(dataSetId, info.payer, info.serviceProvider, msg.sender)
            );
            approver = msg.sender;
        }

        FilecoinPayV1 payments = FilecoinPayV1(IFWSSConfig(address(this)).paymentsContractAddress());

        uint96 pending = info.pendingOneTimePayments;
        if (pending > 0) {
            uint256 leafCount =
                IPDPVerifier(IFWSSConfig(address(this)).pdpVerifierAddress()).getDataSetLeafCount(dataSetId);
            LibStoragePayments.updatePaymentRates(
                dataSetId, info, leafCount, pending, info.lifecycleReserveBalance, immediateTermination, payments
            );
        }

        payments.terminateRail(info.pdpRailId);

        emit ServiceTerminated(approver, dataSetId, info.pdpRailId, info.cacheMissRailId, info.cdnRailId);
    }

    /**
     * @notice Pre-funds the lifecycle reserve beyond the automatic target
     * @dev Useful before scheduling many piece removals or before terminating.
     *      Cannot be called after termination; FilecoinPay forbids raising lockupFixed on a terminated rail.
     * @param dataSetId The ID of the data set
     * @param amount Additional amount to add to the lifecycle reserve
     */
    function topUpLifecycleReserve(uint256 dataSetId, uint256 amount) external {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        address payer = info.payer;
        require(payer != address(0), Errors.InvalidDataSetId(dataSetId));
        require(msg.sender == payer, Errors.CallerNotPayer(dataSetId, payer, msg.sender));
        require(info.pdpEndEpoch == 0, Errors.DataSetPaymentAlreadyTerminated(dataSetId));

        uint256 pdpRailId = info.pdpRailId;
        uint96 newBalance = info.lifecycleReserveBalance + uint96(amount);
        FilecoinPayV1(IFWSSConfig(address(this)).paymentsContractAddress())
            .modifyRailLockup(pdpRailId, DEFAULT_LOCKUP_PERIOD, newBalance);
        info.lifecycleReserveBalance = newBalance;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice Get the service pricing information
     * @return pricing A struct containing pricing details for storage and CDN/cache miss egress
     * @custom:deprecated Use `FilecoinWarmStorageServiceStateView.getPriceList()` instead, which
     *                    returns the complete price catalogue (rates, fees, lockups) in one call.
     */
    function getServicePrice() external view returns (ServicePricing memory pricing) {
        pricing = ServicePricing({
            pricePerTiBPerMonthNoCDN: STORAGE_PRICE_PER_TIB_PER_MONTH,
            pricePerTiBCdnEgress: CDN_EGRESS_PRICE_PER_TIB,
            pricePerTiBCacheMissEgress: CACHE_MISS_EGRESS_PRICE_PER_TIB,
            tokenAddress: usdfcTokenAddress,
            epochsPerMonth: EPOCHS_PER_MONTH,
            datasetFeePerMonth: DATASET_FEE_PER_MONTH
        });
    }

    /**
     * @notice Get the effective rates after commission for both service types
     * @return serviceFee Service fee (per TiB per month)
     * @return spPayment SP payment (per TiB per month)
     * @custom:deprecated Service commission is fixed at zero; the SP receives the full storage
     *                    rate. Use `FilecoinWarmStorageServiceStateView.getPriceList().rates`
     *                    for the canonical pricing.
     */
    function getEffectiveRates() external pure returns (uint256 serviceFee, uint256 spPayment) {
        uint256 total = STORAGE_PRICE_PER_TIB_PER_MONTH;

        serviceFee = (total * SERVICE_COMMISSION_BPS) / COMMISSION_MAX_BPS;
        spPayment = total - serviceFee;

        return (serviceFee, spPayment);
    }

    function _verifyTerminateServiceSignature(address payer, uint256 dataSetId, bytes memory signature)
        internal
        returns (address signer)
    {
        return LibSignatureVerification.verifyTerminateServiceAuthorization(
            payer, dataSetId, dataSetAuthorizer[dataSetId], signature, _domainSeparatorV4(), sessionKeyRegistry
        );
    }

    /**
     * @notice Arbitrates payment based on faults in the given epoch range
     * @dev Implements the IValidator interface function
     *
     * @param railId ID of the payment rail
     * @param proposedAmount The originally proposed payment amount
     * @param fromEpoch Starting epoch (exclusive)
     * @param toEpoch Ending epoch (inclusive)
     * @return result The validation result with modified amount and settlement information
     */
    function validatePayment(
        uint256 railId,
        uint256 proposedAmount,
        uint256 fromEpoch,
        uint256 toEpoch,
        uint256 /* rate */
    )
        external
        view
        override
        returns (ValidationResult memory result)
    {
        // Get the data set ID associated with this rail. A zero here means the rail's data set
        // was abandoned and already torn down by dataSetDeleted -- the only way to release its
        // remaining lockup, since the data set no longer exists to arbitrate proving -- or the
        // rail was never one of ours to begin with. Either way, settle in the payer's favor.
        uint256 dataSetId = railToDataSet[railId];
        if (dataSetId == 0) {
            return
                ValidationResult({modifiedAmount: 0, settleUpto: toEpoch, note: "Rail not associated with a data set"});
        }

        // Calculate the total number of epochs in the requested range
        uint256 totalEpochsRequested = toEpoch - fromEpoch;
        require(totalEpochsRequested > 0, Errors.InvalidEpochRange(fromEpoch, toEpoch));

        // No active proving period covers epochs through the activation boundary. Advance
        // settlement with zero payment so FilecoinPay can discharge pre-activation rate
        // segments, including segments recorded before the first nextProvingPeriod call.
        uint256 activationEpoch = provingActivationEpoch[dataSetId];
        if (activationEpoch == 0 || toEpoch <= activationEpoch) {
            return ValidationResult({modifiedAmount: 0, settleUpto: toEpoch, note: "No proving activity"});
        }

        // Count proven epochs up to toEpoch, possibly stopping earlier if unresolved
        (uint256 provenEpochCount, uint256 settleUpTo) =
            _findProvenEpochs(dataSetId, fromEpoch, toEpoch, activationEpoch);

        // If no epochs are proven, no payment is due (but settlement may still advance)
        if (provenEpochCount == 0) {
            return ValidationResult({
                modifiedAmount: 0, settleUpto: settleUpTo, note: "No proven epochs in the requested range"
            });
        }

        // Calculate the modified amount based on proven epochs
        uint256 modifiedAmount = (proposedAmount * provenEpochCount) / totalEpochsRequested;

        return ValidationResult({modifiedAmount: modifiedAmount, settleUpto: settleUpTo, note: ""});
    }

    /// @dev Counts proven epochs and determines how far settlement can advance.
    ///
    /// Called by validatePayment() to arbitrate how much a provider should be paid for
    /// a given epoch range. Returns two values:
    ///   - provenEpochCount: number of epochs with valid proofs (determines payment)
    ///   - settleUpTo: the epoch up to which settlement can advance (may exceed proven range)
    ///
    /// These are deliberately decoupled: settlement can advance past faulted periods with zero
    /// payment, allowing the rail to eventually be fully settled and finalised even if the
    /// provider missed proofs.
    ///
    /// Iterates through each proving period that overlaps the range (fromEpoch, toEpoch].
    /// Partial periods at the start and end are handled by clamping each period's contribution
    /// to [max(periodStart, fromEpoch), min(toEpoch, deadline)].
    ///
    /// For each period, one of three rules applies:
    ///
    ///   Proven:  Period has a valid proof. Count epochs toward payment, advance settleUpTo.
    ///   Faulted: Deadline has passed with no proof. Advance settleUpTo (zero payment).
    ///   Open:    Deadline has not yet passed. Don't update settleUpTo, blocking settlement
    ///            at wherever the previous period left it. Note: only the last period in
    ///            the range can be open (toEpoch <= block.number guarantees earlier deadlines
    ///            have passed).
    ///
    /// Partial-period requests arise when FilecoinPay settles each rate segment independently
    /// (see _settleWithRateChanges). If the rate changed mid-period (e.g. pieces were added),
    /// toEpoch will fall within a period rather than on a boundary.
    function _findProvenEpochs(uint256 dataSetId, uint256 fromEpoch, uint256 toEpoch, uint256 activationEpoch)
        internal
        view
        returns (uint256 provenEpochCount, uint256 settleUpTo)
    {
        require(toEpoch >= activationEpoch && toEpoch <= block.number, Errors.InvalidEpochRange(fromEpoch, toEpoch));
        if (fromEpoch < activationEpoch) {
            fromEpoch = activationEpoch;
        }
        settleUpTo = fromEpoch;
        uint256 startingPeriod = LibProving.provingPeriodForEpoch(activationEpoch, fromEpoch + 1, maxProvingPeriod);
        uint256 endingPeriod = LibProving.provingPeriodForEpoch(activationEpoch, toEpoch, maxProvingPeriod);
        uint256 deadline = LibProving.calcPeriodDeadline(activationEpoch, startingPeriod, maxProvingPeriod);
        for (uint256 period = startingPeriod; period <= endingPeriod; period++) {
            if (_isPeriodProven(dataSetId, period)) {
                uint256 settleStart = max(deadline - maxProvingPeriod, fromEpoch);
                settleUpTo = min(toEpoch, deadline);
                provenEpochCount += settleUpTo - settleStart;
            } else if (deadline < block.number) {
                // Faulted: deadline passed, no proof, advance with zero payment
                settleUpTo = min(toEpoch, deadline);
            } //else { } // Open: deadline hasn't passed, proof may still arrive, block settlement
            deadline += maxProvingPeriod;
        }

        return (provenEpochCount, settleUpTo);
    }

    function _isPeriodProven(uint256 dataSetId, uint256 periodId) private view returns (bool) {
        uint256 isProven = provenPeriods[dataSetId][periodId >> 8] & (1 << (periodId & 255));
        return isProven != 0;
    }

    function railTerminated(uint256 railId, address terminator, uint256 endEpoch) external override {
        address paymentsContractAddress = IFWSSConfig(address(this)).paymentsContractAddress();
        require(msg.sender == paymentsContractAddress, Errors.CallerNotPayments(paymentsContractAddress, msg.sender));

        if (terminator != address(this)) {
            revert Errors.ServiceContractMustTerminateRail();
        }

        uint256 dataSetId = railToDataSet[railId];
        require(dataSetId != 0, Errors.DataSetNotFoundForRail(railId));
        DataSetInfo storage info = dataSetInfo[dataSetId];
        if (info.pdpEndEpoch == 0 && railId == info.pdpRailId) {
            info.pdpEndEpoch = endEpoch;
            emit PDPPaymentTerminated(dataSetId, endEpoch, info.pdpRailId);
        }
    }
}
