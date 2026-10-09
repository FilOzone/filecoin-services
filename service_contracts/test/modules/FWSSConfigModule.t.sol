// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Errors} from "../../src/Errors.sol";
import {FWSSConfigModule} from "../../src/modules/FWSSConfigModule.sol";
import {MockERC20} from "../mocks/SharedMocks.sol";

contract FWSSConfigModuleTest is Test {
    MockERC20 token;

    function setUp() public {
        token = new MockERC20();
    }

    function testConstructorRejectsZeroPaymentsAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.FilecoinPayV1));
        new FWSSConfigModule(address(0), address(0x1234), token);
    }

    function testConstructorRejectsZeroPDPVerifierAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.PDPVerifier));
        new FWSSConfigModule(address(0x1234), address(0), token);
    }

    function testConstructorRejectsZeroToken() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.USDFC));
        new FWSSConfigModule(address(0x1234), address(0x5678), IERC20Metadata(address(0)));
    }

    function testConstructorRejectsIncorrectTokenDecimals() public {
        vm.mockCall(address(token), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));
        vm.expectRevert();
        new FWSSConfigModule(address(0x1234), address(0x5678), token);
    }
}
