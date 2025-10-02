// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.27;

import {ExtraFeeToken} from "./mocks/ExtraFeeToken.sol";
import {Errors} from "@payments/Errors.sol";
import {Payments} from "@payments/Payments.sol";
import {Test} from "forge-std/Test.sol";

contract WithdrawExtraFeeTokenTest is Test {
    function testWithdrawFeeToken() public {
        Payments payments = new Payments();
        uint256 transferFee = 10 ** 18;
        ExtraFeeToken feeToken = new ExtraFeeToken(transferFee);
        address user1 = vm.addr(0x1111);
        address user2 = vm.addr(0x2222);
        feeToken.mint(user1, 10 ** 24);
        feeToken.mint(user2, 10 ** 24);

        vm.prank(user1);
        feeToken.approve(address(payments), 10 ** 24);

        vm.prank(user2);
        feeToken.approve(address(payments), 10 ** 24);

        vm.prank(user1);
        vm.expectRevert();
        payments.deposit(feeToken, user1, 10 ** 24);

        vm.prank(user1);
        payments.deposit(feeToken, user1, 10 ** 23);

        assertEq(feeToken.balanceOf(address(payments)), 10 ** 23);
        (uint256 deposit,,,) = payments.accounts(feeToken, user1);
        assertEq(deposit, 10 ** 23);

        vm.prank(user1);
        vm.expectRevert();
        payments.withdraw(feeToken, 10 ** 23);

        vm.prank(user2);
        payments.deposit(feeToken, user2, 10 ** 23);
        (deposit,,,) = payments.accounts(feeToken, user2);
        assertEq(deposit, 10 ** 23);

        assertEq(feeToken.balanceOf(address(payments)), 2 * 10 ** 23);

        // the other user's deposit should not allow the withdrawal
        vm.prank(user1);
        vm.expectRevert();
        payments.withdraw(feeToken, 10 ** 23);

        // users can still withdraw their balance
        (deposit,,,) = payments.accounts(feeToken, user1);
        assertEq(deposit, 10 ** 23);
        vm.prank(user1);
        payments.withdraw(feeToken, deposit - transferFee);
        (deposit,,,) = payments.accounts(feeToken, user1);
        assertEq(deposit, 0);

        (deposit,,,) = payments.accounts(feeToken, user2);
        assertEq(deposit, 10 ** 23);
        vm.prank(user2);
        payments.withdraw(feeToken, deposit - transferFee);
        (deposit,,,) = payments.accounts(feeToken, user2);
        assertEq(deposit, 0);

        assertEq(feeToken.balanceOf(address(payments)), 0);
    }

    function testWithdrawLockup() public {
        Payments payments = new Payments();
        uint256 transferFee = 10 ** 18;
        ExtraFeeToken feeToken = new ExtraFeeToken(transferFee);
        address user1 = vm.addr(0x1111);
        address user2 = vm.addr(0x1112);
        feeToken.mint(user1, 10 ** 24);
        feeToken.mint(user2, 10 ** 24);

        vm.prank(user1);
        feeToken.approve(address(payments), 10 ** 24);
        vm.prank(user1);
        payments.deposit(feeToken, user1, 10 ** 24 - transferFee);

        vm.prank(user2);
        feeToken.approve(address(payments), 10 ** 24);
        vm.prank(user2);
        payments.deposit(feeToken, user2, 10 ** 24 - transferFee);

        (uint256 deposit,,,) = payments.accounts(feeToken, user1);
        assertEq(deposit, 10 ** 24 - transferFee);

        address operator = vm.addr(0x2222);

        vm.prank(user1);
        payments.setOperatorApproval(feeToken, operator, true, deposit, deposit, deposit);
        vm.prank(operator);
        uint256 railId = payments.createRail(feeToken, user1, operator, address(0), 0, address(0));

        uint256 lockup = 10 ** 17;
        vm.prank(operator);
        payments.modifyRailLockup(railId, 0, lockup);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientUnlockedFunds.selector, deposit - lockup, deposit));
        payments.withdraw(feeToken, deposit);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientUnlockedFunds.selector, deposit - lockup, deposit - lockup + transferFee
            )
        );
        payments.withdraw(feeToken, deposit - lockup);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientUnlockedFunds.selector, deposit - lockup, deposit));
        payments.withdraw(feeToken, deposit - transferFee);

        vm.prank(user1);
        payments.withdraw(feeToken, deposit - transferFee - lockup);
    }
}
