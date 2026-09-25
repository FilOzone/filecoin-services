// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IMigrateModule} from "../interfaces/IMigrateModule.sol";
import {LibAccessControl} from "../lib/LibAccessControl.sol";
import {NEXT_UPGRADE_SLOT} from "../lib/FilecoinWarmStorageServiceLayout.sol";
import {LibUpgradeRoutes} from "../lib/LibUpgradeRoutes.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";

/// @notice Executes owner-announced Josuke migrations through the ERC-8167 proxy.
contract MigrateModule is IMigrateModule {
    event UpgradeAnnounced(FWSSStorage.PlannedUpgrade plannedUpgrade);

    error InvalidMigration(address migration);
    error MigrationNotAnnounced(address migration);
    error MigrationNotReady(uint96 afterEpoch);

    function announceMigration(address migration, uint96 delayEpochs) external override {
        LibAccessControl.requireOwner(msg.sender);
        if (migration.code.length == 0 || migration == address(this)) revert InvalidMigration(migration);

        uint96 delay = delayEpochs == 0 ? 1 : delayEpochs;
        FWSSStorage.PlannedUpgrade storage plan = _plan();
        plan.nextImplementation = migration;
        plan.afterEpoch = uint96(block.number) + delay;

        emit UpgradeAnnounced(plan);
    }

    /// @dev Josuke calls this entry point with empty calldata to the migration itself.
    function migrate(address migration) external override {
        LibAccessControl.requireOwner(msg.sender);
        FWSSStorage.PlannedUpgrade storage plan = _plan();
        if (migration != plan.nextImplementation || migration == address(0)) {
            revert MigrationNotAnnounced(migration);
        }
        if (block.number < plan.afterEpoch) revert MigrationNotReady(plan.afterEpoch);

        // Consume the announcement before executing code in the proxy's storage context.
        delete plan.nextImplementation;
        delete plan.afterEpoch;

        emit DiamondDelegateCall(migration, "");
        Address.functionDelegateCall(migration, "");

        // FWSS sits behind an ERC-1967 proxy whose implementation is the dispatcher.
        LibUpgradeRoutes.requireUpgradeRoutes(ERC1967Utils.getImplementation());
    }

    function _plan() private pure returns (FWSSStorage.PlannedUpgrade storage plan) {
        // Preserve StateView.nextUpgrade() and the legacy packed address/epoch slot.
        bytes32 slot = NEXT_UPGRADE_SLOT;
        assembly ("memory-safe") {
            plan.slot := slot
        }
    }
}
