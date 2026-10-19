// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Errors} from "./Errors.sol";
import {FWSSOwnable} from "./lib/FWSSOwnable.sol";
import {LibUpgradeRoutes} from "./lib/LibUpgradeRoutes.sol";
import {FWSSMetadataModule} from "./modules/FWSSMetadataModule.sol";
import {FWSSStorage} from "./storage/FWSSStorage.sol";

/// @title FWSSInitializer
/// @notice One-shot ERC-1967 implementation that initializes a fresh FWSS proxy as v1.4.0 `initialize` did, then
/// points it at the ERC-8167 dispatcher and runs the migration that installs the facets.
/// @dev Deploy the proxy with `initialize` as its constructor call: the proxy never runs this contract again.
contract FWSSInitializer is Initializable, EIP712Upgradeable, FWSSStorage, FWSSOwnable, FWSSMetadataModule {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event FilecoinServiceDeployed(string name, string description);

    /// @notice Initializes FWSS, owned by the caller, and moves it to the dispatcher
    /// @param _maxProvingPeriod Maximum proving period in epochs
    /// @param _challengeWindowSize Challenge window size in epochs, less than the proving period
    /// @param _filBeamControllerAddress The address allowed to settle and terminate CDN services
    /// @param dispatcher The pinned ERC-8167 dispatcher
    /// @param migration The migration that routes the facets' selectors
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
