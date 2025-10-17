// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SessionKeyRegistry} from "../src/SessionKeyRegistry.sol";

contract SessionKeyRegistryTest is Test {
    SessionKeyRegistry registry = new SessionKeyRegistry();

    address payable constant SIGNER_ONE = payable(0x1111111111111111111111111111111111111111);
    address payable constant SIGNER_TWO = payable(0x2222222222222222222222222222222222222222);
    bytes32 private constant PERMISSION1 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    bytes32 private constant PERMISSION2 = 0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes32 private constant PERMISSION3 = 0x3333333333333333333333333333333333333333333333333333333333333333;
    string constant ORIGIN = "SessionKeyRegistryTest";

    uint256 private constant DAY_SECONDS = 1 days;

    function test_loginAndFund() public {
        bytes32[] memory permissions = new bytes32[](3);
        permissions[0] = PERMISSION1;
        permissions[1] = PERMISSION2;
        permissions[2] = PERMISSION3;

        assertEq(SIGNER_ONE.balance, 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, PERMISSION1), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, PERMISSION2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, PERMISSION3), 0);

        uint256 expiry = block.timestamp + DAY_SECONDS;
        vm.expectEmit(true, false, false, true, address(registry));
        emit SessionKeyRegistry.AuthorizationsUpdated(address(this), SIGNER_ONE, expiry, permissions, ORIGIN);
        registry.loginAndFund{value: 1 ether}(SIGNER_ONE, expiry, permissions, ORIGIN);

        assertEq(SIGNER_ONE.balance, 1 ether);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, PERMISSION1), expiry);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, PERMISSION2), expiry);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, PERMISSION3), expiry);

        vm.expectEmit(true, false, false, true, address(registry));
        emit SessionKeyRegistry.AuthorizationsUpdated(address(this), SIGNER_ONE, 0, permissions, ORIGIN);
        registry.revoke(SIGNER_ONE, permissions, ORIGIN);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, PERMISSION1), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, PERMISSION2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, PERMISSION3), 0);
    }

    function test_login() public {
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = PERMISSION3;
        permissions[1] = PERMISSION1;

        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, PERMISSION1), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, PERMISSION2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, PERMISSION3), 0);

        uint256 expiry = block.timestamp + 4 * DAY_SECONDS;

        vm.expectEmit(true, false, false, true, address(registry));
        emit SessionKeyRegistry.AuthorizationsUpdated(address(this), SIGNER_TWO, expiry, permissions, ORIGIN);
        registry.login(SIGNER_TWO, expiry, permissions, ORIGIN);

        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, PERMISSION1), expiry);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, PERMISSION2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, PERMISSION3), expiry);

        vm.expectEmit(true, false, false, true, address(registry));
        emit SessionKeyRegistry.AuthorizationsUpdated(address(this), SIGNER_TWO, 0, permissions, ORIGIN);
        registry.revoke(SIGNER_TWO, permissions, ORIGIN);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, PERMISSION1), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, PERMISSION2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, PERMISSION3), 0);
    }
}
