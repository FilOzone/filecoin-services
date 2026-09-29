// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {ExtsloadModule} from "../../src/modules/ExtsloadModule.sol";

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
}
