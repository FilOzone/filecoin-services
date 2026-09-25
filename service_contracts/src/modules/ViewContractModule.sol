// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {Errors} from "../Errors.sol";
import {LibAccessControl} from "../lib/LibAccessControl.sol";
import {VIEW_CONTRACT_ADDRESS_SLOT} from "../lib/FilecoinWarmStorageServiceLayout.sol";

/// @title ViewContractModule
/// @notice Manages the FWSS view contract address used for read-only integrations.
/// @dev Reads the slot directly: inheriting FWSSStorage would clash with its internal viewContractAddress field.
contract ViewContractModule {
    event ViewContractSet(address indexed viewContract);

    /// @notice Ensures the caller is the FWSS owner
    modifier onlyOwner() {
        LibAccessControl.requireOwner(msg.sender);
        _;
    }

    /**
     * @notice Returns the view contract address
     * @return The address of the view contract
     */
    function viewContractAddress() external view returns (address) {
        return StorageSlot.getAddressSlot(VIEW_CONTRACT_ADDRESS_SLOT).value;
    }

    /**
     * @notice Sets the view contract address
     * @dev Replacements remain allowed, as in FilecoinWarmStorageService.setViewContract.
     * @param _viewContract Address of the view contract
     */
    function setViewContract(address _viewContract) external onlyOwner {
        require(_viewContract != address(0), Errors.ZeroAddress(Errors.AddressField.View));

        StorageSlot.getAddressSlot(VIEW_CONTRACT_ADDRESS_SLOT).value = _viewContract;

        emit ViewContractSet(_viewContract);
    }
}
