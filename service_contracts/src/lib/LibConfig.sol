// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

/// @title LibConfig
/// @notice Shared configuration storage for FWSS modules.
library LibConfig {
    /// @custom:storage-location erc7201:filecoin.services.fwss.config
    struct Config {
        address paymentsContractAddress;
    }

    // keccak256(abi.encode(uint256(keccak256("filecoin.services.fwss.config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CONFIG_STORAGE_LOCATION =
        0xf3ad857cf7a647fe9266540d89ea0ba7e80183682843fc3a2003118b0e799f00;

    /// @notice Returns the shared FWSS configuration storage.
    function config() internal pure returns (Config storage configuration) {
        bytes32 location = CONFIG_STORAGE_LOCATION;
        assembly ("memory-safe") {
            configuration.slot := location
        }
    }
}
