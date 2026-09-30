// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {Errors} from "../../src/Errors.sol";
import {FWSSOwnable} from "../../src/lib/FWSSOwnable.sol";
import {VIEW_CONTRACT_ADDRESS_SLOT} from "../../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {FWSSViewContractModule} from "../../src/modules/FWSSViewContractModule.sol";

contract FWSSViewContractModuleTest is Test {
    bytes32 private constant OWNABLE_STORAGE_LOCATION =
        0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    FWSSViewContractModule public viewContractModule;

    function setUp() public {
        MyERC1967Proxy proxy = new MyERC1967Proxy(address(new FWSSViewContractModule()), "");
        viewContractModule = FWSSViewContractModule(address(proxy));

        vm.store(address(proxy), OWNABLE_STORAGE_LOCATION, bytes32(uint256(uint160(address(this)))));
    }

    function testSetViewContractUsesLegacySlot() public {
        vm.expectEmit(true, false, false, false, address(viewContractModule));
        emit FWSSViewContractModule.ViewContractSet(address(0x1234));
        viewContractModule.setViewContract(address(0x1234));

        assertEq(viewContractModule.viewContractAddress(), address(0x1234));
        assertEq(vm.load(address(viewContractModule), VIEW_CONTRACT_ADDRESS_SLOT), bytes32(uint256(0x1234)));

        viewContractModule.setViewContract(address(0x5678));
        assertEq(viewContractModule.viewContractAddress(), address(0x5678));
    }

    function testSetViewContractRejectsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.View));
        viewContractModule.setViewContract(address(0));
    }

    function testOnlyOwnerCanSetViewContract() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(FWSSOwnable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        viewContractModule.setViewContract(address(0x1234));
    }
}
