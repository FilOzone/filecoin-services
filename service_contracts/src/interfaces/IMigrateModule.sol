// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Migrate} from "@erc8167/interfaces/Migrate.sol";

interface IMigrateModule is Migrate {
    function announceMigration(address migration, uint96 delayEpochs) external;
}
