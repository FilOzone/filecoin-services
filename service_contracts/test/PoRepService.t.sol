// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {PoRepPayee, PoRepService, Unauthorized} from "../src/PoRepService.sol";
import {FVMActor} from "@fvm-solidity/FVMActor.sol";
import {FVMMinerActor} from "@fvm-solidity/mocks/FVMMinerActor.sol";
import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";

contract PoRepPayeeTest is MockFVMTest {
    using FVMActor for address;

    uint64 constant MINER_ID = 1643;
    uint64 constant OWNER_ID = 151;
    PoRepPayee payee;

    function setUp() public override {
        super.setUp();

        FVMMinerActor miner = mockMiner(MINER_ID);
        ACTOR_PRECOMPILE.mockResolveAddress(address(this), OWNER_ID);
        ACTOR_PRECOMPILE.mockResolveAddress(address(miner), MINER_ID);
        miner.mockOwner(OWNER_ID);

        payee = new PoRepPayee();
    }

    function getMiner() external pure returns (uint64 payee) {
        return MINER_ID;
    }

    function testOwner() public view {
        assertEq(payee.MINER(), MINER_ID);
        assertEq(payee.owner(), OWNER_ID);
        assertEq(address(this).getActorId(), OWNER_ID);
    }

    function testSudoUnauthorized() public {
        address payable notOwner = payable(0x9999999999999999999999999999999999999999);
        vm.deal(notOwner, 1);
        ACTOR_PRECOMPILE.mockResolveAddress(notOwner, OWNER_ID + 1);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notOwner));
        vm.prank(notOwner);
        payee.sudo{value: 1}(notOwner, bytes(""));
    }

    function testSudo() public {
        address payable notOwner = payable(0x9999999999999999999999999999999999999999);
        assertEq(notOwner.balance, 0);
        payee.sudo{value: 1}(notOwner, bytes(""));
        assertEq(notOwner.balance, 1);
    }
}

contract PoRepServiceTest is MockFVMTest {
    FilecoinPayV1 payments;
    PoRepService service;

    function setUp() public override {
        super.setUp();

        payments = new FilecoinPayV1();
        service = new PoRepService(payments);
    }

    function testCreateReceiver() public {
        uint64 minerId = 64;

        address receiver = service.getReceiverAddress(minerId);
        assertEq(receiver.code.length, 0);

        address created = service.createReceiver(minerId);
        assertEq(receiver, created);
        assertNotEq(receiver.code.length, 0);

        assertEq(PoRepPayee(created).MINER(), minerId);
    }
}
