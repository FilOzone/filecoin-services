// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {PDPListener, PDPVerifier} from "@pdp/PDPVerifier.sol";
import {PandoraService, IPayments} from "../src/PandoraService.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Cids} from "@pdp/Cids.sol";
import {Payments, IArbiter} from "@fws-payments/Payments.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./PandoraService.t.sol";

contract PandoraServiceGracePeriodTest is Test {
    PandoraService public pandora;
    PDPVerifier public pdpVerifier;
    MockERC20 public usdfcToken;
    MockPayments public payments;
    
    address public owner = address(1);
    address public provider = address(2);
    address public client = address(3);
    
    uint256 constant DEFAULT_LOCKUP_PERIOD = 2880 * 10; // 10 days in epochs
    uint256 constant PROOF_SET_ID = 1;
    uint256 constant RAIL_ID = 100;
    
    event GracePeriodStarted(uint256 indexed proofSetId, uint256 expiresAt);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy mock USDFC token
        usdfcToken = new MockERC20();
        
        // Deploy mock payments contract
        payments = new MockPayments();
        
        // Deploy PDPVerifier
        pdpVerifier = new PDPVerifier();
        
        // Deploy and initialize PandoraService
        PandoraService impl = new PandoraService();
        bytes memory initData = abi.encodeWithSelector(
            PandoraService.initialize.selector,
            address(pdpVerifier),
            address(payments),
            address(usdfcToken),
            500, // 5% commission
            2880, // max proving period
            100 // challenge window size
        );
        MyERC1967Proxy proxy = new MyERC1967Proxy(address(impl), initData);
        pandora = PandoraService(address(proxy));
        
        // Register PDPListener in PDPVerifier
        pdpVerifier.addListener(address(pandora));
        
        // Approve and add provider
        pandora.addServiceProvider(provider, "http://pdp.example.com", "http://retrieval.example.com");
        
        vm.stopPrank();
        
        // Give client some tokens
        vm.prank(address(usdfcToken));
        usdfcToken.transfer(client, 1000000 * 10**6);
    }
    
    function testGracePeriodStartedEvent() public {
        // Setup proof set
        _createProofSet();
        
        // Set account to be underfunded (funded until epoch in the past)
        uint256 currentEpoch = block.number;
        uint256 fundedUntilEpoch = currentEpoch - 100; // 100 epochs in the past
        payments.setAccountInfo(client, fundedUntilEpoch);
        
        // Call nextProvingPeriod which should trigger grace period check
        vm.prank(address(pdpVerifier));
        
        // Expect the GracePeriodStarted event
        uint256 expectedExpiresAt = fundedUntilEpoch + DEFAULT_LOCKUP_PERIOD;
        vm.expectEmit(true, false, false, true);
        emit GracePeriodStarted(PROOF_SET_ID, expectedExpiresAt);
        
        pandora.nextProvingPeriod(PROOF_SET_ID, block.number + 2500, 1000, "");
    }
    
    function testNoGracePeriodEventWhenFunded() public {
        // Setup proof set
        _createProofSet();
        
        // Set account to be well funded
        uint256 currentEpoch = block.number;
        uint256 fundedUntilEpoch = currentEpoch + 10000; // Well funded
        payments.setAccountInfo(client, fundedUntilEpoch);
        
        // Call nextProvingPeriod - should NOT emit grace period event
        vm.prank(address(pdpVerifier));
        
        // Record logs to check no event is emitted
        vm.recordLogs();
        pandora.nextProvingPeriod(PROOF_SET_ID, block.number + 2500, 1000, "");
        
        // Check that no GracePeriodStarted event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], keccak256("GracePeriodStarted(uint256,uint256)"));
        }
    }
    
    function testDeleteProofSetAfterGracePeriodExpires() public {
        // Setup proof set
        _createProofSet();
        
        // Set account to be underfunded
        uint256 currentEpoch = block.number;
        uint256 fundedUntilEpoch = currentEpoch - DEFAULT_LOCKUP_PERIOD - 100; // Grace period expired
        payments.setAccountInfo(client, fundedUntilEpoch);
        
        // Provider should be able to delete without client signature
        vm.prank(address(pdpVerifier));
        bytes memory emptySignature = "";
        pandora.proofSetDeleted(PROOF_SET_ID, 0, abi.encode(emptySignature));
        
        // Verify rail was settled and terminated
        assertTrue(payments.wasSettleCalled(RAIL_ID));
        assertTrue(payments.wasTerminateCalled(RAIL_ID));
    }
    
    function testCannotDeleteBeforeGracePeriodExpires() public {
        // Setup proof set
        _createProofSet();
        
        // Set account to be in grace period but not expired
        uint256 currentEpoch = block.number;
        uint256 fundedUntilEpoch = currentEpoch - 100; // In grace period but not expired
        payments.setAccountInfo(client, fundedUntilEpoch);
        
        // Provider should NOT be able to delete
        vm.prank(address(pdpVerifier));
        bytes memory emptySignature = "";
        vm.expectRevert("Not authorized to delete proof set");
        pandora.proofSetDeleted(PROOF_SET_ID, 0, abi.encode(emptySignature));
    }
    
    function testClientCanAlwaysDelete() public {
        // Setup proof set
        _createProofSet();
        
        // Even if funded, client can delete with valid signature
        uint256 fundedUntilEpoch = block.number + 10000;
        payments.setAccountInfo(client, fundedUntilEpoch);
        
        // Create valid signature from client
        bytes memory signature = _createDeleteSignature();
        
        vm.prank(address(pdpVerifier));
        pandora.proofSetDeleted(PROOF_SET_ID, 0, abi.encode(signature));
        
        // Should succeed without settling/terminating rail
        assertFalse(payments.wasSettleCalled(RAIL_ID));
        assertFalse(payments.wasTerminateCalled(RAIL_ID));
    }
    
    function _createProofSet() internal {
        // Create signature for proof set creation
        bytes memory signature = _createProofSetSignature();
        
        // Create proof set
        vm.prank(address(pdpVerifier));
        bytes memory extraData = abi.encode("metadata", client, false, signature);
        pandora.proofSetCreated(PROOF_SET_ID, provider, extraData);
        
        // Set rail ID in payments mock
        payments.setRailId(PROOF_SET_ID, RAIL_ID);
    }
    
    function _createProofSetSignature() internal view returns (bytes memory) {
        // In real implementation, this would create a proper EIP-712 signature
        // For testing, we'll return a dummy signature that the mock accepts
        return abi.encodePacked(uint8(27), bytes32(0), bytes32(0));
    }
    
    function _createDeleteSignature() internal view returns (bytes memory) {
        // In real implementation, this would create a proper EIP-712 signature
        // For testing, we'll return a dummy signature that the mock accepts
        return abi.encodePacked(uint8(27), bytes32(0), bytes32(0));
    }
}

