// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

// Minimum delay grows cubically from MIN to MAX over RAMP epochs since last upgrade
uint256 constant MIN_UPGRADE_DELAY = 10; // 5 min
uint256 constant MAX_UPGRADE_DELAY = 40_320; // 2 weeks
uint256 constant UPGRADE_HARDENING_RAMP = 161_280; // 8 weeks

/// @notice Abstract base that enforces a time-hardened minimum delay before upgrades can execute.
abstract contract UpgradeHardening is UUPSUpgradeable, OwnableUpgradeable {
    struct UpgradePlan {
        address nextImplementation;
        uint96 delay;
    }

    // Used for announcing upgrades, packed into one slot
    struct PlannedUpgrade {
        // Address of the new implementation contract
        address nextImplementation;
        // Upgrade will not occur until at least this epoch
        uint96 afterEpoch;
    }

    event UpgradeAnnounced(PlannedUpgrade plannedUpgrade);
    event ContractUpgraded(string version, address implementation);

    /// @dev Returns a storage reference to the pending upgrade slot. Subclass provides the location.
    function _nextUpgradeStorage() internal view virtual returns (PlannedUpgrade storage);

    /// @dev Returns a storage reference to the upgrade-epoch mapping. Subclass provides the location.
    function _upgradeEpochStorage() internal view virtual returns (mapping(string => uint256) storage);

    function _currentVersion() internal view virtual returns (string memory);

    function upgradeEpoch(string calldata version) external view returns (uint256) {
        return _upgradeEpochStorage()[version];
    }

    function announceUpgradePlan(UpgradePlan calldata upgradePlan) external {
        PlannedUpgrade memory plannedUpgrade =
            PlannedUpgrade(upgradePlan.nextImplementation, uint96(block.number) + upgradePlan.delay);
        _announcePlannedUpgrade(plannedUpgrade);
    }

    /// @custom:deprecated Use announceUpgradePlan instead
    function announcePlannedUpgrade(PlannedUpgrade calldata plannedUpgrade) external {
        _announcePlannedUpgrade(plannedUpgrade);
    }

    function _announcePlannedUpgrade(PlannedUpgrade memory plannedUpgrade) internal onlyOwner {
        require(plannedUpgrade.nextImplementation.code.length > 3000);
        uint256 minAfterEpoch = block.number + _hardenedMinDelay();
        if (plannedUpgrade.afterEpoch < minAfterEpoch) {
            plannedUpgrade.afterEpoch = uint96(minAfterEpoch);
        }
        PlannedUpgrade storage $ = _nextUpgradeStorage();
        $.nextImplementation = plannedUpgrade.nextImplementation;
        $.afterEpoch = plannedUpgrade.afterEpoch;
        emit UpgradeAnnounced(plannedUpgrade);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        PlannedUpgrade storage $ = _nextUpgradeStorage();
        require(newImplementation == $.nextImplementation);
        require(block.number >= $.afterEpoch);
        $.nextImplementation = address(0);
        $.afterEpoch = 0;
    }

    function _hardenedMinDelay() internal view returns (uint256) {
        uint256 lastUpgrade = _upgradeEpochStorage()[_currentVersion()];
        if (lastUpgrade == 0) return MIN_UPGRADE_DELAY;
        uint256 age = block.number - lastUpgrade;
        uint256 t = age < UPGRADE_HARDENING_RAMP ? age : UPGRADE_HARDENING_RAMP;
        uint256 ramp = UPGRADE_HARDENING_RAMP;
        return MIN_UPGRADE_DELAY + (MAX_UPGRADE_DELAY - MIN_UPGRADE_DELAY) * t * t * t / (ramp * ramp * ramp);
    }

    function _recordUpgrade(string memory version) internal {
        _upgradeEpochStorage()[version] = block.number;
        emit ContractUpgraded(version, ERC1967Utils.getImplementation());
    }
}
