// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {FWSS_DISPATCHER_CODE_HASH} from "../src/FWSSDispatcherTransition.sol";
import {DeploymentsJson} from "./lib/DeploymentsJson.sol";

/// @title FWSSDispatcherTransitionScript
/// @notice Inputs shared by the scripts that move the FWSS proxy to the ERC-8167 dispatcher
abstract contract FWSSDispatcherTransitionScript is Script {
    string internal constant FWSS_DISPATCHER_ARTIFACT = "lib/erc8167/out/Proxy.evm/Proxy.json";
    string internal constant FWSS_TRANSITION_ARTIFACT = "src/FWSSDispatcherTransition.sol:FWSSDispatcherTransition";

    function _proxy() internal view returns (address proxy) {
        proxy = _envOrRecorded("FWSS_PROXY_ADDRESS");
        require(
            proxy != address(0),
            string.concat("FWSS_PROXY_ADDRESS is neither set nor recorded in ", DeploymentsJson.path())
        );
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    /// @notice Reads an address from the environment, else from deployments.json, as the legacy
    /// `load_deployment_addresses` does. An empty variable counts as unset; a malformed one reverts.
    function _envOrRecorded(string memory key) internal view returns (address value) {
        value = _envAddress(key);
        if (value == address(0)) value = DeploymentsJson.getAddress(block.chainid, key);
    }

    /// @notice Reads an address from the environment, or zero when unset. An empty variable counts as unset; a
    /// malformed one reverts, where `vm.envOr` would return the default.
    function _envAddress(string memory key) internal view returns (address) {
        return _envSet(key) ? vm.envAddress(key) : address(0);
    }

    function _envSet(string memory key) internal view returns (bool) {
        return vm.envExists(key) && bytes(vm.envString(key)).length != 0;
    }

    function _requirePinnedDispatcher(address dispatcher) internal view {
        require(
            dispatcher.codehash == FWSS_DISPATCHER_CODE_HASH,
            string.concat(
                vm.toString(dispatcher),
                " is not the pinned ERC-8167 dispatcher (code hash ",
                vm.toString(dispatcher.codehash),
                ")"
            )
        );
    }
}
