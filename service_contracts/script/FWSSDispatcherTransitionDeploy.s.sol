// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Script.sol";
import {Constructor} from "@erc8167/lib/Constructor.sol";
import {ERC8167Transition} from "../src/ERC8167Transition.sol";
import {FWSS_DISPATCHER_CODE_HASH, FWSSDispatcherTransition} from "../src/FWSSDispatcherTransition.sol";
import {FWSSDispatcherTransitionScript} from "./FWSSDispatcherTransitionScript.sol";
import {DeploymentsJson} from "./lib/DeploymentsJson.sol";
import {JosukeLedger} from "./lib/JosukeLedger.sol";

/// @title FWSSDispatcherTransitionDeploy
/// @notice Deploys the ERC-8167 dispatcher, unless one is set or recorded, and the FWSSDispatcherTransition pinned to
/// the proxy's current implementation and the migration `josuke deploy` proposed. Run `josuke deploy` first, then
/// announce the transition and complete it with FWSSDispatcherTransitionExecute.
contract FWSSDispatcherTransitionDeploy is FWSSDispatcherTransitionScript {
    string internal constant TRANSITION_KEY = "FWSS_DISPATCHER_TRANSITION";

    /// @notice Deploys what is missing and records it in deployments.json
    function run() external {
        // forge deploys this script from its default sender at nonce 0, the address a walletless broadcast would record
        // for the dispatcher, so every later run would find this script's code there instead of redeploying.
        (, address sender,) = vm.readCallers();
        require(
            !_isBroadcast() || sender != DEFAULT_SENDER,
            "--broadcast needs a wallet: pass --keystore, --account or --private-key"
        );

        uint256 chain = block.chainid;
        address proxy = _proxy();
        console.log("Chain:", chain);
        console.log("FWSS proxy:", proxy);

        // abortTransition restores this implementation if the proxy is ever left on the transition. Read before the
        // ledger, so a rerun after `josuke accept` cleared the proposal names the actual cause.
        address previous = _implementation(proxy);
        require(previous.codehash != FWSS_DISPATCHER_CODE_HASH, "the proxy already runs the ERC-8167 dispatcher");
        require(
            previous.code.length != 0, string.concat("the proxy implementation ", vm.toString(previous), " has no code")
        );
        _requireNotOnTransition(proxy, previous);
        console.log("Current FWSS implementation:", previous);

        address migration = JosukeLedger.proposedMigration(proxy, chain);
        console.log("Josuke proposed migration:", migration);

        (address dispatcher, bool deployedDispatcher) = _dispatcher(chain);

        string[] memory args = new string[](3);
        args[0] = vm.toString(previous);
        args[1] = vm.toString(dispatcher);
        args[2] = vm.toString(migration);
        (address transition, bool deployedTransition) = _transition(chain, args, previous, dispatcher, migration);

        console.log("");
        console.log("# DEPLOYMENT COMPLETE");
        console.log("Previous implementation:", previous);
        console.log("ERC-8167 dispatcher:", dispatcher);
        console.log("Josuke migration:", migration);
        console.log("FWSSDispatcherTransition:", transition);
        console.log("");
        console.log(
            string.concat(
                "Next: josuke verify, then announce with NEW_FWSS_IMPLEMENTATION_ADDRESS=", vm.toString(transition)
            )
        );
        console.log("");

        if (_isDryRun()) {
            console.log("Dry run: deployments.json not updated");
            return;
        }
        if (!deployedDispatcher && !deployedTransition) {
            console.log("Nothing deployed: deployments.json not updated");
            return;
        }

        string memory commit = vm.envOr("GIT_COMMIT", string(""));
        require(bytes(commit).length != 0, "set GIT_COMMIT=$(git rev-parse HEAD) to record the deployment");

        // The record is written during simulation, before forge sends. CREATE addresses follow from sender and
        // nonce: if the broadcast fails, --resume lands the transactions at the recorded addresses, and a rerun
        // without --resume redeploys because the recorded addresses have no code.
        // The dispatcher is raw EVM assembly, not a forge artifact, so only its address is recorded.
        if (deployedDispatcher) DeploymentsJson.setAddress(chain, "FWSS_DISPATCHER_ADDRESS", dispatcher);
        if (deployedTransition) {
            DeploymentsJson.setAddress(chain, "FWSS_DISPATCHER_TRANSITION_ADDRESS", transition);
            DeploymentsJson.recordContract(chain, TRANSITION_KEY, FWSS_TRANSITION_ARTIFACT, args);
        }
        DeploymentsJson.setMetadata(chain, commit);
        console.log("Recorded in", DeploymentsJson.path());
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

    /// @notice Uses FWSS_DISPATCHER_TRANSITION_ADDRESS from the environment, which must pin the expected contracts.
    /// Otherwise reuses the recorded transition when its record matches the artifact and arguments, as the legacy
    /// `deploy_implementation_if_needed` does, and the contract on chain pins the expected contracts; else deploys.
    /// A `pinned` record is never redeployed.
    function _transition(uint256 chain, string[] memory args, address previous, address dispatcher, address migration)
        internal
        returns (address transition, bool deployed)
    {
        string memory pinsError = string.concat(
            " does not pin the expected previous implementation ",
            vm.toString(previous),
            ", dispatcher ",
            vm.toString(dispatcher),
            " and migration ",
            vm.toString(migration)
        );

        transition = _envAddress("FWSS_DISPATCHER_TRANSITION_ADDRESS");
        if (transition != address(0)) {
            require(
                _pinsMatch(transition, previous, dispatcher, migration),
                string.concat("FWSS_DISPATCHER_TRANSITION_ADDRESS ", vm.toString(transition), pinsError)
            );
            console.log("Using FWSSDispatcherTransition from FWSS_DISPATCHER_TRANSITION_ADDRESS:", transition);
            return (transition, false);
        }

        transition = DeploymentsJson.getAddress(chain, "FWSS_DISPATCHER_TRANSITION_ADDRESS");
        bool pinsMatch = transition != address(0) && _pinsMatch(transition, previous, dispatcher, migration);
        if (DeploymentsJson.isPinned(chain, TRANSITION_KEY)) {
            require(
                pinsMatch, string.concat("the pinned FWSSDispatcherTransition ", vm.toString(transition), pinsError)
            );
            console.log("Using the pinned FWSSDispatcherTransition:", transition);
            return (transition, false);
        }

        if (transition != address(0)) {
            if (transition.code.length == 0) {
                console.log(
                    "The recorded FWSSDispatcherTransition has no code, a previous broadcast did not land:", transition
                );
            } else if (!DeploymentsJson.matchesRecord(chain, TRANSITION_KEY, FWSS_TRANSITION_ARTIFACT, args)) {
                console.log("The FWSSDispatcherTransition record differs from the artifact or arguments:", transition);
            } else if (!pinsMatch) {
                console.log("The recorded FWSSDispatcherTransition pins other contracts:", transition);
            } else {
                console.log("FWSSDispatcherTransition up to date at:", transition);
                return (transition, false);
            }
        }

        vm.broadcast();
        transition = address(new FWSSDispatcherTransition(previous, dispatcher, migration));
        deployed = true;
        console.log("Deployed FWSSDispatcherTransition:", transition);
    }

    /// @notice Whether `transition` has code and pins the given contracts and the migration's current code. Reads
    /// with low-level static calls, so an unrelated contract at that address yields false instead of reverting.
    function _pinsMatch(address transition, address previous, address dispatcher, address migration)
        internal
        view
        returns (bool)
    {
        ERC8167Transition candidate = ERC8167Transition(transition);
        return transition.code.length != 0
            && _returns(transition, abi.encodeCall(candidate.previousImplementation, ()), _word(previous))
            && _returns(transition, abi.encodeCall(candidate.dispatcher, ()), _word(dispatcher))
            && _returns(transition, abi.encodeCall(candidate.migration, ()), _word(migration))
            && _returns(transition, abi.encodeCall(candidate.migrationCodeHash, ()), migration.codehash);
    }

    function _returns(address target, bytes memory getter, bytes32 expected) internal view returns (bool) {
        (bool success, bytes memory result) = target.staticcall(getter);
        return success && result.length == 32 && abi.decode(result, (bytes32)) == expected;
    }

    function _word(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }
}
