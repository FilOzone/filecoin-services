// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {Errors} from "@fws-payments/Errors.sol";
import {PoRepDeal} from "../src/PoRepDeal.sol";
import {PoRepPayee, PoRepService, TerminationForbidden, Unauthorized} from "../src/PoRepService.sol";
import {FVMMinerActor} from "@fvm-solidity/mocks/FVMMinerActor.sol";
import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {PieceChange, SectorChanges, SectorContentChangedParams} from "@fvm-solidity/FVMSectorContentChanged.sol";
import {FVMSector, NO_DEADLINE, NO_PARTITION, SectorStatus} from "@fvm-solidity/FVMSector.sol";
import {USR_NOT_FOUND} from "@fvm-solidity/FVMErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

IERC20 constant NATIVE_TOKEN = IERC20(address(0));

contract PoRepDealSectorStatusTest is MockFVMTest {
    uint64 constant MINER_ID = 142;
    uint64 constant OWNER_ID = 156;
    uint64 constant SECTOR_ID = 1;
    int64 constant DEADLINE = 3;
    int64 constant PARTITION = 0;
    uint64 constant DAYS_OF_EPOCHS = uint64(1 days / 30);
    uint64 constant DURATION = 180 * DAYS_OF_EPOCHS;
    uint64 constant FAULT_MAX_AGE = 42 * DAYS_OF_EPOCHS;
    uint64 constant SIZE = 32 * 1024 * 1024 * 1024;
    uint256 constant RATE = 10000;
    uint256 constant INSURANCE_BIPS = 50;

    bytes constant COMMP_CID_1 = hex"0181e203922020cdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b36";
    bytes32 constant COMMP_DIGEST_1 = 0xcdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b36;
    bytes constant COMMP_CID_2 = hex"0181e203922020adf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b36";
    bytes32 constant COMMP_DIGEST_2 = 0xadf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b36;
    uint64 constant SECTOR_ID_2 = 2;

    FilecoinPayV1 payments;
    PoRepService service;
    FVMMinerActor miner;
    address client;
    PoRepDeal poRepDeal;
    uint64 endEpoch;
    PoRepPayee payee;

    function setUp() public override {
        super.setUp();
        client = makeAddr("client");
        vm.deal(client, 1000 ether);

        payments = new FilecoinPayV1();
        service = new PoRepService(payments);
        miner = mockMiner(MINER_ID);
        ACTOR_PRECOMPILE.mockResolveAddress(address(this), OWNER_ID);
        ACTOR_PRECOMPILE.mockResolveAddress(address(miner), MINER_ID);
        miner.mockOwner(OWNER_ID);

        uint256 maxRate = uint256(SIZE) * RATE;
        uint256 maxLockup = maxRate * DURATION;
        vm.prank(client);
        payments.setOperatorApproval(IERC20(address(0)), address(service), true, maxRate, maxLockup, DURATION);

        uint256 required = uint256(SIZE) * RATE * DURATION;
        vm.prank(client);
        payments.deposit{value: required}(NATIVE_TOKEN, client, required);

        endEpoch = uint64(block.number) + DURATION;
        vm.expectEmit(address(service));
        emit PoRepService.DealCreated(client, MINER_ID, _predictDealAddress(MINER_ID));
        poRepDeal = PoRepDeal(service.createDeal(client, MINER_ID, NATIVE_TOKEN, RATE, endEpoch, INSURANCE_BIPS));
        payee = PoRepPayee(service.getReceiverAddress(MINER_ID));

        bytes32[] memory cidHashes = new bytes32[](1);
        cidHashes[0] = COMMP_DIGEST_1;
        vm.prank(client);
        poRepDeal.addPieces(cidHashes);

        // Mock sector as Active with location before activation
        miner.mockSector(SECTOR_ID, SectorStatus.Active, DEADLINE, PARTITION, endEpoch);

        uint64 nonce = _findDealNonce(address(service), address(poRepDeal));
        PieceChange[] memory pieces = new PieceChange[](1);
        pieces[0] = PieceChange({data: COMMP_CID_1, size: SIZE, payload: abi.encodePacked(nonce)});
        SectorChanges[] memory sectorChanges = new SectorChanges[](1);
        sectorChanges[0] = SectorChanges({sector: SECTOR_ID, minimumCommitmentEpoch: int64(endEpoch), added: pieces});
        miner.callSectorContentChanged(address(service), SectorContentChangedParams({sectors: sectorChanges}));
    }

    function _findDealNonce(address deployer, address created) internal pure returns (uint64) {
        for (uint64 n = 1; n <= 20; n++) {
            if (vm.computeCreateAddress(deployer, n) == created) return n;
        }
        revert("could not find deal nonce");
    }

    function _predictDealAddress(uint64 provider) internal view returns (address) {
        uint64 nextNonce = uint64(vm.getNonce(address(service)));
        if (service.getReceiverAddress(provider).code.length == 0) {
            nextNonce++;
        }
        return vm.computeCreateAddress(address(service), nextNonce);
    }

    function assertRailFinalized() internal {
        uint256 railId = poRepDeal.RAIL_ID();
        vm.expectRevert(abi.encodeWithSelector(Errors.RailInactiveOrSettled.selector, railId));
        payments.getRail(railId);
    }

    address constant RECIPIENT = address(0x4141414141414141414141414141414141414141);
    address constant SWEEPER = address(0x4242424242424242424242424242424242424242);

    // tests the case where nobody flagged the fault but someone did flag the expiry
    function testSectorExpiredAfterActivation() public {
        vm.roll(vm.getBlockNumber() + FAULT_MAX_AGE);

        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Dead);
        poRepDeal.sectorExpired(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);

        assertEq(RECIPIENT.balance, FAULT_MAX_AGE * SIZE * INSURANCE_BIPS * 199 / 200);

        (uint256 paid,,,) = payments.accounts(NATIVE_TOKEN, address(payee));
        assertEq(paid, FAULT_MAX_AGE * SIZE * RATE * 199 / 200 * (10000 - INSURANCE_BIPS) / 10000);
        assertRailFinalized();
    }

    // tests recovery
    function testSectorRecoverFaultyAfterActivation() public {
        vm.roll(vm.getBlockNumber() + 3 * DAYS_OF_EPOCHS);

        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Faulty);
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);

        uint256 bounty = RECIPIENT.balance;
        assertEq(bounty, 3 * DAYS_OF_EPOCHS * SIZE * INSURANCE_BIPS * 199 / 400);

        vm.roll(vm.getBlockNumber() + FAULT_MAX_AGE / 2);

        miner.mockSector(SECTOR_ID, SectorStatus.Active, DEADLINE, PARTITION, endEpoch);
        poRepDeal.sectorRecovered(SECTOR_ID, DEADLINE, PARTITION);

        vm.roll(vm.getBlockNumber() + DURATION);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        poRepDeal.sweep(SWEEPER);

        ACTOR_PRECOMPILE.mockResolveAddress(SWEEPER, 999);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, SWEEPER));
        vm.prank(SWEEPER);
        payee.sudo(payable(address(poRepDeal)), abi.encodeWithSelector(PoRepDeal.sweep.selector, SWEEPER));

        payee.sudo(payable(address(poRepDeal)), abi.encodeWithSelector(PoRepDeal.sweep.selector, SWEEPER));

        uint256 paidEpochs = DURATION - FAULT_MAX_AGE / 2;
        assertEq(SWEEPER.balance, paidEpochs * SIZE * INSURANCE_BIPS * 199 / 200 - bounty);

        (uint256 paid,,,) = payments.accounts(NATIVE_TOKEN, address(payee));
        assertEq(paid, paidEpochs * SIZE * RATE * 199 / 200 * (10000 - INSURANCE_BIPS) / 10000);
        assertRailFinalized();
    }

    function testBothSectorsRecovered() public {
        // Extend approval and deposit to cover two sectors
        vm.prank(client);
        payments.setOperatorApproval(
            NATIVE_TOKEN,
            address(service),
            true,
            uint256(2 * SIZE) * RATE,
            uint256(2 * SIZE) * RATE * DURATION,
            DURATION
        );
        vm.prank(client);
        payments.deposit{value: uint256(SIZE) * RATE * DURATION}(NATIVE_TOKEN, client, uint256(SIZE) * RATE * DURATION);

        // Authorize and activate second piece in a second sector
        bytes32[] memory cidHashes = new bytes32[](1);
        cidHashes[0] = COMMP_DIGEST_2;
        vm.prank(client);
        poRepDeal.addPieces(cidHashes);

        uint64 nonce = _findDealNonce(address(service), address(poRepDeal));
        miner.mockSector(SECTOR_ID_2, SectorStatus.Active, DEADLINE, PARTITION, endEpoch);
        PieceChange[] memory pieces = new PieceChange[](1);
        pieces[0] = PieceChange({data: COMMP_CID_2, size: SIZE, payload: abi.encodePacked(nonce)});
        SectorChanges[] memory sectorChanges = new SectorChanges[](1);
        sectorChanges[0] = SectorChanges({sector: SECTOR_ID_2, minimumCommitmentEpoch: int64(endEpoch), added: pieces});
        miner.callSectorContentChanged(address(service), SectorContentChangedParams({sectors: sectorChanges}));

        vm.roll(vm.getBlockNumber() + 3 * DAYS_OF_EPOCHS);

        // First fault pays bounty; second does not
        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Faulty);
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);
        uint256 bounty = RECIPIENT.balance;
        assertGt(bounty, 0);

        miner.mockSectorStatus(SECTOR_ID_2, SectorStatus.Faulty);
        poRepDeal.sectorFaulty(SECTOR_ID_2, DEADLINE, PARTITION, RECIPIENT);
        assertEq(RECIPIENT.balance, bounty);

        vm.roll(vm.getBlockNumber() + FAULT_MAX_AGE / 2);

        // First recovery leaves the deal faulted
        miner.mockSector(SECTOR_ID, SectorStatus.Active, DEADLINE, PARTITION, endEpoch);
        poRepDeal.sectorRecovered(SECTOR_ID, DEADLINE, PARTITION);
        (,, uint32 faultedCount,) = poRepDeal.info();
        assertEq(faultedCount, 1);

        // Second recovery fully restores the deal
        miner.mockSector(SECTOR_ID_2, SectorStatus.Active, DEADLINE, PARTITION, endEpoch);
        poRepDeal.sectorRecovered(SECTOR_ID_2, DEADLINE, PARTITION);
        (,, faultedCount,) = poRepDeal.info();
        assertEq(faultedCount, 0);

        vm.roll(endEpoch + 1);
        payee.sudo(payable(address(poRepDeal)), abi.encodeWithSelector(PoRepDeal.sweep.selector, SWEEPER));
        assertRailFinalized();
    }

    // tests expiration after fault
    function testSectorExpiredAfterFaulty() public {
        vm.roll(vm.getBlockNumber() + 3 * DAYS_OF_EPOCHS);

        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Faulty);
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);

        vm.roll(vm.getBlockNumber() + FAULT_MAX_AGE);

        uint256 balanceBefore = RECIPIENT.balance;
        assertEq(balanceBefore, 3 * DAYS_OF_EPOCHS * SIZE * INSURANCE_BIPS * 199 / 400);

        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Dead);
        poRepDeal.sectorExpired(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);

        assertEq(RECIPIENT.balance, balanceBefore * 2);

        (uint256 paid,,,) = payments.accounts(NATIVE_TOKEN, address(payee));
        assertEq(paid, 3 * DAYS_OF_EPOCHS * SIZE * RATE * 199 / 200 * (10000 - INSURANCE_BIPS) / 10000);
        assertRailFinalized();
    }

    function testSectorExpiredRevertsNotYetCompacted() public {
        vm.expectRevert(
            abi.encodeWithSelector(FVMSector.ValidateSectorStatusFailed.selector, int256(int32(USR_NOT_FOUND)))
        );
        poRepDeal.sectorExpired(SECTOR_ID, NO_DEADLINE, NO_PARTITION, RECIPIENT);
    }

    function testSectorExpiredRevertsIfStillActive() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepDeal.SectorNotDead.selector, SECTOR_ID));
        poRepDeal.sectorExpired(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);
    }

    function testSectorFaultyRevertsIfStillActive() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepDeal.SectorNotFaulty.selector, uint64(SECTOR_ID)));
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);
    }

    function testSectorExpiredAfterDealEnd() public {
        vm.roll(endEpoch);
        vm.expectRevert(PoRepDeal.DealExpired.selector);
        poRepDeal.sectorExpired(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);
    }

    function testSectorExpiredNotInDeal() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepDeal.SectorNotInDeal.selector, uint64(99)));
        poRepDeal.sectorExpired(99, DEADLINE, PARTITION, RECIPIENT);
    }

    function testSectorFaultyAfterDealEnd() public {
        vm.roll(endEpoch);
        vm.expectRevert(PoRepDeal.DealExpired.selector);
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);
    }

    function testSectorFaultyNotInDeal() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepDeal.SectorNotInDeal.selector, uint64(99)));
        poRepDeal.sectorFaulty(99, DEADLINE, PARTITION, RECIPIENT);
    }

    function testSectorFaultyAlreadyFailed() public {
        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Faulty);
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);

        vm.expectRevert(abi.encodeWithSelector(PoRepDeal.SectorAlreadyFailed.selector, uint64(SECTOR_ID)));
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);
    }

    function testSectorRecoveredNotFailed() public {
        vm.expectRevert(abi.encodeWithSelector(PoRepDeal.SectorNotFailed.selector, uint64(SECTOR_ID)));
        poRepDeal.sectorRecovered(SECTOR_ID, DEADLINE, PARTITION);
    }

    function testSectorRecoveredStillFaulty() public {
        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Faulty);
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);

        vm.expectRevert(abi.encodeWithSelector(PoRepDeal.SectorNotActive.selector, uint64(SECTOR_ID)));
        poRepDeal.sectorRecovered(SECTOR_ID, DEADLINE, PARTITION);
    }

    // -------------------------------------------------------------------------
    // authenticateDeal authorization tests
    // -------------------------------------------------------------------------

    function testUpdateLockupsPayeeReceiverUnauthorized() public {
        uint64 dealNonce = _findDealNonce(address(service), address(poRepDeal));
        uint256 railId = poRepDeal.RAIL_ID();
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(payee)));
        vm.prank(address(payee));
        service.updateLockups(dealNonce, railId, 0, 0);
    }

    function testTerminatePayeeReceiverUnauthorized() public {
        uint64 dealNonce = _findDealNonce(address(service), address(poRepDeal));
        uint256 railId = poRepDeal.RAIL_ID();
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(payee)));
        vm.prank(address(payee));
        service.terminate(dealNonce, railId, uint64(0), address(0));
    }

    // The receiver is deployed via CREATE2, so its nonce slot (dealNonce-1) does NOT map to
    // address(payee) under CREATE address derivation. These tests catch a regression where
    // the receiver is changed from CREATE2 to CREATE, which would let the owner authenticate
    // as a deal and manipulate rails.
    function testUpdateLockupsReceiverNonceUnauthorized() public {
        uint64 dealNonce = _findDealNonce(address(service), address(poRepDeal));
        uint256 railId = poRepDeal.RAIL_ID();
        uint64 receiverNonce = dealNonce - 1;
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(payee)));
        vm.prank(address(payee));
        service.updateLockups(receiverNonce, railId, 0, 0);
    }

    function testTerminateReceiverNonceUnauthorized() public {
        uint64 dealNonce = _findDealNonce(address(service), address(poRepDeal));
        uint256 railId = poRepDeal.RAIL_ID();
        uint64 receiverNonce = dealNonce - 1;
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(payee)));
        vm.prank(address(payee));
        service.terminate(receiverNonce, railId, uint64(0), address(0));
    }

    function testUpdateLockupsStrangerUnauthorized() public {
        uint64 dealNonce = _findDealNonce(address(service), address(poRepDeal));
        uint256 railId = poRepDeal.RAIL_ID();
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        vm.prank(stranger);
        service.updateLockups(dealNonce, railId, 0, 0);
    }

    function testTerminateStrangerUnauthorized() public {
        uint64 dealNonce = _findDealNonce(address(service), address(poRepDeal));
        uint256 railId = poRepDeal.RAIL_ID();
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        vm.prank(stranger);
        service.terminate(dealNonce, railId, uint64(0), address(0));
    }

    function testSweepUnauthorized() public {
        vm.roll(endEpoch + 1);
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        vm.prank(stranger);
        poRepDeal.sweep(stranger);
    }

    function testTerminateClientUnauthorized() public {
        uint64 dealNonce = _findDealNonce(address(service), address(poRepDeal));
        uint256 railId = poRepDeal.RAIL_ID();
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, client));
        vm.prank(client);
        service.terminate(dealNonce, railId, uint64(0), address(0));
    }

    function testClientCannotDirectlyTerminateRail() public {
        uint256 railId = poRepDeal.RAIL_ID();
        vm.expectRevert(TerminationForbidden.selector);
        vm.prank(client);
        payments.terminateRail(railId);
    }
}
