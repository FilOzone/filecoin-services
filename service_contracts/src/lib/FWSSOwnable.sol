// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

/// @title FWSSOwnable
/// @notice Owner checks for FWSS modules, backed by the OpenZeppelin OwnableUpgradeable storage slot.
/// @dev Exposes no external functions, so modules can share it without duplicating selectors.
abstract contract FWSSOwnable {
    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Ownable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OWNABLE_STORAGE_LOCATION =
        0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    /// @notice The caller account is not authorized to perform an operation.
    /// @param account The unauthorized account.
    error OwnableUnauthorizedAccount(address account);

    /// @notice Ensures the caller is the FWSS owner
    modifier onlyOwner() {
        _requireOwner();
        _;
    }

    /// @notice Reverts when the caller is not the FWSS owner.
    function _requireOwner() internal view {
        if (msg.sender != _owner()) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
    }

    /**
     * @notice Returns the owner stored by OpenZeppelin OwnableUpgradeable.
     * @return The current owner address.
     */
    function _owner() internal view returns (address) {
        return StorageSlot.getAddressSlot(OWNABLE_STORAGE_LOCATION).value;
    }

    /**
     * @notice Replaces the owner stored by OpenZeppelin OwnableUpgradeable.
     * @param newOwner The new owner address, or zero to renounce ownership.
     * @return previousOwner The replaced owner address.
     */
    function _setOwner(address newOwner) internal returns (address previousOwner) {
        StorageSlot.AddressSlot storage ownerSlot = StorageSlot.getAddressSlot(OWNABLE_STORAGE_LOCATION);
        previousOwner = ownerSlot.value;
        ownerSlot.value = newOwner;
    }
}
