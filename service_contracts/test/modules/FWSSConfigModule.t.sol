// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {Errors} from "../../src/Errors.sol";
import {FWSSConfigModule} from "../../src/modules/FWSSConfigModule.sol";

contract FWSSConfigModuleTest is Test {
    function testConstructorRejectsZeroPaymentsAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.FilecoinPayV1));
        new FWSSConfigModule(address(0), address(0x1234));
    }

    function testConstructorRejectsZeroPDPVerifierAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.PDPVerifier));
        new FWSSConfigModule(address(0x1234), address(0));
    }
}
