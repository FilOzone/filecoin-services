// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FWSSDispatcher} from "../src/FWSSDispatcher.sol";
import {FWSSStateViewManager} from "../src/FWSSStateViewManager.sol";
import {Errors} from "../src/Errors.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract FWSSStateViewManagerTest is Test {
    FWSSDispatcher internal proxy;
    FWSSStateViewManager internal module;
    FWSSStateViewManager internal manager;
    address internal owner;

    function setUp() public {
        owner = makeAddr("owner");
        module = new FWSSStateViewManager();
        FWSSDispatcher dispatcher = new FWSSDispatcher();
        FWSSDispatcher.RouteChange[] memory routes = new FWSSDispatcher.RouteChange[](2);
        routes[0] = FWSSDispatcher.RouteChange(
            FWSSStateViewManager.viewContractAddress.selector, FWSSDispatcher.Action.Add, address(module)
        );
        routes[1] = FWSSDispatcher.RouteChange(
            FWSSStateViewManager.setViewContract.selector, FWSSDispatcher.Action.Add, address(module)
        );
        proxy = FWSSDispatcher(
            payable(address(
                    new ERC1967Proxy(address(dispatcher), abi.encodeCall(FWSSDispatcher.initialize, (owner, routes)))
                ))
        );
        manager = FWSSStateViewManager(address(proxy));
    }

    function testGetterReadsExistingLegacyAddressThroughRoute() public {
        address previousView = makeAddr("previousView");
        vm.store(address(proxy), bytes32(uint256(17)), bytes32(uint256(uint160(previousView))));

        assertEq(manager.viewContractAddress(), previousView);
        assertEq(proxy.implementation(FWSSStateViewManager.viewContractAddress.selector), address(module));
        assertEq(module.viewContractAddress(), address(0));
    }

    function testOwnerCanReplaceAddressWithoutChangingAdjacentSlots() public {
        vm.store(address(proxy), bytes32(uint256(16)), bytes32(uint256(123)));
        vm.store(address(proxy), bytes32(uint256(18)), bytes32(uint256(456)));
        vm.store(address(proxy), bytes32(uint256(19)), bytes32(uint256(789)));
        address firstView = makeAddr("firstView");
        address replacementView = makeAddr("replacementView");

        vm.prank(owner);
        manager.setViewContract(firstView);
        assertEq(manager.viewContractAddress(), firstView);

        vm.expectEmit(true, false, false, true, address(proxy));
        emit FWSSStateViewManager.ViewContractSet(replacementView);
        vm.prank(owner);
        manager.setViewContract(replacementView);

        assertEq(manager.viewContractAddress(), replacementView);
        assertEq(vm.load(address(proxy), bytes32(uint256(17))), bytes32(uint256(uint160(replacementView))));
        assertEq(vm.load(address(proxy), bytes32(uint256(16))), bytes32(uint256(123)));
        assertEq(vm.load(address(proxy), bytes32(uint256(18))), bytes32(uint256(456)));
        assertEq(vm.load(address(proxy), bytes32(uint256(19))), bytes32(uint256(789)));
    }

    function testSetterRejectsNonOwnerAndZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        manager.setViewContract(makeAddr("view"));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.View));
        manager.setViewContract(address(0));

        assertEq(manager.viewContractAddress(), address(0));
    }

    function testSetterUsesTransferredProxyOwnership() public {
        address newOwner = makeAddr("newOwner");
        address stateView = makeAddr("view");
        vm.prank(owner);
        proxy.transferOwnership(newOwner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        manager.setViewContract(stateView);

        vm.prank(newOwner);
        manager.setViewContract(stateView);
        assertEq(manager.viewContractAddress(), stateView);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, newOwner));
        module.setViewContract(stateView);
    }

    function testReplacingManagerPreservesAddressAndOwnership() public {
        address stateView = makeAddr("view");
        vm.prank(owner);
        manager.setViewContract(stateView);
        FWSSStateViewManager replacement = new FWSSStateViewManager();
        FWSSDispatcher.RouteChange[] memory changes = new FWSSDispatcher.RouteChange[](2);
        changes[0] = FWSSDispatcher.RouteChange(
            FWSSStateViewManager.viewContractAddress.selector, FWSSDispatcher.Action.Replace, address(replacement)
        );
        changes[1] = FWSSDispatcher.RouteChange(
            FWSSStateViewManager.setViewContract.selector, FWSSDispatcher.Action.Replace, address(replacement)
        );

        vm.prank(owner);
        proxy.announceRouteUpgrade(changes, 1);
        vm.roll(block.number + 1);
        vm.prank(owner);
        proxy.executeRouteUpgrade(changes);

        assertEq(proxy.implementation(FWSSStateViewManager.viewContractAddress.selector), address(replacement));
        assertEq(proxy.implementation(FWSSStateViewManager.setViewContract.selector), address(replacement));
        assertEq(manager.viewContractAddress(), stateView);
        assertEq(proxy.owner(), owner);

        address nextView = makeAddr("nextView");
        vm.prank(owner);
        manager.setViewContract(nextView);
        assertEq(manager.viewContractAddress(), nextView);
    }
}
