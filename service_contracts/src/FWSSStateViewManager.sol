// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Errors} from "./Errors.sol";
import {VIEW_CONTRACT_ADDRESS_SLOT} from "./lib/FilecoinWarmStorageServiceLayout.sol";

contract FWSSStateViewManager is OwnableUpgradeable {
    struct ViewContractStorage {
        address viewContractAddress;
    }

    event ViewContractSet(address indexed viewContract);

    constructor() {
        _disableInitializers();
    }

    function _viewContractStorage() internal pure returns (ViewContractStorage storage state) {
        // Preserve the address slot used by legacy storage readers without inheriting business storage.
        bytes32 slot = VIEW_CONTRACT_ADDRESS_SLOT;
        assembly {
            state.slot := slot
        }
    }

    function viewContractAddress() external view returns (address) {
        return _viewContractStorage().viewContractAddress;
    }

    /**
     * @notice Sets the view contract address
     * @dev Uses the proxy's existing owner. Replacements remain allowed, as in the current service.
     * @param _viewContract Address of the view contract
     */
    function setViewContract(address _viewContract) external onlyOwner {
        require(_viewContract != address(0), Errors.ZeroAddress(Errors.AddressField.View));

        _viewContractStorage().viewContractAddress = _viewContract;

        emit ViewContractSet(_viewContract);
    }
}
