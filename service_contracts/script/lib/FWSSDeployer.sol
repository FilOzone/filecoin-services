// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Constructor} from "@erc8167/lib/Constructor.sol";
import {Migration, SetDelegateOperation, SetDelegateOperationLibrary} from "@erc8167/lib/Migration.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {FWSSInitializer} from "../../src/FWSSInitializer.sol";
import {IFilecoinWarmStorageService} from "../../src/interfaces/IFilecoinWarmStorageService.sol";
import {JosukeFacetSet} from "./JosukeFacetSet.sol";

string constant FWSS_DISPATCHER_ARTIFACT = "lib/erc8167/out/Proxy.evm/Proxy.json";

/// @dev Deploys FWSS as it runs after the dispatcher transition: an ERC-1967 proxy whose implementation is the ERC-8167
/// dispatcher, routing to the facets josuke.json lists. Shared by the tests and script/FWSSDeploy.s.sol; every contract
/// is created by this contract, so a script broadcasts them all.
abstract contract FWSSDeployer is JosukeFacetSet {
    struct FWSSDeployment {
        address payments;
        address pdpVerifier;
        address usdfc;
        address filBeamBeneficiary;
        address serviceProviderRegistry;
        address sessionKeyRegistry;
        uint64 maxProvingPeriod;
        uint256 challengeWindowSize;
        address filBeamController;
    }

    /// @dev Deploys a dispatcher, the facets and an initialized FWSS proxy that the deployer owns.
    function _deployFWSS(FWSSDeployment memory deployment) internal returns (IFilecoinWarmStorageService) {
        return _deployFWSS(deployment, _deployDispatcher());
    }

    /// @dev Deploys the facets and an initialized FWSS proxy running on `dispatcher`, which the deployer owns.
    function _deployFWSS(FWSSDeployment memory deployment, address dispatcher)
        internal
        returns (IFilecoinWarmStorageService)
    {
        _setConstructorArg("_paymentsContractAddress", deployment.payments);
        _setConstructorArg("_pdpVerifierAddress", deployment.pdpVerifier);
        _setConstructorArg("_usdfc", deployment.usdfc);
        _setConstructorArg("_filBeamBeneficiaryAddress", deployment.filBeamBeneficiary);
        _setConstructorArg("_serviceProviderRegistry", deployment.serviceProviderRegistry);
        _setConstructorArg("_sessionKeyRegistry", deployment.sessionKeyRegistry);

        bytes memory initializeData = abi.encodeCall(
            FWSSInitializer.initialize,
            (
                deployment.maxProvingPeriod,
                deployment.challengeWindowSize,
                deployment.filBeamController,
                dispatcher,
                _createFacetMigration()
            )
        );
        return IFilecoinWarmStorageService(address(new MyERC1967Proxy(address(new FWSSInitializer()), initializeData)));
    }

    /// @dev Deploys the ERC-8167 dispatcher.
    function _deployDispatcher() internal returns (address) {
        return Constructor.create(vm.getCode(FWSS_DISPATCHER_ARTIFACT));
    }

    /// @dev Deploys the josuke.json facets and a migration that routes to them.
    function _createFacetMigration() internal returns (address) {
        SetDelegateOperation[] memory routes = _deployFacetRoutes(_resolveFacets(MAINNET_INDEX));
        SetDelegateOperationLibrary.validate(routes);
        return Migration.createMigration(routes);
    }
}
