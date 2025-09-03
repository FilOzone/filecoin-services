// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {Errors} from "../Errors.sol";
import "../FilecoinWarmStorageService.sol";
import "./FilecoinWarmStorageServiceLayout.sol";

// bytes32(bytes4(keccak256(abi.encodePacked("extsloadStruct(bytes32,uint256)"))));
bytes32 constant EXTSLOAD_STRUCT_SELECTOR = 0x5379a43500000000000000000000000000000000000000000000000000000000;

library FilecoinWarmStorageServiceStateLibrary {
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
    function getDataSetSizeInBytes(uint256 leafCount) public pure returns (uint256) {
        return leafCount * BYTES_PER_LEAF;
    }

    function getChallengesPerProof() public pure returns (uint64) {
        return CHALLENGES_PER_PROOF;
    }

    function clientDataSetIDs(FilecoinWarmStorageService service, address payer) public view returns (uint256) {
        return uint256(service.extsload(keccak256(abi.encode(payer, CLIENT_DATA_SET_IDS_SLOT))));
    }

    function provenThisPeriod(FilecoinWarmStorageService service, uint256 dataSetId) public view returns (bool) {
        return service.extsload(keccak256(abi.encode(dataSetId, PROVEN_THIS_PERIOD_SLOT))) != bytes32(0);
    }

    /**
     * @notice Get data set information by ID
     * @param dataSetId The ID of the data set
     * @return info The data set information struct
     */
    function getDataSet(FilecoinWarmStorageService service, uint256 dataSetId)
        public
        view
        returns (FilecoinWarmStorageService.DataSetInfo memory info)
    {
        bytes32 slot = keccak256(abi.encode(dataSetId, DATA_SET_INFO_SLOT));
        bytes32[] memory info9 = service.extsloadStruct(slot, 10);
        info.pdpRailId = uint256(info9[0]);
        info.cacheMissRailId = uint256(info9[1]);
        info.cdnRailId = uint256(info9[2]);
        info.payer = address(uint160(uint256(info9[3])));
        info.payee = address(uint160(uint256(info9[4])));
        info.commissionBps = uint256(info9[5]);
        info.clientDataSetId = uint256(info9[6]);
        info.pdpEndEpoch = uint256(info9[7]);
        info.providerId = uint256(info9[8]);
        info.cdnEndEpoch = uint256(info9[9]);
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

    function provingDeadline(FilecoinWarmStorageService service, uint256 setId) public view returns (uint256) {
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

    /**
     * @notice Returns PDP configuration values
     * @param service The service contract
     * @return maxProvingPeriod Maximum number of epochs between proofs
     * @return challengeWindowSize Number of epochs for the challenge window
     * @return challengesPerProof Number of challenges required per proof
     * @return initChallengeWindowStart Initial challenge window start for new data sets assuming proving period starts now
     */
    function getPDPConfig(FilecoinWarmStorageService service)
        public
        view
        returns (
            uint64 maxProvingPeriod,
            uint256 challengeWindowSize,
            uint256 challengesPerProof,
            uint256 initChallengeWindowStart
        )
    {
        maxProvingPeriod = getMaxProvingPeriod(service);
        challengeWindowSize = challengeWindow(service);
        challengesPerProof = CHALLENGES_PER_PROOF;
        initChallengeWindowStart = block.number + maxProvingPeriod - challengeWindowSize;
    }

    /**
     * @notice Returns the start of the next challenge window for a data set
     * @param service The service contract
     * @param setId The ID of the data set
     * @return The block number when the next challenge window starts
     */
    function nextPDPChallengeWindowStart(FilecoinWarmStorageService service, uint256 setId)
        public
        view
        returns (uint256)
    {
        uint256 deadline = provingDeadline(service, setId);

        if (deadline == NO_PROVING_DEADLINE) {
            revert Errors.ProvingPeriodNotInitialized(setId);
        }

        uint64 maxProvingPeriod = getMaxProvingPeriod(service);

        // If the current period is open this is the next period's challenge window
        if (block.number <= deadline) {
            return _thisChallengeWindowStart(service, setId) + maxProvingPeriod;
        }

        // Otherwise return the current period's challenge window
        return _thisChallengeWindowStart(service, setId);
    }

    /**
     * @notice Helper to get the start of the current challenge window
     * @param service The service contract
     * @param setId The ID of the data set
     * @return The block number when the current challenge window starts
     */
    function _thisChallengeWindowStart(FilecoinWarmStorageService service, uint256 setId)
        internal
        view
        returns (uint256)
    {
        uint256 deadline = provingDeadline(service, setId);
        uint64 maxProvingPeriod = getMaxProvingPeriod(service);
        uint256 challengeWindowSize = challengeWindow(service);

        uint256 periodsSkipped;
        // Proving period is open 0 skipped periods
        if (block.number <= deadline) {
            periodsSkipped = 0;
        } else {
            // Proving period has closed possibly some skipped periods
            periodsSkipped = 1 + (block.number - (deadline + 1)) / maxProvingPeriod;
        }
        return deadline + periodsSkipped * maxProvingPeriod - challengeWindowSize;
    }

    /**
     * @dev To determine termination status: check if paymentEndEpoch != 0.
     * If paymentEndEpoch > 0, the rails have already been terminated.
     * @dev To determine deletion status: deleted datasets don't appear in
     * getClientDataSets() anymore - they are completely removed.
     */
    function getClientDataSets(FilecoinWarmStorageService service, address client)
        public
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
     * @notice Internal helper to get metadata value without existence check
     * @param service The service contract
     * @param dataSetId The ID of the data set
     * @param key The metadata key
     * @return value The metadata value
     */
    function _getDataSetMetadataValue(FilecoinWarmStorageService service, uint256 dataSetId, string memory key)
        internal
        view
        returns (string memory value)
    {
        // For nested mapping with string key: mapping(uint256 => mapping(string => string))
        bytes32 firstLevel = keccak256(abi.encode(dataSetId, DATA_SET_METADATA_SLOT));
        bytes32 slot = keccak256(abi.encodePacked(bytes(key), firstLevel));
        return getString(service, slot);
    }

    /**
     * @notice Get metadata value for a specific key in a data set
     * @param dataSetId The ID of the data set
     * @param key The metadata key
     * @return exists True if the key exists
     * @return value The metadata value
     */
    function getDataSetMetadata(FilecoinWarmStorageService service, uint256 dataSetId, string memory key)
        public
        view
        returns (bool exists, string memory value)
    {
        // Check if key exists in the keys array
        string[] memory keys = getStringArray(service, keccak256(abi.encode(dataSetId, DATA_SET_METADATA_KEYS_SLOT)));

        bytes memory keyBytes = bytes(key);
        uint256 keyLength = keyBytes.length;
        bytes32 keyHash = keccak256(keyBytes);

        for (uint256 i = 0; i < keys.length; i++) {
            bytes memory currentKeyBytes = bytes(keys[i]);
            if (currentKeyBytes.length == keyLength && keccak256(currentKeyBytes) == keyHash) {
                exists = true;
                value = _getDataSetMetadataValue(service, dataSetId, key);
                break;
            }
        }
    }

    /**
     * @notice Get all metadata key-value pairs for a data set
     * @param dataSetId The ID of the data set
     * @return keys Array of metadata keys
     * @return values Array of metadata values
     */
    function getAllDataSetMetadata(FilecoinWarmStorageService service, uint256 dataSetId)
        public
        view
        returns (string[] memory keys, string[] memory values)
    {
        keys = getStringArray(service, keccak256(abi.encode(dataSetId, DATA_SET_METADATA_KEYS_SLOT)));
        values = new string[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = _getDataSetMetadataValue(service, dataSetId, keys[i]);
        }
    }

    /**
     * @notice Internal helper to get piece metadata value without existence check
     * @param service The service contract
     * @param dataSetId The ID of the data set
     * @param pieceId The ID of the piece
     * @param key The metadata key
     * @return value The metadata value
     */
    function _getPieceMetadataValue(
        FilecoinWarmStorageService service,
        uint256 dataSetId,
        uint256 pieceId,
        string memory key
    ) internal view returns (string memory value) {
        // For triple nested mapping: mapping(uint256 => mapping(uint256 => mapping(string => string)))
        bytes32 firstLevel = keccak256(abi.encode(dataSetId, DATA_SET_PIECE_METADATA_SLOT));
        bytes32 secondLevel = keccak256(abi.encode(pieceId, firstLevel));
        bytes32 slot = keccak256(abi.encodePacked(bytes(key), secondLevel));
        return getString(service, slot);
    }

    /**
     * @notice Get metadata value for a specific key in a piece
     * @param dataSetId The ID of the data set
     * @param pieceId The ID of the piece
     * @param key The metadata key
     * @return exists True if the key exists
     * @return value The metadata value
     */
    function getPieceMetadata(FilecoinWarmStorageService service, uint256 dataSetId, uint256 pieceId, string memory key)
        public
        view
        returns (bool exists, string memory value)
    {
        // Check if key exists in the keys array
        string[] memory keys = getStringArray(
            service, keccak256(abi.encode(pieceId, keccak256(abi.encode(dataSetId, DATA_SET_PIECE_METADATA_KEYS_SLOT))))
        );

        bytes memory keyBytes = bytes(key);
        uint256 keyLength = keyBytes.length;
        bytes32 keyHash = keccak256(keyBytes);

        for (uint256 i = 0; i < keys.length; i++) {
            bytes memory currentKeyBytes = bytes(keys[i]);
            if (currentKeyBytes.length == keyLength && keccak256(currentKeyBytes) == keyHash) {
                exists = true;
                value = _getPieceMetadataValue(service, dataSetId, pieceId, key);
                break;
            }
        }
    }

    /**
     * @notice Get all metadata key-value pairs for a piece
     * @param dataSetId The ID of the data set
     * @param pieceId The ID of the piece
     * @return keys Array of metadata keys
     * @return values Array of metadata values
     */
    function getAllPieceMetadata(FilecoinWarmStorageService service, uint256 dataSetId, uint256 pieceId)
        public
        view
        returns (string[] memory keys, string[] memory values)
    {
        keys = getStringArray(
            service, keccak256(abi.encode(pieceId, keccak256(abi.encode(dataSetId, DATA_SET_PIECE_METADATA_KEYS_SLOT))))
        );
        values = new string[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = _getPieceMetadataValue(service, dataSetId, pieceId, keys[i]);
        }
    }

    /**
     * @notice Check if a provider is approved
     * @param service The service contract
     * @param providerId The ID of the provider to check
     * @return Whether the provider is approved
     */
    function isProviderApproved(FilecoinWarmStorageService service, uint256 providerId) public view returns (bool) {
        return service.extsload(keccak256(abi.encode(providerId, APPROVED_PROVIDERS_SLOT))) != bytes32(0);
    }

    /**
     * @notice Get all approved provider IDs
     * @param service The service contract
     * @return providerIds Array of all approved provider IDs
     */
    function getApprovedProviders(FilecoinWarmStorageService service)
        public
        view
        returns (uint256[] memory providerIds)
    {
        bytes32 slot = APPROVED_PROVIDER_IDS_SLOT;
        uint256 length = uint256(service.extsload(slot));

        if (length == 0) {
            return new uint256[](0);
        }

        bytes32[] memory result = service.extsloadStruct(keccak256(abi.encode(slot)), length);
        assembly ("memory-safe") {
            providerIds := result
        }
    }

    /**
     * @notice Get the FIL CDN Controller address
     * @param service The service contract
     * @return The FIL CDN Controller address
     */
    function filCDNControllerAddress(FilecoinWarmStorageService service) public view returns (address) {
        return address(uint160(uint256(service.extsload(FIL_CDN_CONTROLLER_ADDRESS_SLOT))));
    }
}
