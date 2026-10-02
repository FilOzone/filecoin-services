// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {ERC8167Transition} from "./ERC8167Transition.sol";
import {FWSSOwnable} from "./lib/FWSSOwnable.sol";
import {LibUpgradeRoutes} from "./lib/LibUpgradeRoutes.sol";

/// @title FWSSDispatcherTransition
/// @notice Moves the FWSS proxy from the v1.4.0 UUPS monolith to the ERC-8167 dispatcher in one upgrade call.
contract FWSSDispatcherTransition is ERC8167Transition, FWSSOwnable {
    // Runtime hash of Proxy.evm at the pinned ERC-8167 revision.
    bytes32 private constant DISPATCHER_CODE_HASH = 0x108d179021d554c7ad078adb0e30b9afbe6e022acfcd59ac878b2b684f29550a;

    // v1.4.0 announceUpgradePlan only accepts implementations over 3000 bytes of code. Distinct 32-byte lines keep the
    // optimizer from folding the padding; the transition tests pin the resulting size.
    bytes private constant LEGACY_UPGRADE_PADDING = "FWSS 1.4.0 code size padding 001"
        "FWSS 1.4.0 code size padding 002" "FWSS 1.4.0 code size padding 003" "FWSS 1.4.0 code size padding 004"
        "FWSS 1.4.0 code size padding 005" "FWSS 1.4.0 code size padding 006" "FWSS 1.4.0 code size padding 007"
        "FWSS 1.4.0 code size padding 008" "FWSS 1.4.0 code size padding 009" "FWSS 1.4.0 code size padding 010"
        "FWSS 1.4.0 code size padding 011" "FWSS 1.4.0 code size padding 012" "FWSS 1.4.0 code size padding 013"
        "FWSS 1.4.0 code size padding 014" "FWSS 1.4.0 code size padding 015" "FWSS 1.4.0 code size padding 016"
        "FWSS 1.4.0 code size padding 017" "FWSS 1.4.0 code size padding 018" "FWSS 1.4.0 code size padding 019"
        "FWSS 1.4.0 code size padding 020" "FWSS 1.4.0 code size padding 021" "FWSS 1.4.0 code size padding 022"
        "FWSS 1.4.0 code size padding 023" "FWSS 1.4.0 code size padding 024" "FWSS 1.4.0 code size padding 025"
        "FWSS 1.4.0 code size padding 026" "FWSS 1.4.0 code size padding 027" "FWSS 1.4.0 code size padding 028"
        "FWSS 1.4.0 code size padding 029" "FWSS 1.4.0 code size padding 030" "FWSS 1.4.0 code size padding 031"
        "FWSS 1.4.0 code size padding 032" "FWSS 1.4.0 code size padding 033" "FWSS 1.4.0 code size padding 034"
        "FWSS 1.4.0 code size padding 035" "FWSS 1.4.0 code size padding 036" "FWSS 1.4.0 code size padding 037"
        "FWSS 1.4.0 code size padding 038" "FWSS 1.4.0 code size padding 039" "FWSS 1.4.0 code size padding 040";

    constructor(address dispatcher_, address migration_) ERC8167Transition(dispatcher_, migration_) {
        require(dispatcher_.codehash == DISPATCHER_CODE_HASH, InvalidTransition());
    }

    /// @notice Padding that lets v1.4.0 announce this contract as its next implementation
    /// @return The padding bytes
    function legacyUpgradePadding() external pure returns (bytes memory) {
        return LEGACY_UPGRADE_PADDING;
    }

    function _authorizeTransition() internal view override {
        _requireOwner();
    }

    function _checkRoutes() internal view override {
        LibUpgradeRoutes.requireUpgradeRoutes(dispatcher);
    }
}
