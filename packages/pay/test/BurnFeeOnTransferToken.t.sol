// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {MockFVMTest} from "fvm-solidity/mocks/MockFVMTest.sol";
import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";

import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {MockFeeOnTransferTokenWithPermit} from "./mocks/MockFeeOnTransferTokenWithPermit.sol";
import {FIRST_AUCTION_START_PRICE, Payments} from "../src/Payments.sol";

contract BurnFeeOnTransferTokenTest is MockFVMTest {
    PaymentsTestHelpers helper = new PaymentsTestHelpers();
    Payments payments;
    MockFeeOnTransferTokenWithPermit feeToken;

    uint256 railId;

    address operator;
    address payer;
    address payee;
    address recipient;

    function setUp() public override {
        // Mock the FVM precompiles
        super.setUp();

        helper.setupStandardTestEnvironment();
        payments = helper.payments();
        operator = helper.OPERATOR();
        payer = helper.USER1();
        payee = helper.USER2();
        recipient = helper.USER3();
    }

    function testBurnFeeOnTransferToken() public {
        feeToken = new MockFeeOnTransferTokenWithPermit("FeeToken", "FEE", 100);

        feeToken.mint(payer, 50000 * 10 ** 18);
        vm.prank(payer);
        feeToken.approve(address(payments), 50000 * 10 ** 18);
        vm.prank(payer);
        payments.deposit(feeToken, payer, 500 * 10 ** 18);

        (uint256 balance,,,) = payments.accounts(feeToken, payer);
        assertEq(balance, 495 * 10 ** 18);

        vm.prank(payer);
        payments.setOperatorApproval(feeToken, operator, true, 50000 * 10 ** 18, 500 * 10 ** 18, 28800);

        vm.prank(operator);
        railId = payments.createRail(feeToken, payer, payee, address(0), 0, address(0));

        uint256 newRate = 100 * 10 ** 16;

        vm.prank(operator);
        payments.modifyRailPayment(railId, newRate, 0);

        vm.roll(vm.getBlockNumber() + 10);

        vm.prank(payer);
        payments.settleRail(railId, vm.getBlockNumber());

        (uint256 available,,,) = payments.accounts(feeToken, address(payments));
        assertEq(available, 10 * newRate * payments.NETWORK_FEE_NUMERATOR() / payments.NETWORK_FEE_DENOMINATOR());

        payments.burnForFees{value: FIRST_AUCTION_START_PRICE}(feeToken, recipient, available);
        uint256 received = feeToken.balanceOf(recipient);
        assertEq(available * 99 / 100, received);

        (uint256 availableAfter,,,) = payments.accounts(feeToken, address(payments));
        assertEq(availableAfter, 0);

        assertEq(BURN_ADDRESS.balance, FIRST_AUCTION_START_PRICE);
    }
}
