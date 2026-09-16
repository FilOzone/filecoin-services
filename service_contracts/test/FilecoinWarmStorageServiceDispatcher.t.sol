// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FilecoinWarmStorageServiceDispatcher as Dispatcher} from "../src/FilecoinWarmStorageServiceDispatcher.sol";
import {RoutingDelegate} from "./ERC8167Dispatcher.t.sol";
import {IERC8167} from "../src/interfaces/IERC8167.sol";
import {ERC8167Dispatcher} from "../src/ERC8167Dispatcher.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract FilecoinWarmStorageServiceDispatcherTest is Test {
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
        bytes4[8] memory fixedSelectors = [
            proxy.owner.selector,
            proxy.transferOwnership.selector,
            proxy.renounceOwnership.selector,
            proxy.initialize.selector,
            proxy.announceRouteUpgrade.selector,
            proxy.executeRouteUpgrade.selector,
            proxy.pendingRouteUpgrade.selector,
            proxy.cancelRouteUpgrade.selector
        ];
        for (uint256 i; i < fixedSelectors.length; ++i) {
            assertEq(proxy.implementation(fixedSelectors[i]), address(dispatcher));
            for (uint256 j; j < 3; ++j) {
                Dispatcher.Action action = Dispatcher.Action(j);
                Dispatcher.RouteChange[] memory changes = _change(
                    fixedSelectors[i], action, action == Dispatcher.Action.Remove ? address(0) : address(module)
                );
                vm.prank(owner);
                proxy.announceRouteUpgrade(changes, 1);
                vm.roll(block.number + 1);
                vm.prank(owner);
                vm.expectRevert();
                proxy.executeRouteUpgrade(changes);
            }
        }
        assertEq(proxy.selectors().length, fixedSelectors.length + 3);
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
