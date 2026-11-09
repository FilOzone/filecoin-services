// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Errors} from "../Errors.sol";
import {FWSSOwnable} from "../lib/FWSSOwnable.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";

/// @title FWSSProviderManagementModule
/// @notice Manages the set of provider IDs approved to use FWSS.
contract FWSSProviderManagementModule is FWSSStorage, FWSSOwnable {
    event ProviderApproved(uint256 indexed providerId);
    event ProviderUnapproved(uint256 indexed providerId);

    /**
     * @notice Adds a provider ID to the approved list
     * @dev Only callable by the contract owner. Reverts if already approved.
     * @param providerId The provider ID to approve
     */
    function addApprovedProvider(uint256 providerId) external onlyOwner {
        if (approvedProviders[providerId]) {
            revert Errors.ProviderAlreadyApproved(providerId);
        }
        approvedProviders[providerId] = true;
        approvedProviderIds.push(providerId);
        emit ProviderApproved(providerId);
    }

    /**
     * @notice Removes a provider ID from the approved list
     * @dev Only callable by the contract owner. Reverts if not in list.
     * @param providerId The provider ID to remove
     * @param index The index of the provider ID in the approvedProviderIds array
     */
    function removeApprovedProvider(uint256 providerId, uint256 index) external onlyOwner {
        if (!approvedProviders[providerId]) {
            revert Errors.ProviderNotInApprovedList(providerId);
        }

        require(approvedProviderIds[index] == providerId, Errors.ProviderIdMismatchAtIndex(index, providerId));

        approvedProviders[providerId] = false;

        // Remove from array using swap-and-pop pattern
        uint256 length = approvedProviderIds.length;
        if (index != length - 1) {
            approvedProviderIds[index] = approvedProviderIds[length - 1];
        }
        approvedProviderIds.pop();

        emit ProviderUnapproved(providerId);
    }
}
