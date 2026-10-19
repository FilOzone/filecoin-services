// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Constructor} from "@erc8167/lib/Constructor.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ERC8167Transition} from "../src/ERC8167Transition.sol";
import {FWSS_DISPATCHER_CODE_HASH} from "../src/FWSSDispatcherTransition.sol";
import {DeploymentsJson} from "./lib/DeploymentsJson.sol";
import {FWSS_DISPATCHER_ARTIFACT} from "./lib/FWSSDeployer.sol";

/// @title FWSSDispatcherTransitionScript
/// @notice Inputs shared by the scripts that move the FWSS proxy to the ERC-8167 dispatcher
abstract contract FWSSDispatcherTransitionScript is Script {
    string internal constant FWSS_TRANSITION_ARTIFACT = "src/FWSSDispatcherTransition.sol:FWSSDispatcherTransition";

    /// @notice Whether forge runs this script without `--broadcast`. Virtual because `forge test` runs in its own
    /// context, so tests override it to cover the dry run.
    function _isDryRun() internal view virtual returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
    }

    /// @notice Whether forge runs this script with `--broadcast`. Virtual for the same reason as `_isDryRun`.
    function _isBroadcast() internal view virtual returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
    }

    /// @notice Reverts on `--broadcast` without a wallet. forge deploys the script from its default sender at nonce 0,
    /// the address a walletless broadcast would record for the dispatcher, so every later run would find the script's
    /// code there instead of redeploying.
    function _requireWallet() internal view {
        (, address sender,) = vm.readCallers();
        require(
            !_isBroadcast() || sender != DEFAULT_SENDER,
            "--broadcast needs a wallet: pass --keystore, --account or --private-key"
        );
    }

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

    /// @notice Reverts when the proxy runs a transition: an upgrade with empty data installed it without `migrate`, so
    /// only `migrate(migration)` or `abortTransition()` on the proxy can move it on. Neither script can help, and
    /// a deploy would record a new transition pinned to this one as its rollback target.
    function _requireNotOnTransition(address proxy, address implementation) internal view {
        (bool success, bytes memory result) =
            implementation.staticcall(abi.encodeCall(ERC8167Transition(implementation).migrationCodeHash, ()));
        require(
            !success || result.length != 32,
            string.concat(
                "the proxy runs the transition ",
                vm.toString(implementation),
                "; call migrate(migration) or abortTransition() on ",
                vm.toString(proxy)
            )
        );
    }

    /// @notice Uses FWSS_DISPATCHER_ADDRESS from the environment, else the recorded dispatcher, else deploys one. A
    /// recorded dispatcher without code is redeployed: the broadcast that should have created it did not land.
    function _dispatcher(uint256 chain) internal returns (address dispatcher, bool deployed) {
        dispatcher = _envAddress("FWSS_DISPATCHER_ADDRESS");
        if (dispatcher != address(0)) {
            console.log("Using the ERC-8167 dispatcher from FWSS_DISPATCHER_ADDRESS:", dispatcher);
        } else {
            dispatcher = DeploymentsJson.getAddress(chain, "FWSS_DISPATCHER_ADDRESS");
            if (dispatcher != address(0) && dispatcher.code.length == 0) {
                console.log(
                    "The recorded ERC-8167 dispatcher has no code, a previous broadcast did not land:", dispatcher
                );
                dispatcher = address(0);
            }

            if (dispatcher == address(0)) {
                bytes memory initcode = vm.getCode(FWSS_DISPATCHER_ARTIFACT);
                vm.broadcast();
                dispatcher = Constructor.create(initcode);
                deployed = true;
                console.log("Deployed the ERC-8167 dispatcher:", dispatcher);
            } else {
                console.log("Using the recorded ERC-8167 dispatcher:", dispatcher);
            }
        }

        // Checked on every run: the simulation deploys for real, unlike the bash dry run.
        _requirePinnedDispatcher(dispatcher);
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