// Mock Payments contract for testing
contract MockPayments is IPayments {
    mapping(address => uint256) public fundedUntilEpoch;
    mapping(uint256 => bool) public settleCalled;
    mapping(uint256 => bool) public terminateCalled;
    mapping(uint256 => uint256) public proofSetToRail;
    
    function setAccountInfo(address account, uint256 _fundedUntilEpoch) external {
        fundedUntilEpoch[account] = _fundedUntilEpoch;
    }
    
    function setRailId(uint256 proofSetId, uint256 railId) external {
        proofSetToRail[proofSetId] = railId;
    }
    
    function getAccountInfoIfSettled(address token, address owner) external view returns (
        uint256 funds,
        uint256 lockupCurrent,
        uint256 lockupRate,
        uint256 lockupLastSettledAt,
        uint256 _fundedUntilEpoch
    ) {
        return (1000000, 100000, 100, block.number, fundedUntilEpoch[owner]);
    }
    
    function settleRail(uint256 railId, uint256 untilEpoch) external returns (
        uint256 totalSettledAmount,
        uint256 totalNetPayeeAmount,
        uint256 totalPaymentFee,
        uint256 totalOperatorCommission,
        uint256 finalSettledEpoch,
        string memory note
    ) {
        settleCalled[railId] = true;
        return (1000, 950, 10, 40, untilEpoch, "Settled");
    }
    
    function terminateRail(uint256 railId, uint256 endEpoch) external {
        terminateCalled[railId] = true;
    }
    
    function wasSettleCalled(uint256 railId) external view returns (bool) {
        return settleCalled[railId];
    }
    
    function wasTerminateCalled(uint256 railId) external view returns (bool) {
        return terminateCalled[railId];
    }
    
    // Implement other required functions with dummy implementations
    function createRail(
        address token,
        address from,
        address to,
        address arbiter,
        uint256 commissionRateBps
    ) external returns (uint256) {
        return proofSetToRail[1]; // Return the rail ID set for testing
    }
    
    function modifyRailLockup(
        uint256 railId,
        uint256 lockupPeriod,
        uint256 lockupFixed
    ) external {}
    
    function modifyRailPayment(
        uint256 railId,
        uint256 newRate,
        uint256 oneTimePayment
    ) external {}
}