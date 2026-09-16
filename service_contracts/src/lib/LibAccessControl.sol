// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

/// @title LibAccessControl
/// @notice Shared access-control checks for FWSS modules.
library LibAccessControl {
    /// @custom:storage-location erc7201:openzeppelin.storage.Ownable
    struct OwnableStorage {
        address owner;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Ownable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OWNABLE_STORAGE_LOCATION =
        0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    /// @notice The caller account is not authorized to perform an operation.
    /// @param account The unauthorized account.
    error OwnableUnauthorizedAccount(address account);

    /**
     * @notice Reverts when `account` is not the FWSS owner.
     * @param account The account requiring owner authorization.
     */
    function requireOwner(address account) internal view {
        if (account != owner()) {
            revert OwnableUnauthorizedAccount(account);
        }
    }

    /**
     * @notice Returns the owner stored by OpenZeppelin OwnableUpgradeable.
     * @return The current owner address.
     */
    function owner() internal view returns (address) {
        OwnableStorage storage ownableStorage;
        bytes32 location = OWNABLE_STORAGE_LOCATION;

        assembly ("memory-safe") {
            ownableStorage.slot := location
        }

        return ownableStorage.owner;
    }
}
