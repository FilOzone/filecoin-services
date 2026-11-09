// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {FWSSOwnable} from "../lib/FWSSOwnable.sol";

/// @title OwnershipModule
/// @notice Exposes the FWSS owner with OpenZeppelin OwnableUpgradeable semantics.
contract OwnershipModule is FWSSOwnable {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OwnableInvalidOwner(address owner);

    /**
     * @notice Returns the current owner
     * @return The owner address
     */
    function owner() external view returns (address) {
        return _owner();
    }

    /**
     * @notice Transfers ownership to a new account
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @notice Leaves the contract without an owner, disabling owner-only functions and migrations
     */
    function renounceOwnership() external onlyOwner {
        _transferOwnership(address(0));
    }

    function _transferOwnership(address newOwner) private {
        address previousOwner = _setOwner(newOwner);
        emit OwnershipTransferred(previousOwner, newOwner);
    }
}
