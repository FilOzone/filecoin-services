// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Cids} from "@pdp/Cids.sol";
import {IPDPProvingSchedule} from "@pdp/IPDPProvingSchedule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFWSSConfig} from "../interfaces/IFWSSConfig.sol";
import {Errors} from "../Errors.sol";
import {CHALLENGES_PER_PROOF, NO_PROVING_DEADLINE, FilecoinWarmStorageService} from "../FilecoinWarmStorageService.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";
import {LibProving} from "../lib/LibProving.sol";
import {PriceList} from "../lib/PriceList.sol";
import {
    DATASET_FEE_PER_MONTH,
    SERVICE_COMMISSION_BPS,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    priceList
} from "../lib/PriceListUSDFC.sol";

/// @title FWSSViewModule
/// @notice Exposes typed FWSS state reads at the proxy address.
/// @dev Reads proxy storage through FWSSStorage. Public function signatures match StateView.
///      The catalogue token is read through the FWSSConfigModule getter at the proxy.
contract FWSSViewModule is FWSSStorage, IPDPProvingSchedule {
    // =========================================================================
    // Service configuration reads

    /// @notice Returns the FWSS proxy address, matching the standalone StateView service getter.
    function service() external view returns (FilecoinWarmStorageService) {
        return FilecoinWarmStorageService(address(this));
    }

    /// @notice Returns the pending upgrade or migration announcement from the existing storage.
    function nextUpgrade() external view returns (address nextImplementation, uint96 afterEpoch) {
        return (_nextUpgrade.nextImplementation, _nextUpgrade.afterEpoch);
    }

    /// @notice Returns the account allowed to manage FilBeam rails.
    function filBeamControllerAddress() external view returns (address) {
        return _filBeamControllerAddress;
    }

    // =========================================================================
    // Dataset and client reads

    /// @notice Returns dataset payment information, including the supplied dataset ID.
    /// @dev Missing datasets return zero-valued payment fields.
    /// @param dataSetId The dataset ID.
    function getDataSet(uint256 dataSetId)
        public
        view
        returns (FilecoinWarmStorageService.DataSetInfoView memory info)
    {
        FWSSStorage.DataSetInfo storage stored = dataSetInfo[dataSetId];
        info = FilecoinWarmStorageService.DataSetInfoView({
            pdpRailId: stored.pdpRailId,
            cacheMissRailId: stored.cacheMissRailId,
            cdnRailId: stored.cdnRailId,
            payer: stored.payer,
            payee: stored.payee,
            serviceProvider: stored.serviceProvider,
            commissionBps: stored.commissionBps,
            clientDataSetId: stored.clientDataSetId,
            pdpEndEpoch: stored.pdpEndEpoch,
            providerId: stored.providerId,
            pendingOneTimePayments: stored.pendingOneTimePayments,
            lifecycleReserveBalance: stored.lifecycleReserveBalance,
            dataSetId: dataSetId
        });
    }

    /// @notice Returns just the payer and PDP rail ID of a dataset.
    function getDataSetPayerAndRailId(uint256 dataSetId) external view returns (address payer, uint256 pdpRailId) {
        FWSSStorage.DataSetInfo storage info = dataSetInfo[dataSetId];
        return (info.payer, info.pdpRailId);
    }

    /// @notice Returns whether a dataset exists and has an activated proving schedule.
    /// @dev Termination does not make a dataset inactive; deletion does.
    function getDataSetStatus(uint256 dataSetId)
        external
        view
        returns (FilecoinWarmStorageService.DataSetStatus status)
    {
        if (dataSetInfo[dataSetId].pdpRailId == 0 || _provingActivationEpoch[dataSetId] == 0) {
            return FilecoinWarmStorageService.DataSetStatus.Inactive;
        }
        return FilecoinWarmStorageService.DataSetStatus.Active;
    }

    /// @notice Approximates raw dataset bytes from a sum of data-bearing leaf counts.
    /// @dev Overestimates by up to 31 bytes per piece; does not look up a dataset ID.
    /// @custom:deprecated Use Cids.leafCountToRawSize directly.
    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256) {
        return Cids.leafCountToRawSize(leafCount);
    }

    /// @notice Returns the optional dataset authorizer, or zero for payer/session-key authorization.
    function getDataSetAuthorizer(uint256 dataSetId) external view returns (address) {
        return dataSetAuthorizer[dataSetId];
    }

    /// @notice Returns the packed replay-protection value for a client's nonce.
    /// @dev Lower 128 bits hold the dataset ID; upper 128 bits hold the cumulative piece count.
    function clientNonces(address payer, uint256 nonce) external view returns (uint256) {
        return _clientNonces[payer][nonce];
    }

    /// @notice Returns the dataset associated with a payment rail.
    function railToDataSet(uint256 railId) external view returns (uint256) {
        return _railToDataSet[railId];
    }

    /// @notice Returns every dataset ID registered for a client.
    /// @dev Use the paginated overload for large lists.
    function clientDataSets(address payer) external view returns (uint256[] memory dataSetIds) {
        return _clientDataSets[payer];
    }

    /// @notice Returns client dataset IDs starting at offset; limit=0 returns all remaining IDs.
    /// @dev An offset beyond the list returns an empty array.
    function clientDataSets(address payer, uint256 offset, uint256 limit)
        public
        view
        returns (uint256[] memory dataSetIds)
    {
        uint256[] storage ids = _clientDataSets[payer];
        uint256 length = _pageLength(ids.length, offset, limit);
        dataSetIds = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            dataSetIds[i] = ids[offset + i];
        }
    }

    /// @notice Returns the number of datasets registered for a client.
    function getClientDataSetsLength(address payer) external view returns (uint256) {
        return _clientDataSets[payer].length;
    }

    /// @notice Returns payment information for every dataset registered for a client.
    /// @dev Use the paginated overload for large lists.
    function getClientDataSets(address client)
        external
        view
        returns (FilecoinWarmStorageService.DataSetInfoView[] memory infos)
    {
        return getClientDataSets(client, 0, 0);
    }

    /// @notice Returns enriched client datasets starting at offset; limit=0 returns all remaining.
    function getClientDataSets(address client, uint256 offset, uint256 limit)
        public
        view
        returns (FilecoinWarmStorageService.DataSetInfoView[] memory infos)
    {
        uint256[] memory ids = clientDataSets(client, offset, limit);
        infos = new FilecoinWarmStorageService.DataSetInfoView[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            infos[i] = getDataSet(ids[i]);
        }
    }

    /// @notice Returns a metadata value and whether its key exists, including keys with empty values.
    function getDataSetMetadata(uint256 dataSetId, string memory key)
        external
        view
        returns (bool exists, string memory value)
    {
        string[] storage keys = dataSetMetadataKeys[dataSetId];
        bytes32 keyHash = keccak256(bytes(key));
        for (uint256 i; i < keys.length; ++i) {
            if (bytes(keys[i]).length == bytes(key).length && keccak256(bytes(keys[i])) == keyHash) {
                return (true, dataSetMetadata[dataSetId][key]);
            }
        }
    }

    /// @notice Returns every metadata key and its corresponding value in stored key order.
    function getAllDataSetMetadata(uint256 dataSetId)
        external
        view
        returns (string[] memory keys, string[] memory values)
    {
        keys = dataSetMetadataKeys[dataSetId];
        values = new string[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            values[i] = dataSetMetadata[dataSetId][keys[i]];
        }
    }

    // =========================================================================
    // Provider reads

    /// @notice Returns whether a service provider ID is approved.
    function isProviderApproved(uint256 providerId) external view returns (bool) {
        return approvedProviders[providerId];
    }

    /// @notice Returns the number of approved providers.
    function getApprovedProvidersLength() external view returns (uint256 count) {
        return approvedProviderIds.length;
    }

    /// @notice Returns approved provider IDs starting at offset; limit=0 returns all remaining.
    function getApprovedProviders(uint256 offset, uint256 limit) external view returns (uint256[] memory providerIds) {
        uint256[] storage providers = approvedProviderIds;
        uint256 length = _pageLength(providers.length, offset, limit);
        providerIds = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            providerIds[i] = providers[offset + i];
        }
    }

    // =========================================================================
    // Proving reads

    /// @notice Returns whether the bit for a dataset's proving period is set.
    function provenPeriods(uint256 dataSetId, uint256 periodId) public view returns (bool) {
        return _provenPeriods[dataSetId][periodId >> 8] & (1 << (periodId & 255)) != 0;
    }

    /// @notice Returns whether the dataset has proven its current scheduled period.
    function provenThisPeriod(uint256 dataSetId) external view returns (bool) {
        return _provenThisPeriod[dataSetId];
    }

    /// @notice Returns the original activation epoch of a dataset's proving schedule.
    function provingActivationEpoch(uint256 dataSetId) external view returns (uint256) {
        return _provingActivationEpoch[dataSetId];
    }

    /// @notice Returns the dataset's proving deadline, or zero when no deadline is scheduled.
    function provingDeadline(uint256 setId) external view returns (uint256) {
        return provingDeadlines[setId];
    }

    /// @notice Returns whether the previous lifetime period is proven or the current scheduled period has a proof.
    /// @dev Before or at activation this returns false.
    function hasBeenProvenRecently(uint256 dataSetId) external view returns (bool) {
        uint256 activationEpoch = _provingActivationEpoch[dataSetId];
        if (activationEpoch == 0 || block.number <= activationEpoch) return false;
        uint256 currentPeriod = LibProving.provingPeriodForEpoch(activationEpoch, block.number, maxProvingPeriod);
        if (currentPeriod >= 1 && provenPeriods(dataSetId, currentPeriod - 1)) return true;
        return _provenThisPeriod[dataSetId];
    }

    /// @inheritdoc IPDPProvingSchedule
    function getPDPConfig()
        external
        view
        override
        returns (
            uint64 maxProvingPeriod,
            uint256 challengeWindowSize,
            uint256 challengesPerProof,
            uint256 initChallengeWindowStart
        )
    {
        return (
            FWSSStorage.maxProvingPeriod,
            FWSSStorage.challengeWindowSize,
            CHALLENGES_PER_PROOF,
            block.number + FWSSStorage.maxProvingPeriod - FWSSStorage.challengeWindowSize
        );
    }

    /// @inheritdoc IPDPProvingSchedule
    function nextPDPChallengeWindowStart(uint256 setId) external view override returns (uint256) {
        uint256 deadline = provingDeadlines[setId];
        uint64 maxProvingPeriod = FWSSStorage.maxProvingPeriod;
        uint256 challengeWindowSize = FWSSStorage.challengeWindowSize;

        if (deadline == NO_PROVING_DEADLINE) {
            uint256 activationEpoch = _provingActivationEpoch[setId];
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

    // =========================================================================
    // Pricing reads

    /// @notice Returns the full price catalogue for this FWSS deployment.
    function getPriceList() external view returns (PriceList memory list) {
        list = priceList();
        list.token = IERC20(address(IFWSSConfig(address(this)).usdfcTokenAddress()));
    }

    /// @notice Returns monthly storage pricing per TiB and the additive dataset fee.
    /// @custom:deprecated Use getPriceList().rates.
    function getCurrentPricingRates() external pure returns (uint256 storagePrice, uint256 datasetFee) {
        return (STORAGE_PRICE_PER_TIB_PER_MONTH, DATASET_FEE_PER_MONTH);
    }

    /// @notice Returns the service's base commission in basis points.
    function serviceCommissionBps() external pure returns (uint256) {
        return SERVICE_COMMISSION_BPS;
    }

    /// @dev Preserves legacy pagination: limit=0 returns all remaining entries.
    function _pageLength(uint256 totalLength, uint256 offset, uint256 limit) private pure returns (uint256) {
        if (offset >= totalLength) return 0;
        uint256 remaining = totalLength - offset;
        return limit == 0 || limit > remaining ? remaining : limit;
    }

    /// @dev Returns the current or next aligned window after accounting for skipped periods.
    function _thisChallengeWindowStart(uint256 dataSetId) private view returns (uint256) {
        uint256 deadline = provingDeadlines[dataSetId];
        uint256 periodsSkipped;
        if (block.number > deadline) periodsSkipped = 1 + (block.number - (deadline + 1)) / maxProvingPeriod;
        return deadline + periodsSkipped * maxProvingPeriod - challengeWindowSize;
    }
}
