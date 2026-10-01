// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {FWSSStorage} from "../storage/FWSSStorage.sol";

/// @title FWSSViewContractModule
/// @notice Returns the FWSS view contract address used for read-only integrations.
contract FWSSViewContractModule is FWSSStorage {
    /**
     * @notice Returns the view contract address
     * @return The address of the view contract
     */
    function viewContractAddress() external view returns (address) {
        return _viewContractAddress;
    }
}
