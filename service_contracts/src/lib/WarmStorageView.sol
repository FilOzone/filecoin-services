// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";
import "../FilecoinWarmStorageService.sol";
import "./FilecoinWarmStorageServiceLayout.sol";

library WarmStorageView {
    function getString(FilecoinWarmStorageService service, bytes32 loc) internal view returns (string memory str) {
        uint256 compressed = uint256(service.extsload(loc));
        if (compressed & 1 != 0) {
            uint256 length = compressed >> 1;
            str = new string(length);
            assembly ("memory-safe") {
                let fmp := mload(0x40)

                mstore(0, loc)
                loc := keccak256(0, 32)

                // extsloadStruct
                mstore(0, 0x5379a43500000000000000000000000000000000000000000000000000000000)
                mstore(4, loc)
                mstore(36, shr(5, add(31, length)))
                pop(staticcall(gas(), service, 0, 68, 0, 0))
                returndatacopy(add(32, str), 64, length)

                mstore(0x40, fmp)
            }
        } else {
            // len < 32
            str = new string(compressed >> 1 & 31);
            assembly ("memory-safe") {
                mstore(add(32, str), compressed)
            }
        }
    }

    // --- Public getter functions ---

    /**
     * @notice Get the total size of a data set in bytes
     * @param leafCount Number of leaves in the data set
     * @return totalBytes Total size in bytes
     */
    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256) {
        return leafCount * BYTES_PER_LEAF;
    }

    function clientDataSetIDs(FilecoinWarmStorageService service, address payer) public view returns (uint256) {
        return uint256(service.extsload(keccak256(abi.encode(payer, CLIENT_DATA_SET_IDS_SLOT))));
    }

    function getPieceMetadata(FilecoinWarmStorageService service, uint256 dataSetId, uint256 pieceId)
        public
        view
        returns (string memory)
    {
        return getString(
            service, keccak256(abi.encode(pieceId, keccak256(abi.encode(dataSetId, DATA_SET_PIECE_METADATA_SLOT))))
        );
    }

    function provenThisPeriod(FilecoinWarmStorageService service, uint256 dataSetId) public view returns (bool) {
        return service.extsload(keccak256(abi.encode(dataSetId, PROVEN_THIS_PERIOD_SLOT))) != bytes32(0);
    }

    function clientDataSets(FilecoinWarmStorageService service, address payer)
        public
        view
        returns (uint256[] memory dataSetIds)
    {
        bytes32 slot = keccak256(abi.encode(payer, CLIENT_DATA_SETS_SLOT));
        uint256 length = uint256(service.extsload(slot));
        bytes32[] memory result = service.extsloadStruct(keccak256(abi.encode(slot)), length);
        assembly ("memory-safe") {
            dataSetIds := result
        }
    }

    function railToDataSet(FilecoinWarmStorageService service, uint256 railId) public view returns (uint256) {
        return uint256(service.extsload(keccak256(abi.encode(railId, RAIL_TO_DATA_SET_SLOT))));
    }

    function provenPeriods(FilecoinWarmStorageService service, uint256 dataSetId, uint256 periodId)
        public
        view
        returns (bool)
    {
        return service.extsload(keccak256(abi.encode(periodId, keccak256(abi.encode(dataSetId, PROVEN_PERIODS_SLOT)))))
            != bytes32(0);
    }

    function provingActivationEpoch(FilecoinWarmStorageService service, uint256 dataSetId)
        public
        view
        returns (uint256)
    {
        return uint256(service.extsload(keccak256(abi.encode(dataSetId, PROVING_ACTIVATION_EPOCH_SLOT))));
    }

    function provingDeadlines(FilecoinWarmStorageService service, uint256 setId) public view returns (uint256) {
        return uint256(service.extsload(keccak256(abi.encode(setId, PROVING_DEADLINES_SLOT))));
    }

    function getMaxProvingPeriod(FilecoinWarmStorageService service) public view returns (uint64) {
        return uint64(uint256(service.extsload(MAX_PROVING_PERIOD_SLOT)));
    }

    // Number of epochs at the end of a proving period during which a
    // proof of possession can be submitted
    function challengeWindow(FilecoinWarmStorageService service) public view returns (uint256) {
        return uint256(service.extsload(CHALLENGE_WINDOW_SIZE_SLOT));
    }

    // Initial value for challenge window start
    // Can be used for first call to nextProvingPeriod
    function initChallengeWindowStart(FilecoinWarmStorageService service) public view returns (uint256) {
        return block.number + getMaxProvingPeriod(service) - challengeWindow(service);
    }

    // The start of the challenge window for the current proving period
    function thisChallengeWindowStart(FilecoinWarmStorageService service, uint256 setId)
        public
        view
        returns (uint256)
    {
        if (provingDeadlines(service, setId) == NO_PROVING_DEADLINE) {
            revert Errors.ProvingPeriodNotInitialized(setId);
        }

        uint256 periodsSkipped;
        // Proving period is open 0 skipped periods
        if (block.number <= provingDeadlines(service, setId)) {
            periodsSkipped = 0;
        } else {
            // Proving period has closed possibly some skipped periods
            periodsSkipped = 1 + (block.number - (provingDeadlines(service, setId) + 1)) / getMaxProvingPeriod(service);
        }
        return
            provingDeadlines(service, setId) + periodsSkipped * getMaxProvingPeriod(service) - challengeWindow(service);
    }

    // The start of the NEXT OPEN proving period's challenge window
    // Useful for querying before nextProvingPeriod to determine challengeEpoch to submit for nextProvingPeriod
    function nextChallengeWindowStart(FilecoinWarmStorageService service, uint256 setId)
        external
        view
        returns (uint256)
    {
        if (provingDeadlines(service, setId) == NO_PROVING_DEADLINE) {
            revert Errors.ProvingPeriodNotInitialized(setId);
        }
        // If the current period is open this is the next period's challenge window
        if (block.number <= provingDeadlines(service, setId)) {
            return thisChallengeWindowStart(service, setId) + getMaxProvingPeriod(service);
        }
        // If the current period is not yet open this is the current period's challenge window
        return thisChallengeWindowStart(service, setId);
    }
}
