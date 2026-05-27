// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import "./FilecoinWarmStorageService.t.sol";
import {
    ADD_PIECES_FEE,
    LIFECYCLE_RESERVE_TARGET,
    SCHEDULE_PIECE_REMOVALS_FEE,
    TERMINATE_FEE
} from "../src/lib/PriceListUSDFC.sol";

contract OpFeesTest is FilecoinWarmStorageServiceTest {
    uint256 constant PIECE_HEIGHT = 4;
    uint256 constant PIECE_LEAVES = 1 << PIECE_HEIGHT;

    // Creates a dataset with one piece added and the first proving period initialized.
    // Returns (dataSetId, pdpRailId, leafCount, firstDeadline, maxProvingPeriod).
    // On return: pendingOneTimePayments == 0, lifecycleReserveBalance == LIFECYCLE_RESERVE_TARGET - ADD_PIECES_FEE.
    function _createDataSetWithPiece()
        internal
        returns (uint256 dataSetId, uint256 pdpRailId, uint256 leafCount, uint256 firstDeadline, uint256 maxPeriod)
    {
        dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        pdpRailId = viewContract.getDataSet(dataSetId).pdpRailId;
        leafCount = PIECE_LEAVES;

        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, uint8(PIECE_HEIGHT), keccak256("op-fees-piece"));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, 0, pieces, nextClientDataSetId++, FAKE_SIGNATURE, keys, values
        );

        uint256 challengeWindow;
        (maxPeriod, challengeWindow,,) = viewContract.getPDPConfig();
        firstDeadline = block.number + maxPeriod;
        mockPDPVerifier.nextProvingPeriod(
            pdpServiceWithPayments, dataSetId, firstDeadline - challengeWindow / 2, leafCount, ""
        );
    }

    // Rolls past currentDeadline, calls nextProvingPeriod, and returns the new deadline.
    function _advanceProvingPeriod(uint256 dataSetId, uint256 currentDeadline, uint256 maxPeriod, uint256 leafCount)
        internal
        returns (uint256 newDeadline)
    {
        vm.roll(currentDeadline + 1);
        newDeadline = currentDeadline + maxPeriod;
        (, uint256 challengeWindow,,) = viewContract.getPDPConfig();
        mockPDPVerifier.nextProvingPeriod(
            pdpServiceWithPayments, dataSetId, newDeadline - challengeWindow / 2, leafCount, ""
        );
    }

    // -------------------------------------------------------------------------

    function test_addPiecesFee_immediateFlush() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint256 pdpRailId = info.pdpRailId;

        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET);
        assertEq(info.pendingOneTimePayments, 0);

        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, uint8(PIECE_HEIGHT), keccak256("piece0"));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, 0, pieces, nextClientDataSetId++, FAKE_SIGNATURE, keys, values
        );

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "fee flushed immediately in piecesAdded");
        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET - ADD_PIECES_FEE, "reserve decreased by fee");

        FilecoinPayV1.RailView memory rail = payments.getRail(pdpRailId);
        assertEq(rail.lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    function test_scheduledRemovalFee_deferredThenFlushed() public {
        (uint256 dataSetId, uint256 pdpRailId,, uint256 firstDeadline, uint256 maxPeriod) = _createDataSetWithPiece();

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint96 reserveBefore = info.lifecycleReserveBalance;

        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, SCHEDULE_PIECE_REMOVALS_FEE, "fee pending, not yet flushed");
        assertEq(info.lifecycleReserveBalance, reserveBefore, "reserve unchanged before flush");

        // nextProvingPeriod processes the removal and flushes the fee
        _advanceProvingPeriod(dataSetId, firstDeadline, maxPeriod, 0);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "fee flushed");
        assertEq(info.lifecycleReserveBalance, reserveBefore - SCHEDULE_PIECE_REMOVALS_FEE, "reserve decreased by fee");

        FilecoinPayV1.RailView memory rail = payments.getRail(pdpRailId);
        assertEq(rail.lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    function test_multipleRemovalFees_accumulate() public {
        (uint256 dataSetId, uint256 pdpRailId, uint256 leafCount, uint256 firstDeadline, uint256 maxPeriod) =
            _createDataSetWithPiece();

        // Add a second piece
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, uint8(PIECE_HEIGHT), keccak256("piece1"));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, 1, pieces, nextClientDataSetId++, FAKE_SIGNATURE, keys, values
        );
        leafCount += PIECE_LEAVES;

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint96 reserveBefore = info.lifecycleReserveBalance;

        // Schedule two separate removal batches
        uint256[] memory ids0 = new uint256[](1);
        ids0[0] = 0;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, ids0, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        uint256[] memory ids1 = new uint256[](1);
        ids1[0] = 1;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, ids1, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 2 * SCHEDULE_PIECE_REMOVALS_FEE, "both fees accumulated");

        _advanceProvingPeriod(dataSetId, firstDeadline, maxPeriod, 0);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(info.lifecycleReserveBalance, reserveBefore - 2 * SCHEDULE_PIECE_REMOVALS_FEE);

        FilecoinPayV1.RailView memory rail = payments.getRail(pdpRailId);
        assertEq(rail.lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    function test_terminateFee_chargedOnPayerInitiated() public {
        (uint256 dataSetId,,,,) = _createDataSetWithPiece();

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint96 reserveBefore = info.lifecycleReserveBalance;
        assertEq(info.pendingOneTimePayments, 0);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, TERMINATE_FEE, "fee charged on payer termination");
        assertEq(info.lifecycleReserveBalance, reserveBefore, "reserve unchanged until flush");
    }

    function test_terminateFee_notChargedOnSpInitiated() public {
        (uint256 dataSetId,,,,) = _createDataSetWithPiece();

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0);

        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId);

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0, "no fee on SP-initiated termination");
    }

    // TERMINATE_FEE must flush at nextProvingPeriod even when no piece removals are pending.
    function test_terminateFee_flushedWithoutRemovals() public {
        (uint256 dataSetId, uint256 pdpRailId, uint256 leafCount, uint256 firstDeadline, uint256 maxPeriod) =
            _createDataSetWithPiece();

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint96 reserveAfterAdd = info.lifecycleReserveBalance;

        // Payer terminates; no removals scheduled
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, TERMINATE_FEE);

        // Advance proving period with no removals — fee must still flush
        _advanceProvingPeriod(dataSetId, firstDeadline, maxPeriod, leafCount);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "TERMINATE_FEE flushed despite no removals");
        assertEq(info.lifecycleReserveBalance, reserveAfterAdd - TERMINATE_FEE, "reserve decreased by fee");

        FilecoinPayV1.RailView memory rail = payments.getRail(pdpRailId);
        assertEq(rail.lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }
}
