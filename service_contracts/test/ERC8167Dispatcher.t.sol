// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC8167Dispatcher} from "../src/ERC8167Dispatcher.sol";
import {IERC8167} from "../src/interfaces/IERC8167.sol";

contract RoutingHarness is ERC8167Dispatcher {
    function initialize(bytes4[] memory initialSelectors, address delegate) external {
        for (uint256 i; i < initialSelectors.length; ++i) {
            _addRoute(initialSelectors[i], delegate);
        }
    }
}

contract RoutingDelegate {
    uint256 public value;

    function store(uint256 next, bytes calldata payload) external payable returns (address, uint256, bytes memory) {
        value = next;
        return (msg.sender, msg.value, payload);
    }

    error Rejected(uint256 value);

    function fail(uint256 reason) external pure {
        revert Rejected(reason);
    }
}

contract ERC8167DispatcherTest is Test {
    function testEmptyCalldataIsRejectedEvenWithAZeroSelectorRoute() public {
        RoutingDelegate delegate = new RoutingDelegate();
        bytes4[] memory initialSelectors = new bytes4[](1);
        address proxy = address(
            new ERC1967Proxy(
                address(new RoutingHarness()),
                abi.encodeCall(RoutingHarness.initialize, (initialSelectors, address(delegate)))
            )
        );
        (bool success, bytes memory result) = proxy.call("");
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IERC8167.FunctionNotFound.selector, bytes4(0)));
    }

    function testInvalidDelegateTargetsAreRejected() public {
        RoutingHarness dispatcher = new RoutingHarness();
        RoutingHarness proxy = RoutingHarness(payable(address(new ERC1967Proxy(address(dispatcher), ""))));
        bytes4[] memory initialSelectors = new bytes4[](1);
        initialSelectors[0] = RoutingDelegate.fail.selector;
        address[4] memory invalid = [address(0), makeAddr("no code"), address(proxy), address(dispatcher)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert();
            proxy.initialize(initialSelectors, invalid[i]);
        }
    }

    function testFixedSelectorsCannotBeRouted() public {
        RoutingHarness dispatcher = new RoutingHarness();
        RoutingDelegate delegate = new RoutingDelegate();
        bytes4[] memory initialSelectors = new bytes4[](1);
        initialSelectors[0] = IERC8167.selectors.selector;
        vm.expectRevert();
        new ERC1967Proxy(
            address(dispatcher), abi.encodeCall(RoutingHarness.initialize, (initialSelectors, address(delegate)))
        );
    }

    function testDuplicateSelectorsCannotBeInstalled() public {
        RoutingHarness dispatcher = new RoutingHarness();
        RoutingDelegate delegate = new RoutingDelegate();
        bytes4[] memory initialSelectors = new bytes4[](2);
        initialSelectors[0] = RoutingDelegate.fail.selector;
        initialSelectors[1] = RoutingDelegate.fail.selector;
        vm.expectRevert();
        new ERC1967Proxy(
            address(dispatcher), abi.encodeCall(RoutingHarness.initialize, (initialSelectors, address(delegate)))
        );
    }

    function testInspectionIncludesRoutesAndDispatcherMethods() public {
        RoutingDelegate delegate = new RoutingDelegate();
        RoutingHarness dispatcher = new RoutingHarness();
        bytes4[] memory initialSelectors = new bytes4[](1);
        initialSelectors[0] = RoutingDelegate.fail.selector;
        IERC8167 proxy = IERC8167(
            address(
                new ERC1967Proxy(
                    address(dispatcher),
                    abi.encodeCall(RoutingHarness.initialize, (initialSelectors, address(delegate)))
                )
            )
        );
        assertEq(proxy.implementation(RoutingDelegate.fail.selector), address(delegate));
        assertEq(proxy.implementation(IERC8167.implementation.selector), address(dispatcher));
        assertEq(proxy.implementation(IERC8167.selectors.selector), address(dispatcher));
        assertEq(proxy.implementation(bytes4(0x12345678)), address(0));
        bytes4[] memory installed = proxy.selectors();
        assertEq(installed.length, 3);
        assertEq(installed[0], IERC8167.implementation.selector);
        assertEq(installed[1], IERC8167.selectors.selector);
        assertEq(installed[2], RoutingDelegate.fail.selector);
        vm.expectRevert(abi.encodeWithSelector(RoutingDelegate.Rejected.selector, 73));
        RoutingDelegate(address(proxy)).fail(73);
    }

    function testDelegationPreservesContextCalldataAndProxyStorage() public {
        RoutingDelegate delegate = new RoutingDelegate();
        bytes4[] memory initialSelectors = new bytes4[](2);
        initialSelectors[0] = RoutingDelegate.store.selector;
        initialSelectors[1] = bytes4(keccak256("value()"));
        address proxy = address(
            new ERC1967Proxy(
                address(new RoutingHarness()),
                abi.encodeCall(RoutingHarness.initialize, (initialSelectors, address(delegate)))
            )
        );
        address caller = makeAddr("caller");
        vm.deal(caller, 2 ether);
        vm.prank(caller);
        (address sender, uint256 amount, bytes memory payload) =
            RoutingDelegate(proxy).store{value: 1 ether}(42, hex"c0ffee");
        assertEq(sender, caller);
        assertEq(amount, 1 ether);
        assertEq(payload, hex"c0ffee");
        assertEq(RoutingDelegate(proxy).value(), 42);
        assertEq(delegate.value(), 0);
        assertEq(proxy.balance, 1 ether);
    }

    function testUnknownSelectorReverts() public {
        address proxy = address(new ERC1967Proxy(address(new RoutingHarness()), ""));
        (bool success, bytes memory result) = proxy.call(hex"12345678");
        assertFalse(success);
        assertEq(result, abi.encodeWithSelector(IERC8167.FunctionNotFound.selector, bytes4(0x12345678)));
    }
}
