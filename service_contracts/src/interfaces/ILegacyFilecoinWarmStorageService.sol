// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {IFilecoinWarmStorageService} from "./IFilecoinWarmStorageService.sol";

/// @title ILegacyFilecoinWarmStorageService
/// @notice The v1.4.0 monolith's functions that no facet routes, which the dispatcher transition still calls.
/// @dev Its `migrate(address)` shares a selector with the facets' and is inherited.
interface ILegacyFilecoinWarmStorageService is IFilecoinWarmStorageService {
    function initialize(uint64 _maxProvingPeriod, uint256 _challengeWindowSize, address _filBeamControllerAddress)
        external;
    function announceUpgradePlan(address nextImplementation, uint96 delayEpochs) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
