// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Dutch} from "../src/Dutch.sol";

contract ExternalDutch {
    using Dutch for uint256;

    function dutch(uint256 startPrice, uint256 elapsed) external pure returns (uint256) {
        return startPrice.decay(elapsed);
    }
}

contract DutchTest is Test {
    using Dutch for uint256;

    function checkExactDecay(uint256 startPrice) internal pure {
        assertEq(startPrice.decay(0), startPrice);
        assertEq(startPrice.decay(3.5 days), startPrice / 2);
        assertEq(startPrice.decay(7 days), startPrice / 4);
        assertEq(startPrice.decay(14 days), startPrice / 16);
        assertEq(startPrice.decay(21 days), startPrice / 64);
        assertEq(startPrice.decay(28 days), startPrice / 256);
        assertEq(startPrice.decay(35 days), startPrice / 1024);
    }

    function testDecay() public pure {
        checkExactDecay(0.00000001 ether);
        checkExactDecay(0.01 ether);
        checkExactDecay(9 ether);
        checkExactDecay(11 ether);
        checkExactDecay(13 ether);
        checkExactDecay(1300000 ether);
    }

    function testMaxDecayU256() public pure {
        uint256 maxPrice = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

        assertEq(maxPrice.decay(0), maxPrice);
        assertEq(maxPrice.decay(10000000), 12852371374314799914919560702529050018701224735495877087613516410500);
        assertEq(maxPrice.decay(50000000), 1950746206018947071427216775);
        assertEq(maxPrice.decay(58060000), 18480601319969968529);
        assertEq(maxPrice.decay(Dutch.MAX_DECAY - 1), 18446828639436756833);
        assertEq(maxPrice.decay(Dutch.MAX_DECAY), 18446786356524694827);
        assertEq(maxPrice.decay(Dutch.MAX_DECAY + 1), 0);
    }

    function testMaxDecayFIL() public pure {
        uint256 maxPrice = 2 * 10 ** 27; // max FIL supply

        assertEq(maxPrice.decay(0), maxPrice);
        assertEq(maxPrice.decay(90 days), 36329437917604310558);
        assertEq(maxPrice.decay(10000000), 221990491042506894);
        assertEq(maxPrice.decay(20000000), 24639889);
        assertEq(maxPrice.decay(23000000), 25423);
        assertEq(maxPrice.decay(26000000), 26);
        assertEq(maxPrice.decay(26500000), 8);
        assertEq(maxPrice.decay(27000000), 2);
        assertEq(maxPrice.decay(27425278), 1);
        assertEq(maxPrice.decay(27425279), 0);
        assertEq(maxPrice.decay(Dutch.MAX_DECAY - 1), 0);
        assertEq(maxPrice.decay(Dutch.MAX_DECAY), 0);
        assertEq(maxPrice.decay(Dutch.MAX_DECAY + 1), 0);
    }
}
