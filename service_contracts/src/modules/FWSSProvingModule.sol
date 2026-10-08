// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {CHALLENGES_PER_PROOF, NO_PROVING_DEADLINE} from "../FilecoinWarmStorageService.sol";
import {Errors} from "../Errors.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {FWSSPieceMetadataRemovals} from "../abstract/FWSSPieceMetadataRemovals.sol";
import {IFWSSConfig} from "../interfaces/IFWSSConfig.sol";
import {FWSSOwnable} from "../lib/FWSSOwnable.sol";
import {FWSSPDPVerifier} from "../lib/FWSSPDPVerifier.sol";
import {LibProving} from "../lib/LibProving.sol";
import {LibServiceLifecycleGuards} from "../lib/LibServiceLifecycleGuards.sol";
import {LibStoragePayments} from "../lib/LibStoragePayments.sol";

/// @title FWSSProvingModule
/// @notice Records PDP proofs and advances or configures proving periods.
contract FWSSProvingModule is FWSSPieceMetadataRemovals, FWSSOwnable, FWSSPDPVerifier {
    event FaultRecord(uint256 indexed dataSetId, uint256 periodsFaulted, uint256 deadline);

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
}
