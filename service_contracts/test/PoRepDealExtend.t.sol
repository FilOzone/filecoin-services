// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {PoRepDeal} from "../src/PoRepDeal.sol";
import {PoRepService} from "../src/PoRepService.sol";
import {FVMMinerActor} from "@fvm-solidity/mocks/FVMMinerActor.sol";
import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {PieceChange, SectorChanges, SectorContentChangedParams} from "@fvm-solidity/FVMSectorContentChanged.sol";
import {SectorStatus} from "@fvm-solidity/FVMSector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

IERC20 constant NATIVE_TOKEN = IERC20(address(0));

contract PoRepDealExtendTest is MockFVMTest {
    uint64 constant MINER_ID = 42;
    uint64 constant SECTOR_ID = 1;
    int64 constant DEADLINE = 3;
    int64 constant PARTITION = 0;
    uint64 constant DAYS_OF_EPOCHS = uint64(1 days / 30);
    uint64 constant DURATION = 180 * DAYS_OF_EPOCHS;
    uint64 constant EXTENSION = 42 * DAYS_OF_EPOCHS;
    uint64 constant SIZE = 32 * 1024 * 1024 * 1024;
    uint256 constant RATE = 1;

    bytes constant COMMP_CID_1 = hex"0181e203922020cdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b38";
    bytes32 constant COMMP_DIGEST_1 = 0xcdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b38;

    FilecoinPayV1 payments;
    PoRepService service;
    FVMMinerActor miner;
    address client;
    PoRepDeal poRepDeal;
    uint64 endEpoch;

    function setUp() public override {
        super.setUp();
        client = makeAddr("client");
        vm.deal(client, 1000 ether);

        payments = new FilecoinPayV1();
        service = new PoRepService(payments);
        miner = mockMiner(MINER_ID);

        uint256 maxRate = uint256(SIZE) * RATE;
        // maxLockup must cover the initial DURATION lockup plus the EXTENSION re-lock
        uint256 maxLockup = maxRate * (DURATION + EXTENSION);
        vm.prank(client);
        payments.setOperatorApproval(NATIVE_TOKEN, address(service), true, maxRate, maxLockup, DURATION + EXTENSION);

        // deposit covers initial lockup (DURATION) plus funds needed to re-lock after settling EXTENSION epochs
        uint256 deposit = uint256(SIZE) * RATE * (DURATION + EXTENSION);
        vm.prank(client);
        payments.deposit{value: deposit}(NATIVE_TOKEN, client, deposit);

        endEpoch = uint64(block.number) + DURATION;
        poRepDeal = PoRepDeal(service.createDeal(client, MINER_ID, NATIVE_TOKEN, RATE, endEpoch, 0));

        bytes32[] memory cidHashes = new bytes32[](1);
        cidHashes[0] = COMMP_DIGEST_1;
        vm.prank(client);
        poRepDeal.addPieces(cidHashes);

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
        revert("could not find poRepDeal nonce");
    }

    function testExtend() public {
        vm.roll(vm.getBlockNumber() + EXTENSION);

        vm.prank(client);
        poRepDeal.extend(EXTENSION);

        (, uint64 newEndEpoch,,) = poRepDeal.info();
        assertEq(newEndEpoch, endEpoch + EXTENSION);

        // poRepDeal is still live past the original end epoch
        vm.roll(endEpoch + 1);
        vm.expectRevert();
        poRepDeal.sweep(address(this));
    }

    function testExtendRevertsAfterExpiry() public {
        vm.roll(endEpoch);
        vm.expectRevert();
        vm.prank(client);
        poRepDeal.extend(EXTENSION);
    }

    function testExtendRevertsWhenFaulted() public {
        vm.roll(vm.getBlockNumber() + DAYS_OF_EPOCHS);
        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Faulty);
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, address(this));

        vm.expectRevert();
        vm.prank(client);
        poRepDeal.extend(EXTENSION);
    }

    function testExtendRevertsIfNotClient() public {
        vm.expectRevert();
        poRepDeal.extend(EXTENSION);
    }
}
