// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {IERC8167} from "@erc8167/interfaces/IERC8167.sol";
import {Migrate} from "@erc8167/interfaces/Migrate.sol";
import {ProxyStorage} from "@erc8167/lib/ProxyStorage.sol";
import {IMigrateModule} from "../interfaces/IMigrateModule.sol";

/// @notice Guards the dispatcher routes that later upgrades depend on.
library LibUpgradeRoutes {
    error MissingUpgradeRoute(bytes4 selector);

    /// @notice Reverts unless introspection and migration selectors route to deployed modules.
    /// @dev A migration that drops `migrate` or `announceMigration` would make FWSS permanently unupgradeable.
    /// @param dispatcher The ERC-8167 dispatcher, which must not route to itself
    function requireUpgradeRoutes(address dispatcher) internal view {
        bytes4[4] memory selectors = [
            IERC8167.implementation.selector,
            IERC8167.selectors.selector,
            IMigrateModule.announceMigration.selector,
            Migrate.migrate.selector
        ];
        for (uint256 i; i < selectors.length; ++i) {
            address delegate = ProxyStorage.get().delegates[selectors[i]];
            if (delegate.code.length == 0 || delegate == address(this) || delegate == dispatcher) {
                revert MissingUpgradeRoute(selectors[i]);
            }
        }
    }
}
