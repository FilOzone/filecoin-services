// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../../src/Payments.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BaseTestHelper} from "./BaseTestHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Errors} from "../../src/Errors.sol";

contract PaymentsTestHelpers is Test, BaseTestHelper {
    // Common constants
    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant DEPOSIT_AMOUNT = 100 ether;
    uint256 internal constant MAX_LOCKUP_PERIOD = 100;

    Payments public payments;
    MockERC20 public testToken;
    IERC20 private constant NATIVE_TOKEN = IERC20(address(0));

    // Standard test environment setup with common addresses and token
    function setupStandardTestEnvironment() public {
        vm.startPrank(OWNER);
        payments = new Payments();
        vm.stopPrank();

        // Setup test token and assign to common users
        address[] memory users = new address[](6);
        users[0] = OWNER;
        users[1] = USER1;
        users[2] = USER2;
        users[3] = OPERATOR;
        users[4] = OPERATOR2;
        users[5] = VALIDATOR;

        vm.deal(USER1, INITIAL_BALANCE);
        vm.deal(USER2, INITIAL_BALANCE);

        testToken = setupTestToken("Test Token", "TEST", users, INITIAL_BALANCE, address(payments));
    }

    function setupTestToken(
        string memory name,
        string memory symbol,
        address[] memory users,
        uint256 initialBalance,
        address paymentsContract
    ) public returns (MockERC20) {
        MockERC20 newToken = new MockERC20(name, symbol);

        // Mint tokens to users
        for (uint256 i = 0; i < users.length; i++) {
            newToken.mint(users[i], initialBalance);

            // Approve payments contract to spend tokens (i.e. allowance)
            vm.startPrank(users[i]);
            newToken.approve(paymentsContract, type(uint256).max);
            vm.stopPrank();
        }

        return newToken;
    }

    function getPermitSignature(uint256 privateKey, address owner, address spender, uint256 value, uint256 deadline)
        public
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        uint256 nonce = MockERC20(testToken).nonces(owner);
        bytes32 domainSeparator = MockERC20(testToken).DOMAIN_SEPARATOR();

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);

        // Sign the exact digest that `permit` expects using the provided private key
        (v, r, s) = vm.sign(privateKey, digest);
    }

    function makeDepositWithPermit(uint256 fromPrivateKey, address to, uint256 amount) public {
        address from = vm.addr(fromPrivateKey);
        uint256 deadline = block.timestamp + 1 hours;

        // Capture pre-deposit balances and state
        uint256 fromBalanceBefore = _balanceOf(from, false);
        uint256 paymentsBalanceBefore = _balanceOf(address(payments), false);
        Payments.Account memory toAccountBefore = _getAccountData(to, false);

        // get signature for permit
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(fromPrivateKey, from, address(payments), amount, deadline);

        // Execute deposit with permit
        vm.startPrank(from);

        payments.depositWithPermit(testToken, to, amount, deadline, v, r, s);

        vm.stopPrank();

        // Capture post-deposit balances and state
        uint256 fromBalanceAfter = _balanceOf(from, false);
        uint256 paymentsBalanceAfter = _balanceOf(address(payments), false);
        Payments.Account memory toAccountAfter = _getAccountData(to, false);

        // Asserts / Checks
        _assertDepositBalances(
            fromBalanceBefore,
            fromBalanceAfter,
            paymentsBalanceBefore,
            paymentsBalanceAfter,
            toAccountBefore,
            toAccountAfter,
            amount
        );
    }

    function _assertDepositBalances(
        uint256 fromBalanceBefore,
        uint256 fromBalanceAfter,
        uint256 paymentsBalanceBefore,
        uint256 paymentsBalanceAfter,
        Payments.Account memory toAccountBefore,
        Payments.Account memory toAccountAfter,
        uint256 amount
    ) public pure {
        assertEq(fromBalanceAfter, fromBalanceBefore - amount, "Sender's balance not reduced correctly");
        assertEq(
            paymentsBalanceAfter, paymentsBalanceBefore + amount, "Payments contract balance not increased correctly"
        );

        assertEq(
            paymentsBalanceAfter, paymentsBalanceBefore + amount, "Payments contract balance not increased correctly"
        );

        assertEq(
            toAccountAfter.funds, toAccountBefore.funds + amount, "Recipient's account balance not increased correctly"
        );
    }

    function getAccountData(address user) public view returns (Payments.Account memory) {
        return _getAccountData(user, false);
    }

    function getNativeAccountData(address user) public view returns (Payments.Account memory) {
        return _getAccountData(user, true);
    }

    function _getAccountData(address user, bool useNativeToken) public view returns (Payments.Account memory) {
        IERC20 token = useNativeToken ? NATIVE_TOKEN : testToken;
        (uint256 funds, uint256 lockupCurrent, uint256 lockupRate, uint256 lockupLastSettledAt) =
            payments.accounts(token, user);

        return Payments.Account({
            funds: funds,
            lockupCurrent: lockupCurrent,
            lockupRate: lockupRate,
            lockupLastSettledAt: lockupLastSettledAt
        });
    }

    function makeDeposit(address from, address to, uint256 amount) public {
        _performDeposit(from, to, amount, false);
    }

    function makeNativeDeposit(address from, address to, uint256 amount) public {
        _performDeposit(from, to, amount, true);
    }

    function _performDeposit(address from, address to, uint256 amount, bool useNativeToken) public {
        // Capture pre-deposit balances
        uint256 fromBalanceBefore = _balanceOf(from, useNativeToken);
        uint256 paymentsBalanceBefore = _balanceOf(address(payments), useNativeToken);
        Payments.Account memory toAccountBefore = _getAccountData(to, useNativeToken);

        // Make the deposit
        vm.startPrank(from);

        uint256 value = 0;
        IERC20 token = testToken;
        if (useNativeToken) {
            value = amount;
            token = NATIVE_TOKEN;
        }

        payments.deposit{value: value}(token, to, amount);
        vm.stopPrank();

        // Verify token balances
        uint256 fromBalanceAfter = _balanceOf(from, useNativeToken);
        uint256 paymentsBalanceAfter = _balanceOf(address(payments), useNativeToken);
        Payments.Account memory toAccountAfter = _getAccountData(to, useNativeToken);

        // Verify balances
        assertEq(fromBalanceAfter, fromBalanceBefore - amount, "Sender's balance not reduced correctly");
        assertEq(
            paymentsBalanceAfter, paymentsBalanceBefore + amount, "Payments contract balance not increased correctly"
        );
        assertEq(
            toAccountAfter.funds, toAccountBefore.funds + amount, "Recipient's account balance not increased correctly"
        );
        console.log("toAccountAfter.funds", toAccountAfter.funds);
    }

    function makeWithdrawal(address from, uint256 amount) public {
        _performWithdrawal(
            from,
            from, // recipient is the same as sender
            amount,
            true, // use the standard withdraw function
            false // use ERC20 token
        );
    }

    function makeNativeWithdrawal(address from, uint256 amount) public {
        _performWithdrawal(
            from,
            from, // recipient is the same as sender
            amount,
            true, // use the standard withdraw function
            true // use native token
        );
    }

    function expectWithdrawalToFail(address from, uint256 available, uint256 requested) public {
        vm.startPrank(from);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientUnlockedFunds.selector, available, requested));
        payments.withdraw(testToken, requested);
        vm.stopPrank();
    }

    function makeWithdrawalTo(address from, address to, uint256 amount) public {
        _performWithdrawal(
            from,
            to,
            amount,
            false, // use the withdrawTo function
            false // use erc20 token
        );
    }

    function makeNativeWithdrawalTo(address from, address to, uint256 amount) public {
        _performWithdrawal(
            from,
            to,
            amount,
            false, // use the withdrawTo function
            true // use native token
        );
    }

    function _balanceOf(address addr, bool useNativeToken) public view returns (uint256) {
        if (useNativeToken) {
            return addr.balance;
        } else {
            return testToken.balanceOf(addr);
        }
    }

    function _performWithdrawal(
        address from,
        address to,
        uint256 amount,
        bool isStandardWithdrawal,
        bool useNativeToken
    ) private {
        IERC20 token = useNativeToken ? NATIVE_TOKEN : testToken;

        // Capture pre-withdrawal balances
        uint256 fromAccountBalanceBefore = _getAccountData(from, useNativeToken).funds;
        uint256 recipientBalanceBefore = _balanceOf(to, useNativeToken);
        uint256 paymentsBalanceBefore = _balanceOf(address(payments), useNativeToken);

        // Make the withdrawal
        vm.startPrank(from);
        if (isStandardWithdrawal) {
            payments.withdraw(token, amount);
        } else {
            payments.withdrawTo(token, to, amount);
        }
        vm.stopPrank();

        // Verify balances
        uint256 fromAccountBalanceAfter = _getAccountData(from, useNativeToken).funds;
        uint256 recipientBalanceAfter = _balanceOf(to, useNativeToken);
        uint256 paymentsBalanceAfter = _balanceOf(address(payments), useNativeToken);

        // Assert balances changed correctly
        assertEq(
            fromAccountBalanceAfter,
            fromAccountBalanceBefore - amount,
            "Sender's account balance not decreased correctly"
        );
        assertEq(recipientBalanceAfter, recipientBalanceBefore + amount, "Recipient's balance not increased correctly");
        assertEq(
            paymentsBalanceAfter, paymentsBalanceBefore - amount, "Payments contract balance not decreased correctly"
        );
    }

    function createRail(address from, address to, address railOperator, address validator, address serviceFeeRecipient)
        public
        returns (uint256)
    {
        vm.startPrank(railOperator);
        uint256 railId = payments.createRail(
            testToken,
            from,
            to,
            validator,
            0, // commissionRateBps
            serviceFeeRecipient // serviceFeeRecipient
        );
        vm.stopPrank();

        // Verify rail was created with the correct parameters
        Payments.RailView memory rail = payments.getRail(railId);
        assertEq(address(rail.token), address(testToken), "Rail token address mismatch");
        assertEq(rail.from, from, "Rail sender address mismatch");
        assertEq(rail.to, to, "Rail recipient address mismatch");
        assertEq(rail.validator, validator, "Rail validator address mismatch");
        assertEq(rail.operator, railOperator, "Rail operator address mismatch");
        assertEq(rail.serviceFeeRecipient, serviceFeeRecipient, "Rail service fee recipient address mismatch");

        return railId;
    }

    function setupRailWithParameters(
        address from,
        address to,
        address railOperator,
        uint256 paymentRate,
        uint256 lockupPeriod,
        uint256 lockupFixed,
        address validator,
        address serviceFeeRecipient
    ) public returns (uint256 railId) {
        // Calculate required allowances for the rail
        uint256 requiredRateAllowance = paymentRate;
        uint256 requiredLockupAllowance = lockupFixed + (paymentRate * lockupPeriod);

        // Get current operator allowances
        (bool isApproved, uint256 rateAllowance, uint256 lockupAllowance,,,) =
            payments.operatorApprovals(testToken, from, railOperator);

        // Ensure operator has sufficient allowances before creating the rail
        if (!isApproved || rateAllowance < requiredRateAllowance || lockupAllowance < requiredLockupAllowance) {
            vm.startPrank(from);
            payments.setOperatorApproval(
                testToken,
                railOperator,
                true,
                requiredRateAllowance > rateAllowance ? requiredRateAllowance : rateAllowance,
                requiredLockupAllowance > lockupAllowance ? requiredLockupAllowance : lockupAllowance,
                MAX_LOCKUP_PERIOD
            );
            vm.stopPrank();
        }

        railId = createRail(from, to, railOperator, validator, serviceFeeRecipient);

        // Get operator usage before modifications
        (,,, uint256 rateUsageBefore, uint256 lockupUsageBefore,) =
            payments.operatorApprovals(testToken, from, railOperator);

        // Get rail parameters before modifications to accurately calculate expected usage changes
        Payments.RailView memory railBefore;
        try payments.getRail(railId) returns (Payments.RailView memory railData) {
            railBefore = railData;
        } catch {
            // If this is a new rail, all values will be zero
            railBefore.paymentRate = 0;
            railBefore.lockupPeriod = 0;
            railBefore.lockupFixed = 0;
        }

        // Set payment rate and lockup parameters
        vm.startPrank(railOperator);
        payments.modifyRailPayment(railId, paymentRate, 0);
        payments.modifyRailLockup(railId, lockupPeriod, lockupFixed);
        vm.stopPrank();

        // Verify rail parameters were set correctly
        Payments.RailView memory rail = payments.getRail(railId);
        assertEq(rail.paymentRate, paymentRate, "Rail payment rate mismatch");
        assertEq(rail.lockupPeriod, lockupPeriod, "Rail lockup period mismatch");
        assertEq(rail.lockupFixed, lockupFixed, "Rail fixed lockup mismatch");
        assertEq(rail.validator, validator, "Rail validator address mismatch");

        // Get operator usage after modifications
        (,,, uint256 rateUsageAfter, uint256 lockupUsageAfter,) =
            payments.operatorApprovals(testToken, from, railOperator);

        // Calculate expected change in rate usage
        int256 expectedRateChange;
        if (paymentRate > railBefore.paymentRate) {
            expectedRateChange = int256(paymentRate - railBefore.paymentRate);
        } else {
            expectedRateChange = -int256(railBefore.paymentRate - paymentRate);
        }

        // Calculate old and new lockup values to determine the change
        uint256 oldLockupTotal = railBefore.lockupFixed + (railBefore.paymentRate * railBefore.lockupPeriod);
        uint256 newLockupTotal = lockupFixed + (paymentRate * lockupPeriod);
        int256 expectedLockupChange;

        if (newLockupTotal > oldLockupTotal) {
            expectedLockupChange = int256(newLockupTotal - oldLockupTotal);
        } else {
            expectedLockupChange = -int256(oldLockupTotal - newLockupTotal);
        }

        // Verify operator usage has been updated correctly
        if (expectedRateChange > 0) {
            assertEq(
                rateUsageAfter,
                rateUsageBefore + uint256(expectedRateChange),
                "Operator rate usage not increased correctly"
            );
        } else {
            assertEq(
                rateUsageBefore,
                rateUsageAfter + uint256(-expectedRateChange),
                "Operator rate usage not decreased correctly"
            );
        }

        if (expectedLockupChange > 0) {
            assertEq(
                lockupUsageAfter,
                lockupUsageBefore + uint256(expectedLockupChange),
                "Operator lockup usage not increased correctly"
            );
        } else {
            assertEq(
                lockupUsageBefore,
                lockupUsageAfter + uint256(-expectedLockupChange),
                "Operator lockup usage not decreased correctly"
            );
        }

        return railId;
    }

    function setupOperatorApproval(
        address from,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) public {
        // Get initial usage values for verification
        (,,, uint256 initialRateUsage, uint256 initialLockupUsage,) =
            payments.operatorApprovals(testToken, from, operator);

        // Set approval
        vm.startPrank(from);
        payments.setOperatorApproval(testToken, operator, true, rateAllowance, lockupAllowance, maxLockupPeriod);
        vm.stopPrank();

        // Verify operator allowances after setting them
        verifyOperatorAllowances(
            from,
            operator,
            true, // isApproved
            rateAllowance, // rateAllowance
            lockupAllowance, // lockupAllowance
            initialRateUsage, // rateUsage shouldn't change
            initialLockupUsage, // lockupUsage shouldn't change
            maxLockupPeriod // maxLockupPeriod
        );
    }

    function revokeOperatorApprovalAndVerify(address from, address operator) public {
        // Get current values for verification
        (
            ,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        ) = payments.operatorApprovals(testToken, from, operator);

        // Revoke approval
        vm.startPrank(from);
        payments.setOperatorApproval(testToken, operator, false, rateAllowance, lockupAllowance, maxLockupPeriod);
        vm.stopPrank();

        // Verify operator allowances after revoking
        verifyOperatorAllowances(
            from,
            operator,
            false, // isApproved should be false
            rateAllowance, // rateAllowance should remain the same
            lockupAllowance, // lockupAllowance should remain the same
            rateUsage, // rateUsage shouldn't change
            lockupUsage, // lockupUsage shouldn't change,
            maxLockupPeriod // maxLockupPeriod should remain the same
        );
    }

    function advanceBlocks(uint256 blocks) public {
        vm.roll(block.number + blocks);
    }

    function assertAccountState(
        address user,
        uint256 expectedFunds,
        uint256 expectedLockup,
        uint256 expectedRate,
        uint256 expectedLastSettled
    ) public view {
        Payments.Account memory account = getAccountData(user);
        assertEq(account.funds, expectedFunds, "Account funds incorrect");
        assertEq(account.lockupCurrent, expectedLockup, "Account lockup incorrect");
        assertEq(account.lockupRate, expectedRate, "Account lockup rate incorrect");
        assertEq(account.lockupLastSettledAt, expectedLastSettled, "Account last settled at incorrect");
    }

    function verifyOperatorAllowances(
        address client,
        address operator,
        bool expectedIsApproved,
        uint256 expectedRateAllowance,
        uint256 expectedLockupAllowance,
        uint256 expectedRateUsage,
        uint256 expectedLockupUsage,
        uint256 expectedMaxLockupPeriod
    ) public view {
        (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        ) = payments.operatorApprovals(testToken, client, operator);

        assertEq(isApproved, expectedIsApproved, "Operator approval status mismatch");
        assertEq(rateAllowance, expectedRateAllowance, "Rate allowance mismatch");
        assertEq(lockupAllowance, expectedLockupAllowance, "Lockup allowance mismatch");
        assertEq(rateUsage, expectedRateUsage, "Rate usage mismatch");
        assertEq(lockupUsage, expectedLockupUsage, "Lockup usage mismatch");
        assertEq(maxLockupPeriod, expectedMaxLockupPeriod, "Max lockup period mismatch");
    }

    // Get current operator allowance and usage
    function getOperatorAllowanceAndUsage(address client, address operator)
        public
        view
        returns (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 rateUsage,
            uint256 lockupUsage,
            uint256 maxLockupPeriod
        )
    {
        return payments.operatorApprovals(testToken, client, operator);
    }

    function executeOneTimePayment(uint256 railId, address operatorAddress, uint256 oneTimeAmount) public {
        Payments.RailView memory railBefore = payments.getRail(railId);
        address railClient = railBefore.from;
        address railRecipient = railBefore.to;

        // Get initial balances
        Payments.Account memory clientBefore = getAccountData(railClient);
        Payments.Account memory recipientBefore = getAccountData(railRecipient);
        Payments.Account memory operatorBefore = getAccountData(operatorAddress);

        // Get operator allowance and usage before payment
        (,, uint256 lockupAllowanceBefore,, uint256 lockupUsageBefore,) =
            payments.operatorApprovals(testToken, railClient, operatorAddress);

        // Make one-time payment
        vm.startPrank(operatorAddress);
        payments.modifyRailPayment(railId, railBefore.paymentRate, oneTimeAmount);
        vm.stopPrank();

        // Verify balance changes
        Payments.Account memory clientAfter = getAccountData(railClient);
        Payments.Account memory recipientAfter = getAccountData(railRecipient);
        Payments.Account memory operatorAfter = getAccountData(operatorAddress);

        assertEq(
            clientAfter.funds,
            clientBefore.funds - oneTimeAmount,
            "Client funds not reduced correctly after one-time payment"
        );

        uint256 networkFee = oneTimeAmount * payments.NETWORK_FEE_NUMERATOR() / payments.NETWORK_FEE_DENOMINATOR();
        // Get commission rate from rail
        uint256 commissionRate = railBefore.commissionRateBps;
        uint256 operatorCommission = 0;

        if (commissionRate > 0) {
            operatorCommission = ((oneTimeAmount - networkFee) * commissionRate) / payments.COMMISSION_MAX_BPS();
            // Verify operator commission is non-zero when commission rate is non-zero
            assertGt(operatorCommission, 0, "Operator commission should be non-zero when commission rate is non-zero");
        }

        uint256 netPayeeAmount = oneTimeAmount - networkFee - operatorCommission;

        assertEq(
            recipientAfter.funds,
            recipientBefore.funds + netPayeeAmount,
            "Recipient funds not increased correctly after one-time payment"
        );

        // Verify fixed lockup was reduced
        Payments.RailView memory railAfter = payments.getRail(railId);
        assertEq(
            railAfter.lockupFixed,
            railBefore.lockupFixed - oneTimeAmount,
            "Fixed lockup not reduced by one-time payment amount"
        );

        // Verify operator account is credited with commission
        if (operatorCommission > 0) {
            assertEq(
                operatorAfter.funds,
                operatorBefore.funds + operatorCommission,
                "Operator funds not increased correctly with commission amount"
            );
        }

        // Verify account lockup is also reduced
        assertEq(
            clientAfter.lockupCurrent,
            clientBefore.lockupCurrent - oneTimeAmount,
            "Client lockup not reduced correctly after one-time payment"
        );

        // Verify operator lockup allowance and usage are both reduced
        (,, uint256 lockupAllowanceAfter,, uint256 lockupUsageAfter,) =
            payments.operatorApprovals(testToken, railClient, operatorAddress);

        assertEq(
            lockupAllowanceBefore - oneTimeAmount,
            lockupAllowanceAfter,
            "Operator lockup allowance not reduced correctly after one-time payment"
        );

        assertEq(
            lockupUsageBefore - oneTimeAmount,
            lockupUsageAfter,
            "Operator lockup usage not reduced correctly after one-time payment"
        );
    }

    function expectcreateRailToRevertWithoutOperatorApproval() public {
        vm.startPrank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Errors.OperatorNotApproved.selector, USER1, OPERATOR));
        payments.createRail(
            testToken,
            USER1,
            USER2,
            address(0),
            0,
            SERVICE_FEE_RECIPIENT // operator commision receiver
        );
    }

    function expectExpiredPermitToRevert(uint256 senderSk, address to, uint256 amount) public {
        address from = vm.addr(senderSk);
        uint256 futureDeadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(senderSk, from, address(payments), amount, futureDeadline);
        vm.warp(futureDeadline + 10);
        vm.startPrank(from);
        vm.expectRevert(abi.encodeWithSignature("ERC2612ExpiredSignature(uint256)", futureDeadline));
        payments.depositWithPermit(testToken, to, amount, futureDeadline, v, r, s);
        vm.stopPrank();
    }

    function expectNativeTokenDepositWithPermitToRevert(uint256 senderSk, address to, uint256 amount) public {
        uint256 deadline = block.timestamp + 1 hours;
        address from = vm.addr(senderSk);
        vm.startPrank(from);
        vm.expectRevert(Errors.NativeTokenNotSupported.selector);
        payments.depositWithPermit(
            NATIVE_TOKEN, // Native token is not allowed
            to,
            amount,
            deadline,
            0, // v
            bytes32(0), // r
            bytes32(0) // s
        );
        vm.stopPrank();
    }

    function expectInvalidPermitToRevert(uint256 senderSk, address to, uint256 amount) public {
        uint256 deadline = block.timestamp + 1 hours;

        uint256 notSenderSk = senderSk == user1Sk ? user2Sk : user1Sk;
        address from = vm.addr(senderSk);

        // Make permit signature from notFromSk, but call from 'from'
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(notSenderSk, from, address(payments), amount, deadline);

        vm.startPrank(from);

        // Expect custom error: ERC2612InvalidSigner(wrongRecovered, expectedOwner)
        vm.expectRevert(abi.encodeWithSignature("ERC2612InvalidSigner(address,address)", vm.addr(notSenderSk), from));
        payments.depositWithPermit(testToken, to, amount, deadline, v, r, s);
        vm.stopPrank();
    }

    function makeDepositWithPermitAndOperatorApproval(
        uint256 fromPrivateKey,
        uint256 amount,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) public {
        address from = vm.addr(fromPrivateKey);
        address to = from;
        uint256 deadline = block.timestamp + 1 hours;

        // Capture pre-deposit balances and state
        uint256 fromBalanceBefore = _balanceOf(from, false);
        uint256 paymentsBalanceBefore = _balanceOf(address(payments), false);
        Payments.Account memory toAccountBefore = _getAccountData(to, false);

        // get signature for permit
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(fromPrivateKey, from, address(payments), amount, deadline);

        // Execute deposit with permit
        vm.startPrank(from);

        payments.depositWithPermitAndApproveOperator(
            testToken, from, amount, deadline, v, r, s, operator, rateAllowance, lockupAllowance, maxLockupPeriod
        );

        vm.stopPrank();

        // Capture post-deposit balances and state
        uint256 fromBalanceAfter = _balanceOf(from, false);
        uint256 paymentsBalanceAfter = _balanceOf(address(payments), false);
        Payments.Account memory toAccountAfter = _getAccountData(to, false);

        // Asserts / Checks
        _assertDepositBalances(
            fromBalanceBefore,
            fromBalanceAfter,
            paymentsBalanceBefore,
            paymentsBalanceAfter,
            toAccountBefore,
            toAccountAfter,
            amount
        );

        verifyOperatorAllowances(from, operator, true, rateAllowance, lockupAllowance, 0, 0, maxLockupPeriod);
    }

    function expectInvalidPermitAndOperatorApprovalToRevert(
        uint256 senderSk,
        uint256 amount,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) public {
        uint256 deadline = block.timestamp + 1 hours;
        address to = vm.addr(senderSk); // Use the sender's address as recipient

        uint256 notSenderSk = senderSk == user1Sk ? user2Sk : user1Sk;
        address from = vm.addr(senderSk);

        // Make permit signature from notFromSk, but call from 'from'
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(notSenderSk, from, address(payments), amount, deadline);

        // Capture pre-deposit balances and state
        uint256 fromBalanceBefore = _balanceOf(from, false);
        uint256 paymentsBalanceBefore = _balanceOf(address(payments), false);
        Payments.Account memory toAccountBefore = _getAccountData(to, false);

        vm.startPrank(from);

        // Expect custom error: ERC2612InvalidSigner(wrongRecovered, expectedOwner)
        vm.expectRevert(abi.encodeWithSignature("ERC2612InvalidSigner(address,address)", vm.addr(notSenderSk), from));
        payments.depositWithPermitAndApproveOperator(
            testToken, from, amount, deadline, v, r, s, operator, rateAllowance, lockupAllowance, maxLockupPeriod
        );
        vm.stopPrank();

        // Capture post-deposit balances and state
        uint256 fromBalanceAfter = _balanceOf(from, false);
        uint256 paymentsBalanceAfter = _balanceOf(address(payments), false);
        Payments.Account memory toAccountAfter = _getAccountData(to, false);

        // Asserts / Checks
        _assertDepositBalances(
            fromBalanceBefore,
            fromBalanceAfter,
            paymentsBalanceBefore,
            paymentsBalanceAfter,
            toAccountBefore,
            toAccountAfter,
            0 // No funds should have been transferred due to revert
        );

        verifyOperatorAllowances(from, operator, false, 0, 0, 0, 0, 0); // No values should have been set due to revert - expect defaults
    }

    function makeDepositWithPermitToAnotherUser(uint256 senderSk, address depositer, uint256 amount) public {
        address to = vm.addr(senderSk);
        uint256 deadline = block.timestamp + 1 hours;

        // Get permit signature for 'to' address
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(senderSk, to, address(payments), amount, deadline);

        vm.startPrank(depositer);
        payments.depositWithPermit(testToken, to, amount, deadline, v, r, s);
        vm.stopPrank();
    }

    // keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    ); // as per EIP-3009

    function getReceiveWithAuthorizationSignature(
        uint256 privateKey,
        IERC20 token,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (uint8 v, bytes32 r, bytes32 s) {
        // EIP-712 domain for ERC-3009 (MockERC20 defines its own domainSeparator unrelated to ERC2612)
        bytes32 domainSeparator = MockERC20(address(token)).domainSeparator();

        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce));

        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);

        (v, r, s) = vm.sign(privateKey, digest);
    }

    function depositWithAuthorizationInsufficientBalance(uint256 fromPrivateKey) public {
        address from = vm.addr(fromPrivateKey);
        address to = from;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 300;
        uint256 amount = INITIAL_BALANCE + 1;
        bytes32 nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        (uint8 v, bytes32 r, bytes32 s) = getReceiveWithAuthorizationSignature(
            fromPrivateKey, testToken, from, address(payments), amount, validAfter, validBefore, nonce
        );

        vm.startPrank(from);
        // Since signature is valid but balance is insufficient, MockERC20 will revert with ERC20InsufficientBalance
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", from, INITIAL_BALANCE, amount)
        );
        payments.depositWithAuthorization(testToken, to, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();
    }

    function depositWithAuthorizationAndOperatorApproval(
        uint256 fromPrivateKey,
        uint256 amount,
        uint256 validForSeconds,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) public returns (bytes32 nonce) {
        address from = vm.addr(fromPrivateKey);
        address to = from;

        // Windows
        uint256 validAfter = 0; // valid immediately
        uint256 validBefore = block.timestamp + validForSeconds;

        // Unique nonce
        nonce = keccak256(abi.encodePacked("auth-nonce", from, to, amount, block.number));

        // Pre-state capture
        uint256 fromBalanceBefore = _balanceOf(from, false);
        uint256 paymentsBalanceBefore = _balanceOf(address(payments), false);
        Payments.Account memory toAccountBefore = _getAccountData(to, false);

        // Build signature
        (uint8 v, bytes32 r, bytes32 s) = getReceiveWithAuthorizationSignature(
            fromPrivateKey,
            testToken,
            from,
            address(payments), // pay to Payments contract
            amount,
            validAfter,
            validBefore,
            nonce
        );

        // Execute deposit via authorization
        vm.startPrank(from);

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
            operator,
            rateAllowance,
            lockupAllowance,
            maxLockupPeriod
        );

        vm.stopPrank();

        // Post-state capture
        uint256 fromBalanceAfter = _balanceOf(from, false);
        uint256 paymentsBalanceAfter = _balanceOf(address(payments), false);
        Payments.Account memory toAccountAfter = _getAccountData(from, false);

        // Assertions
        _assertDepositBalances(
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

        verifyOperatorAllowances(from, operator, true, rateAllowance, lockupAllowance, 0, 0, maxLockupPeriod);
    }
}
