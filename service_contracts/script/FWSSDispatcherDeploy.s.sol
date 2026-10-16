// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Script.sol";
import {FWSS_DISPATCHER_CODE_HASH} from "../src/FWSSDispatcherTransition.sol";
import {FWSSDispatcherTransitionScript} from "./FWSSDispatcherTransitionScript.sol";
import {DeploymentsJson} from "./lib/DeploymentsJson.sol";

/// @title FWSSDispatcherDeploy
/// @notice Deploys the ERC-8167 dispatcher, unless one is set or recorded, before `josuke deploy`. The proxy still runs
/// the v1.4.0 monolith, so josuke.json lists the proxy under this dispatcher until the transition: `josuke deploy` and
/// `josuke verify` then rehearse the migration against dispatcher code. Run FWSSDispatcherTransitionDeploy next.
contract FWSSDispatcherDeploy is FWSSDispatcherTransitionScript {
    /// @notice Deploys the dispatcher if needed and records it in deployments.json
    function run() external {
        _requireWallet();

        uint256 chain = block.chainid;
        address proxy = _proxy();
        console.log("Chain:", chain);
        console.log("FWSS proxy:", proxy);
        require(
            _implementation(proxy).codehash != FWSS_DISPATCHER_CODE_HASH,
            "the proxy already runs the ERC-8167 dispatcher"
        );

        (address dispatcher,) = _dispatcher(chain);

        console.log("");
        console.log(
            string.concat(
                "Next: list ",
                vm.toString(proxy),
                " under ",
                vm.toString(dispatcher),
                " in josuke.json, then josuke deploy"
            )
        );
        console.log("");

        if (_isDryRun()) {
            console.log("Dry run: deployments.json not updated");
            return;
        }
        // The next steps read the dispatcher from deployments.json, so one from FWSS_DISPATCHER_ADDRESS is recorded too.
        if (DeploymentsJson.getAddress(chain, "FWSS_DISPATCHER_ADDRESS") == dispatcher) {
            console.log("Already recorded: deployments.json not updated");
            return;
        }

        // Written during simulation, before forge sends; see FWSSDispatcherTransitionDeploy for --resume. No commit is
        // recorded: the pinned code hash identifies the dispatcher.
        DeploymentsJson.setAddress(chain, "FWSS_DISPATCHER_ADDRESS", dispatcher);
        console.log("Recorded in", DeploymentsJson.path());
    }
}
