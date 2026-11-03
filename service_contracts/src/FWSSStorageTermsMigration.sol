// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Migrate} from "@erc8167/interfaces/Migrate.sol";
import {LibStorageTerms} from "./lib/LibStorageTerms.sol";
import {IFWSSConfig} from "./interfaces/IFWSSConfig.sol";

/// @notice Runs a Josuke route migration and atomically installs the legacy storage terms record.
/// @dev Pass this contract to the pre-storage-terms FWSSMigrateModule instead of the raw Josuke migration.
contract FWSSStorageTermsMigration {
    address public immutable migration;

    error InvalidMigration(address migration);

    constructor(address migration_) {
        if (migration_.code.length == 0) revert InvalidMigration(migration_);
        migration = migration_;
    }

    fallback() external {
        emit Migrate.DiamondDelegateCall(migration, "");
        Address.functionDelegateCall(migration, "");
        LibStorageTerms.initialize(address(IFWSSConfig(address(this)).usdfcTokenAddress()));
    }
}
