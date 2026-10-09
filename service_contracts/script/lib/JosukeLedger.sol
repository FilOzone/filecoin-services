// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {VmSafe} from "forge-std/Vm.sol";

/// @title JosukeLedger
/// @notice Reads the josuke ledger (josuke.json). Josuke stays the source of the modules and the migration.
library JosukeLedger {
    VmSafe private constant VM = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ProxyNotInLedger(address proxy);
    error LedgerEntryWithoutAddress(uint256 index);
    error ProxyListedTwice(address proxy);
    error NoProposedMigration(address proxy, uint256 chainId);

    /// @notice The ledger to read: JOSUKE_LEDGER, or josuke.json. An empty value counts as unset.
    /// @return The path of the ledger
    function path() internal view returns (string memory) {
        string memory configured = VM.envOr("JOSUKE_LEDGER", string(""));
        return bytes(configured).length == 0 ? "josuke.json" : configured;
    }

    /// @notice The migration `josuke deploy` proposed for a proxy on a chain
    /// @param proxy The proxy
    /// @param chainId The chain
    /// @return The proposed migration
    function proposedMigration(address proxy, uint256 chainId) internal view returns (address) {
        string memory json = VM.readFile(path());
        bool found;
        uint256 index;
        for (uint256 i; VM.keyExistsJson(json, _entry(i)); ++i) {
            string memory addressKey = string.concat(_entry(i), ".address");
            require(VM.keyExistsJson(json, addressKey), LedgerEntryWithoutAddress(i));
            if (VM.parseJsonAddress(json, addressKey) != proxy) continue;

            require(!found, ProxyListedTwice(proxy));
            found = true;
            index = i;
        }
        require(found, ProxyNotInLedger(proxy));

        string memory key =
            string.concat(_entry(index), ".deployments.", VM.toString(chainId), ".proposed.migration.address");
        require(VM.keyExistsJson(json, key), NoProposedMigration(proxy, chainId));
        return VM.parseJsonAddress(json, key);
    }

    function _entry(uint256 index) private pure returns (string memory) {
        return string.concat(".[", VM.toString(index), "]");
    }
}
