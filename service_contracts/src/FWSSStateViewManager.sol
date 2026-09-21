// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {Errors} from "./Errors.sol";
import {VIEW_CONTRACT_ADDRESS_SLOT} from "./lib/FilecoinWarmStorageServiceLayout.sol";

contract FWSSStateViewManager is OwnableUpgradeable {
    event ViewContractSet(address indexed viewContract);

    function viewContractAddress() external view returns (address) {
        // Legacy storage readers discover StateView through this slot.
        return StorageSlot.getAddressSlot(VIEW_CONTRACT_ADDRESS_SLOT).value;
    }

    /**
     * @notice Sets the view contract address
     * @dev Uses the proxy's existing owner. Replacements remain allowed, as in the current service.
     * @param _viewContract Address of the view contract
     */
    function setViewContract(address _viewContract) external onlyOwner {
        require(_viewContract != address(0), Errors.ZeroAddress(Errors.AddressField.View));

        StorageSlot.getAddressSlot(VIEW_CONTRACT_ADDRESS_SLOT).value = _viewContract;

        emit ViewContractSet(_viewContract);
    }
}
