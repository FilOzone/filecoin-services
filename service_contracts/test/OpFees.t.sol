// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

import {FilecoinWarmStorageServiceTest} from "./FilecoinWarmStorageService.t.sol";
import {Cids} from "@pdp/Cids.sol";
import {FilecoinWarmStorageService, MAX_ADD_PIECES_EXTRA_DATA_SIZE} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {
    ADD_PIECES_BASE_FEE,
    ADD_PIECES_PER_PIECE_FEE,
    CREATE_DATA_SET_FEE,
    DATASET_FEE_PER_MONTH,
    LIFECYCLE_RESERVE_TARGET,
    REPLENISH_THRESHOLD,
    SCHEDULE_PIECE_REMOVALS_FEE,
    TERMINATE_FEE
} from "../src/lib/PriceListUSDFC.sol";

contract OpFeesTest is FilecoinWarmStorageServiceTest {
    uint256 constant PIECE_HEIGHT = 4;
    uint256 constant PIECE_LEAVES = 1 << PIECE_HEIGHT;
    // Minimum N such that pending = CREATE_DATA_SET_FEE + ADD_PIECES_BASE_FEE + N * ADD_PIECES_PER_PIECE_FEE
    // satisfies LIFECYCLE_RESERVE_TARGET < pending + REPLENISH_THRESHOLD, i.e. triggers replenishment.
    uint256 constant REPLENISH_BATCH = (
        LIFECYCLE_RESERVE_TARGET - REPLENISH_THRESHOLD - CREATE_DATA_SET_FEE - ADD_PIECES_BASE_FEE
    ) / ADD_PIECES_PER_PIECE_FEE + 1;
    // ABI encoding of abi.encode(nonce, allKeys, allValues, sig) with N empty-metadata pieces:
    //   overhead  = 4*32 (nonce + 3 dynamic offsets)
    //             + 2*32 (outer array lengths for allKeys and allValues)
    //             + 32   (signature length word)
    //             + ceil(FAKE_SIGNATURE.length / 32) * 32 (padded signature data)
    //   per piece = 4*32 (offset + empty array for each of allKeys[i] and allValues[i])
    uint256 constant FAKE_SIGNATURE_LEN = 65; // r(32) + s(32) + v(1)
    // Round up to next 32-byte boundary without divide-then-multiply.
    uint256 constant FAKE_SIGNATURE_PADDED = FAKE_SIGNATURE_LEN + (32 - FAKE_SIGNATURE_LEN % 32) % 32;
    uint256 constant ADD_PIECES_EXTRA_DATA_PER_PIECE = 4 * 32;
    uint256 constant ADD_PIECES_EXTRA_DATA_OVERHEAD = 4 * 32 + 2 * 32 + 32 + FAKE_SIGNATURE_PADDED;
    uint256 constant BATCH_CAP =
        (MAX_ADD_PIECES_EXTRA_DATA_SIZE - ADD_PIECES_EXTRA_DATA_OVERHEAD) / ADD_PIECES_EXTRA_DATA_PER_PIECE;
    // Fee drained by each full-BATCH_CAP addPieces call (CREATE_DATA_SET_FEE only appears in the first call).
    uint256 constant PER_CALL_DRAIN = ADD_PIECES_BASE_FEE + BATCH_CAP * ADD_PIECES_PER_PIECE_FEE;
    // Full-BATCH_CAP calls that flush safely before the reserve crosses the replenishment threshold.
    uint256 constant NUM_SAFE_CALLS =
        (LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - REPLENISH_THRESHOLD) / PER_CALL_DRAIN;

    function _buildBatch(uint256 n) internal pure returns (Cids.Cid[] memory pieces) {
        pieces = new Cids.Cid[](n);
        for (uint256 i = 0; i < n; i++) {
            pieces[i] = Cids.CommPv2FromDigest(0, uint8(PIECE_HEIGHT), keccak256(abi.encodePacked(i)));
        }
    }

    // Creates a dataset with one piece added and the first proving period initialized.
    // Returns (dataSetId, pdpRailId, leafCount, firstDeadline, maxProvingPeriod).
    // On return: pendingOneTimePayments == 0, lifecycleReserveBalance == LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - ADD_PIECES_BASE_FEE - ADD_PIECES_PER_PIECE_FEE.
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
        assertEq(info.pendingOneTimePayments, CREATE_DATA_SET_FEE, "create dataset fee pending");

        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, uint8(PIECE_HEIGHT), keccak256("piece0"));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, 0, pieces, nextClientDataSetId++, FAKE_SIGNATURE, keys, values
        );

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "fees flushed immediately in piecesAdded");
        assertEq(
            info.lifecycleReserveBalance,
            LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE - ADD_PIECES_BASE_FEE - ADD_PIECES_PER_PIECE_FEE,
            "reserve decreased by both fees"
        );

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

    function test_terminateFee_chargedOnConsentCase() public {
        (uint256 dataSetId, uint256 pdpRailId,,,) = _createDataSetWithPiece();

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint96 reserveBefore = info.lifecycleReserveBalance;
        assertEq(info.pendingOneTimePayments, 0);

        // Consent case: payer signs off-chain, SP submits with signature in extraData
        makeSignaturePass(client);
        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId, abi.encode(FAKE_SIGNATURE));

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "fee flushed at termination");
        assertEq(info.lifecycleReserveBalance, reserveBefore - TERMINATE_FEE, "reserve decreased by fee");
        assertEq(payments.getRail(pdpRailId).lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    function test_terminateFee_notChargedOnPayerDirectCall() public {
        (uint256 dataSetId,,,,) = _createDataSetWithPiece();

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0, "no fee on payer direct termination");
    }

    function test_terminateFee_notChargedOnSpInitiated() public {
        (uint256 dataSetId,,,,) = _createDataSetWithPiece();

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0);

        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId);

        assertEq(viewContract.getDataSet(dataSetId).pendingOneTimePayments, 0, "no fee on SP-initiated termination");
    }

    function test_addPiecesFee_largeBatch_triggersReplenishment() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");

        uint256 added = 0;
        for (uint256 i = 0; i < NUM_SAFE_CALLS; i++) {
            makeSignaturePass(client);
            mockPDPVerifier.addPieces(
                pdpServiceWithPayments,
                dataSetId,
                added,
                _buildBatch(BATCH_CAP),
                nextClientDataSetId++,
                FAKE_SIGNATURE,
                new string[](0),
                new string[](0)
            );
            added += BATCH_CAP;
        }
        // One more call crosses the threshold and triggers replenishment.
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments,
            dataSetId,
            added,
            _buildBatch(BATCH_CAP),
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "fees flushed");
        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET, "reserve replenished to target");

        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        assertEq(rail.lockupFixed, LIFECYCLE_RESERVE_TARGET, "lockupFixed reflects replenishment");
    }

    function test_addPiecesFee_largeBatch_revertsInsufficientFunds() public {
        // Client has just enough for safe flushes (lifecycle reserve + 2× dataset fee covers
        // the rate-based lockup from adding pieces) but not enough for replenishment
        // (which needs ≈ LIFECYCLE_RESERVE_TARGET - REPLENISH_THRESHOLD ≈ 0.095 USDFC more).
        address minClient = makeAddr("minClient");
        uint256 minAmount = LIFECYCLE_RESERVE_TARGET + 2 * DATASET_FEE_PER_MONTH;
        require(mockUSDFC.transfer(minClient, minAmount));
        vm.startPrank(minClient);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), minAmount);
        payments.deposit(mockUSDFC, minClient, minAmount);
        vm.stopPrank();

        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        bytes memory encodedData = abi.encode(minClient, nextClientDataSetId++, emptyKeys, emptyValues, FAKE_SIGNATURE);
        makeSignaturePass(minClient);
        vm.prank(sp1);
        uint256 dataSetId = mockPDPVerifier.createDataSet(pdpServiceWithPayments, encodedData);

        uint256 added = 0;
        for (uint256 i = 0; i < NUM_SAFE_CALLS; i++) {
            makeSignaturePass(minClient);
            mockPDPVerifier.addPieces(
                pdpServiceWithPayments,
                dataSetId,
                added,
                _buildBatch(BATCH_CAP),
                nextClientDataSetId++,
                FAKE_SIGNATURE,
                new string[](0),
                new string[](0)
            );
            added += BATCH_CAP;
        }

        makeSignaturePass(minClient);
        vm.expectRevert("invariant failure: insufficient funds to cover lockup after function execution");
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments,
            dataSetId,
            added,
            _buildBatch(BATCH_CAP),
            nextClientDataSetId++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );
    }

    // TERMINATE_FEE must flush at termination time even when no piece removals are pending.
    function test_terminateFee_flushedWithoutRemovals() public {
        (uint256 dataSetId, uint256 pdpRailId,,,) = _createDataSetWithPiece();

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        uint96 reserveAfterAdd = info.lifecycleReserveBalance;

        // Consent case: payer signs off-chain, SP submits; no removals scheduled
        makeSignaturePass(client);
        vm.prank(sp1);
        pdpServiceWithPayments.terminateService(dataSetId, abi.encode(FAKE_SIGNATURE));

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "TERMINATE_FEE flushed at termination");
        assertEq(info.lifecycleReserveBalance, reserveAfterAdd - TERMINATE_FEE, "reserve decreased by fee");

        FilecoinPayV1.RailView memory rail = payments.getRail(pdpRailId);
        assertEq(rail.lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }

    // CREATE_DATA_SET_FEE must be collected even when the dataset is terminated before any proving.
    function test_createTerminate_createFeeFlushes() public {
        uint256 dataSetId = createDataSetForServiceProviderTest(sp1, client, "");
        uint256 pdpRailId = viewContract.getDataSet(dataSetId).pdpRailId;

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, CREATE_DATA_SET_FEE, "create fee pending before termination");
        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);

        info = viewContract.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "create fee flushed at termination");
        assertEq(
            info.lifecycleReserveBalance,
            LIFECYCLE_RESERVE_TARGET - CREATE_DATA_SET_FEE,
            "reserve decreased by create fee"
        );
        assertEq(payments.getRail(pdpRailId).lockupFixed, info.lifecycleReserveBalance, "lockupFixed mirrors reserve");
    }
}
