// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";
import {Errors} from "../src/Errors.sol";

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

    function testDepositWithAuthorizationAndOperatorApproval_HappyPath() public {
        uint256 fromPrivateKey = user1Sk;
        uint256 validForSeconds = 60;
        uint256 amount = DEPOSIT_AMOUNT;

        helper.depositWithAuthorizationAndOperatorApproval(
            fromPrivateKey, amount, validForSeconds, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );
    }

    function testDepositWithAuthorizationAndOperatorApproval_ZeroAmount() public {
        uint256 fromPrivateKey = user1Sk;
        uint256 validForSeconds = 60;
        uint256 amount = 0; // Zero amount

        helper.depositWithAuthorizationAndOperatorApproval(
            fromPrivateKey, amount, validForSeconds, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );
    }

    function testDepositWithAuthorizationAndOperatorApproval_Revert_InvalidSignature() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 60;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        // Build signature with wrong private key
        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user2Sk, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        vm.startPrank(from);

        vm.expectRevert("EIP3009: invalid signature");
        payments.depositWithAuthorizationAndApproveOperator(
            testToken,
            to,
            amount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            OPERATOR,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            MAX_LOCKUP_PERIOD
        );

        vm.stopPrank();
    }

    function testDepositWithAuthorizationAndOperatorApproval_Revert_InvalidSignature_Corrupted() public {
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
        payments.depositWithAuthorizationAndApproveOperator(
            testToken,
            to,
            amount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            OPERATOR,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            MAX_LOCKUP_PERIOD
        );
    }

    function testDepositWithAuthorizationAndOperatorApproval_Revert_ExpiredAuthorization() public {
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
        payments.depositWithAuthorizationAndApproveOperator(
            testToken,
            to,
            amount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            OPERATOR,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            MAX_LOCKUP_PERIOD
        );
    }

    function testDepositWithAuthorizationAndOperatorApproval_Revert_NotYetValidAuthorization() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = block.timestamp + 60;
        uint256 validBefore = validAfter + 300;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        vm.startPrank(from);
        vm.expectRevert("EIP3009: authorization not yet valid"); // not yet valid
        payments.depositWithAuthorizationAndApproveOperator(
            testToken,
            to,
            amount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            OPERATOR,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            MAX_LOCKUP_PERIOD
        );
    }

    function testDepositWithAuthorizationAndOperatorApproval_Revert_DifferentSender() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 60;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        // Attempt to submit as a different user
        from = vm.addr(user2Sk);
        vm.startPrank(from);
        vm.expectRevert(abi.encodeWithSelector(Errors.SignerMustBeMsgSender.selector, from, to));
        payments.depositWithAuthorizationAndApproveOperator(
            testToken,
            to,
            amount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            OPERATOR,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            MAX_LOCKUP_PERIOD
        );
        vm.stopPrank();
    }

    function testDepositWithAuthorizationAndIncreaseOperatorApproval_HappyPath() public {
        uint256 fromPrivateKey = user1Sk;
        address from = vm.addr(fromPrivateKey);
        address to = from;
        uint256 validForSeconds = 60 * 60;
        uint256 amount = DEPOSIT_AMOUNT;

        // Step 1: First establish initial operator approval with deposit
        helper.depositWithAuthorizationAndOperatorApproval(
            fromPrivateKey, amount, validForSeconds, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );

        // Step 2: Verify initial approval state
        (bool isApproved, uint256 initialRateAllowance, uint256 initialLockupAllowance,,,) =
            payments.operatorApprovals(testToken, USER1, OPERATOR);
        assertEq(isApproved, true);
        assertEq(initialRateAllowance, RATE_ALLOWANCE);
        assertEq(initialLockupAllowance, LOCKUP_ALLOWANCE);

        // Step 3: Prepare for the increase operation
        uint256 additionalDeposit = 500 ether;
        uint256 rateIncrease = 50 ether;
        uint256 lockupIncrease = 500 ether;

        // Give USER1 more tokens for the additional deposit
        testToken.mint(USER1, additionalDeposit);

        uint256 validAfter = 0;
        uint256 validBefore = validAfter + validForSeconds;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, additionalDeposit, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), additionalDeposit, validAfter, validBefore, nonce
        );

        // Record initial account state
        (uint256 initialFunds,,,) = payments.accounts(testToken, USER1);

        // Step 4: Execute depositWithAuthorizationAndIncreaseOperatorApproval
        vm.startPrank(USER1);
        payments.depositWithAuthorizationAndIncreaseOperatorApproval(
            testToken,
            to,
            additionalDeposit,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            OPERATOR,
            rateIncrease,
            lockupIncrease
        );

        vm.stopPrank();

        // Step 5: Verify results
        // Check deposit was successful
        (uint256 finalFunds,,,) = payments.accounts(testToken, USER1);
        assertEq(finalFunds, initialFunds + additionalDeposit);

        // Check operator approval was increased
        (, uint256 finalRateAllowance, uint256 finalLockupAllowance,,,) =
            payments.operatorApprovals(testToken, USER1, OPERATOR);
        assertEq(finalRateAllowance, initialRateAllowance + rateIncrease);
        assertEq(finalLockupAllowance, initialLockupAllowance + lockupIncrease);
    }

    function testDepositWithAuthorizationAndIncreaseOperatorApproval_ZeroIncrease() public {
        uint256 fromPrivateKey = user1Sk;
        address from = vm.addr(fromPrivateKey);
        address to = from;
        uint256 validForSeconds = 60 * 60;
        uint256 amount = DEPOSIT_AMOUNT;

        // Step 1: First establish initial operator approval with deposit
        helper.depositWithAuthorizationAndOperatorApproval(
            fromPrivateKey, amount, validForSeconds, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );

        // Step 2: Verify initial approval state
        (bool isApproved, uint256 initialRateAllowance, uint256 initialLockupAllowance,,,) =
            payments.operatorApprovals(testToken, USER1, OPERATOR);
        assertEq(isApproved, true);
        assertEq(initialRateAllowance, RATE_ALLOWANCE);
        assertEq(initialLockupAllowance, LOCKUP_ALLOWANCE);

        // Step 3: Prepare for the increase operation
        uint256 additionalDeposit = 500 ether;
        uint256 rateIncrease = 0;
        uint256 lockupIncrease = 0;

        // Give USER1 more tokens for the additional deposit
        testToken.mint(USER1, additionalDeposit);

        uint256 validAfter = 0;
        uint256 validBefore = validAfter + validForSeconds;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, additionalDeposit, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), additionalDeposit, validAfter, validBefore, nonce
        );

        // Record initial account state
        (uint256 initialFunds,,,) = payments.accounts(testToken, USER1);

        // Step 4: Execute depositWithAuthorizationAndIncreaseOperatorApproval
        vm.startPrank(USER1);
        payments.depositWithAuthorizationAndIncreaseOperatorApproval(
            testToken,
            to,
            additionalDeposit,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            OPERATOR,
            rateIncrease,
            lockupIncrease
        );

        vm.stopPrank();

        // Step 5: Verify results
        // Check deposit was successful
        (uint256 finalFunds,,,) = payments.accounts(testToken, USER1);
        assertEq(finalFunds, initialFunds + additionalDeposit);

        (, uint256 finalRateAllowance, uint256 finalLockupAllowance,,,) =
            payments.operatorApprovals(testToken, USER1, OPERATOR);
        assertEq(finalRateAllowance, initialRateAllowance); // No change
        assertEq(finalLockupAllowance, initialLockupAllowance); // No change
    }

    function testDepositWithAuthorizationAndIncreaseOperatorApproval_InvalidSignature() public {
        uint256 fromPrivateKey = user1Sk;
        address from = vm.addr(fromPrivateKey);
        address to = from;
        uint256 validForSeconds = 60 * 60;
        uint256 amount = DEPOSIT_AMOUNT;

        // First establish initial operator approval with deposit
        helper.depositWithAuthorizationAndOperatorApproval(
            fromPrivateKey, amount, validForSeconds, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );

        // Verify initial approval state
        (bool isApproved, uint256 initialRateAllowance, uint256 initialLockupAllowance,,,) =
            payments.operatorApprovals(testToken, USER1, OPERATOR);
        assertEq(isApproved, true);
        assertEq(initialRateAllowance, RATE_ALLOWANCE);
        assertEq(initialLockupAllowance, LOCKUP_ALLOWANCE);

        // Prepare for the increase operation
        uint256 additionalDeposit = 500 ether;
        uint256 rateIncrease = 0;
        uint256 lockupIncrease = 0;

        // Give USER1 more tokens for the additional deposit
        testToken.mint(USER1, additionalDeposit);

        uint256 validAfter = 0;
        uint256 validBefore = validAfter + validForSeconds;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, additionalDeposit, block.number));

        // Create invalid permit signature (wrong private key)
        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user2Sk, testToken, from, address(payments), additionalDeposit, validAfter, validBefore, nonce
        );

        vm.startPrank(USER1);
        vm.expectRevert("EIP3009: invalid signature");
        payments.depositWithAuthorizationAndIncreaseOperatorApproval(
            testToken,
            to,
            additionalDeposit,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            OPERATOR,
            rateIncrease,
            lockupIncrease
        );
        vm.stopPrank();

        (, uint256 finalRateAllowance, uint256 finalLockupAllowance,,,) =
            payments.operatorApprovals(testToken, USER1, OPERATOR);
        assertEq(finalRateAllowance, initialRateAllowance); // No change
        assertEq(finalLockupAllowance, initialLockupAllowance); // No change
    }

    function testDepositWithAuthorizationAndIncreaseOperatorApproval_WithExistingUsage() public {
        uint256 fromPrivateKey = user1Sk;
        address from = vm.addr(fromPrivateKey);
        address to = from;
        uint256 validForSeconds = 60 * 60;
        uint256 amount = DEPOSIT_AMOUNT;

        // First establish initial operator approval with deposit
        helper.depositWithAuthorizationAndOperatorApproval(
            fromPrivateKey, amount, validForSeconds, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );

        // Create rail and use some allowance to establish existing usage
        uint256 railId = helper.createRail(USER1, USER2, OPERATOR, address(0), SERVICE_FEE_RECIPIENT);
        uint256 paymentRate = 30 ether;
        uint256 lockupFixed = 200 ether;

        vm.startPrank(OPERATOR);
        payments.modifyRailPayment(railId, paymentRate, 0);
        payments.modifyRailLockup(railId, 0, lockupFixed);
        vm.stopPrank();

        // Verify some allowance is used
        (, uint256 preRateAllowance, uint256 preLockupAllowance, uint256 preRateUsage, uint256 preLockupUsage,) =
            payments.operatorApprovals(testToken, USER1, OPERATOR);
        assertEq(preRateUsage, paymentRate);
        assertEq(preLockupUsage, lockupFixed);

        // Setup for additional deposit with increase
        uint256 additionalDeposit = 500 ether;
        uint256 rateIncrease = 70 ether;
        uint256 lockupIncrease = 800 ether;

        testToken.mint(USER1, additionalDeposit);

        uint256 validAfter = 0;
        uint256 validBefore = validAfter + validForSeconds;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, additionalDeposit, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), additionalDeposit, validAfter, validBefore, nonce
        );

        (uint256 initialFunds,,,) = payments.accounts(testToken, USER1);

        // Execute increase with existing usage
        vm.startPrank(USER1);
        payments.depositWithAuthorizationAndIncreaseOperatorApproval(
            testToken,
            to,
            additionalDeposit,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s,
            OPERATOR,
            rateIncrease,
            lockupIncrease
        );
        vm.stopPrank();

        // Verify results
        (uint256 finalFunds,,,) = payments.accounts(testToken, USER1);
        assertEq(finalFunds, initialFunds + additionalDeposit);

        (, uint256 finalRateAllowance, uint256 finalLockupAllowance, uint256 finalRateUsage, uint256 finalLockupUsage,)
        = payments.operatorApprovals(testToken, USER1, OPERATOR);
        assertEq(finalRateAllowance, preRateAllowance + rateIncrease);
        assertEq(finalLockupAllowance, preLockupAllowance + lockupIncrease);
        assertEq(finalRateUsage, preRateUsage); // Usage unchanged
        assertEq(finalLockupUsage, preLockupUsage); // Usage unchanged
    }

    function testDepositWithAuthorizationAndIncreaseOperatorApproval_Revert_DifferentSender() public {
        address from = vm.addr(user1Sk);
        address to = from;
        uint256 amount = DEPOSIT_AMOUNT;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 60;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        (uint8 v, bytes32 r, bytes32 s) = helper.getReceiveWithAuthorizationSignature(
            user1Sk, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        // First establish initial operator approval with deposit
        helper.depositWithAuthorizationAndOperatorApproval(
            user1Sk, amount, 60 * 60, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );

        // Verify initial approval state
        (bool isApproved, uint256 initialRateAllowance, uint256 initialLockupAllowance,,,) =
            payments.operatorApprovals(testToken, USER1, OPERATOR);
        assertEq(isApproved, true);
        assertEq(initialRateAllowance, RATE_ALLOWANCE);
        assertEq(initialLockupAllowance, LOCKUP_ALLOWANCE);

        // Prepare for the increase operation
        uint256 rateIncrease = 10 ether;
        uint256 lockupIncrease = 10 ether;

        // Give USER1 more tokens for the additional deposit
        testToken.mint(USER1, amount);

        // Attempt to submit as a different user
        from = vm.addr(user2Sk);
        vm.startPrank(from);
        vm.expectRevert(abi.encodeWithSelector(Errors.SignerMustBeMsgSender.selector, from, to));
        payments.depositWithAuthorizationAndIncreaseOperatorApproval(
            testToken, to, amount, validAfter, validBefore, nonce, v, r, s, OPERATOR, rateIncrease, lockupIncrease
        );
        vm.stopPrank();
    }
}
