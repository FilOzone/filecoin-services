// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Migration, SetDelegateOperation, SetDelegateOperationLibrary} from "@erc8167/lib/Migration.sol";
import {ProxyStorage} from "@erc8167/lib/ProxyStorage.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Errors} from "../../src/Errors.sol";
import {IFilecoinWarmStorageService} from "../../src/interfaces/IFilecoinWarmStorageService.sol";
import {FWSSOwnable} from "../../src/lib/FWSSOwnable.sol";
import {LibUpgradeRoutes} from "../../src/lib/LibUpgradeRoutes.sol";
import {FWSSMetadataModule} from "../../src/modules/FWSSMetadataModule.sol";
import {FWSSStorage} from "../../src/storage/FWSSStorage.sol";
import {JosukeFacetSet} from "./JosukeFacetSet.sol";

/// @notice One-shot ERC-1967 implementation that initializes a fresh FWSS proxy as v1.4.0 `initialize` did, then
/// points it at the ERC-8167 dispatcher and runs the migration that installs the facets.
contract FWSSInitializer is Initializable, EIP712Upgradeable, FWSSStorage, FWSSOwnable, FWSSMetadataModule {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event FilecoinServiceDeployed(string name, string description);

    function initialize(
        uint64 _maxProvingPeriod,
        uint256 _challengeWindowSize,
        address _filBeamControllerAddress,
        address dispatcher,
        address migration
    ) external initializer {
        _setOwner(msg.sender);
        emit OwnershipTransferred(address(0), msg.sender);
        __EIP712_init("FilecoinWarmStorageService", "1");

        require(_maxProvingPeriod > 0, Errors.MaxProvingPeriodZero());
        require(
            _challengeWindowSize > 0 && _challengeWindowSize < _maxProvingPeriod,
            Errors.InvalidChallengeWindowSize(_challengeWindowSize, _maxProvingPeriod)
        );
        require(_filBeamControllerAddress != address(0), Errors.ZeroAddress(Errors.AddressField.FilBeamController));
        filBeamControllerAddress = _filBeamControllerAddress;

        emit FilecoinServiceDeployed(SERVICE_NAME, SERVICE_DESCRIPTION);

        maxProvingPeriod = _maxProvingPeriod;
        challengeWindowSize = _challengeWindowSize;

        ERC1967Utils.upgradeToAndCall(dispatcher, "");
        Address.functionDelegateCall(migration, "");
        LibUpgradeRoutes.requireUpgradeRoutes(dispatcher);
    }
}

/// @dev Deploys FWSS as it runs after the dispatcher transition: an ERC-1967 proxy whose implementation is the ERC-8167
/// dispatcher, routing to the facets josuke.json lists.
abstract contract FWSSDeployer is JosukeFacetSet {
    string internal constant FWSS_DISPATCHER_ARTIFACT = "lib/erc8167/out/Proxy.evm/Proxy.json";

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

    /// @dev Deploys the facets and an initialized FWSS proxy that this contract owns.
    function _deployFWSS(FWSSDeployment memory deployment) internal returns (IFilecoinWarmStorageService) {
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
                deployCode(FWSS_DISPATCHER_ARTIFACT),
                _createFacetMigration()
            )
        );
        return IFilecoinWarmStorageService(address(new MyERC1967Proxy(address(new FWSSInitializer()), initializeData)));
    }

    /// @dev Deploys the josuke.json facets and a migration that routes to them.
    function _createFacetMigration() internal returns (address) {
        SetDelegateOperation[] memory routes = _deployFacetRoutes(_resolveFacets(MAINNET_INDEX));
        SetDelegateOperationLibrary.validate(routes);
        return Migration.createMigration(routes);
    }

    /// @dev Routes a selector without a migration, such as to a test-only facet.
    function _route(address proxy, bytes4 selector, address delegate) internal {
        vm.store(proxy, ProxyStorage.delegateStorageKey(selector), bytes32(uint256(uint160(delegate))));
    }
}
