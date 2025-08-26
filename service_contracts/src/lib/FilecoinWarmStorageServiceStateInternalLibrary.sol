// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

// Generated with 'make src/lib/FilecoinWarmStorageServiceStateInternalLibrary.sol'

import {Errors} from "../Errors.sol";
import "../FilecoinWarmStorageService.sol";
import "./FilecoinWarmStorageServiceLayout.sol";

// bytes32(bytes4(keccak256(abi.encodePacked("extsloadStruct(bytes32,uint256)"))));
bytes32 constant EXTSLOAD_STRUCT_SELECTOR = 0x5379a43500000000000000000000000000000000000000000000000000000000;

library FilecoinWarmStorageServiceStateInternalLibrary {
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
                mstore(0, EXTSLOAD_STRUCT_SELECTOR)
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

    function getStringArray(FilecoinWarmStorageService service, bytes32 loc)
        internal
        view
        returns (string[] memory strings)
    {
        uint256 length = uint256(service.extsload(loc));
        loc = keccak256(abi.encode(loc));
        strings = new string[](length);
        for (uint256 i = 0; i < length; i++) {
            strings[i] = getString(service, loc);
            assembly ("memory-safe") {
                loc := add(1, loc)
            }
        }
    }

    // --- Public getter functions ---

    /**
     * @notice Get the total size of a data set in bytes
     * @param leafCount Number of leaves in the data set
     * @return totalBytes Total size in bytes
     */
    function getDataSetSizeInBytes(uint256 leafCount) internal pure returns (uint256) {
        return leafCount * BYTES_PER_LEAF;
    }

    function getChallengesPerProof() internal pure returns (uint64) {
        return CHALLENGES_PER_PROOF;
    }

    function clientDataSetIDs(FilecoinWarmStorageService service, address payer) internal view returns (uint256) {
        return uint256(service.extsload(keccak256(abi.encode(payer, CLIENT_DATA_SET_IDS_SLOT))));
    }

    function provenThisPeriod(FilecoinWarmStorageService service, uint256 dataSetId) internal view returns (bool) {
        return service.extsload(keccak256(abi.encode(dataSetId, PROVEN_THIS_PERIOD_SLOT))) != bytes32(0);
    }

    /**
     * @notice Get data set information by ID
     * @param dataSetId The ID of the data set
     * @return info The data set information struct
     */
    function getDataSet(FilecoinWarmStorageService service, uint256 dataSetId)
        internal
        view
        returns (FilecoinWarmStorageService.DataSetInfo memory info)
    {
        bytes32 slot = keccak256(abi.encode(dataSetId, DATA_SET_INFO_SLOT));
        bytes32[] memory info9 = service.extsloadStruct(slot, 9);
        info.pdpRailId = uint256(info9[0]);
        info.cacheMissRailId = uint256(info9[1]);
        info.cdnRailId = uint256(info9[2]);
        info.payer = address(uint160(uint256(info9[3])));
        info.owner = address(uint160(uint256(info9[4])));
        info.payee = address(uint160(uint256(info9[5])));
        info.commissionBps = uint256(info9[6]);
        info.clientDataSetId = uint256(info9[7]);
        info.paymentEndEpoch = uint256(info9[8]);
    }

    function clientDataSets(FilecoinWarmStorageService service, address payer)
        internal
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

    function railToDataSet(FilecoinWarmStorageService service, uint256 railId) internal view returns (uint256) {
        return uint256(service.extsload(keccak256(abi.encode(railId, RAIL_TO_DATA_SET_SLOT))));
    }

    function provenPeriods(FilecoinWarmStorageService service, uint256 dataSetId, uint256 periodId)
        internal
        view
        returns (bool)
    {
        return service.extsload(keccak256(abi.encode(periodId, keccak256(abi.encode(dataSetId, PROVEN_PERIODS_SLOT)))))
            != bytes32(0);
    }

    function provingActivationEpoch(FilecoinWarmStorageService service, uint256 dataSetId)
        internal
        view
        returns (uint256)
    {
        return uint256(service.extsload(keccak256(abi.encode(dataSetId, PROVING_ACTIVATION_EPOCH_SLOT))));
    }

    function provingDeadlines(FilecoinWarmStorageService service, uint256 setId) internal view returns (uint256) {
        return uint256(service.extsload(keccak256(abi.encode(setId, PROVING_DEADLINES_SLOT))));
    }

    function getMaxProvingPeriod(FilecoinWarmStorageService service) internal view returns (uint64) {
        return uint64(uint256(service.extsload(MAX_PROVING_PERIOD_SLOT)));
    }

    // Number of epochs at the end of a proving period during which a
    // proof of possession can be submitted
    function challengeWindow(FilecoinWarmStorageService service) internal view returns (uint256) {
        return uint256(service.extsload(CHALLENGE_WINDOW_SIZE_SLOT));
    }

    // Initial value for challenge window start
    // Can be used for first call to nextProvingPeriod
    function initChallengeWindowStart(FilecoinWarmStorageService service) internal view returns (uint256) {
        return block.number + getMaxProvingPeriod(service) - challengeWindow(service);
    }

    // The start of the challenge window for the current proving period
    function thisChallengeWindowStart(FilecoinWarmStorageService service, uint256 setId)
        internal
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
        internal
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

    function getClientDataSets(FilecoinWarmStorageService service, address client)
        internal
        view
        returns (FilecoinWarmStorageService.DataSetInfo[] memory infos)
    {
        uint256[] memory dataSetIds = clientDataSets(service, client);

        infos = new FilecoinWarmStorageService.DataSetInfo[](dataSetIds.length);
        for (uint256 i = 0; i < dataSetIds.length; i++) {
            infos[i] = getDataSet(service, dataSetIds[i]);
        }
    }

    /**
     * @notice Get metadata value for a specific key in a data set
     * @param dataSetId The ID of the data set
     * @param key The metadata key
     * @return value The metadata value
     */
    function getDataSetMetadata(FilecoinWarmStorageService service, uint256 dataSetId, string memory key)
        internal
        view
        returns (string memory)
    {
        // For nested mapping with string key: mapping(uint256 => mapping(string => string))
        bytes32 firstLevel = keccak256(abi.encode(dataSetId, DATA_SET_METADATA_SLOT));
        bytes32 slot = keccak256(abi.encodePacked(bytes(key), firstLevel));
        return getString(service, slot);
    }

    /**
     * @notice Get all metadata key-value pairs for a data set
     * @param dataSetId The ID of the data set
     * @return keys Array of metadata keys
     * @return values Array of metadata values
     */
    function getAllDataSetMetadata(FilecoinWarmStorageService service, uint256 dataSetId)
        internal
        view
        returns (string[] memory keys, string[] memory values)
    {
        keys = getStringArray(service, keccak256(abi.encode(dataSetId, DATA_SET_METADATA_KEYS_SLOT)));
        values = new string[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = getDataSetMetadata(service, dataSetId, keys[i]);
        }
    }

    /**
     * @notice Get metadata value for a specific key in a piece
     * @param dataSetId The ID of the data set
     * @param pieceId The ID of the piece
     * @param key The metadata key
     * @return value The metadata value
     */
    function getPieceMetadata(FilecoinWarmStorageService service, uint256 dataSetId, uint256 pieceId, string memory key)
        internal
        view
        returns (string memory)
    {
        // For triple nested mapping: mapping(uint256 => mapping(uint256 => mapping(string => string)))
        bytes32 firstLevel = keccak256(abi.encode(dataSetId, DATA_SET_PIECE_METADATA_SLOT));
        bytes32 secondLevel = keccak256(abi.encode(pieceId, firstLevel));
        bytes32 slot = keccak256(abi.encodePacked(bytes(key), secondLevel));
        return getString(service, slot);
    }

    /**
     * @notice Get all metadata key-value pairs for a piece
     * @param dataSetId The ID of the data set
     * @param pieceId The ID of the piece
     * @return keys Array of metadata keys
     * @return values Array of metadata values
     */
    function getAllPieceMetadata(FilecoinWarmStorageService service, uint256 dataSetId, uint256 pieceId)
        internal
        view
        returns (string[] memory keys, string[] memory values)
    {
        keys = getStringArray(
            service, keccak256(abi.encode(pieceId, keccak256(abi.encode(dataSetId, DATA_SET_PIECE_METADATA_KEYS_SLOT))))
        );
        values = new string[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = getPieceMetadata(service, dataSetId, pieceId, keys[i]);
        }
    }
}
