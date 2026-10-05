// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {VIEW_CONTRACT_ADDRESS_SLOT} from "../../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {FWSSViewContractModule} from "../../src/modules/FWSSViewContractModule.sol";

contract FWSSViewContractModuleTest is Test {
    FWSSViewContractModule public viewContractModule;

    function setUp() public {
        MyERC1967Proxy proxy = new MyERC1967Proxy(address(new FWSSViewContractModule()), "");
        viewContractModule = FWSSViewContractModule(address(proxy));
    }

    function testViewContractAddressReadsLegacySlot() public {
        assertEq(viewContractModule.viewContractAddress(), address(0));

        vm.store(address(viewContractModule), VIEW_CONTRACT_ADDRESS_SLOT, bytes32(uint256(0x1234)));
        assertEq(viewContractModule.viewContractAddress(), address(0x1234));
    }
}
