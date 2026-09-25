// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {Errors} from "../../src/Errors.sol";
import {ExtsloadModule} from "../../src/modules/ExtsloadModule.sol";
import {UsdfcTokenModule} from "../../src/modules/UsdfcTokenModule.sol";

contract StorageReadModulesTest is Test {
    function testExtsloadReadsCallerStorage() public {
        ExtsloadModule module = ExtsloadModule(address(new MyERC1967Proxy(address(new ExtsloadModule()), "")));
        vm.store(address(module), bytes32(uint256(7)), bytes32(uint256(0xAA)));
        vm.store(address(module), bytes32(uint256(8)), bytes32(uint256(0xBB)));

        assertEq(module.extsload(bytes32(uint256(7))), bytes32(uint256(0xAA)));
        bytes32[] memory words = module.extsloadStruct(bytes32(uint256(7)), 2);
        assertEq(words.length, 2);
        assertEq(words[0], bytes32(uint256(0xAA)));
        assertEq(words[1], bytes32(uint256(0xBB)));
    }

    function testUsdfcTokenModuleExposesToken() public {
        UsdfcTokenModule module = new UsdfcTokenModule(IERC20Metadata(address(0x1234)));
        assertEq(address(module.usdfcTokenAddress()), address(0x1234));
    }

    function testUsdfcTokenModuleRejectsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.USDFC));
        new UsdfcTokenModule(IERC20Metadata(address(0)));
    }
}
