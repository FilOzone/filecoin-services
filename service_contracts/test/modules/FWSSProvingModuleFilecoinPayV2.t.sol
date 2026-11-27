// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Cids} from "@pdp/Cids.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {IExtsload} from "@filecoin-pay-v2/interfaces/IExtsload.sol";
import {RailId, RailIdLibrary, StreamState} from "@filecoin-pay-v2/lib/RailId.sol";
import {CHALLENGES_PER_PROOF} from "../../src/lib/FWSSConstants.sol";
import {RailRateUpdated} from "../../src/lib/LibRails.sol";
import {
    ADD_PIECES_BASE_FEE,
    ADD_PIECES_PER_PIECE_FEE,
    CREATE_DATA_SET_FEE,
    DEFAULT_LOCKUP_PERIOD,
    SCHEDULE_PIECE_REMOVALS_FEE,
    STORAGE_PRICE_PER_TIB_PER_MONTH,
    TERMINATE_FEE
} from "../../src/lib/PriceListUSDFC.sol";
import {PAY_VERSION_FILECOIN_PAY_V2, StorageTerms} from "../../src/lib/StorageTerms.sol";
import {FWSSProvingModule} from "../../src/modules/FWSSProvingModule.sol";
import {FWSSStorageTermsModule} from "../../src/modules/FWSSStorageTermsModule.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";

