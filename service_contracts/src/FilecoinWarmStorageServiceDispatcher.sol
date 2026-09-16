// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC8167Dispatcher} from "./ERC8167Dispatcher.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FWSSStorage} from "./storage/FWSSStorage.sol";

/// @notice Selector routing and upgrade administration; business delegates are installed separately.
contract FilecoinWarmStorageServiceDispatcher is ERC8167Dispatcher, OwnableUpgradeable, UUPSUpgradeable, FWSSStorage {
    error InvalidInitialAction();
    error NoRouteUpgradePlanned();
    error RouteUpgradeMismatch();
    error RouteUpgradeNotReady(uint96 afterEpoch);
    error EmptyRouteUpgrade();
    error InvalidUpgradeImplementation(address implementation);
    error UpgradeNotAnnounced(address implementation);
    error UpgradeNotReady(uint96 afterEpoch);
    enum Action {
        Add,
        Replace,
        Remove
    }

    struct RouteChange {
        bytes4 selector;
        Action action;
        address delegate;
    }

    /// @custom:storage-location erc7201:filecoin.storage.RouteUpgrade
    struct RouteUpgradeStorage {
        bytes32 changeHash;
        uint96 afterEpoch;
    }

    // keccak256(abi.encode(uint256(keccak256("filecoin.storage.RouteUpgrade")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROUTE_UPGRADE_STORAGE_LOCATION =
        0x6b6adb899fdc188b98c68fdb8ff01d880ebd6007e31f6d955018116949f5cf00;

    event RouteUpgradeAnnounced(bytes32 indexed changeHash, uint96 afterEpoch, RouteChange[] changes);
    event RouteUpgradeExecuted(bytes32 indexed changeHash);
    event RouteUpgradeCancelled(bytes32 indexed changeHash);
    event UpgradeAnnounced(PlannedUpgrade plannedUpgrade);

    function _routeUpgradeStorage() internal pure returns (RouteUpgradeStorage storage state) {
        assembly {
            state.slot := ROUTE_UPGRADE_STORAGE_LOCATION
        }
    }

    constructor() {
        _disableInitializers();
    }

    function announceUpgradePlan(address nextImplementation, uint96 delayEpochs) external onlyOwner {
        // Preserve the current FWSS announcement policy, including the minimum implementation size.
        require(nextImplementation.code.length > 3000, InvalidUpgradeImplementation(nextImplementation));
        if (delayEpochs == 0) delayEpochs = 1;
        nextUpgrade.nextImplementation = nextImplementation;
        nextUpgrade.afterEpoch = uint96(block.number) + delayEpochs;
        emit UpgradeAnnounced(nextUpgrade);
    }

    function pendingDispatcherUpgrade() external view returns (address, uint96) {
        return (nextUpgrade.nextImplementation, nextUpgrade.afterEpoch);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        require(newImplementation == nextUpgrade.nextImplementation, UpgradeNotAnnounced(newImplementation));
        require(block.number >= nextUpgrade.afterEpoch, UpgradeNotReady(nextUpgrade.afterEpoch));
        delete nextUpgrade;
        // Invalidate the old plan before the new implementation or its migration can execute.
        bytes32 changeHash = _clearRouteUpgrade();
        if (changeHash != bytes32(0)) emit RouteUpgradeCancelled(changeHash);
    }

    function cancelRouteUpgrade() external onlyOwner {
        bytes32 changeHash = _clearRouteUpgrade();
        require(changeHash != bytes32(0), NoRouteUpgradePlanned());
        emit RouteUpgradeCancelled(changeHash);
    }

    function _clearRouteUpgrade() internal returns (bytes32 changeHash) {
        RouteUpgradeStorage storage state = _routeUpgradeStorage();
        changeHash = state.changeHash;
        delete state.changeHash;
        delete state.afterEpoch;
    }

    /// @dev Replaces the pending plan. Route validity is checked at execution against the then-current routes.
    function announceRouteUpgrade(RouteChange[] calldata changes, uint96 delayEpochs) external onlyOwner {
        require(changes.length != 0, EmptyRouteUpgrade());
        if (delayEpochs == 0) delayEpochs = 1;
        RouteUpgradeStorage storage state = _routeUpgradeStorage();
        state.changeHash = keccak256(abi.encode(changes));
        state.afterEpoch = uint96(block.number) + delayEpochs;
        emit RouteUpgradeAnnounced(state.changeHash, state.afterEpoch, changes);
    }

    function pendingRouteUpgrade() external view returns (bytes32, uint96) {
        RouteUpgradeStorage storage state = _routeUpgradeStorage();
        return (state.changeHash, state.afterEpoch);
    }

    function executeRouteUpgrade(RouteChange[] calldata changes) external onlyOwner {
        RouteUpgradeStorage storage state = _routeUpgradeStorage();
        bytes32 changeHash = state.changeHash;
        require(changeHash != bytes32(0), NoRouteUpgradePlanned());
        require(changeHash == keccak256(abi.encode(changes)), RouteUpgradeMismatch());
        require(block.number >= state.afterEpoch, RouteUpgradeNotReady(state.afterEpoch));
        _clearRouteUpgrade();
        for (uint256 i; i < changes.length; ++i) {
            RouteChange calldata change = changes[i];
            if (change.action == Action.Add) {
                _addRoute(change.selector, change.delegate);
            } else if (change.action == Action.Replace) {
                _replaceRoute(change.selector, change.delegate);
            } else {
                require(change.delegate == address(0), InvalidDelegate(change.delegate));
                _removeRoute(change.selector);
            }
        }
        emit RouteUpgradeExecuted(changeHash);
    }

    /// @dev Fresh-proxy setup only. Existing FWSS proxies require a separate migration entry point.
    function initialize(address initialOwner, RouteChange[] calldata initialRoutes) external initializer onlyProxy {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        for (uint256 i; i < initialRoutes.length; ++i) {
            require(initialRoutes[i].action == Action.Add, InvalidInitialAction());
            _addRoute(initialRoutes[i].selector, initialRoutes[i].delegate);
        }
    }

    function _fixedSelectors() internal pure override returns (bytes4[] memory result) {
        result = new bytes4[](16);
        result[0] = this.implementation.selector;
        result[1] = this.selectors.selector;
        result[2] = this.owner.selector;
        result[3] = this.transferOwnership.selector;
        result[4] = this.renounceOwnership.selector;
        result[5] = this.initialize.selector;
        result[6] = this.announceRouteUpgrade.selector;
        result[7] = this.executeRouteUpgrade.selector;
        result[8] = this.pendingRouteUpgrade.selector;
        result[9] = this.cancelRouteUpgrade.selector;
        result[10] = this.announceUpgradePlan.selector;
        result[11] = this.pendingDispatcherUpgrade.selector;
        result[12] = this.upgradeToAndCall.selector;
        result[13] = this.proxiableUUID.selector;
        result[14] = this.UPGRADE_INTERFACE_VERSION.selector;
        result[15] = this.viewContractAddress.selector;
    }
}
