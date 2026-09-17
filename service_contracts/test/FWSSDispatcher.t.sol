// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FWSSDispatcher as Dispatcher} from "../src/FWSSDispatcher.sol";
import {RoutingDelegate} from "./ERC8167Dispatcher.t.sol";
import {IERC8167} from "../src/interfaces/IERC8167.sol";
import {ERC8167Dispatcher} from "../src/ERC8167Dispatcher.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract WrongUUIDDispatcher is Dispatcher {
    function proxiableUUID() external pure override returns (bytes32) {
        return bytes32(0);
    }
}

contract FWSSDispatcherTest is Test {
    Dispatcher internal dispatcher;
    Dispatcher internal proxy;
    RoutingDelegate internal module;
    address internal owner;

    function setUp() public {
        owner = makeAddr("owner");
        module = new RoutingDelegate();
        dispatcher = new Dispatcher();
        Dispatcher.RouteChange[] memory initial =
            _change(RoutingDelegate.store.selector, Dispatcher.Action.Add, address(module));
        proxy = Dispatcher(
            payable(address(
                    new ERC1967Proxy(address(dispatcher), abi.encodeCall(Dispatcher.initialize, (owner, initial)))
                ))
        );
    }

    function _change(bytes4 selector, Dispatcher.Action action, address delegate)
        internal
        pure
        returns (Dispatcher.RouteChange[] memory changes)
    {
        changes = new Dispatcher.RouteChange[](1);
        changes[0] = Dispatcher.RouteChange({selector: selector, action: action, delegate: delegate});
    }

    function testInitialOwnerAndRoutesAreInstalled() public view {
        assertEq(proxy.owner(), owner);
        assertEq(proxy.implementation(RoutingDelegate.store.selector), address(module));
    }

    function testInspectionMatchesCompiledDispatcherMethods() public {
        Dispatcher emptyProxy = Dispatcher(
            payable(address(
                    new ERC1967Proxy(
                        address(dispatcher),
                        abi.encodeCall(Dispatcher.initialize, (owner, new Dispatcher.RouteChange[](0)))
                    )
                ))
        );
        string memory artifact = vm.readFile("out/FWSSDispatcher.sol/FWSSDispatcher.json");
        string[] memory signatures = vm.parseJsonKeys(artifact, ".methodIdentifiers");
        bytes4[] memory installed = emptyProxy.selectors();

        assertGt(signatures.length, 0);
        assertEq(installed.length, signatures.length);

        for (uint256 i; i < signatures.length; ++i) {
            bytes4 selector = bytes4(keccak256(bytes(signatures[i])));
            uint256 occurrences;

            for (uint256 j; j < installed.length; ++j) {
                if (installed[j] == selector) ++occurrences;
            }

            assertEq(occurrences, 1, signatures[i]);
            assertEq(emptyProxy.implementation(selector), address(dispatcher), signatures[i]);
        }
    }

    function testDispatcherUpgradeRequiresOwnerAnnouncedAddressAndDelay() public {
        Dispatcher replacement = new Dispatcher();
        Dispatcher other = new Dispatcher();
        vm.expectRevert();
        proxy.announceUpgradePlan(address(replacement), 0);
        vm.prank(owner);
        vm.expectRevert();
        proxy.upgradeToAndCall(address(replacement), "");
        vm.prank(owner);
        proxy.announceUpgradePlan(address(replacement), 0);
        (, uint96 afterEpoch) = proxy.pendingDispatcherUpgrade();
        assertEq(afterEpoch, block.number + 1);
        vm.prank(owner);
        vm.expectRevert();
        proxy.upgradeToAndCall(address(replacement), "");
        vm.roll(afterEpoch);
        vm.expectRevert();
        proxy.upgradeToAndCall(address(replacement), "");
        vm.prank(owner);
        vm.expectRevert();
        proxy.upgradeToAndCall(address(other), "");
        vm.prank(owner);
        proxy.announceUpgradePlan(address(other), 5);
        vm.prank(owner);
        vm.expectRevert();
        proxy.upgradeToAndCall(address(replacement), "");
        vm.prank(owner);
        vm.expectRevert();
        proxy.upgradeToAndCall(address(other), "");
        vm.roll(block.number + 5);
        vm.prank(owner);
        proxy.upgradeToAndCall(address(other), "");
        assertEq(proxy.implementation(proxy.owner.selector), address(other));
    }

    function testRevertedUpgradeCallPreservesBothAnnouncements() public {
        _assertUpgradeRollback(false);
    }

    function testRejectedUUPSImplementationPreservesBothAnnouncements() public {
        _assertUpgradeRollback(true);
    }

    function _assertUpgradeRollback(bool wrongUUID) internal {
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        (bytes32 routeHash, uint96 routeEpoch) = proxy.pendingRouteUpgrade();
        address replacement = wrongUUID ? address(new WrongUUIDDispatcher()) : address(new Dispatcher());
        vm.prank(owner);
        proxy.announceUpgradePlan(replacement, 1);
        (, uint96 upgradeEpoch) = proxy.pendingDispatcherUpgrade();
        vm.roll(upgradeEpoch);
        bytes memory migration = wrongUUID ? bytes("") : abi.encodeCall(Dispatcher.initialize, (owner, changes));
        vm.prank(owner);
        vm.expectRevert();
        proxy.upgradeToAndCall(replacement, migration);
        assertEq(proxy.implementation(proxy.owner.selector), address(dispatcher));
        (bytes32 remainingHash, uint96 remainingEpoch) = proxy.pendingRouteUpgrade();
        assertEq(remainingHash, routeHash);
        assertEq(remainingEpoch, routeEpoch);
        (address remainingImplementation, uint96 remainingUpgradeEpoch) = proxy.pendingDispatcherUpgrade();
        assertEq(remainingImplementation, replacement);
        assertEq(remainingUpgradeEpoch, upgradeEpoch);
        vm.prank(owner);
        proxy.executeRouteUpgrade(changes);
        assertEq(proxy.implementation(RoutingDelegate.fail.selector), address(module));
        (remainingImplementation,) = proxy.pendingDispatcherUpgrade();
        assertEq(remainingImplementation, replacement);
    }

    function testRouteCancellationDoesNotCancelDispatcherUpgrade() public {
        Dispatcher replacement = new Dispatcher();
        vm.prank(owner);
        proxy.announceUpgradePlan(address(replacement), 10);
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        vm.prank(owner);
        proxy.cancelRouteUpgrade();
        (address remaining, uint96 afterEpoch) = proxy.pendingDispatcherUpgrade();
        assertEq(remaining, address(replacement));
        assertEq(afterEpoch, block.number + 10);
    }

    function testUUPSCallContextGuardsArePreserved() public {
        assertEq(dispatcher.proxiableUUID(), ERC1967Utils.IMPLEMENTATION_SLOT);
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        proxy.proxiableUUID();
        vm.prank(owner);
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        dispatcher.upgradeToAndCall(address(dispatcher), "");
    }

    function testAnnouncementDelayOverflowAndSmallUpgradeTargetAreRejected() public {
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        proxy.announceRouteUpgrade(changes, type(uint96).max);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        proxy.announceUpgradePlan(address(dispatcher), type(uint96).max);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Dispatcher.InvalidUpgradeImplementation.selector, address(module)));
        proxy.announceUpgradePlan(address(module), 1);
    }

    function testInitializationRejectsInvalidOwnerActionsAndReservedSelectors() public {
        Dispatcher.RouteChange[] memory initial = new Dispatcher.RouteChange[](0);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(dispatcher), abi.encodeCall(Dispatcher.initialize, (address(0), initial)));
        initial = _change(RoutingDelegate.store.selector, Dispatcher.Action.Replace, address(module));
        vm.expectRevert(Dispatcher.InvalidInitialAction.selector);
        new ERC1967Proxy(address(dispatcher), abi.encodeCall(Dispatcher.initialize, (owner, initial)));
        initial = _change(proxy.upgradeToAndCall.selector, Dispatcher.Action.Add, address(module));
        vm.expectRevert(
            abi.encodeWithSelector(ERC8167Dispatcher.FixedSelector.selector, proxy.upgradeToAndCall.selector)
        );
        new ERC1967Proxy(address(dispatcher), abi.encodeCall(Dispatcher.initialize, (owner, initial)));
    }

    function testSuccessfulDispatcherUpgradeInvalidatesThePendingRoutePlan() public {
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        Dispatcher replacement = new Dispatcher();
        vm.prank(owner);
        proxy.announceUpgradePlan(address(replacement), 1);
        vm.roll(block.number + 1);
        vm.prank(owner);
        proxy.upgradeToAndCall(address(replacement), "");
        (bytes32 commitment, uint96 afterEpoch) = proxy.pendingRouteUpgrade();
        assertEq(commitment, bytes32(0));
        assertEq(afterEpoch, 0);
        vm.prank(owner);
        vm.expectRevert(Dispatcher.NoRouteUpgradePlanned.selector);
        proxy.executeRouteUpgrade(changes);
        _execute(changes);
    }

    function testDispatcherUpgradePreservesOwnerRoutesAndStoredValues() public {
        _execute(_change(bytes4(keccak256("value()")), Dispatcher.Action.Add, address(module)));
        RoutingDelegate(address(proxy)).store(42, "");
        Dispatcher replacement = new Dispatcher();
        vm.prank(owner);
        proxy.announceUpgradePlan(address(replacement), 5);
        (address next, uint96 afterEpoch) = proxy.pendingDispatcherUpgrade();
        assertEq(next, address(replacement));
        assertEq(afterEpoch, block.number + 5);
        vm.roll(afterEpoch);
        vm.prank(owner);
        proxy.upgradeToAndCall(address(replacement), "");
        assertEq(proxy.implementation(proxy.selectors.selector), address(replacement));
        assertEq(proxy.owner(), owner);
        assertEq(proxy.implementation(RoutingDelegate.store.selector), address(module));
        assertEq(RoutingDelegate(address(proxy)).value(), 42);
        (next, afterEpoch) = proxy.pendingDispatcherUpgrade();
        assertEq(next, address(0));
        assertEq(afterEpoch, 0);
        _execute(_change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module)));
        assertEq(proxy.implementation(RoutingDelegate.fail.selector), address(module));
    }

    function testBatchFailureRollsBackEarlierChangesAndKeepsTheAnnouncement() public {
        Dispatcher.RouteChange[] memory changes = new Dispatcher.RouteChange[](2);
        changes[0] = Dispatcher.RouteChange({
            selector: RoutingDelegate.fail.selector, action: Dispatcher.Action.Add, delegate: address(module)
        });
        changes[1] = Dispatcher.RouteChange({
            selector: RoutingDelegate.store.selector, action: Dispatcher.Action.Add, delegate: address(module)
        });
        uint256 countBefore = proxy.selectors().length;
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        (bytes32 beforeHash, uint96 beforeEpoch) = proxy.pendingRouteUpgrade();
        vm.roll(beforeEpoch);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ERC8167Dispatcher.SelectorAlreadyInstalled.selector, RoutingDelegate.store.selector)
        );
        proxy.executeRouteUpgrade(changes);
        assertEq(proxy.implementation(RoutingDelegate.fail.selector), address(0));
        assertEq(proxy.implementation(RoutingDelegate.store.selector), address(module));
        assertEq(proxy.selectors().length, countBefore);
        (bytes32 afterHash, uint96 afterEpoch) = proxy.pendingRouteUpgrade();
        assertEq(afterHash, beforeHash);
        assertEq(afterEpoch, beforeEpoch);
    }

    function testUnauthorizedAccountsCannotAnnounceOrExecute() public {
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        proxy.announceRouteUpgrade(changes, 1);
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        proxy.executeRouteUpgrade(changes);
    }

    function testInitializationIsLockedOnImplementationAndCannotRepeatOnProxy() public {
        Dispatcher.RouteChange[] memory initial = new Dispatcher.RouteChange[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        dispatcher.initialize(address(this), initial);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        proxy.initialize(address(this), initial);
    }

    function testInvalidRemoveAndReplaceOperationsLeaveRoutesIntact() public {
        Dispatcher.RouteChange[] memory invalid = new Dispatcher.RouteChange[](5);
        invalid[0] = Dispatcher.RouteChange({
            selector: RoutingDelegate.fail.selector, action: Dispatcher.Action.Replace, delegate: address(module)
        });
        invalid[1] = Dispatcher.RouteChange({
            selector: RoutingDelegate.store.selector, action: Dispatcher.Action.Replace, delegate: address(module)
        });
        invalid[2] = Dispatcher.RouteChange({
            selector: RoutingDelegate.store.selector, action: Dispatcher.Action.Replace, delegate: address(0)
        });
        invalid[3] = Dispatcher.RouteChange({
            selector: RoutingDelegate.fail.selector, action: Dispatcher.Action.Remove, delegate: address(0)
        });
        invalid[4] = Dispatcher.RouteChange({
            selector: RoutingDelegate.store.selector, action: Dispatcher.Action.Remove, delegate: address(module)
        });
        for (uint256 i; i < invalid.length; ++i) {
            Dispatcher.RouteChange[] memory changes = new Dispatcher.RouteChange[](1);
            changes[0] = invalid[i];
            vm.prank(owner);
            proxy.announceRouteUpgrade(changes, 1);
            vm.roll(block.number + 1);
            vm.prank(owner);
            vm.expectRevert();
            proxy.executeRouteUpgrade(changes);
            assertEq(proxy.implementation(RoutingDelegate.store.selector), address(module));
        }
    }

    function testRouteEventsExposeAnnouncementExecutionAndCancellation() public {
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        bytes32 changeHash = keccak256(abi.encode(changes));
        vm.expectEmit(true, false, false, true, address(proxy));
        emit Dispatcher.RouteUpgradeAnnounced(changeHash, uint96(block.number + 1), changes);
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        vm.roll(block.number + 1);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit IERC8167.SelectorDelegated(RoutingDelegate.fail.selector, address(module));
        vm.expectEmit(true, false, false, true, address(proxy));
        emit Dispatcher.RouteUpgradeExecuted(changeHash);
        vm.prank(owner);
        proxy.executeRouteUpgrade(changes);
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        vm.expectEmit(true, false, false, true, address(proxy));
        emit Dispatcher.RouteUpgradeCancelled(changeHash);
        vm.prank(owner);
        proxy.cancelRouteUpgrade();
    }

    function testFuzzRemovalAndReadditionKeepEnumerationConsistent(uint8 countSeed, uint8 indexSeed) public {
        uint256 count = bound(countSeed, 1, 8);
        uint256 index = uint256(indexSeed) % count;
        uint256 initialCount = proxy.selectors().length;
        Dispatcher.RouteChange[] memory changes = new Dispatcher.RouteChange[](count);
        for (uint256 i; i < count; ++i) {
            changes[i] = Dispatcher.RouteChange({
                selector: bytes4(uint32(0x10000000 + i)), action: Dispatcher.Action.Add, delegate: address(module)
            });
        }
        _execute(changes);
        bytes4 removed = changes[index].selector;
        _execute(_change(removed, Dispatcher.Action.Remove, address(0)));
        assertEq(proxy.implementation(removed), address(0));
        _execute(_change(removed, Dispatcher.Action.Add, address(module)));
        assertEq(proxy.selectors().length, initialCount + count);
        for (uint256 i; i < count; ++i) {
            assertEq(proxy.implementation(changes[i].selector), address(module));
            changes[i].action = Dispatcher.Action.Remove;
            changes[i].delegate = address(0);
        }
        _execute(changes);
        assertEq(proxy.selectors().length, initialCount);
        assertEq(proxy.implementation(RoutingDelegate.store.selector), address(module));
    }

    function testEmptyAnnouncementDoesNotReplacePendingPlan() public {
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        (bytes32 beforeHash, uint96 beforeEpoch) = proxy.pendingRouteUpgrade();
        vm.prank(owner);
        vm.expectRevert();
        proxy.announceRouteUpgrade(new Dispatcher.RouteChange[](0), 1);
        (bytes32 afterHash, uint96 afterEpoch) = proxy.pendingRouteUpgrade();
        assertEq(afterHash, beforeHash);
        assertEq(afterEpoch, beforeEpoch);
    }

    function testAdministrationIsDiscoverableAndCannotBeAddedReplacedOrRemoved() public {
        bytes4[14] memory administrationSelectors = [
            proxy.owner.selector,
            proxy.transferOwnership.selector,
            proxy.renounceOwnership.selector,
            proxy.initialize.selector,
            proxy.announceRouteUpgrade.selector,
            proxy.executeRouteUpgrade.selector,
            proxy.pendingRouteUpgrade.selector,
            proxy.cancelRouteUpgrade.selector,
            proxy.announceUpgradePlan.selector,
            proxy.pendingDispatcherUpgrade.selector,
            proxy.upgradeToAndCall.selector,
            proxy.proxiableUUID.selector,
            proxy.UPGRADE_INTERFACE_VERSION.selector,
            proxy.viewContractAddress.selector
        ];
        for (uint256 i; i < administrationSelectors.length; ++i) {
            assertEq(proxy.implementation(administrationSelectors[i]), address(dispatcher));
            for (uint256 j; j < 3; ++j) {
                Dispatcher.Action action = Dispatcher.Action(j);
                Dispatcher.RouteChange[] memory changes = _change(
                    administrationSelectors[i],
                    action,
                    action == Dispatcher.Action.Remove ? address(0) : address(module)
                );
                vm.prank(owner);
                proxy.announceRouteUpgrade(changes, 1);
                vm.roll(block.number + 1);
                vm.prank(owner);
                vm.expectRevert();
                proxy.executeRouteUpgrade(changes);
            }
        }
        uint256 inspectionSelectorCount = 2;
        uint256 installedRouteCount = 1;
        assertEq(
            proxy.selectors().length, administrationSelectors.length + inspectionSelectorCount + installedRouteCount
        );
    }

    function _execute(Dispatcher.RouteChange[] memory changes) internal {
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        vm.roll(block.number + 1);
        vm.prank(owner);
        proxy.executeRouteUpgrade(changes);
    }

    function testMixedBatchReplacesAndRemovesRoutesWithoutLosingStorageOrEnumeration() public {
        RoutingDelegate replacement = new RoutingDelegate();
        RoutingDelegate(address(proxy)).store(42, "");
        Dispatcher.RouteChange[] memory changes = new Dispatcher.RouteChange[](3);
        bytes4 getter = bytes4(keccak256("value()"));
        changes[0] =
            Dispatcher.RouteChange({selector: getter, action: Dispatcher.Action.Add, delegate: address(replacement)});
        changes[1] = Dispatcher.RouteChange({
            selector: RoutingDelegate.store.selector, action: Dispatcher.Action.Replace, delegate: address(replacement)
        });
        changes[2] = Dispatcher.RouteChange({
            selector: RoutingDelegate.fail.selector, action: Dispatcher.Action.Add, delegate: address(module)
        });
        _execute(changes);
        assertEq(proxy.implementation(RoutingDelegate.store.selector), address(replacement));
        assertEq(RoutingDelegate(address(proxy)).value(), 42);
        assertEq(replacement.value(), 0);
        uint256 countBefore = proxy.selectors().length;

        changes = new Dispatcher.RouteChange[](2);
        changes[0] = Dispatcher.RouteChange({
            selector: RoutingDelegate.store.selector, action: Dispatcher.Action.Remove, delegate: address(0)
        });
        changes[1] = Dispatcher.RouteChange({
            selector: RoutingDelegate.fail.selector, action: Dispatcher.Action.Remove, delegate: address(0)
        });
        _execute(changes);
        assertEq(proxy.implementation(RoutingDelegate.store.selector), address(0));
        assertEq(proxy.implementation(RoutingDelegate.fail.selector), address(0));
        assertEq(proxy.selectors().length, countBefore - 2);
        assertEq(RoutingDelegate(address(proxy)).value(), 42);
        _execute(_change(getter, Dispatcher.Action.Remove, address(0)));
        assertEq(proxy.selectors().length, countBefore - 3);
    }

    function testOwnerCanCancelWithoutChangingRoutes() public {
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        vm.expectRevert();
        proxy.cancelRouteUpgrade();
        vm.prank(owner);
        proxy.cancelRouteUpgrade();
        (bytes32 commitment, uint96 afterEpoch) = proxy.pendingRouteUpgrade();
        assertEq(commitment, bytes32(0));
        assertEq(afterEpoch, 0);
        assertEq(proxy.implementation(RoutingDelegate.store.selector), address(module));
        vm.roll(block.number + 1);
        vm.prank(owner);
        vm.expectRevert();
        proxy.executeRouteUpgrade(changes);
    }

    function testReannouncementReplacesThePlanAndRestartsMinimumDelay() public {
        Dispatcher.RouteChange[] memory first =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        Dispatcher.RouteChange[] memory second = _change(bytes4(0x12345678), Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        proxy.announceRouteUpgrade(first, 3);
        vm.roll(block.number + 3);
        vm.prank(owner);
        proxy.announceRouteUpgrade(second, 0);
        (, uint96 afterEpoch) = proxy.pendingRouteUpgrade();
        assertEq(afterEpoch, block.number + 1);
        vm.prank(owner);
        vm.expectRevert();
        proxy.executeRouteUpgrade(second);
        vm.roll(afterEpoch);
        vm.prank(owner);
        vm.expectRevert();
        proxy.executeRouteUpgrade(first);
        vm.prank(owner);
        proxy.executeRouteUpgrade(second);
        assertEq(proxy.implementation(RoutingDelegate.fail.selector), address(0));
        assertEq(proxy.implementation(bytes4(0x12345678)), address(module));
    }

    function testRouteExecutionRequiresTheAnnouncedPayloadAndDelay() public {
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        vm.expectRevert();
        proxy.executeRouteUpgrade(changes);
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 10);
        vm.prank(owner);
        vm.expectRevert();
        proxy.executeRouteUpgrade(changes);
        vm.roll(block.number + 10);
        Dispatcher.RouteChange[] memory other = _change(bytes4(0x12345678), Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        vm.expectRevert();
        proxy.executeRouteUpgrade(other);
        vm.prank(owner);
        proxy.executeRouteUpgrade(changes);
        vm.prank(owner);
        vm.expectRevert();
        proxy.executeRouteUpgrade(changes);
    }

    function testAnnouncedAdditionExecutesAfterDelayAndConsumesPlan() public {
        Dispatcher.RouteChange[] memory changes =
            _change(RoutingDelegate.fail.selector, Dispatcher.Action.Add, address(module));
        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 10);
        (bytes32 commitment, uint96 afterEpoch) = proxy.pendingRouteUpgrade();
        assertTrue(commitment != bytes32(0));
        assertEq(afterEpoch, block.number + 10);
        assertEq(proxy.implementation(RoutingDelegate.fail.selector), address(0));
        vm.roll(afterEpoch);
        vm.prank(owner);
        proxy.executeRouteUpgrade(changes);
        assertEq(proxy.implementation(RoutingDelegate.fail.selector), address(module));
        (commitment, afterEpoch) = proxy.pendingRouteUpgrade();
        assertEq(commitment, bytes32(0));
        assertEq(afterEpoch, 0);
    }
}
