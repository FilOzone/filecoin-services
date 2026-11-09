// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {Errors} from "../../src/Errors.sol";
import {FWSSConfigModule} from "../../src/modules/FWSSConfigModule.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TOKEN_DECIMALS} from "../../src/lib/PriceListUSDFC.sol";
import {MockERC20} from "../mocks/SharedMocks.sol";

contract FWSSConfigModuleTest is Test {
    IERC20Metadata private token;

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

    function testConstructorRejectsZeroUSDFCAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.USDFC));
        new FWSSConfigModule(address(0x1234), address(0x5678), IERC20Metadata(address(0)));
    }

    function testFuzzConstructorRejectsIncorrectTokenDecimals(uint8 decimals) public {
        vm.assume(decimals != TOKEN_DECIMALS);
        vm.mockCall(address(token), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(decimals));

        vm.expectRevert();
        new FWSSConfigModule(address(0x1234), address(0x5678), token);
    }

    function testConfigGettersReturnConstructorDependencies() public {
        FWSSConfigModule module = new FWSSConfigModule(address(0x1234), address(0x5678), token);

        assertEq(module.paymentsContractAddress(), address(0x1234));
        assertEq(module.pdpVerifierAddress(), address(0x5678));
        assertEq(address(module.usdfcTokenAddress()), address(token));
    }
}
