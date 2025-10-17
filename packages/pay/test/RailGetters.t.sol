// SPDX-License-Identifier: Apache-2.0 OR MIT

pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {RailSettlementHelpers} from "./helpers/RailSettlementHelpers.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";

contract PayeeRailsTest is Test, BaseTestHelper {
    PaymentsTestHelpers helper;
    RailSettlementHelpers settlementHelper;
    Payments payments;
    MockERC20 token;

    // Secondary token for multi-token testing
    MockERC20 token2;

    uint256 constant INITIAL_BALANCE = 5000 ether;
    uint256 constant DEPOSIT_AMOUNT = 200 ether;
    uint256 constant MAX_LOCKUP_PERIOD = 100;

    // Rail IDs for tests
    uint256 rail1Id;
    uint256 rail2Id;
    uint256 rail3Id;
    uint256 rail4Id; // Different token
    uint256 rail5Id; // Different payee

    function setUp() public {
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();
        token = MockERC20(address(helper.testToken()));

        // Create settlement helper
        settlementHelper = new RailSettlementHelpers();
        settlementHelper.initialize(payments, helper);

        // Create a second token for multi-token tests
        token2 = new MockERC20("Token 2", "TK2");
        token2.mint(USER1, INITIAL_BALANCE);

        // Make deposits to test accounts
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);

        // For token2
        vm.startPrank(USER1);
        token2.approve(address(payments), type(uint256).max);
        payments.deposit(token2, USER1, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Setup operator approvals
        helper.setupOperatorApproval(
            USER1, // from
            OPERATOR, // operator
            15 ether, // rate allowance (sum of all rates: 5+3+2+1 = 11 ether)
            200 ether, // lockup allowance,
            MAX_LOCKUP_PERIOD // maximum lockup period
        );

        // Setup approval for token2
        vm.startPrank(USER1);
        payments.setOperatorApproval(
            token2,
            OPERATOR,
            true, // approved
            10 ether, // rate allowance
            100 ether, // lockup allowance
            MAX_LOCKUP_PERIOD // maximum lockup period
        );
        vm.stopPrank();

        // Create different rails for testing
        createTestRails();
    }

    function createTestRails() internal {
        // Rail 1: Standard rail with token1 and USER2 as payee
        rail1Id = helper.setupRailWithParameters(
            USER1, // from
            USER2, // to (payee)
            OPERATOR, // operator
            5 ether, // rate
            10, // lockupPeriod
            0, // No fixed lockup
            address(0), // No validator
            SERVICE_FEE_RECIPIENT // operator commision receiver
        );

        // Rail 2: Another rail with token1 and USER2 as payee
        rail2Id = helper.setupRailWithParameters(
            USER1, // from
            USER2, // to (payee)
            OPERATOR, // operator
            3 ether, // rate
            10, // lockupPeriod
            0, // No fixed lockup
            address(0), // No validator
            SERVICE_FEE_RECIPIENT // operator commision receiver
        );

        // Rail 3: Will be terminated
        rail3Id = helper.setupRailWithParameters(
            USER1, // from
            USER2, // to (payee)
            OPERATOR, // operator
            2 ether, // rate
            5, // lockupPeriod
            0, // No fixed lockup
            address(0), // No validator
            SERVICE_FEE_RECIPIENT // operator commision receiver
        );

        // Rail 4: With token2 and USER2 as payee
        vm.startPrank(OPERATOR);
        rail4Id = payments.createRail(
            token2,
            USER1, // from
            USER2, // to (payee)
            address(0), // no validator
            0, // no commission
            SERVICE_FEE_RECIPIENT // operator commision receiver
        );
        payments.modifyRailPayment(rail4Id, 4 ether, 0);
        payments.modifyRailLockup(rail4Id, 10, 0);
        vm.stopPrank();

        // Rail 5: With token1 but USER3 as payee
        rail5Id = helper.setupRailWithParameters(
            USER1, // from
            USER3, // to (payee)
            OPERATOR, // operator
            1 ether, // rate
            10, // lockupPeriod
            0, // No fixed lockup
            address(0), // No validator
            SERVICE_FEE_RECIPIENT // operator commision receiver
        );

        // Terminate Rail 3
        vm.prank(OPERATOR);
        payments.terminateRail(rail3Id);
    }

    function testGetRailsForPayeeAndToken() public view {
        // Test getting all rails for USER2 and token1 (should include terminated)
        (Payments.RailInfo[] memory rails,,) = payments.getRailsForPayeeAndToken(USER2, token, 0, 3);

        // Should include 3 rails: rail1Id, rail2Id, and rail3Id (terminated)
        assertEq(rails.length, 3, "Should have 3 rails for USER2 with token1");

        // Verify the rail IDs and their termination status
        bool foundRail1 = false;
        bool foundRail2 = false;
        bool foundRail3 = false;

        for (uint256 i = 0; i < rails.length; i++) {
            if (rails[i].railId == rail1Id) {
                foundRail1 = true;
                assertFalse(rails[i].isTerminated, "Rail 1 should not be terminated");
                assertEq(rails[i].endEpoch, 0, "Rail 1 should have 0 endEpoch");
            } else if (rails[i].railId == rail2Id) {
                foundRail2 = true;
                assertFalse(rails[i].isTerminated, "Rail 2 should not be terminated");
                assertEq(rails[i].endEpoch, 0, "Rail 2 should have 0 endEpoch");
            } else if (rails[i].railId == rail3Id) {
                foundRail3 = true;
                assertTrue(rails[i].isTerminated, "Rail 3 should be terminated");
                assertTrue(rails[i].endEpoch > 0, "Rail 3 should have non-zero endEpoch");
            }
        }

        assertTrue(foundRail1, "Rail 1 not found");
        assertTrue(foundRail2, "Rail 2 not found");
        assertTrue(foundRail3, "Rail 3 not found");

        // Test different token (should only return rails for that token)
        (Payments.RailInfo[] memory token2Rail,,) = payments.getRailsForPayeeAndToken(USER2, token2, 0, 0);

        // Should include only 1 rail with token2: rail4Id
        assertEq(token2Rail.length, 1, "Should have 1 rail for USER2 with token2");
        assertEq(token2Rail[0].railId, rail4Id, "Rail ID should match rail4Id");

        // Test different payee (should only return rails for that payee)
        (Payments.RailInfo[] memory user3Rails,,) = payments.getRailsForPayeeAndToken(USER3, token, 0, 0);

        // Should include only 1 rail for USER3: rail5Id
        assertEq(user3Rails.length, 1, "Should have 1 rail for USER3 with token1");
        assertEq(user3Rails[0].railId, rail5Id, "Rail ID should match rail5Id");
    }

    function testGetRailsForPayerAndToken() public view {
        // Test getting all rails for USER1 (payer) and token1 (should include terminated)
        (Payments.RailInfo[] memory rails,,) = payments.getRailsForPayerAndToken(USER1, token, 0, 4);

        // Should include 4 rails: rail1Id, rail2Id, rail3Id (terminated), and rail5Id
        assertEq(rails.length, 4, "Should have 4 rails for USER1 with token1");

        // Verify the rail IDs and their termination status
        bool foundRail1 = false;
        bool foundRail2 = false;
        bool foundRail3 = false;
        bool foundRail5 = false;

        for (uint256 i = 0; i < rails.length; i++) {
            if (rails[i].railId == rail1Id) {
                foundRail1 = true;
                assertFalse(rails[i].isTerminated, "Rail 1 should not be terminated");
                assertEq(rails[i].endEpoch, 0, "Rail 1 should have 0 endEpoch");
            } else if (rails[i].railId == rail2Id) {
                foundRail2 = true;
                assertFalse(rails[i].isTerminated, "Rail 2 should not be terminated");
                assertEq(rails[i].endEpoch, 0, "Rail 2 should have 0 endEpoch");
            } else if (rails[i].railId == rail3Id) {
                foundRail3 = true;
                assertTrue(rails[i].isTerminated, "Rail 3 should be terminated");
                assertTrue(rails[i].endEpoch > 0, "Rail 3 should have non-zero endEpoch");
            } else if (rails[i].railId == rail5Id) {
                foundRail5 = true;
                assertFalse(rails[i].isTerminated, "Rail 5 should not be terminated");
                assertEq(rails[i].endEpoch, 0, "Rail 5 should have 0 endEpoch");
            }
        }

        assertTrue(foundRail1, "Rail 1 not found");
        assertTrue(foundRail2, "Rail 2 not found");
        assertTrue(foundRail3, "Rail 3 not found");
        assertTrue(foundRail5, "Rail 5 not found");

        // Test different token (should only return rails for that token)
        (Payments.RailInfo[] memory token2Rails,,) = payments.getRailsForPayerAndToken(USER1, token2, 0, 0);

        // Should include only 1 rail with token2: rail4Id
        assertEq(token2Rails.length, 1, "Should have 1 rail for USER1 with token2");
        assertEq(token2Rails[0].railId, rail4Id, "Rail ID should match rail4Id");
    }

    function testRailsBeyondEndEpoch() public {
        // Get the initial rails when Rail 3 is terminated but not beyond its end epoch
        (Payments.RailInfo[] memory initialPayeeRails,,) = payments.getRailsForPayeeAndToken(USER2, token, 0, 3);
        (Payments.RailInfo[] memory initialPayerRails,,) = payments.getRailsForPayerAndToken(USER1, token, 0, 4);

        // Should include all 3 rails for payee
        assertEq(initialPayeeRails.length, 3, "Should have 3 rails initially for payee");
        // Should include all 4 rails for payer
        assertEq(initialPayerRails.length, 4, "Should have 4 rails initially for payer");

        // Get the endEpoch for Rail 3
        uint256 endEpoch;
        for (uint256 i = 0; i < initialPayeeRails.length; i++) {
            if (initialPayeeRails[i].railId == rail3Id) {
                endEpoch = initialPayeeRails[i].endEpoch;
                break;
            }
        }

        // Advance blocks beyond the end epoch of Rail 3
        uint256 blocksToAdvance = endEpoch - block.number + 1;
        helper.advanceBlocks(blocksToAdvance);

        // IMPORTANT: Settle the rail now that we're beyond its end epoch
        // This will finalize the rail (set rail.from = address(0))
        vm.prank(USER1); // Settle as the client
        payments.settleRail(rail3Id, endEpoch);

        // Get rails again for both payee and payer
        (Payments.RailInfo[] memory finalPayeeRails,,) = payments.getRailsForPayeeAndToken(USER2, token, 0, 3);
        (Payments.RailInfo[] memory finalPayerRails,,) = payments.getRailsForPayerAndToken(USER1, token, 0, 4);

        // Should include only 2 rails now for payee, as Rail 3 is beyond its end epoch
        assertEq(finalPayeeRails.length, 2, "Should have 2 rails for payee after advancing beyond end epoch");

        // Should include only 3 rails now for payer, as Rail 3 is beyond its end epoch
        assertEq(finalPayerRails.length, 3, "Should have 3 rails for payer after advancing beyond end epoch");

        // Verify Rail 3 is no longer included in payee rails
        bool railFoundInPayeeRails = false;
        for (uint256 i = 0; i < finalPayeeRails.length; i++) {
            if (finalPayeeRails[i].railId == rail3Id) {
                railFoundInPayeeRails = true;
                break;
            }
        }

        // Verify Rail 3 is no longer included in payer rails
        bool railFoundInPayerRails = false;
        for (uint256 i = 0; i < finalPayerRails.length; i++) {
            if (finalPayerRails[i].railId == rail3Id) {
                railFoundInPayerRails = true;
                break;
            }
        }

        assertFalse(railFoundInPayeeRails, "Rail 3 should not be included in payee rails after its end epoch");

        assertFalse(railFoundInPayerRails, "Rail 3 should not be included in payer rails after its end epoch");
    }

    function testEmptyResult() public view {
        // Test non-existent payee
        (Payments.RailInfo[] memory nonExistentPayee,,) = payments.getRailsForPayeeAndToken(address(0x123), token, 0, 0);
        assertEq(nonExistentPayee.length, 0, "Should return empty array for non-existent payee");

        // Test non-existent payer
        (Payments.RailInfo[] memory nonExistentPayer,,) = payments.getRailsForPayerAndToken(address(0x123), token, 0, 0);
        assertEq(nonExistentPayer.length, 0, "Should return empty array for non-existent payer");

        // Test non-existent token for payee
        (Payments.RailInfo[] memory nonExistentTokenForPayee,,) =
            payments.getRailsForPayeeAndToken(USER2, IERC20(address(0x456)), 0, 0);
        assertEq(nonExistentTokenForPayee.length, 0, "Should return empty array for non-existent token with payee");

        // Test non-existent token for payer
        (Payments.RailInfo[] memory nonExistentTokenForPayer,,) =
            payments.getRailsForPayerAndToken(USER1, IERC20(address(0x456)), 0, 0);
        assertEq(nonExistentTokenForPayer.length, 0, "Should return empty array for non-existent token with payer");
    }

    function testPagination() public view {
        // Test pagination for payee rails (USER2 has 3 rails with token1)

        // Test getting first 2 rails
        (Payments.RailInfo[] memory page1, uint256 nextOffset1, uint256 total1) =
            payments.getRailsForPayeeAndToken(USER2, token, 0, 2);

        assertEq(page1.length, 2, "First page should have 2 rails");
        assertEq(nextOffset1, 2, "Next offset should be 2");
        assertEq(total1, 3, "Total should be 3");

        // Test getting remaining rail
        (Payments.RailInfo[] memory page2, uint256 nextOffset2, uint256 total2) =
            payments.getRailsForPayeeAndToken(USER2, token, nextOffset1, 2);

        assertEq(page2.length, 1, "Second page should have 1 rail");
        assertEq(nextOffset2, 3, "Next offset should be 3 (end of array)");
        assertEq(total2, 3, "Total should still be 3");

        // Verify no duplicate rails between pages
        bool duplicateFound = false;
        for (uint256 i = 0; i < page1.length; i++) {
            for (uint256 j = 0; j < page2.length; j++) {
                if (page1[i].railId == page2[j].railId) {
                    duplicateFound = true;
                    break;
                }
            }
        }
        assertFalse(duplicateFound, "No duplicate rails should exist between pages");

        // Test offset beyond array length
        (Payments.RailInfo[] memory emptyPage, uint256 nextOffset3, uint256 total3) =
            payments.getRailsForPayeeAndToken(USER2, token, 10, 2);

        assertEq(emptyPage.length, 0, "Should return empty array for offset beyond length");
        assertEq(nextOffset3, 3, "Next offset should equal total length");
        assertEq(total3, 3, "Total should still be 3");

        // Test pagination for payer rails (USER1 has 4 rails with token1)
        (Payments.RailInfo[] memory payerPage1, uint256 payerNext1, uint256 payerTotal1) =
            payments.getRailsForPayerAndToken(USER1, token, 0, 3);

        assertEq(payerPage1.length, 3, "Payer first page should have 3 rails");
        assertEq(payerNext1, 3, "Payer next offset should be 3");
        assertEq(payerTotal1, 4, "Payer total should be 4");

        (Payments.RailInfo[] memory payerPage2, uint256 payerNext2, uint256 payerTotal2) =
            payments.getRailsForPayerAndToken(USER1, token, payerNext1, 3);

        assertEq(payerPage2.length, 1, "Payer second page should have 1 rail");
        assertEq(payerNext2, 4, "Payer next offset should be 4 (end of array)");
        assertEq(payerTotal2, 4, "Payer total should still be 4");
    }
}