contract FWSSProvingModuleFilecoinPayV2Test is FilecoinWarmStorageServiceFixture {
    uint8 private constant PIECE_HEIGHT = 30;
    uint256 private constant FUNDED = 10e18;

    address private payer;
    uint256 private dataSetId;
    uint256 private pdpRailId;
    uint256 private activationEpoch;
    uint256 private maxProvingPeriod;
    uint256 private challengeWindow;
    uint256 private leavesPerPiece;
    uint256 private piecesAdded;
    uint256 private addNonce = 1;

    function setUp() public override {
        super.setUp();
        payer = makeAddr("v2Payer");
        _fundV2Payer(payer, FUNDED);
        (maxProvingPeriod, challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        leavesPerPiece = Cids.leafCount(0, PIECE_HEIGHT);

        bytes32 termsId = FWSSStorageTermsModule(address(pdpServiceWithPayments))
            .registerStorageTerms(
                StorageTerms({
                token: address(mockUSDFC),
                tokenDecimals: 18,
                salt: bytes32(0),
                pricePerTiBPerMonth: uint96(STORAGE_PRICE_PER_TIB_PER_MONTH),
                payVersion: PAY_VERSION_FILECOIN_PAY_V2
            })
            );
        makeSignaturePass(payer);
        vm.prank(serviceProvider);
        dataSetId = mockPDPVerifier.createDataSet(
            PDPListener(address(pdpServiceWithPayments)),
            abi.encode(payer, uint256(0), new string[](0), new string[](0), FAKE_SIGNATURE, termsId)
        );
        pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        _addPieces(4);
    }

    function _addPieces(uint256 count) private {
        Cids.Cid[] memory pieceData = new Cids.Cid[](count);
        for (uint256 i = 0; i < count; i++) {
            pieceData[i] = Cids.CommPv2FromDigest(0, PIECE_HEIGHT, keccak256(abi.encode(dataSetId, piecesAdded + i)));
        }
        makeSignaturePass(payer);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            piecesAdded,
            pieceData,
            addNonce++,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );
        piecesAdded += count;
    }

    /// @dev nextProvingPeriod reads the leaf count after the removals from its argument, as PDPVerifier passes it.
    function _scheduleRemoval() private {
        makeSignaturePass(payer);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, new uint256[](1), address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );
    }

    function _deadline(uint256 period) private view returns (uint256) {
        return activationEpoch + (period + 1) * maxProvingPeriod;
    }

    function _startProving() private {
        activationEpoch = vm.getBlockNumber();
        _nextProvingPeriod(dataSetId, _deadline(0) - challengeWindow / 2, 4 * leavesPerPiece);
    }

    function _proveFirstPeriod() private {
        vm.roll(_deadline(0) - challengeWindow / 2);
        vm.prank(address(mockPDPVerifier));
        FWSSProvingModule(address(pdpServiceWithPayments))
            .possessionProven(dataSetId, 4 * leavesPerPiece, 12345, CHALLENGES_PER_PROOF);
    }

    function _rail() private view returns (StreamState memory) {
        return RailIdLibrary.getRail(IExtsload(address(filecoinPayV2)), RailId.wrap(pdpRailId));
    }

    function _balance(address account) private view returns (uint256) {
        return filecoinPayV2.balanceOf(account, uint256(uint160(address(mockUSDFC))));
    }

    function _feesPaid() private pure returns (uint256) {
        return CREATE_DATA_SET_FEE + ADD_PIECES_BASE_FEE + 4 * ADD_PIECES_PER_PIECE_FEE + SCHEDULE_PIECE_REMOVALS_FEE;
    }

    function testRemovalLowersRateAndUnlocksAfterProvenPeriod() public {
        uint256 createdAt = vm.getBlockNumber();
        uint256 oldRate = _rateForLeaves(4 * leavesPerPiece);
        uint256 newRate = _rateForLeaves(3 * leavesPerPiece);
        _startProving();
        _proveFirstPeriod();
        _scheduleRemoval();

        vm.expectEmit(true, false, false, true, address(pdpServiceWithPayments));
        emit RailRateUpdated(dataSetId, pdpRailId, newRate);
        _nextProvingPeriod(dataSetId, _deadline(1) - challengeWindow / 2, 3 * leavesPerPiece);

        // The settleRail callback pays the proven period at the old rate before the rate drops
        uint256 earned = (vm.getBlockNumber() - createdAt) * oldRate;
        assertEq(_rail().incomingRate, newRate);
        assertEq(_rail().available, TERMINATE_FEE + newRate * DEFAULT_LOCKUP_PERIOD, "lock follows the lower rate");
        assertEq(_balance(serviceProvider), _feesPaid() + earned, "payee paid for the proven period");
        assertEq(
            _balance(payer),
            FUNDED - TERMINATE_FEE - newRate * DEFAULT_LOCKUP_PERIOD - _feesPaid() - earned,
            "payer gets the lock decrease back"
        );
    }

    function testRemovalAfterFaultedPeriodRefundsAndHoldsOpenPeriod() public {
        uint256 createdAt = vm.getBlockNumber();
        uint256 oldRate = _rateForLeaves(4 * leavesPerPiece);
        uint256 newRate = _rateForLeaves(3 * leavesPerPiece);
        _startProving();
        vm.roll(_deadline(0) + 10);
        _scheduleRemoval();

        // nextProvingPeriod has already moved the deadline when setRate calls back, and the callback still
        // refunds the faulted period and holds the open one
        uint256 refund = (_deadline(0) - createdAt) * oldRate;
        uint256 held = 10 * oldRate;
        vm.expectEmit(true, true, false, true, address(pdpServiceWithPayments));
        emit FWSSProvingModule.PDPPaymentSettled(dataSetId, pdpRailId, createdAt, vm.getBlockNumber(), 0, refund, held);
        _nextProvingPeriod(dataSetId, _deadline(1) - challengeWindow / 2, 3 * leavesPerPiece);

        assertEq(_rail().incomingRate, newRate);
        assertEq(_rail().available, TERMINATE_FEE + newRate * DEFAULT_LOCKUP_PERIOD + held);
        assertEq(_balance(serviceProvider), _feesPaid(), "faulted period pays nothing");
        assertEq(_balance(payer), FUNDED - TERMINATE_FEE - newRate * DEFAULT_LOCKUP_PERIOD - _feesPaid() - held);
    }

    function testRemovalBeforeProvingLowersRateAtActivation() public {
        uint256 newRate = _rateForLeaves(3 * leavesPerPiece);
        vm.roll(vm.getBlockNumber() + 50);
        _scheduleRemoval();

        activationEpoch = vm.getBlockNumber();
        _nextProvingPeriod(dataSetId, _deadline(0) - challengeWindow / 2, 3 * leavesPerPiece);

        // Epochs before activation are refunded
        assertEq(_rail().incomingRate, newRate);
        assertEq(_rail().available, TERMINATE_FEE + newRate * DEFAULT_LOCKUP_PERIOD);
        assertEq(_balance(serviceProvider), _feesPaid());
        assertEq(_balance(payer), FUNDED - TERMINATE_FEE - newRate * DEFAULT_LOCKUP_PERIOD - _feesPaid());
    }

    function testRemovingEveryPieceDropsRateAndLockToZero() public {
        _startProving();
        _proveFirstPeriod();
        _scheduleRemoval();

        _nextProvingPeriod(dataSetId, 0, 0);

        assertEq(_rail().incomingRate, 0);
        assertEq(_rail().available, TERMINATE_FEE, "only the termination fee stays locked");
    }

    function testRemovalAlreadyRepricedByAddSkipsSetRateForPayerBehind() public {
        uint256 rate = _rateForLeaves(4 * leavesPerPiece);
        _startProving();
        _proveFirstPeriod();
        _scheduleRemoval();

        // processPieceDeletions drops the piece without a callback, and the next add sets the rate for the new size
        mockPDPVerifier.setDataSetLeafCount(dataSetId, 3 * leavesPerPiece);
        _addPieces(1);
        assertEq(_rail().incomingRate, rate);
        vm.startPrank(payer);
        filecoinPayV2.withdraw(address(mockUSDFC), _balance(payer));
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 2);

        vm.expectCall(address(filecoinPayV2), abi.encodeWithSignature("executeScript(uint256,bytes)"), 0);
        _nextProvingPeriod(dataSetId, _deadline(1) - challengeWindow / 2, 4 * leavesPerPiece);

        assertEq(_rail().incomingRate, rate);
    }

    function testNoRemovalLeavesRateAlone() public {
        uint256 rate = _rateForLeaves(4 * leavesPerPiece);
        _startProving();
        _proveFirstPeriod();

        vm.expectCall(address(filecoinPayV2), abi.encodeWithSignature("executeScript(uint256,bytes)"), 0);
        _nextProvingPeriod(dataSetId, _deadline(1) - challengeWindow / 2, 4 * leavesPerPiece);

        assertEq(_rail().incomingRate, rate);
        assertEq(_rail().available, TERMINATE_FEE + rate * DEFAULT_LOCKUP_PERIOD);
    }
}
