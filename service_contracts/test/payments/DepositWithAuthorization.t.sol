// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Payments} from "@payments/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";

contract DepositWithAuthorization is Test, BaseTestHelper {
    MockERC20 testToken;
    PaymentsTestHelpers helper;
    Payments payments;

    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant RATE_ALLOWANCE = 100 ether;
    uint256 constant LOCKUP_ALLOWANCE = 1000 ether;
    uint256 constant MAX_LOCKUP_PERIOD = 100;
    uint256 internal constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();

        testToken = helper.testToken();
    }

    function testDepositWithAuthorization_HappyPath() public {
        uint256 fromPrivateKey = user1Sk;
        address from = vm.addr(fromPrivateKey);
        address to = from;
        uint256 validForSeconds = 60;
        uint256 amount = DEPOSIT_AMOUNT;

        // Windows
        uint256 validAfter = 0; // valid immediately
        uint256 validBefore = block.timestamp + validForSeconds;

        // Nonce: generate a unique bytes32 per authorization
        // For tests you can make it deterministic:
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        // Pre-state capture
        uint256 fromBalanceBefore = helper._balanceOf(from, false);
        uint256 paymentsBalanceBefore = helper._balanceOf(address(payments), false);
        Payments.Account memory toAccountBefore = helper._getAccountData(to, false);

        // Build signature
        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            fromPrivateKey,
            testToken,
            from,
            address(payments), // receiveWithAuthorization pays to Payments contract
            amount,
            validAfter,
            validBefore,
            nonce
        );

        // Execute deposit via authorization
        vm.startPrank(from);

        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);

        vm.stopPrank();

        // Post-state capture
        uint256 fromBalanceAfter = helper._balanceOf(from, false);
        uint256 paymentsBalanceAfter = helper._balanceOf(address(payments), false);
        Payments.Account memory toAccountAfter = helper._getAccountData(from, false);

        // Assertions
        helper._assertDepositBalances(
            fromBalanceBefore,
            fromBalanceAfter,
            paymentsBalanceBefore,
            paymentsBalanceAfter,
            toAccountBefore,
            toAccountAfter,
            amount
        );

        // Verify authorization is consumed on the token
        bool used = testToken.authorizationState(from, nonce);
        assertTrue(used);
    }

    function testDepositWithAuthorization_Revert_ReplayNonceUsed() public {
        uint256 fromPrivateKey = user1Sk;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validForSeconds = 60;

        address from = vm.addr(fromPrivateKey);
        address to = from;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + validForSeconds;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            fromPrivateKey, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        vm.startPrank(from);
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);
        // Second attempt with same nonce must revert
        vm.expectRevert("EIP3009: authorization already used");
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();
    }

    function testDepositWithAuthorization_Revert_InvalidSignature_WrongSigner() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 60;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        // Generate signature with a different private key
        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user2Sk, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        vm.startPrank(from);
        vm.expectRevert("EIP3009: invalid signature");
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();
    }

    function testDepositWithAuthorization_Revert_InvalidSignature_Corrupted() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 60;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        // Corrupt r
        r = bytes32(uint256(r) ^ 3);

        vm.startPrank(from);
        vm.expectRevert("EIP712: invalid signature"); // invalid signature should revert
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();
    }

    function testDepositWithAuthorization_Revert_ExpiredAuthorization() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        // advance beyond validBefore
        vm.warp(validBefore + 1);

        vm.startPrank(from);
        vm.expectRevert("EIP3009: authorization expired"); // expired window should revert
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();
    }

    function testDepositWithAuthorization_Revert_NotYetValidAuthorization() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = block.timestamp + 60;
        uint256 validBefore = validAfter + 300;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        // Pre-state capture
        uint256 fromBalanceBefore = helper._balanceOf(from, false);
        uint256 paymentsBalanceBefore = helper._balanceOf(address(payments), false);
        Payments.Account memory toAccountBefore = helper._getAccountData(to, false);

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        vm.startPrank(from);
        vm.expectRevert("EIP3009: authorization not yet valid"); // not yet valid
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);

        // Now advance to validAfter + 1 and succeed
        vm.warp(validAfter + 1);
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();

        // Post-state capture
        uint256 fromBalanceAfter = helper._balanceOf(from, false);
        uint256 paymentsBalanceAfter = helper._balanceOf(address(payments), false);
        Payments.Account memory toAccountAfter = helper._getAccountData(from, false);

        // Assertions
        helper._assertDepositBalances(
            fromBalanceBefore,
            fromBalanceAfter,
            paymentsBalanceBefore,
            paymentsBalanceAfter,
            toAccountBefore,
            toAccountAfter,
            amount
        );

        // Verify authorization is consumed on the token
        bool used = testToken.authorizationState(from, nonce);
        assertTrue(used);
    }

    function testDepositWithAuthorization_SubmittedByDifferentSender() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 300;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        // Pre-state capture
        uint256 fromBalanceBefore = helper._balanceOf(from, false);
        uint256 paymentsBalanceBefore = helper._balanceOf(address(payments), false);
        Payments.Account memory toAccountBefore = helper._getAccountData(to, false);

        // Attempt to submit as a different user
        address relayer = vm.addr(user2Sk);
        vm.startPrank(relayer);
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();

        // Post-state capture
        uint256 fromBalanceAfter = helper._balanceOf(from, false);
        uint256 paymentsBalanceAfter = helper._balanceOf(address(payments), false);
        Payments.Account memory toAccountAfter = helper._getAccountData(to, false);

        // Assertions
        helper._assertDepositBalances(
            fromBalanceBefore,
            fromBalanceAfter,
            paymentsBalanceBefore,
            paymentsBalanceAfter,
            toAccountBefore,
            toAccountAfter,
            amount
        );

        // Verify authorization is consumed on the token
        bool used = testToken.authorizationState(from, nonce);
        assertTrue(used);
    }

    function testDepositWithAuthorization_Revert_InsufficientBalance() public {
        helper.depositWithAuthorizationInsufficientBalance(user1Sk);
    }

    function testDepositWithAuthorization_Revert_DomainMismatchWrongToken() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 300;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        // Create a second token
        MockERC20 otherToken = new MockERC20("OtherToken", "OTK");

        // Sign against otherToken domain
        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, otherToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        vm.startPrank(from);
        vm.expectRevert("EIP3009: invalid signature"); // domain mismatch
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();
    }
}
