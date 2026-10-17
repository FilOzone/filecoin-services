// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {console} from "forge-std/Script.sol";
import {IFilecoinWarmStorageService} from "../src/interfaces/IFilecoinWarmStorageService.sol";
import {FWSSDispatcherTransitionScript} from "./FWSSDispatcherTransitionScript.sol";
import {DeploymentsJson} from "./lib/DeploymentsJson.sol";
import {FWSSDeployer} from "./lib/FWSSDeployer.sol";

/// @title FWSSDeploy
/// @notice Deploys a fresh FWSS proxy on the ERC-8167 dispatcher, with the facets josuke.json lists, owned by the
/// broadcaster. For new networks such as local devnets; existing deployments change through josuke migrations.
/// @dev Reads each dependency from the environment, else from deployments.json, as tools/warm-storage-deploy-all.sh
/// passes them. Uses FWSS_DISPATCHER_ADDRESS, else the recorded dispatcher, else deploys one. Run `make erc8167` first.
contract FWSSDeploy is FWSSDispatcherTransitionScript, FWSSDeployer {
    /// @notice Deploys FWSS and records the proxy and the dispatcher in deployments.json
    function run() external {
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

        (address dispatcher,) = _dispatcher(chain);

        vm.startBroadcast();
        IFilecoinWarmStorageService fwss = _deployFWSS(deployment, dispatcher);
        vm.stopBroadcast();
        console.log("FWSS proxy deployed at", address(fwss));

        if (_isDryRun()) {
            console.log("Dry run: deployments.json not updated");
            return;
        }
        // Written during simulation, before forge sends, as FWSSDispatcherDeploy does.
        DeploymentsJson.setAddress(chain, "FWSS_DISPATCHER_ADDRESS", dispatcher);
        DeploymentsJson.setAddress(chain, "FWSS_PROXY_ADDRESS", address(fwss));
        console.log("Recorded in", DeploymentsJson.path());
    }

    function _requireEnvOrRecorded(string memory key) internal view returns (address value) {
        value = _envOrRecorded(key);
        require(value != address(0), string.concat(key, " is neither set nor recorded in ", DeploymentsJson.path()));
    }
}
