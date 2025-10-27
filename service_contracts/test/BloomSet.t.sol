// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {BloomSet16} from "../src/lib/BloomSet.sol";

contract BloomSetTest is Test {
    using BloomSet16 for string;
    using BloomSet16 for uint256;

    function testIdentical() public pure {
        uint256 set = BloomSet16.EMPTY;
        assertTrue(set.mayContain(BloomSet16.EMPTY));
        string[] memory same = new string[](6);
        for (uint256 i = 0; i < same.length; i++) {
            same[i] = "theVerySame";
        }
        for (uint256 i = 0; i < same.length; i++) {
            set |= same[i].compressed();
        }
        assertTrue(set.mayContain(BloomSet16.EMPTY));
        assertTrue(set.mayContain(set));
        string memory verySame = "theVerySame";
        assertEq(set, verySame.compressed());
        assertTrue(set.mayContain(verySame.compressed()));
        string memory fromCat = string.concat(string.concat("the", "Very"), "Same");
        assertEq(verySame.compressed(), fromCat.compressed());
    }

    function testDifferent() public pure {
        uint256 set = BloomSet16.EMPTY;
        string memory one = "1";
        string memory two = "2";
        string memory three = "3";
        set |= one.compressed();
        assertTrue(set.mayContain(one.compressed()));
        assertFalse(set.mayContain(two.compressed()));
        assertFalse(set.mayContain(three.compressed()));
        set |= two.compressed();
        assertTrue(set.mayContain(BloomSet16.EMPTY));
        assertTrue(set.mayContain(one.compressed()));
        assertTrue(set.mayContain(two.compressed()));
        assertFalse(set.mayContain(three.compressed()));
        assertFalse(one.compressed().mayContain(set));
        assertFalse(two.compressed().mayContain(set));
        assertFalse(three.compressed().mayContain(set));
        assertFalse(BloomSet16.EMPTY.mayContain(set));
        assertFalse(BloomSet16.EMPTY.mayContain(one.compressed()));
        assertFalse(BloomSet16.EMPTY.mayContain(two.compressed()));
        assertFalse(BloomSet16.EMPTY.mayContain(three.compressed()));
    }
}
