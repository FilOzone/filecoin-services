// SPDX-License-Identifier: Apache-2.0 OR MIT

pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Payments} from "@payments/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {RailSettlementHelpers} from "./helpers/RailSettlementHelpers.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";

contract FeesTest is Test, BaseTestHelper {
    PaymentsTestHelpers helper;
    RailSettlementHelpers settlementHelper;
    Payments payments;

    // Multiple tokens for testing
    MockERC20 token1;
    MockERC20 token2;
    MockERC20 token3;

    uint256 constant INITIAL_BALANCE = 5000 ether;
    uint256 constant DEPOSIT_AMOUNT = 200 ether;
    uint256 constant MAX_LOCKUP_PERIOD = 100;

    // Payment rates for each rail
    uint256 constant RAIL1_RATE = 5 ether;
    uint256 constant RAIL2_RATE = 10 ether;
    uint256 constant RAIL3_RATE = 15 ether;

    // Rail IDs
    uint256 rail1Id;
    uint256 rail2Id;
    uint256 rail3Id;

    function setUp() public {
        // Initialize helpers
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();

        settlementHelper = new RailSettlementHelpers();
        settlementHelper.initialize(payments, helper);

        // Set up 3 different tokens
        token1 = MockERC20(helper.testToken()); // Use the default token from the helper
        token2 = new MockERC20("Token 2", "TK2");
        token3 = new MockERC20("Token 3", "TK3");

        // Initialize tokens and make deposits
        setupTokensAndDeposits();

        // Create rails with different tokens
        createRails();
    }

    function setupTokensAndDeposits() internal {
        // Mint tokens to users
        // Token 1 is already handled by the helper
        token2.mint(USER1, INITIAL_BALANCE);
        token3.mint(USER1, INITIAL_BALANCE);

        // Approve transfers for all tokens
        vm.startPrank(USER1);
        token1.approve(address(payments), type(uint256).max);
        token2.approve(address(payments), type(uint256).max);
        token3.approve(address(payments), type(uint256).max);
        vm.stopPrank();

        // Make deposits with all tokens
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT); // Uses token1

        // Make deposits with token2 and token3
        vm.startPrank(USER1);
        payments.deposit(token2, USER1, DEPOSIT_AMOUNT);
        payments.deposit(token3, USER1, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function createRails() internal {
        // Set up operator approvals for each token
        helper.setupOperatorApproval(
            USER1, // from
            OPERATOR, // operator
            RAIL1_RATE, // rate allowance for token1
            RAIL1_RATE * 10, // lockup allowance (enough for the period)
            MAX_LOCKUP_PERIOD // max lockup period
        );

        // Operator approvals for token2 and token3
        vm.startPrank(USER1);
        payments.setOperatorApproval(
            token2,
            OPERATOR,
            true, // approved
            RAIL2_RATE, // rate allowance for token2
            RAIL2_RATE * 10, // lockup allowance (enough for the period)
            MAX_LOCKUP_PERIOD // max lockup period
        );

        payments.setOperatorApproval(
            token3,
            OPERATOR,
            true, // approved
            RAIL3_RATE, // rate allowance for token3
            RAIL3_RATE * 10, // lockup allowance (enough for the period)
            MAX_LOCKUP_PERIOD // max lockup period
        );
        vm.stopPrank();

        // Create rails with different tokens
        rail1Id = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            RAIL1_RATE,
            10, // lockupPeriod
            0, // No fixed lockup
            address(0), // No validator
            SERVICE_FEE_RECIPIENT // operator commision receiver
        );

        // Create a rail with token2
        vm.startPrank(OPERATOR);
        rail2Id = payments.createRail(
            token2,
            USER1, // from
            USER2, // to
            address(0), // no validator
            0, // no commission
            SERVICE_FEE_RECIPIENT // operator commision receiver
        );

        // Set rail2 parameters
        payments.modifyRailPayment(rail2Id, RAIL2_RATE, 0);
        payments.modifyRailLockup(rail2Id, 10, 0); // 10 blocks, no fixed lockup

        // Create a rail with token3
        rail3Id = payments.createRail(
            token3,
            USER1, // from
            USER2, // to
            address(0), // no validator
            0, // no commission
            SERVICE_FEE_RECIPIENT // operator commision receiver
        );

        // Set rail3 parameters
        payments.modifyRailPayment(rail3Id, RAIL3_RATE, 0);
        payments.modifyRailLockup(rail3Id, 10, 0); // 10 blocks, no fixed lockup
        vm.stopPrank();
    }
}
