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

contract PoRepDealSectorStatusTest is MockFVMTest {
    uint64 constant MINER_ID = 42;
    uint64 constant SECTOR_ID = 1;
    int64 constant DEADLINE = 3;
    int64 constant PARTITION = 0;
    uint64 constant MIN_COMMITMENT_EPOCHS = uint64(180 days / 30);
    uint64 constant SIZE_32GB = 32 * 1024 * 1024 * 1024;
    uint256 constant RATE = 1;

    bytes constant COMMP_CID_1 = hex"0155912024cdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b367a49ce18";
    bytes constant COMMP_DIGEST_1 = hex"cdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b367a49ce18";

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

        uint256 maxRate = uint256(SIZE_32GB) * RATE;
        uint256 maxLockup = maxRate * MIN_COMMITMENT_EPOCHS;
        vm.prank(client);
        payments.setOperatorApproval(
            IERC20(address(0)), address(service), true, maxRate, maxLockup, MIN_COMMITMENT_EPOCHS
        );

        uint256 required = uint256(SIZE_32GB) * RATE * MIN_COMMITMENT_EPOCHS;
        vm.prank(client);
        payments.deposit{value: required}(NATIVE_TOKEN, client, required);

        endEpoch = uint64(block.number) + MIN_COMMITMENT_EPOCHS;
        poRepDeal = PoRepDeal(service.createDeal(client, MINER_ID, NATIVE_TOKEN, RATE, endEpoch, 0));

        bytes32[] memory cidHashes = new bytes32[](1);
        cidHashes[0] = keccak256(COMMP_DIGEST_1);
        vm.prank(client);
        poRepDeal.addPieces(cidHashes);

        // Mock sector as Active with location before activation
        miner.mockSector(SECTOR_ID, SectorStatus.Active, DEADLINE, PARTITION, endEpoch);

        uint64 nonce = _findDealNonce(address(service), address(poRepDeal));
        PieceChange[] memory pieces = new PieceChange[](1);
        pieces[0] = PieceChange({data: COMMP_CID_1, size: SIZE_32GB, payload: abi.encodePacked(nonce)});
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

    function testSectorExpiredAfterActivation() public {
        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Dead);
        poRepDeal.sectorExpired(SECTOR_ID, RECIPIENT, 0);
        miner.mockSector(SECTOR_ID, SectorStatus.Active, DEADLINE, PARTITION, endEpoch);
        poRepDeal.sectorActive(SECTOR_ID, DEADLINE, PARTITION);
    }

    function testSectorFaultyAfterActivation() public {
        miner.mockSectorStatus(SECTOR_ID, SectorStatus.Faulty);
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT, 0);
        miner.mockSector(SECTOR_ID, SectorStatus.Active, DEADLINE, PARTITION, endEpoch);
        poRepDeal.sectorActive(SECTOR_ID, DEADLINE, PARTITION);
    }

    function testSectorExpiredRevertsIfStillActive() public {
        vm.expectRevert();
        poRepDeal.sectorExpired(SECTOR_ID, RECIPIENT, 0);
    }

    function testSectorFaultyRevertsIfStillActive() public {
        vm.expectRevert();
        poRepDeal.sectorFaulty(SECTOR_ID, DEADLINE, PARTITION, RECIPIENT, 0);
    }
}
