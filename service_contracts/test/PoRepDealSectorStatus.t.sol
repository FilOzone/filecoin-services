// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {PoRepDeal} from "../src/PoRepDeal.sol";
import {PoRepPayee, PoRepService, Unauthorized} from "../src/PoRepService.sol";
import {FVMMinerActor} from "@fvm-solidity/mocks/FVMMinerActor.sol";
import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {PieceChange, SectorChanges, SectorContentChangedParams} from "@fvm-solidity/FVMSectorContentChanged.sol";
import {SectorStatus} from "@fvm-solidity/FVMSector.sol";
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

    bytes constant COMMP_CID_1 = hex"0155912024cdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b367a49ce18";
    bytes constant COMMP_DIGEST_1 = hex"cdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b367a49ce18";

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
        poRepDeal = PoRepDeal(service.createDeal(client, MINER_ID, NATIVE_TOKEN, RATE, endEpoch, INSURANCE_BIPS));
        payee = PoRepPayee(service.getReceiverAddress(MINER_ID));

        bytes32[] memory cidHashes = new bytes32[](1);
        cidHashes[0] = keccak256(COMMP_DIGEST_1);
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

    address constant RECIPIENT = address(0x4141414141414141414141414141414141414141);
    address constant SWEEPER = address(0x4242424242424242424242424242424242424242);

    // tests the case where nobody flagged the fault but someone did flag the expiry
    function testSectorExpiredAfterActivation() public {
        vm.roll(vm.getBlockNumber() + FAULT_MAX_AGE);

        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Dead);
        poRepDeal.sectorExpired(SECTOR_ID, RECIPIENT);

        assertEq(RECIPIENT.balance, FAULT_MAX_AGE * SIZE * INSURANCE_BIPS * 199 / 200);

        (uint256 paid,,,) = payments.accounts(NATIVE_TOKEN, address(payee));
        assertEq(paid, FAULT_MAX_AGE * SIZE * RATE * 199 / 200 * (10000 - INSURANCE_BIPS) / 10000);
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
        poRepDeal.sectorExpired(SECTOR_ID, RECIPIENT);

        assertEq(RECIPIENT.balance, balanceBefore * 2);

        (uint256 paid,,,) = payments.accounts(NATIVE_TOKEN, address(payee));
        assertEq(paid, 3 * DAYS_OF_EPOCHS * SIZE * RATE * 199 / 200 * (10000 - INSURANCE_BIPS) / 10000);
    }

    function testSectorExpiredRevertsIfStillActive() public {
        vm.expectRevert();
        poRepDeal.sectorExpired(SECTOR_ID, RECIPIENT);
    }

    function testSectorFaultyRevertsIfStillActive() public {
        vm.expectRevert();
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT);
    }
}
