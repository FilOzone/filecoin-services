// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";

contract SessionKeyRegistryTest is Test {
    SessionKeyRegistry registry = new SessionKeyRegistry();

    address payable constant SIGNER_ONE = payable(0x1111111111111111111111111111111111111111);
    address payable constant SIGNER_TWO = payable(0x2222222222222222222222222222222222222222);
    bytes32 private constant permission1 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    bytes32 private constant permission2 = 0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes32 private constant permission3 = 0x3333333333333333333333333333333333333333333333333333333333333333;

    uint256 DAY_SECONDS = 24 * 60 * 60;

    function test_loginAndFund() public {
        bytes32[] memory permissions = new bytes32[](3);
        permissions[0] = permission1;
        permissions[1] = permission2;
        permissions[2] = permission3;

        assertEq(SIGNER_ONE.balance, 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, permission1), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, permission2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, permission3), 0);

        uint256 expiry = block.timestamp + DAY_SECONDS;
        registry.loginAndFund{value: 1 ether}(SIGNER_ONE, expiry, permissions);

        assertEq(SIGNER_ONE.balance, 1 ether);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, permission1), expiry);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, permission2), expiry);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, permission3), expiry);

        registry.revoke(SIGNER_ONE, permissions);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, permission1), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, permission2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_ONE, permission3), 0);
    }

    function test_login() public {
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = permission3;
        permissions[1] = permission1;

        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, permission1), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, permission2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, permission3), 0);

        uint256 expiry = block.timestamp + 4 * DAY_SECONDS;

        registry.login(SIGNER_TWO, expiry, permissions);

        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, permission1), expiry);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, permission2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, permission3), expiry);

        registry.revoke(SIGNER_TWO, permissions);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, permission1), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, permission2), 0);
        assertEq(registry.authorizationExpiry(address(this), SIGNER_TWO, permission3), 0);
    }
}
