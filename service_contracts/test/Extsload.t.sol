// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Extsload} from "../src/Extsload.sol";

contract Extsstore is Extsload {
    function extsstore(bytes32 slot, bytes32 value) external {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }
}

contract ExtsloadTest is Test {
    Extsstore private extsload;

    bytes32 private constant slot0 = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 private constant slot1 = 0x0000000000000000000000000000000000000000000000000000000000000001;
    bytes32 private constant slot2 = 0x0000000000000000000000000000000000000000000000000000000000000002;
    bytes32 private constant d256 = 0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd;
    bytes32 private constant e256 = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;

    function setUp() public {
        extsload = new Extsstore();
    }

    function test_extsload() public {
        assertEq(extsload.extsload(slot0), 0);
        assertEq(extsload.extsload(slot1), 0);
        assertEq(extsload.extsload(slot2), 0);

        extsload.extsstore(slot1, e256);
        assertEq(extsload.extsload(slot0), 0);
        assertEq(extsload.extsload(slot1), e256);
        assertEq(extsload.extsload(slot2), 0);
    }

    function test_extsloadStruct() public {
        bytes32[] memory loaded = extsload.extsloadStruct(slot1, 2);
        assertEq(loaded.length, 2);
        assertEq(loaded[0], 0);
        assertEq(loaded[1], 0);

        extsload.extsstore(slot1, e256);
        extsload.extsstore(slot2, d256);

        loaded = extsload.extsloadStruct(slot1, 3);
        assertEq(loaded.length, 3);
        assertEq(loaded[0], e256);
        assertEq(loaded[1], d256);
        assertEq(loaded[2], 0);
    }
}
