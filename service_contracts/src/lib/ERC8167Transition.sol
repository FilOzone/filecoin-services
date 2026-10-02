// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Migrate} from "@erc8167/interfaces/Migrate.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title ERC8167Transition
/// @notice One-shot UUPS implementation that moves an ERC-1967 proxy to an ERC-8167 dispatcher.
/// @dev Upgrade with `upgradeToAndCall(transition, abi.encodeCall(Migrate.migrate, (migration)))`. The call points the
/// proxy at the dispatcher and runs the pinned migration in the proxy's storage, so the transition never stays
/// installed. After an upgrade with empty data, an authorized caller can still finish through the proxy.
abstract contract ERC8167Transition is IERC1822Proxiable, Migrate {
    /// @notice The ERC-8167 dispatcher the proxy points at after the transition
    address public immutable dispatcher;

    /// @notice The migration that writes the dispatcher's routes
    address public immutable migration;

    /// @notice The migration's code hash, so a delayed upgrade reviews its code, not just its address
    bytes32 public immutable migrationCodeHash;

    address private immutable SELF = address(this);

    error InvalidTransition();
    error UnauthorizedCallContext();
    error UnexpectedMigration(address migration);
    error DispatcherChanged(address implementation);

    constructor(address dispatcher_, address migration_) {
        require(dispatcher_.code.length != 0 && migration_.code.length != 0, InvalidTransition());
        dispatcher = dispatcher_;
        migration = migration_;
        migrationCodeHash = migration_.codehash;
    }

    /// @notice Lets a UUPS implementation upgrade to this contract
    /// @return The ERC-1967 implementation slot
    function proxiableUUID() external view returns (bytes32) {
        require(address(this) == SELF, UnauthorizedCallContext());
        return ERC1967Utils.IMPLEMENTATION_SLOT;
    }

    /// @notice Points the proxy at the dispatcher and runs the pinned migration
    /// @param migration_ The pinned migration
    function migrate(address migration_) external {
        require(address(this) != SELF && ERC1967Utils.getImplementation() == SELF, UnauthorizedCallContext());
        _authorizeTransition();
        require(migration_ == migration && migration_.codehash == migrationCodeHash, UnexpectedMigration(migration_));

        // Uninstall first, so calls the migration makes back into the proxy reach the dispatcher.
        ERC1967Utils.upgradeToAndCall(dispatcher, "");

        emit DiamondDelegateCall(migration_, "");
        Address.functionDelegateCall(migration_, "");

        address implementation = ERC1967Utils.getImplementation();
        require(implementation == dispatcher, DispatcherChanged(implementation));
        _checkRoutes();
    }

    /// @notice Reverts unless the caller may run the transition
    function _authorizeTransition() internal view virtual;

    /// @notice Reverts unless the migrated routes keep the proxy upgradeable
    function _checkRoutes() internal view virtual;
}
