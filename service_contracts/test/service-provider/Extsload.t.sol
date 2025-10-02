// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Extsload} from "@service-provider/Extsload.sol";

contract Extsstore is Extsload {
    function extsstore(bytes32 slot, bytes32 value) external {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }
}

contract ExtsloadTest is Test {
    Extsstore private extsload;

    bytes32 private constant SLOT0 = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 private constant SLOT1 = 0x0000000000000000000000000000000000000000000000000000000000000001;
    bytes32 private constant SLOT2 = 0x0000000000000000000000000000000000000000000000000000000000000002;
    bytes32 private constant D256 = 0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd;
    bytes32 private constant E256 = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;

    function setUp() public {
        extsload = new Extsstore();
    }

    function test_extsload() public {
        assertEq(extsload.extsload(SLOT0), 0);
        assertEq(extsload.extsload(SLOT1), 0);
        assertEq(extsload.extsload(SLOT2), 0);

        extsload.extsstore(SLOT1, E256);
        assertEq(extsload.extsload(SLOT0), 0);
        assertEq(extsload.extsload(SLOT1), E256);
        assertEq(extsload.extsload(SLOT2), 0);
    }

    function test_extsloadStruct() public {
        bytes32[] memory loaded = extsload.extsloadStruct(SLOT1, 2);
        assertEq(loaded.length, 2);
        assertEq(loaded[0], 0);
        assertEq(loaded[1], 0);

        extsload.extsstore(SLOT1, E256);
        extsload.extsstore(SLOT2, D256);

        loaded = extsload.extsloadStruct(SLOT1, 3);
        assertEq(loaded.length, 3);
        assertEq(loaded[0], E256);
        assertEq(loaded[1], D256);
        assertEq(loaded[2], 0);
    }
}
