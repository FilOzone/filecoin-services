// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {Dutch} from "@payments/Dutch.sol";
import {Errors} from "@payments/Errors.sol";
import {FIRST_AUCTION_START_PRICE, MAX_AUCTION_START_PRICE, Payments} from "@payments/Payments.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";

contract BurnTest is Test {
    using Dutch for uint256;

    PaymentsTestHelpers helper = new PaymentsTestHelpers();
    Payments payments;
    uint256 testTokenRailId;
    uint256 nativeTokenRailId;

    address payable private constant BURN_ADDRESS = payable(0xff00000000000000000000000000000000000063);

    IERC20 private testToken;
    IERC20 private constant NATIVE_TOKEN = IERC20(address(0));
    address private payer;
    address private payee;
    address private operator;
    address private recipient;

    function setUp() public {
        helper.setupStandardTestEnvironment();
        payments = helper.payments();

        testToken = helper.testToken();
        operator = helper.OPERATOR();
        payer = helper.USER1();
        payee = helper.USER2();
        recipient = helper.USER3();

        vm.prank(payer);
        payments.setOperatorApproval(testToken, operator, true, 5 * 10 ** 18, 5 * 10 ** 18, 28800);
        vm.prank(payer);
        payments.setOperatorApproval(NATIVE_TOKEN, operator, true, 5 * 10 ** 18, 5 * 10 ** 18, 28800);

        vm.prank(operator);
        testTokenRailId = payments.createRail(testToken, payer, payee, address(0), 0, address(0));
        vm.prank(operator);
        nativeTokenRailId = payments.createRail(NATIVE_TOKEN, payer, payee, address(0), 0, address(0));

        vm.prank(payer);
        testToken.approve(address(payments), 5 * 10 ** 18);
        vm.prank(payer);
        payments.deposit(testToken, payer, 5 * 10 ** 18);

        vm.prank(payer);
        payments.deposit{value: 5 * 10 ** 18}(NATIVE_TOKEN, payer, 5 * 10 ** 18);
    }

    function testBurn() public {
        uint256 newRate = 9 * 10 ** 16;
        vm.prank(operator);
        payments.modifyRailPayment(testTokenRailId, newRate, 0);

        vm.roll(vm.getBlockNumber() + 10);

        (uint256 availableBefore,,,) = payments.accounts(testToken, address(payments));
        assertEq(availableBefore, 0);

        vm.prank(payer);
        payments.settleRail(testTokenRailId, vm.getBlockNumber());

        (uint256 available,,,) = payments.accounts(testToken, address(payments));
        assertEq(available, 10 * newRate * payments.NETWORK_FEE_NUMERATOR() / payments.NETWORK_FEE_DENOMINATOR());

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.WithdrawAmountExceedsAccumulatedFees.selector, testToken, available, available + 1
            )
        );
        payments.burnForFees{value: FIRST_AUCTION_START_PRICE}(testToken, recipient, available + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientNativeTokenForBurn.selector, FIRST_AUCTION_START_PRICE - 1, FIRST_AUCTION_START_PRICE
            )
        );
        payments.burnForFees{value: FIRST_AUCTION_START_PRICE - 1}(testToken, recipient, available);

        payments.burnForFees{value: FIRST_AUCTION_START_PRICE}(testToken, recipient, available);
        uint256 received = testToken.balanceOf(recipient);
        assertEq(available, received);

        (uint256 availableAfter,,,) = payments.accounts(testToken, address(payments));
        assertEq(availableAfter, 0);

        assertEq(BURN_ADDRESS.balance, FIRST_AUCTION_START_PRICE);

        uint256 oneTimePayment = 2 * 10 ** 16;

        vm.prank(operator);
        payments.modifyRailLockup(testTokenRailId, 20, oneTimePayment);

        newRate = 11 * 10 ** 16;
        vm.prank(operator);
        payments.modifyRailPayment(testTokenRailId, newRate, oneTimePayment);

        (uint256 startPrice, uint256 startTime) = payments.auctionInfo(testToken);
        assertEq(startTime, block.timestamp);
        assertEq(startPrice, FIRST_AUCTION_START_PRICE * Dutch.RESET_FACTOR);

        vm.roll(vm.getBlockNumber() + 17);

        (available,,,) = payments.accounts(testToken, address(payments));
        assertEq(available, oneTimePayment * payments.NETWORK_FEE_NUMERATOR() / payments.NETWORK_FEE_DENOMINATOR());

        vm.prank(payer);
        payments.settleRail(testTokenRailId, vm.getBlockNumber());

        (available,,,) = payments.accounts(testToken, address(payments));
        assertEq(
            available,
            (17 * newRate + oneTimePayment) * payments.NETWORK_FEE_NUMERATOR() / payments.NETWORK_FEE_DENOMINATOR()
        );

        vm.warp(startTime + 11 days);
        uint256 expectedPrice = startPrice.decay(11 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.WithdrawAmountExceedsAccumulatedFees.selector, testToken, available, available + 1
            )
        );
        payments.burnForFees{value: expectedPrice}(testToken, recipient, available + 1);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InsufficientNativeTokenForBurn.selector, expectedPrice - 1, expectedPrice)
        );
        payments.burnForFees{value: expectedPrice - 1}(testToken, recipient, available);

        // can buy less than full amount
        uint256 remainder = 113;
        payments.burnForFees{value: expectedPrice}(testToken, recipient, available - remainder);

        uint256 totalReceived = testToken.balanceOf(recipient);
        assertEq(received + available - remainder, totalReceived);

        (available,,,) = payments.accounts(testToken, address(payments));
        assertEq(available, remainder);

        assertEq(BURN_ADDRESS.balance, FIRST_AUCTION_START_PRICE + expectedPrice);
    }

    function testNativeAutoBurned() public {
        uint256 newRate = 7 * 10 ** 16;
        vm.prank(operator);
        payments.modifyRailPayment(nativeTokenRailId, newRate, 0);

        vm.roll(vm.getBlockNumber() + 12);

        assertEq(BURN_ADDRESS.balance, 0);

        (uint256 availableBefore,,,) = payments.accounts(NATIVE_TOKEN, address(payments));
        assertEq(availableBefore, 0);

        vm.prank(payer);
        payments.settleRail(nativeTokenRailId, vm.getBlockNumber());

        (uint256 availableAfter,,,) = payments.accounts(NATIVE_TOKEN, address(payments));
        assertEq(availableAfter, 0);

        assertEq(
            BURN_ADDRESS.balance, 12 * newRate * payments.NETWORK_FEE_NUMERATOR() / payments.NETWORK_FEE_DENOMINATOR()
        );
    }

    function testBurnNoOp() public {
        uint256 startPrice;
        uint256 startTime;
        for (uint256 i = 0; i < 5; i++) {
            (startPrice, startTime) = payments.auctionInfo(testToken);
            assertEq(startPrice.decay(vm.getBlockTimestamp() - startTime), 0);
            payments.burnForFees(testToken, recipient, 0);
            (startPrice, startTime) = payments.auctionInfo(testToken);
            assertEq(startPrice, 0);
            assertEq(startTime, vm.getBlockTimestamp());
        }

        uint256 newRate = 9 * 10 ** 16;
        vm.prank(operator);
        payments.modifyRailPayment(testTokenRailId, newRate, 0);
        vm.roll(vm.getBlockNumber() + 10);
        // verify that settling rail in this situation still restarts the auction
        vm.prank(payer);
        payments.settleRail(testTokenRailId, vm.getBlockNumber());
        vm.prank(operator);
        payments.modifyRailPayment(testTokenRailId, 0, 0);

        (startPrice, startTime) = payments.auctionInfo(testToken);
        assertEq(startPrice, FIRST_AUCTION_START_PRICE);
        assertEq(startTime, vm.getBlockTimestamp());

        // wait until the price is 0 again
        uint256 heatDeath = vm.getBlockTimestamp() + 10 ** 24;
        vm.warp(heatDeath);

        for (uint256 i = 0; i < 5; i++) {
            (startPrice, startTime) = payments.auctionInfo(testToken);
            assertEq(startPrice.decay(vm.getBlockTimestamp() - startTime), 0);
            payments.burnForFees(testToken, recipient, 0);
            (startPrice, startTime) = payments.auctionInfo(testToken);
            assertEq(startPrice, 0);
            assertEq(startTime, vm.getBlockTimestamp());
        }

        // verify that settling rail in this situation still restarts the auction
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(operator);
        payments.modifyRailPayment(testTokenRailId, newRate, 0);
        vm.roll(vm.getBlockNumber() + 10);
        vm.prank(payer);
        payments.settleRail(testTokenRailId, vm.getBlockNumber());

        (startPrice, startTime) = payments.auctionInfo(testToken);
        assertEq(startPrice, FIRST_AUCTION_START_PRICE);
        assertEq(startTime, vm.getBlockTimestamp());
    }

    // test escalating fees up to uint max
    function testInferno() public {
        // start the auction
        uint256 newRate = 19 * 10 ** 14;
        vm.prank(operator);
        payments.modifyRailPayment(testTokenRailId, newRate, 0);
        vm.roll(vm.getBlockNumber() + 10);
        vm.prank(payer);
        payments.settleRail(testTokenRailId, vm.getBlockNumber());

        uint256 startPrice;
        uint256 startTime;
        uint256 available;
        uint256 expectedStartPrice = FIRST_AUCTION_START_PRICE;
        // repeatedly end the auction, multiplying the burn
        for (uint256 i = 0; i < 256; i++) {
            (available,,,) = payments.accounts(testToken, address(payments));
            (startPrice, startTime) = payments.auctionInfo(testToken);
            assertEq(startPrice, expectedStartPrice);
            assertEq(startTime, vm.getBlockTimestamp());
            vm.deal(recipient, startPrice);
            vm.prank(recipient);
            payments.burnForFees{value: startPrice}(testToken, recipient, available);
            expectedStartPrice *= Dutch.RESET_FACTOR;
            if (expectedStartPrice > MAX_AUCTION_START_PRICE) {
                expectedStartPrice = MAX_AUCTION_START_PRICE;
            }
        }
        assertEq(expectedStartPrice, MAX_AUCTION_START_PRICE);
    }
}
