// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {CHALLENGES_PER_PROOF, NO_PROVING_DEADLINE} from "../FilecoinWarmStorageService.sol";
import {Errors} from "../Errors.sol";
import {FilecoinPayV1, IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FWSSPieceMetadataRemovals} from "../abstract/FWSSPieceMetadataRemovals.sol";
import {IFWSSConfig} from "../interfaces/IFWSSConfig.sol";
import {FWSSOwnable} from "../lib/FWSSOwnable.sol";
import {FWSSPDPVerifier} from "../lib/FWSSPDPVerifier.sol";
import {LibProving} from "../lib/LibProving.sol";
import {LibServiceLifecycleGuards} from "../lib/LibServiceLifecycleGuards.sol";
import {LibStoragePayments} from "../lib/LibStoragePayments.sol";

/// @title FWSSProvingModule
/// @notice Records PDP proofs, advances or configures proving periods, and arbitrates PDP rail payments from them.
contract FWSSProvingModule is IValidator, FWSSPieceMetadataRemovals, FWSSOwnable, FWSSPDPVerifier {
    event FaultRecord(uint256 indexed dataSetId, uint256 periodsFaulted, uint256 deadline);

    event PDPPaymentTerminated(uint256 indexed dataSetId, uint256 endEpoch, uint256 pdpRailId);

    uint256 private constant NO_CHALLENGE_SCHEDULED = 0;

    /**
     * @notice Sets new proving period parameters
     * @param _maxProvingPeriod Maximum number of epochs between two consecutive proofs
     * @param _challengeWindowSize Number of epochs for the challenge window
     */
    function configureProvingPeriod(uint64 _maxProvingPeriod, uint256 _challengeWindowSize) external onlyOwner {
        require(_maxProvingPeriod > 0, Errors.MaxProvingPeriodZero());
        require(
            _challengeWindowSize > 0 && _challengeWindowSize < _maxProvingPeriod,
            Errors.InvalidChallengeWindowSize(_maxProvingPeriod, _challengeWindowSize)
        );

        maxProvingPeriod = _maxProvingPeriod;
        challengeWindowSize = _challengeWindowSize;
    }

    // possession proven checks for correct challenge count and reverts if too low
    // it also checks that proofs are not late and emits a fault record if so
    function possessionProven(
        uint256 dataSetId,
        uint256, /*challengedLeafCount*/
        uint256, /*seed*/
        uint256 challengeCount
    )
        external
        onlyPDPVerifier
    {
        LibServiceLifecycleGuards.requirePaymentNotBeyondEndEpoch(dataSetId, dataSetInfo[dataSetId].pdpEndEpoch);

        if (provenThisPeriod[dataSetId]) {
            revert Errors.ProofAlreadySubmitted(dataSetId);
        }

        uint256 expectedChallengeCount = CHALLENGES_PER_PROOF;
        if (challengeCount < expectedChallengeCount) {
            revert Errors.InvalidChallengeCount(dataSetId, expectedChallengeCount, challengeCount);
        }

        if (provingDeadlines[dataSetId] == NO_PROVING_DEADLINE) {
            revert Errors.ProvingNotStarted(dataSetId);
        }

        // check for proof outside of challenge window
        if (provingDeadlines[dataSetId] < block.number) {
            revert Errors.ProvingPeriodPassed(dataSetId, provingDeadlines[dataSetId], block.number);
        }

        uint256 windowStart = provingDeadlines[dataSetId] - challengeWindowSize;
        if (windowStart > block.number) {
            revert Errors.ChallengeWindowTooEarly(dataSetId, windowStart, block.number);
        }
        provenThisPeriod[dataSetId] = true;
        uint256 currentPeriod = getProvingPeriodForEpoch(dataSetId, block.number);
        provenPeriods[dataSetId][currentPeriod >> 8] |= 1 << (currentPeriod & 255);
    }

    // nextProvingPeriod checks for unsubmitted proof in which case it emits a fault event
    // Additionally it enforces constraints on the update of its state:
    // 1. One update per proving period.
    // 2. Next challenge epoch must fall within the challenge window in the last challengeWindow()
    //    epochs of the proving period.
    //
    // In the payment version, it also updates the payment rate based on the current storage size.
    function nextProvingPeriod(uint256 dataSetId, uint256 challengeEpoch, uint256 leafCount, bytes calldata)
        external
        onlyPDPVerifier
    {
        LibServiceLifecycleGuards.requirePaymentNotBeyondEndEpoch(dataSetId, dataSetInfo[dataSetId].pdpEndEpoch);

        DataSetInfo storage info = dataSetInfo[dataSetId];
        uint96 pending = info.pendingOneTimePayments;
        uint96 reserveBalance = info.lifecycleReserveBalance;

        uint256 activationEpoch = provingActivationEpoch[dataSetId];
        if (provingDeadlines[dataSetId] == NO_PROVING_DEADLINE) {
            uint256 firstDeadline;
            if (activationEpoch == 0) {
                // First activation establishes the lifetime proving-period origin.
                activationEpoch = block.number;
                provingActivationEpoch[dataSetId] = activationEpoch;
                firstDeadline = activationEpoch + maxProvingPeriod;
            } else {
                // Reactivation resumes the original timeline, pinned to the earliest deadline with a full
                // period of headroom, keeping the window one period wide.
                require(
                    challengeEpoch > activationEpoch,
                    Errors.InvalidChallengeEpoch(
                        dataSetId, activationEpoch + 1, activationEpoch + maxProvingPeriod, challengeEpoch
                    )
                );
                uint256 minimumDeadline = block.number + maxProvingPeriod;
                uint256 period = LibProving.provingPeriodForEpoch(activationEpoch, minimumDeadline, maxProvingPeriod);
                firstDeadline = LibProving.calcPeriodDeadline(activationEpoch, period, maxProvingPeriod);
            }

            uint256 minWindow = firstDeadline - challengeWindowSize;
            if (challengeEpoch < minWindow || challengeEpoch > firstDeadline) {
                revert Errors.InvalidChallengeEpoch(dataSetId, minWindow, firstDeadline, challengeEpoch);
            }
            provingDeadlines[dataSetId] = firstDeadline;

            // Rate was already set in piecesAdded; only update if pieces were removed or fees are pending
            if (_processScheduledPieceMetadataRemovals(dataSetId) || pending > 0) {
                LibStoragePayments.updatePaymentRates(
                    dataSetId,
                    info,
                    leafCount,
                    pending,
                    reserveBalance,
                    false,
                    FilecoinPayV1(IFWSSConfig(address(this)).paymentsContractAddress())
                );
            }

            return;
        }

        // Revert when proving period not yet open
        // Can only get here if calling nextProvingPeriod multiple times within the same proving period
        uint256 prevDeadline = provingDeadlines[dataSetId] - maxProvingPeriod;
        if (block.number <= prevDeadline) {
            revert Errors.NextProvingPeriodAlreadyCalled(dataSetId, prevDeadline, block.number);
        }

        uint256 periodsSkipped;
        // Proving period is open 0 skipped periods
        if (block.number <= provingDeadlines[dataSetId]) {
            periodsSkipped = 0;
        } else {
            // Proving period has closed possibly some skipped periods
            periodsSkipped = (block.number - (provingDeadlines[dataSetId] + 1)) / maxProvingPeriod;
        }

        uint256 nextDeadline;
        // the data set has become empty and provingDeadline is set inactive
        if (challengeEpoch == NO_CHALLENGE_SCHEDULED) {
            nextDeadline = NO_PROVING_DEADLINE;
        } else {
            nextDeadline = provingDeadlines[dataSetId] + maxProvingPeriod * (periodsSkipped + 1);
            uint256 windowStart = nextDeadline - challengeWindowSize;
            uint256 windowEnd = nextDeadline;

            if (challengeEpoch < windowStart || challengeEpoch > windowEnd) {
                revert Errors.InvalidChallengeEpoch(dataSetId, windowStart, windowEnd, challengeEpoch);
            }
        }
        uint256 faultPeriods = periodsSkipped;
        if (!provenThisPeriod[dataSetId]) {
            // include previous unproven period
            faultPeriods += 1;
        }
        if (faultPeriods > 0) {
            emit FaultRecord(dataSetId, faultPeriods, provingDeadlines[dataSetId]);
        }

        provingDeadlines[dataSetId] = nextDeadline;
        provenThisPeriod[dataSetId] = false;

        // Additions update rate immediately in piecesAdded; update here if pieces were removed or fees are pending
        bool hadRemovals = _processScheduledPieceMetadataRemovals(dataSetId);
        if (hadRemovals || pending > 0) {
            LibStoragePayments.updatePaymentRates(
                dataSetId,
                info,
                leafCount,
                pending,
                reserveBalance,
                false,
                FilecoinPayV1(IFWSSConfig(address(this)).paymentsContractAddress())
            );
        }
    }

    /**
     * @notice Determines which proving period an epoch belongs to
     * @dev For a given epoch, calculates the period ID based on activation time
     * @param dataSetId The ID of the data set
     * @param epoch The epoch to check
     * @return The period ID this epoch belongs to, or type(uint256).max if before activation
     */
    function getProvingPeriodForEpoch(uint256 dataSetId, uint256 epoch) public view returns (uint256) {
        return LibProving.provingPeriodForEpoch(provingActivationEpoch[dataSetId], epoch, maxProvingPeriod);
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
        uint256 provingPeriod = maxProvingPeriod;
        uint256 startingPeriod = LibProving.provingPeriodForEpoch(activationEpoch, fromEpoch + 1, provingPeriod);
        uint256 endingPeriod = LibProving.provingPeriodForEpoch(activationEpoch, toEpoch, provingPeriod);
        uint256 deadline = LibProving.calcPeriodDeadline(activationEpoch, startingPeriod, provingPeriod);
        for (uint256 period = startingPeriod; period <= endingPeriod; period++) {
            if (_isPeriodProven(dataSetId, period)) {
                uint256 settleStart = Math.max(deadline - provingPeriod, fromEpoch);
                settleUpTo = Math.min(toEpoch, deadline);
                provenEpochCount += settleUpTo - settleStart;
            } else if (deadline < block.number) {
                // Faulted: deadline passed, no proof, advance with zero payment
                settleUpTo = Math.min(toEpoch, deadline);
            } //else { } // Open: deadline hasn't passed, proof may still arrive, block settlement
            deadline += provingPeriod;
        }

        return (provenEpochCount, settleUpTo);
    }

    function _isPeriodProven(uint256 dataSetId, uint256 periodId) private view returns (bool) {
        uint256 isProven = provenPeriods[dataSetId][periodId >> 8] & (1 << (periodId & 255));
        return isProven != 0;
    }
}
