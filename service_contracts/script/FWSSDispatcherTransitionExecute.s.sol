// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Migrate} from "@erc8167/interfaces/Migrate.sol";
import {ERC8167Transition} from "../src/ERC8167Transition.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FWSSDispatcherTransitionScript} from "./FWSSDispatcherTransitionScript.sol";
import {JosukeLedger} from "./lib/JosukeLedger.sol";

/// @notice The upgrade plan getter of the FWSS view contract
interface IFWSSUpgradePlan {
    function nextUpgrade() external view returns (address nextImplementation, uint96 afterEpoch);
}

/// @title FWSSDispatcherTransitionExecute
/// @notice Completes the announced FWSSDispatcherTransition with `upgradeToAndCall(transition, migrate(migration))`,
/// or prints the Safe transaction when CALLDATA_ONLY=true. Run `josuke accept` afterwards.
/// @dev Writes nothing to deployments.json, which tracks UUPS implementations; josuke.json records the routes.
contract FWSSDispatcherTransitionExecute is FWSSDispatcherTransitionScript {
    /// @notice Checks the plan and the transition's pins, then upgrades the proxy or prints the Safe transaction
    function run() external {
        uint256 chain = block.chainid;
        address proxy = _proxy();
        address transition = _envOrRecorded("FWSS_DISPATCHER_TRANSITION_ADDRESS");
        require(
            transition.code.length != 0,
            string.concat("FWSS_DISPATCHER_TRANSITION_ADDRESS ", vm.toString(transition), " has no code")
        );
        // An empty CALLDATA_ONLY counts as unset; a malformed one reverts, where vm.envOr would read false.
        bool calldataOnly = _envSet("CALLDATA_ONLY") && vm.envBool("CALLDATA_ONLY");
        console.log("Chain:", chain);
        console.log("FWSS proxy:", proxy);
        console.log("FWSSDispatcherTransition:", transition);

        // Checked first: the view reads below revert without a reason through a transition.
        _requireNotOnTransition(proxy, _implementation(proxy));
        _requireAnnounced(proxy, transition);
        (address dispatcher, address migration) = _requirePins(proxy, chain, ERC8167Transition(transition));
        console.log("ERC-8167 dispatcher:", dispatcher);
        console.log("Josuke migration:", migration);

        bytes memory data = abi.encodeCall(Migrate.migrate, (migration));
        address owner = FilecoinWarmStorageService(proxy).owner();
        if (calldataOnly) {
            _simulateAsOwner(proxy, owner, transition, data, dispatcher);
            _printSafeTransaction(
                proxy, abi.encodeCall(FilecoinWarmStorageService(proxy).upgradeToAndCall, (transition, data))
            );
            return;
        }

        (, address sender,) = vm.readCallers();
        require(
            sender == owner,
            string.concat(
                "sender ",
                vm.toString(sender),
                " is not the proxy owner ",
                vm.toString(owner),
                "; pass --sender with the owner's wallet, or set CALLDATA_ONLY=true"
            )
        );

        console.log("Completing the transition as:", sender);
        vm.broadcast();
        FilecoinWarmStorageService(proxy).upgradeToAndCall(transition, data);

        _requireDispatcherInstalled(proxy, dispatcher);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console.log("Dry run: the upgrade was simulated only, nothing was sent");
            return;
        }
        console.log("Simulation passed: the proxy would point to the dispatcher:", dispatcher);
        console.log(
            "Forge sends the transaction next. Confirm on chain that the implementation slot holds the dispatcher:"
        );
        console.log(string.concat("  cast implementation ", vm.toString(proxy)));
        console.log("Then: josuke accept, and commit josuke.json");
    }

    /// @notice Runs the upgrade as the owner in a discarded snapshot, so the Safe signs a transaction that passed
    /// the migration's own checks, not only this script's
    function _simulateAsOwner(address proxy, address owner, address transition, bytes memory data, address dispatcher)
        internal
    {
        uint256 snapshot = vm.snapshotState();

        vm.prank(owner);
        FilecoinWarmStorageService(proxy).upgradeToAndCall(transition, data);
        _requireDispatcherInstalled(proxy, dispatcher);

        vm.revertToState(snapshot);
        console.log("Simulated the upgrade as the owner:", owner);
    }

    function _requireDispatcherInstalled(address proxy, address dispatcher) internal view {
        address implementation = _implementation(proxy);
        require(
            implementation == dispatcher,
            string.concat("expected dispatcher ", vm.toString(dispatcher), ", got ", vm.toString(implementation))
        );
    }

    function _requireAnnounced(address proxy, address transition) internal view {
        address viewContract = _envOrRecorded("FWSS_VIEW_ADDRESS");
        if (viewContract == address(0)) viewContract = FilecoinWarmStorageService(proxy).viewContractAddress();

        (address planned, uint96 afterEpoch) = IFWSSUpgradePlan(viewContract).nextUpgrade();
        require(
            planned == transition,
            string.concat("the announced upgrade is ", vm.toString(planned), ", not ", vm.toString(transition))
        );
        require(
            block.number >= afterEpoch,
            string.concat("not time yet (", vm.toString(block.number), " < ", vm.toString(afterEpoch), ")")
        );
        console.log("Upgrade plan matches, ready since epoch:", afterEpoch);
    }

    function _requirePins(address proxy, uint256 chain, ERC8167Transition transition)
        internal
        view
        returns (address dispatcher, address migration)
    {
        migration = transition.migration();
        address proposed = JosukeLedger.proposedMigration(proxy, chain);
        require(
            migration == proposed,
            string.concat(
                "the transition pins migration ",
                vm.toString(migration),
                ", but ",
                JosukeLedger.path(),
                " proposes ",
                vm.toString(proposed)
            )
        );
        require(
            migration.codehash == transition.migrationCodeHash(),
            string.concat("the code at ", vm.toString(migration), " changed since the transition was deployed")
        );

        address previous = transition.previousImplementation();
        address current = _implementation(proxy);
        require(
            previous == current,
            string.concat(
                "the transition would abort to ", vm.toString(previous), ", but the proxy runs ", vm.toString(current)
            )
        );

        dispatcher = transition.dispatcher();
        _requirePinnedDispatcher(dispatcher);
    }

    /// @notice Prints the transaction in the format of `print_safe_transaction` in tools/multisig.sh
    function _printSafeTransaction(address target, bytes memory callData) internal pure {
        console.log("");
        console.log("============================================================");
        console.log("  Safe Multisig Transaction");
        console.log("============================================================");
        console.log(string.concat("  Target:    ", vm.toString(target)));
        console.log("  Function:  upgradeToAndCall(address,bytes)");
        console.log(string.concat("  Calldata:  ", vm.toString(callData)));
        console.log("  Value:     0");
        console.log("============================================================");
        console.log("");
        console.log("Paste the calldata above into the Safe UI transaction builder.");
        console.log("");
    }
}
