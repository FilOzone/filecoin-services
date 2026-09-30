// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {VIEW_CONTRACT_ADDRESS_SLOT} from "../lib/FilecoinWarmStorageServiceLayout.sol";

/// @title FWSSViewContractModule
/// @notice Returns the FWSS view contract address used for read-only integrations.
/// @dev Reads the slot directly: inheriting FWSSStorage would clash with its internal viewContractAddress field.
contract FWSSViewContractModule {
    /**
     * @notice Returns the view contract address
     * @return The address of the view contract
     */
    function viewContractAddress() external view returns (address) {
        return StorageSlot.getAddressSlot(VIEW_CONTRACT_ADDRESS_SLOT).value;
    }
}
