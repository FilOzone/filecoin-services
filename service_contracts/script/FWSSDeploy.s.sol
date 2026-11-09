// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Script.sol";
import {FWSSDispatcherTransitionScript} from "./FWSSDispatcherTransitionScript.sol";
import {DeploymentsJson} from "./lib/DeploymentsJson.sol";
import {FWSSDeployer} from "./lib/FWSSDeployer.sol";

/// @title FWSSDeploy
/// @notice Deploys a fresh FWSS proxy on the ERC-8167 dispatcher, with the facets josuke.json lists, owned by the
/// broadcaster. For new networks such as local devnets; existing deployments change through josuke migrations.
/// @dev Reads each dependency from the environment, else from deployments.json, as tools/warm-storage-deploy-all.sh
/// passes them. Uses FWSS_DISPATCHER_ADDRESS, else the recorded dispatcher, else deploys one. Run `make erc8167` first.
/// SKIP_UPDATE_DEPLOYMENTS=true leaves deployments.json alone, as it does for tools/deployments.sh.
contract FWSSDeploy is FWSSDispatcherTransitionScript, FWSSDeployer {
    /// @notice Deploys FWSS and records the proxy and the dispatcher in deployments.json
    /// @return dispatcher The ERC-8167 dispatcher the proxy runs
    /// @return proxy The FWSS proxy
    function run() external returns (address dispatcher, address proxy) {
        _requireWallet();

        uint256 chain = block.chainid;
        FWSSDeployment memory deployment = FWSSDeployment({
            payments: _requireEnvOrRecorded("FILECOIN_PAY_ADDRESS"),
            pdpVerifier: _requireEnvOrRecorded("PDP_VERIFIER_PROXY_ADDRESS"),
            usdfc: _requireEnvOrRecorded("USDFC_TOKEN_ADDRESS"),
            filBeamBeneficiary: _requireEnvOrRecorded("FILBEAM_BENEFICIARY_ADDRESS"),
            serviceProviderRegistry: _requireEnvOrRecorded("SERVICE_PROVIDER_REGISTRY_PROXY_ADDRESS"),
            sessionKeyRegistry: _requireEnvOrRecorded("SESSION_KEY_REGISTRY_ADDRESS"),
            maxProvingPeriod: uint64(vm.envUint("MAX_PROVING_PERIOD")),
            challengeWindowSize: vm.envUint("CHALLENGE_WINDOW_SIZE"),
            filBeamController: vm.envAddress("FILBEAM_CONTROLLER_ADDRESS")
        });
        console.log("Chain:", chain);

        (dispatcher,) = _dispatcher(chain);

        vm.startBroadcast();
        proxy = address(_deployFWSS(deployment, dispatcher));
        vm.stopBroadcast();
        console.log("FWSS proxy deployed at", proxy);

        if (_isDryRun()) {
            console.log("Dry run: deployments.json not updated");
        } else if (_envSet("SKIP_UPDATE_DEPLOYMENTS") && vm.envBool("SKIP_UPDATE_DEPLOYMENTS")) {
            console.log("SKIP_UPDATE_DEPLOYMENTS: deployments.json not updated");
        } else {
            // Written before forge broadcasts any of the transactions above.
            DeploymentsJson.setAddress(chain, "FWSS_DISPATCHER_ADDRESS", dispatcher);
            DeploymentsJson.setAddress(chain, "FWSS_PROXY_ADDRESS", proxy);
            console.log("Recorded in", DeploymentsJson.path());
        }
    }

    function _requireEnvOrRecorded(string memory key) internal view returns (address value) {
        value = _envOrRecorded(key);
        require(value != address(0), string.concat(key, " is neither set nor recorded in ", DeploymentsJson.path()));
    }
}
