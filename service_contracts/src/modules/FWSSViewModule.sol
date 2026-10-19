// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

// Code generated - DO NOT EDIT.
// This file is a generated binding and any changes will be lost.
// Generated with tools/generate_view_module.sh

import {Cids} from "@pdp/Cids.sol";
import {Errors} from "../Errors.sol";
import {CHALLENGES_PER_PROOF, NO_PROVING_DEADLINE} from "../lib/FWSSConstants.sol";
import {DataSetInfoView, DataSetStatus} from "../lib/FWSSViewTypes.sol";
import {
    DATASET_FEE_PER_MONTH,
    SERVICE_COMMISSION_BPS,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    priceList
} from "../lib/PriceListUSDFC.sol";
import {PriceList} from "../lib/PriceList.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPDPProvingSchedule} from "@pdp/IPDPProvingSchedule.sol";
import "../lib/FilecoinWarmStorageServiceLayout.sol" as StorageLayout;

/// @title FWSSViewModule
/// @notice Exposes FilecoinWarmStorageServiceStateLibrary getters at the FWSS proxy.
contract FWSSViewModule is IPDPProvingSchedule {
    IERC20 internal immutable usdfcTokenAddress;

    /// @param _usdfc The USDFC token reported by getPriceList.
    constructor(IERC20 _usdfc) {
        require(_usdfc != IERC20(address(0)), Errors.ZeroAddress(Errors.AddressField.USDFC));
        usdfcTokenAddress = _usdfc;
    }

    function sload(bytes32 slot) internal view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function sloadStruct(bytes32 slot, uint256 size) internal view returns (bytes32[] memory values) {
        values = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            values[i] = sload(bytes32(uint256(slot) + i));
        }
    }

    function getString(bytes32 loc) internal pure returns (string memory) {
        string storage str;
        assembly ("memory-safe") {
            str.slot := loc
        }
        return str;
    }

    function getStringArray(bytes32 loc) internal view returns (string[] memory strings) {
        uint256 length = uint256(sload(loc));
        loc = keccak256(abi.encode(loc));
        strings = new string[](length);
        for (uint256 i = 0; i < length; i++) {
            strings[i] = getString(loc);
            assembly ("memory-safe") {
                loc := add(1, loc)
            }
        }
    }

    // --- Public getter functions ---

    /**
     * @notice Approximate raw (pre-Fr32-expansion) data set size in bytes.
     * @custom:deprecated Use Cids.leafCountToRawSize directly. Will be removed in a future release.
     * @dev Overestimates by up to 31 bytes per piece. See leafCountToRawSize in the pdp Cids
     *      library (lib/pdp/src/Cids.sol) for derivation.
     * @param leafCount Sum of data-bearing leaves currently recorded in the data set
     *      (PDPVerifier.getDataSetLeafCount). Decreases only when nextProvingPeriod
     *      processes scheduled removals.
     * @return totalBytes Approximate raw byte size
     */
    function getDataSetSizeInBytes(uint256 leafCount) public pure returns (uint256) {
        return Cids.leafCountToRawSize(leafCount);
    }

    function clientNonces(address payer, uint256 nonce) public view returns (uint256) {
        return
            uint256(sload(keccak256(abi.encode(nonce, keccak256(abi.encode(payer, StorageLayout.CLIENT_NONCES_SLOT))))));
    }

    function provenThisPeriod(uint256 dataSetId) public view returns (bool) {
        return sload(keccak256(abi.encode(dataSetId, StorageLayout.PROVEN_THIS_PERIOD_SLOT))) != bytes32(0);
    }

    function hasBeenProvenRecently(uint256 dataSetId) public view returns (bool) {
        uint256 activation = provingActivationEpoch(dataSetId);
        if (activation == 0 || block.number <= activation) {
            return false;
        }
        uint256 maxPeriod = getMaxProvingPeriod();
        uint256 currentPeriod = (block.number - activation - 1) / maxPeriod;
        if (currentPeriod >= 1 && provenPeriods(dataSetId, currentPeriod - 1)) {
            return true;
        }
        return provenThisPeriod(dataSetId);
    }

    /**
     * @notice Get data set information by ID
     * @param dataSetId The ID of the data set
     * @return info The data set information struct
     */
    function getDataSet(uint256 dataSetId) public view returns (DataSetInfoView memory info) {
        bytes32 slot = keccak256(abi.encode(dataSetId, StorageLayout.DATA_SET_INFO_SLOT));
        bytes32[] memory info11 = sloadStruct(slot, 11);
        info.pdpRailId = uint256(info11[0]);
        info.cacheMissRailId = uint256(info11[1]);
        info.cdnRailId = uint256(info11[2]);
        info.payer = address(uint160(uint256(info11[3])));
        info.payee = address(uint160(uint256(info11[4])));
        info.serviceProvider = address(uint160(uint256(info11[5])));
        info.commissionBps = uint256(info11[6]);
        info.clientDataSetId = uint256(info11[7]);
        info.pdpEndEpoch = uint256(info11[8]);
        info.providerId = uint256(info11[9]);
        info.pendingOneTimePayments = uint96(uint256(info11[10]));
        info.lifecycleReserveBalance = uint96(uint256(info11[10]) >> 96);
        info.dataSetId = dataSetId;
    }

    // TODO: measure whether loading 4 slots in one extsloadStruct call is cheaper than two
    // separate extsload calls for slots 0 (pdpRailId) and 3 (payer) on Filecoin.
    function getDataSetPayerAndRailId(uint256 dataSetId) public view returns (address payer, uint256 pdpRailId) {
        bytes32 slot = keccak256(abi.encode(dataSetId, StorageLayout.DATA_SET_INFO_SLOT));
        bytes32[] memory info4 = sloadStruct(slot, 4);
        pdpRailId = uint256(info4[0]);
        payer = address(uint160(uint256(info4[3])));
    }

    /**
     * @notice Get the current status of a dataset
     * @dev A dataset is Active when it has pieces and proving history (including terminated datasets)
     * @dev A dataset is Inactive when: non-existent or no pieces added yet
     * @param dataSetId The ID of the dataset
     * @return status The current status
     */
    function getDataSetStatus(uint256 dataSetId) public view returns (DataSetStatus status) {
        DataSetInfoView memory info = getDataSet(dataSetId);

        // Non-existent datasets are inactive
        if (info.pdpRailId == 0) {
            return DataSetStatus.Inactive;
        }

        // Check if proving is activated (has pieces)
        // Inactive only if no proving has started, everything else is Active
        uint256 activationEpoch = provingActivationEpoch(dataSetId);
        if (activationEpoch == 0) {
            return DataSetStatus.Inactive;
        }

        return DataSetStatus.Active;
    }

    function clientDataSets(address payer) public view returns (uint256[] memory dataSetIds) {
        bytes32 slot = keccak256(abi.encode(payer, StorageLayout.CLIENT_DATA_SETS_SLOT));
        uint256 length = uint256(sload(slot));
        bytes32[] memory result = sloadStruct(keccak256(abi.encode(slot)), length);
        assembly ("memory-safe") {
            dataSetIds := result
        }
    }

    /**
     * @notice Get client data set IDs with optional pagination
     * @param payer The client address
     * @param offset Starting index (0-based). Use 0 to start from beginning
     * @param limit Maximum number of data set IDs to return. Use 0 to get all remaining
     * @return dataSetIds Array of data set IDs
     * @dev For large lists, use pagination to avoid gas limit issues. If limit=0,
     * returns all remaining data sets starting from offset. Example:
     * clientDataSets(payer, 0, 100) gets first 100 data set IDs.
     */
    function clientDataSets(address payer, uint256 offset, uint256 limit)
        public
        view
        returns (uint256[] memory dataSetIds)
    {
        bytes32 slot = keccak256(abi.encode(payer, StorageLayout.CLIENT_DATA_SETS_SLOT));
        uint256 totalLength = uint256(sload(slot));

        if (totalLength == 0 || offset >= totalLength) {
            return new uint256[](0);
        }

        uint256 remaining = totalLength - offset;
        uint256 actualLength = (limit == 0 || limit > remaining) ? remaining : limit;

        bytes32 baseSlot = keccak256(abi.encode(slot));
        bytes32 startSlot = bytes32(uint256(baseSlot) + offset);
        bytes32[] memory paginatedResult = sloadStruct(startSlot, actualLength);

        assembly ("memory-safe") {
            dataSetIds := paginatedResult
        }
    }

    /**
     * @notice Get the total number of data sets for a client
     * @param payer The client address
     * @return count Total number of data sets
     */
    function getClientDataSetsLength(address payer) public view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(payer, StorageLayout.CLIENT_DATA_SETS_SLOT));
        return uint256(sload(slot));
    }

    function railToDataSet(uint256 railId) public view returns (uint256) {
        return uint256(sload(keccak256(abi.encode(railId, StorageLayout.RAIL_TO_DATA_SET_SLOT))));
    }

    function getDataSetAuthorizer(uint256 dataSetId) public view returns (address) {
        return
            address(uint160(uint256(sload(keccak256(abi.encode(dataSetId, StorageLayout.DATA_SET_AUTHORIZER_SLOT))))));
    }

    function provenPeriods(uint256 dataSetId, uint256 periodId) public view returns (bool) {
        return uint256(
                sload(
                keccak256(
                abi.encode(periodId >> 8, keccak256(abi.encode(dataSetId, StorageLayout.PROVEN_PERIODS_SLOT)))
            )
            )
            ) & (1 << (periodId & 255)) != 0;
    }

    function provingActivationEpoch(uint256 dataSetId) public view returns (uint256) {
        return uint256(sload(keccak256(abi.encode(dataSetId, StorageLayout.PROVING_ACTIVATION_EPOCH_SLOT))));
    }

    function provingDeadline(uint256 setId) public view returns (uint256) {
        return uint256(sload(keccak256(abi.encode(setId, StorageLayout.PROVING_DEADLINES_SLOT))));
    }

    function getMaxProvingPeriod() internal view returns (uint64) {
        return uint64(uint256(sload(StorageLayout.MAX_PROVING_PERIOD_SLOT)));
    }

    // Number of epochs at the end of a proving period during which a
    // proof of possession can be submitted
    function challengeWindow() internal view returns (uint256) {
        return uint256(sload(StorageLayout.CHALLENGE_WINDOW_SIZE_SLOT));
    }

    /**
     * @notice Returns PDP configuration values
     * @return maxProvingPeriod Maximum number of epochs between proofs
     * @return challengeWindowSize Number of epochs for the challenge window
     * @return challengesPerProof Number of challenges required per proof
     * @return initChallengeWindowStart Initial challenge window start for new data sets assuming proving period starts now
     */
    function getPDPConfig()
        public
        view
        returns (
            uint64 maxProvingPeriod,
            uint256 challengeWindowSize,
            uint256 challengesPerProof,
            uint256 initChallengeWindowStart
        )
    {
        maxProvingPeriod = getMaxProvingPeriod();
        challengeWindowSize = challengeWindow();
        challengesPerProof = CHALLENGES_PER_PROOF;
        initChallengeWindowStart = block.number + maxProvingPeriod - challengeWindowSize;
    }

    function serviceCommissionBps() public pure returns (uint256) {
        return SERVICE_COMMISSION_BPS;
    }

    /**
     * @notice Returns the start of the next challenge window for a data set
     * @param setId The ID of the data set
     * @return The block number when the next challenge window starts
     */
    function nextPDPChallengeWindowStart(uint256 setId) public view returns (uint256) {
        uint256 deadline = provingDeadline(setId);
        uint64 maxProvingPeriod = getMaxProvingPeriod();
        uint256 challengeWindowSize = challengeWindow();

        if (deadline == NO_PROVING_DEADLINE) {
            uint256 activationEpoch = provingActivationEpoch(setId);
            if (activationEpoch == 0) {
                revert Errors.ProvingPeriodNotInitialized(setId);
            }

            // Leave one full proving period for PDP challenge finality and transaction
            // inclusion, then align the window to the dataset's lifetime period origin.
            uint256 minimumDeadline = block.number + maxProvingPeriod;
            uint256 periodsFromActivation =
                (minimumDeadline - activationEpoch + maxProvingPeriod - 1) / maxProvingPeriod;
            deadline = activationEpoch + periodsFromActivation * maxProvingPeriod;
            return deadline - challengeWindowSize;
        }

        // If the current period is open this is the next period's challenge window
        if (block.number <= deadline) {
            return _thisChallengeWindowStart(setId) + maxProvingPeriod;
        }

        // Otherwise return the current period's challenge window
        return _thisChallengeWindowStart(setId);
    }

    /**
     * @notice Helper to get the start of the current challenge window
     * @param setId The ID of the data set
     * @return The block number when the current challenge window starts
     */
    function _thisChallengeWindowStart(uint256 setId) internal view returns (uint256) {
        uint256 deadline = provingDeadline(setId);
        uint64 maxProvingPeriod = getMaxProvingPeriod();
        uint256 challengeWindowSize = challengeWindow();

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
    function getClientDataSets(address client) public view returns (DataSetInfoView[] memory infos) {
        uint256[] memory dataSetIds = clientDataSets(client);

        infos = new DataSetInfoView[](dataSetIds.length);
        for (uint256 i = 0; i < dataSetIds.length; i++) {
            infos[i] = getDataSet(dataSetIds[i]);
        }
    }

    /**
     * @notice Get enriched client data sets with optional pagination
     * @param client The client address
     * @param offset Starting index (0-based). Use 0 to start from beginning
     * @param limit Maximum number of data sets to return. Use 0 to get all remaining
     * @return infos Array of enriched data set info structs
     * @dev For large lists, use pagination to avoid gas limit issues. If limit=0,
     * returns all remaining data sets starting from offset. Example:
     * getClientDataSets(client, 0, 50) gets the first 50 enriched data sets.
     */
    function getClientDataSets(address client, uint256 offset, uint256 limit)
        public
        view
        returns (DataSetInfoView[] memory infos)
    {
        uint256[] memory dataSetIds = clientDataSets(client, offset, limit);

        infos = new DataSetInfoView[](dataSetIds.length);
        for (uint256 i = 0; i < dataSetIds.length; i++) {
            infos[i] = getDataSet(dataSetIds[i]);
        }
    }

    /**
     * @notice Internal helper to get metadata value without existence check
     * @param dataSetId The ID of the data set
     * @param key The metadata key
     * @return value The metadata value
     */
    function _getDataSetMetadataValue(uint256 dataSetId, string memory key)
        internal
        pure
        returns (string memory value)
    {
        // For nested mapping with string key: mapping(uint256 => mapping(string => string))
        bytes32 firstLevel = keccak256(abi.encode(dataSetId, StorageLayout.DATA_SET_METADATA_SLOT));
        bytes32 slot = keccak256(abi.encodePacked(bytes(key), firstLevel));
        return getString(slot);
    }

    /**
     * @notice Get metadata value for a specific key in a data set
     * @param dataSetId The ID of the data set
     * @param key The metadata key
     * @return exists True if the key exists
     * @return value The metadata value
     */
    function getDataSetMetadata(uint256 dataSetId, string memory key)
        public
        view
        returns (bool exists, string memory value)
    {
        // Check if key exists in the keys array
        string[] memory keys =
            getStringArray(keccak256(abi.encode(dataSetId, StorageLayout.DATA_SET_METADATA_KEYS_SLOT)));

        bytes memory keyBytes = bytes(key);
        uint256 keyLength = keyBytes.length;
        bytes32 keyHash = keccak256(keyBytes);

        for (uint256 i = 0; i < keys.length; i++) {
            bytes memory currentKeyBytes = bytes(keys[i]);
            if (currentKeyBytes.length == keyLength && keccak256(currentKeyBytes) == keyHash) {
                exists = true;
                value = _getDataSetMetadataValue(dataSetId, key);
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
    function getAllDataSetMetadata(uint256 dataSetId)
        public
        view
        returns (string[] memory keys, string[] memory values)
    {
        keys = getStringArray(keccak256(abi.encode(dataSetId, StorageLayout.DATA_SET_METADATA_KEYS_SLOT)));
        values = new string[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            values[i] = _getDataSetMetadataValue(dataSetId, keys[i]);
        }
    }

    /**
     * @notice Check if a provider is approved
     * @param providerId The ID of the provider to check
     * @return Whether the provider is approved
     */
    function isProviderApproved(uint256 providerId) public view returns (bool) {
        return sload(keccak256(abi.encode(providerId, StorageLayout.APPROVED_PROVIDERS_SLOT))) != bytes32(0);
    }

    /**
     * @notice Get approved provider IDs with optional pagination
     * @param offset Starting index (0-based). Use 0 to start from beginning
     * @param limit Maximum number of providers to return. Use 0 to get all remaining providers
     * @return providerIds Array of approved provider IDs
     * @dev For large lists, use pagination to avoid gas limit issues. If limit=0,
     * returns all remaining providers starting from offset. Example:
     * getApprovedProviders(0, 100) gets first 100 providers.
     */
    function getApprovedProviders(uint256 offset, uint256 limit) public view returns (uint256[] memory providerIds) {
        bytes32 slot = StorageLayout.APPROVED_PROVIDER_IDS_SLOT;
        uint256 totalLength = uint256(sload(slot));

        if (totalLength == 0) {
            return new uint256[](0);
        }

        if (offset >= totalLength) {
            return new uint256[](0);
        }

        uint256 remaining = totalLength - offset;
        uint256 actualLength = (limit == 0 || limit > remaining) ? remaining : limit;

        bytes32 baseSlot = keccak256(abi.encode(slot));
        bytes32 startSlot = bytes32(uint256(baseSlot) + offset);
        bytes32[] memory paginatedResult = sloadStruct(startSlot, actualLength);

        assembly ("memory-safe") {
            providerIds := paginatedResult
        }
    }

    /**
     * @notice Get the total number of approved providers
     * @return count Total number of approved providers
     */
    function getApprovedProvidersLength() public view returns (uint256 count) {
        bytes32 slot = StorageLayout.APPROVED_PROVIDER_IDS_SLOT;
        return uint256(sload(slot));
    }

    /**
     * @notice Get the FilBeam Controller address
     * @return The FilBeam Controller address
     */
    function filBeamControllerAddress() public view returns (address) {
        return address(uint160(uint256(sload(StorageLayout.FIL_BEAM_CONTROLLER_ADDRESS_SLOT))));
    }

    /**
     * @notice Get information about the next contract upgrade
     * @return nextImplementation The next code for the contract
     * @return afterEpoch The earliest the upgrade may complete
     */
    function nextUpgrade() public view returns (address nextImplementation, uint96 afterEpoch) {
        bytes32 upgradeInfo = sload(StorageLayout.NEXT_UPGRADE_SLOT);
        nextImplementation = address(uint160(uint256(upgradeInfo)));
        afterEpoch = uint96(uint256(upgradeInfo) >> 160);
    }

    /**
     * @notice Get the current pricing rates
     * @return storagePrice Current storage price per TiB per month
     * @return datasetFee Per-dataset additive monthly fee
     * @custom:deprecated Use `getPriceList()` for the complete catalogue. The same values appear
     *                    as `getPriceList().rates.storagePerTibPerMonth` and
     *                    `getPriceList().rates.datasetFeePerMonth`.
     */
    function getCurrentPricingRates() public pure returns (uint256 storagePrice, uint256 datasetFee) {
        return (STORAGE_PRICE_PER_TIB_PER_MONTH, DATASET_FEE_PER_MONTH);
    }

    /**
     * @notice Get the full price catalogue for this FWSS deployment.
     * @dev Single discovery point: streaming rates, one-time fees, and lockup amounts/periods in
     *      one struct. The `token` field is populated from the FWSS proxy's `usdfcTokenAddress`
     *      immutable; the rest comes from the on-chain price constants. Replaces the legacy
     *      `getServicePrice`, `getCurrentPricingRates`, and `getEffectiveRates` for consumers
     *      that want the complete price picture.
     */
    function getPriceList() public view returns (PriceList memory list) {
        list = priceList();
        list.token = usdfcTokenAddress;
    }
}
