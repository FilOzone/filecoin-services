// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {FWSSOwnable} from "../../src/lib/FWSSOwnable.sol";
import {OwnershipModule} from "../../src/modules/OwnershipModule.sol";

contract OwnershipModuleTest is Test {
    bytes32 private constant OWNABLE_STORAGE_LOCATION =
        0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    OwnershipModule public ownershipModule;

    address public owner;
    address public other;

    function setUp() public {
        owner = address(this);
        other = address(0xB0B);

        MyERC1967Proxy proxy = new MyERC1967Proxy(address(new OwnershipModule()), "");
        ownershipModule = OwnershipModule(address(proxy));

        vm.store(address(proxy), OWNABLE_STORAGE_LOCATION, bytes32(uint256(uint160(owner))));
    }

    function testTransferOwnership() public {
        vm.expectEmit(true, true, false, false, address(ownershipModule));
        emit OwnershipModule.OwnershipTransferred(owner, other);
        ownershipModule.transferOwnership(other);

        assertEq(ownershipModule.owner(), other);

        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, owner));
        ownershipModule.transferOwnership(owner);
    }

    function testTransferOwnershipRejectsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(OwnershipModule.OwnableInvalidOwner.selector, address(0)));
        ownershipModule.transferOwnership(address(0));
    }

    function testRenounceOwnership() public {
        vm.expectEmit(true, true, false, false, address(ownershipModule));
        emit OwnershipModule.OwnershipTransferred(owner, address(0));
        ownershipModule.renounceOwnership();

        assertEq(ownershipModule.owner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, owner));
        ownershipModule.transferOwnership(other);
    }

    function testOnlyOwnerCanChangeOwnership() public {
        vm.startPrank(other);
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, other));
        ownershipModule.transferOwnership(other);
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, other));
        ownershipModule.renounceOwnership();
        vm.stopPrank();

        assertEq(ownershipModule.owner(), owner);
    }
}
