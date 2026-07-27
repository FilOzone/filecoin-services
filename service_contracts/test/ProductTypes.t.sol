// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {REQUIRED_PDP_KEYS} from "../src/ServiceProviderRegistry.sol";
import {BloomSet16} from "../src/lib/BloomSet.sol";

contract ProductTypesTest is Test {
    function testPDPKeys() public pure {
        uint256 expected =
            (BloomSet16.compressed("serviceURL") | BloomSet16.compressed("minPieceSizeInBytes")
                | BloomSet16.compressed("maxPieceSizeInBytes") | BloomSet16.compressed("storagePricePerTibPerDay")
                | BloomSet16.compressed("minProvingPeriodInEpochs") | BloomSet16.compressed("location")
                | BloomSet16.compressed("paymentTokenAddress"));
        assertEq(expected, REQUIRED_PDP_KEYS);
    }
}
