// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {PoRepDeal} from "../src/PoRepDeal.sol";
import {PoRepService} from "../src/PoRepService.sol";
import {FVMMinerActor} from "@fvm-solidity/mocks/FVMMinerActor.sol";
import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {PieceChange, SectorChanges, SectorContentChangedParams} from "@fvm-solidity/FVMSectorContentChanged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

IERC20 constant NATIVE_TOKEN = IERC20(address(0));

contract PoRepDealActivationTest is MockFVMTest {
    uint64 constant MINER_ID = 42;
    // 180 days at 30 seconds per epoch
    uint64 constant MIN_COMMITMENT_EPOCHS = uint64(180 days / 30);
    // 32 GB and 64 GB padded piece sizes
    uint64 constant SIZE_32GB = 32 * 1024 * 1024 * 1024;
    uint64 constant SIZE_64GB = 64 * 1024 * 1024 * 1024;
    // 1 attoFIL per byte per epoch
    uint256 constant RATE = 1;

    // CommP CIDs from the FVMSectorContentChanged test suite; prefix stripped to get the 36-byte digest
    bytes constant COMMP_CID_1 = hex"0181e203922020cdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b36";
    bytes32 constant COMMP_DIGEST_1 = 0xcdf33e17483f8397390b0a963ded6e34a18f2fce6daa671716057f905f645b36;
    FilecoinPayV1 payments;
    PoRepService service;
    FVMMinerActor miner;
    address client;

    function setUp() public override {
        super.setUp();
        client = makeAddr("client");
        vm.deal(client, 1000 ether);

        payments = new FilecoinPayV1();
        service = new PoRepService(payments);
        miner = mockMiner(MINER_ID);

        // Approve the service as rail operator for the client on native token.
        // Allowances are sized for a single 64 GB activation over the minimum commitment duration.
        uint256 maxRate = uint256(SIZE_64GB) * RATE;
        uint256 maxLockup = maxRate * MIN_COMMITMENT_EPOCHS;
        vm.prank(client);
        payments.setOperatorApproval(
            IERC20(address(0)), address(service), true, maxRate, maxLockup, MIN_COMMITMENT_EPOCHS
        );
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Scan CREATE nonces to find the one that produced `created` from `deployer`.
    function _findDealNonce(address deployer, address created) internal pure returns (uint64) {
        for (uint64 n = 1; n <= 20; n++) {
            if (vm.computeCreateAddress(deployer, n) == created) return n;
        }
        revert("could not find deal nonce");
    }

    function _createDeal() internal returns (PoRepDeal deal, uint64 endEpoch) {
        endEpoch = uint64(block.number) + MIN_COMMITMENT_EPOCHS;
        deal = PoRepDeal(service.createDeal(client, MINER_ID, NATIVE_TOKEN, RATE, endEpoch, 0));
    }

    function _authorize(PoRepDeal deal, bytes32 digest) internal {
        bytes32[] memory cidHashes = new bytes32[](1);
        cidHashes[0] = digest;
        vm.prank(client);
        deal.addPieces(cidHashes);
    }

    function _activate(PoRepDeal deal, bytes memory cid, uint64 paddedSize, uint64 sectorId, int64 minEpoch) internal {
        uint64 nonce = _findDealNonce(address(service), address(deal));

        PieceChange[] memory pieces = new PieceChange[](1);
        // payload is read back via CalldataUtils.toUint64(), which expects exactly 8 raw big-endian bytes
        pieces[0] = PieceChange({data: cid, size: paddedSize, payload: abi.encodePacked(nonce)});
        SectorChanges[] memory sectorChanges = new SectorChanges[](1);
        sectorChanges[0] = SectorChanges({sector: sectorId, minimumCommitmentEpoch: minEpoch, added: pieces});
        miner.callSectorContentChanged(address(service), SectorContentChangedParams({sectors: sectorChanges}));
    }

    function _deposit(uint256 amount) internal {
        vm.prank(client);
        payments.deposit{value: amount}(NATIVE_TOKEN, client, amount);
    }

    /// The same piece (same CID hash) cannot be activated twice in the same deal.
    function testCannotActivatePieceTwice() public {
        uint256 required = uint256(SIZE_32GB) * RATE * MIN_COMMITMENT_EPOCHS;
        _deposit(required);

        (PoRepDeal deal, uint64 endEpoch) = _createDeal();
        _authorize(deal, COMMP_DIGEST_1);

        int64 minEpoch = int64(endEpoch);

        // First activation succeeds.
        _activate(deal, COMMP_CID_1, SIZE_32GB, 1, minEpoch);

        // Second activation of the same piece (even into a different sector) must revert because
        // PoRepDeal.pieceAdded requires PieceStatus.AUTHORIZED but it is now ACTIVE.
        uint64 nonce = _findDealNonce(address(service), address(deal));
        PieceChange[] memory pieces = new PieceChange[](1);
        pieces[0] = PieceChange({data: COMMP_CID_1, size: SIZE_32GB, payload: abi.encodePacked(nonce)});
        SectorChanges[] memory sectorChanges = new SectorChanges[](1);
        sectorChanges[0] = SectorChanges({sector: 2, minimumCommitmentEpoch: minEpoch, added: pieces});

        vm.expectRevert();
        miner.callSectorContentChanged(address(service), SectorContentChangedParams({sectors: sectorChanges}));
    }

    /// A client holding exactly size × rate × duration can successfully lock up and settle a 32 GB deal.
    function testExactBalanceSufficient() public {
        uint256 required = uint256(SIZE_32GB) * RATE * MIN_COMMITMENT_EPOCHS;
        _deposit(required);

        (PoRepDeal deal, uint64 endEpoch) = _createDeal();
        _authorize(deal, COMMP_DIGEST_1);
        _activate(deal, COMMP_CID_1, SIZE_32GB, 1, int64(endEpoch));

        deal.amortize();
        vm.roll(endEpoch);
        deal.amortize();

        vm.roll(endEpoch + 1);
        deal.amortize();
    }
}
