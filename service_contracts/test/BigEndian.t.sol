// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {BigEndian} from "../src/lib/BigEndian.sol";
import {Test} from "forge-std/Test.sol";

contract BigEndianTest is Test {
    using BigEndian for bytes;

    function test_decode() public pure {
        bytes memory test;

        test = hex"";
        assertEq(test.decode(), 0);
        test = hex"00";
        assertEq(test.decode(), 0);
        test = hex"01";
        assertEq(test.decode(), 1);
        test = hex"11";
        assertEq(test.decode(), 17);
        test = hex"1100";
        assertEq(test.decode(), 4352);
        test = hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
        assertEq(test.decode(), 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
    }

    using BigEndian for uint256;

    function test_encode() public pure {
        uint256 test;
        bytes memory encoded;

        test = 0;
        encoded = test.encode();
        assertEq(encoded.length, 0);
        assertEq(encoded.decode(), test);

        test = 1;
        encoded = test.encode();
        assertEq(encoded.length, 1);
        assertEq(encoded.decode(), test);

        test = 2;
        encoded = test.encode();
        assertEq(encoded.length, 1);
        assertEq(encoded.decode(), test);

        test = 1;
        uint256 expectedSize = 0;
        while (++expectedSize <= 32) {
            for (uint256 i = 0; i < 4; i++) {
                encoded = test.encode();
                assertEq(encoded.length, expectedSize);
                assertEq(encoded.decode(), test);
                test <<= 1;
            }

            encoded = test.encode();
            assertEq(encoded.length, expectedSize);
            assertEq(encoded.decode(), test);
            test ^= expectedSize;

            for (uint256 i = 0; i < 4; i++) {
                encoded = test.encode();
                assertEq(encoded.length, expectedSize);
                assertEq(encoded.decode(), test);
                test <<= 1;
            }
        }
    }
}
