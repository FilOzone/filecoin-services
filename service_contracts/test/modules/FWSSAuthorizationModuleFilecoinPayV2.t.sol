// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Cids} from "@pdp/Cids.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {FilecoinPayV2} from "@filecoin-pay-v2/FilecoinPayV2.sol";
import {IExtsload} from "@filecoin-pay-v2/interfaces/IExtsload.sol";
import {CREATE_RAIL} from "@filecoin-pay-v2/lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, StreamState} from "@filecoin-pay-v2/lib/RailId.sol";
import {DataSetInfoView} from "../../src/lib/FWSSViewTypes.sol";
import {LibRailsV2} from "../../src/lib/LibRailsV2.sol";
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
import {FWSSStorageTermsModule} from "../../src/modules/FWSSStorageTermsModule.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";
import {CreationSixDecimalToken} from "../StorageTermsCreation.t.sol";

contract FWSSAuthorizationModuleFilecoinPayV2Test is FilecoinWarmStorageServiceFixture {
    uint8 private constant PIECE_HEIGHT = 30;

    address private payer;
    bytes32 private v2Terms;
    uint256 private addNonce = 1;
    uint256 private piecesAdded;

    function setUp() public override {
        super.setUp();
        payer = makeAddr("v2Payer");
        v2Terms = _registerV2Terms(address(mockUSDFC), 18, uint96(STORAGE_PRICE_PER_TIB_PER_MONTH));
    }

    function _registerV2Terms(address token, uint8 tokenDecimals, uint96 price) private returns (bytes32) {
        return FWSSStorageTermsModule(address(pdpServiceWithPayments))
            .registerStorageTerms(
                StorageTerms({
                token: token,
                tokenDecimals: tokenDecimals,
                salt: bytes32(0),
                pricePerTiBPerMonth: price,
                payVersion: PAY_VERSION_FILECOIN_PAY_V2
            })
            );
    }

    function _create(bytes32 storageTermsId, bool cdn) private returns (uint256) {
        string[] memory keys = new string[](cdn ? 1 : 0);
        string[] memory values = new string[](cdn ? 1 : 0);
        if (cdn) {
            keys[0] = "withCDN";
            values[0] = "true";
        }
        makeSignaturePass(payer);
        vm.prank(serviceProvider);
        return mockPDPVerifier.createDataSet(
            PDPListener(address(pdpServiceWithPayments)),
            abi.encode(payer, uint256(0), keys, values, FAKE_SIGNATURE, storageTermsId)
        );
    }

    function _scheduleRemovals(uint256 dataSetId, uint256 count) private {
        uint256[] memory pieceIds = new uint256[](1);
        for (uint256 i = 0; i < count; i++) {
            makeSignaturePass(payer);
            mockPDPVerifier.piecesScheduledRemove(
                dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
            );
        }
    }

    function _addPieces(uint256 dataSetId, uint256 count, uint8 height) private {
        Cids.Cid[] memory pieceData = new Cids.Cid[](count);
        for (uint256 i = 0; i < count; i++) {
            pieceData[i] = Cids.CommPv2FromDigest(0, height, keccak256(abi.encode(dataSetId, piecesAdded + i)));
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

    function _addFee(uint256 count) private pure returns (uint256) {
        return ADD_PIECES_BASE_FEE + count * ADD_PIECES_PER_PIECE_FEE;
    }

    function _rateFor(uint256 dataSetId) private view returns (uint256) {
        return _rateForLeaves(mockPDPVerifier.getDataSetLeafCount(dataSetId));
    }

    function _rail(uint256 railId) private view returns (StreamState memory) {
        return RailIdLibrary.getRail(IExtsload(address(filecoinPayV2)), RailId.wrap(railId));
    }

    function _balance(address account, address token) private view returns (uint256) {
        return filecoinPayV2.balanceOf(account, uint256(uint160(token)));
    }

    function testRemovalPaysFeeToPayeeAtOnce() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        uint256 payerBefore = _balance(payer, address(mockUSDFC));
        uint256 payeeBefore = _balance(serviceProvider, address(mockUSDFC));

        // The charge runs with no permissions: lock and disburse need no grant from the payer
        vm.expectCall(
            address(filecoinPayV2),
            abi.encodePacked(bytes4(keccak256("executeScript(uint256,bytes)")), abi.encode(uint256(0)))
        );
        _scheduleRemovals(dataSetId, 1);

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "no fee waits");
        assertEq(info.lifecycleReserveBalance, TERMINATE_FEE, "reserve unchanged");
        assertEq(_rail(pdpRailId).available, TERMINATE_FEE, "rail keeps only the termination fee");
        assertEq(payerBefore - _balance(payer, address(mockUSDFC)), SCHEDULE_PIECE_REMOVALS_FEE, "payer pays the fee");
        assertEq(_balance(serviceProvider, address(mockUSDFC)) - payeeBefore, SCHEDULE_PIECE_REMOVALS_FEE, "payee paid");
    }

    function testManyRemovalsNeverTouchTheReserve() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;

        // Under FilecoinPayV1 the 65th removal would refill the reserve
        _scheduleRemovals(dataSetId, 70);

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(info.lifecycleReserveBalance, TERMINATE_FEE);
        assertEq(_rail(pdpRailId).available, TERMINATE_FEE);
        assertEq(_balance(serviceProvider, address(mockUSDFC)), CREATE_DATA_SET_FEE + 70 * SCHEDULE_PIECE_REMOVALS_FEE);
    }

    function testRemovalKeepsHeldPayment() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;

        // Payment held by the settlement callback sits in the same available balance as the reserve
        uint256 held = 3e18;
        vm.prank(address(pdpServiceWithPayments));
        filecoinPayV2.lock(
            payer, serviceProvider, FLAG_CALLBACK | uint64(dataSetId), uint256(uint160(address(mockUSDFC))), held
        );

        _scheduleRemovals(dataSetId, 1);

        assertEq(_rail(pdpRailId).available, TERMINATE_FEE + held, "held payment kept");
    }

    function testRemovalRevertsWhenPayerCannotPay() public {
        _fundV2Payer(payer, TERMINATE_FEE + CREATE_DATA_SET_FEE);
        uint256 dataSetId = _create(v2Terms, false);

        uint256[] memory pieceIds = new uint256[](1);
        makeSignaturePass(payer);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );
    }

    function testRemovalChargesOnlyPdpRailWithCDN() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, true);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint256 cacheMissBefore = _rail(info.cacheMissRailId).available;
        uint256 cdnBefore = _rail(info.cdnRailId).available;

        _scheduleRemovals(dataSetId, 1);

        assertEq(_rail(info.pdpRailId).available, TERMINATE_FEE);
        assertEq(_rail(info.cacheMissRailId).available, cacheMissBefore, "cache-miss rail untouched");
        assertEq(_rail(info.cdnRailId).available, cdnBefore, "CDN rail untouched");
        assertEq(_balance(serviceProvider, address(mockUSDFC)), CREATE_DATA_SET_FEE + SCHEDULE_PIECE_REMOVALS_FEE);
    }

    function testRemovalFeeScalesToSixDecimalTerms() public {
        CreationSixDecimalToken token = new CreationSixDecimalToken();
        bytes32 termsId = _registerV2Terms(address(token), 6, 2_500_000);
        require(token.transfer(payer, 10e6));
        vm.startPrank(payer);
        token.approve(address(filecoinPayV2), 10e6);
        filecoinPayV2.deposit(address(token), 10e6);
        filecoinPayV2.authorize(address(pdpServiceWithPayments), CREATE_RAIL);
        vm.stopPrank();
        uint256 dataSetId = _create(termsId, false);

        _scheduleRemovals(dataSetId, 1);

        // 0.006 termination fee locked, 0.025 creation and 0.007 removal fees paid, in six decimals
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.lifecycleReserveBalance, 6_000);
        assertEq(_rail(info.pdpRailId).available, 6_000);
        assertEq(_balance(payer, address(token)), 10e6 - 6_000 - 25_000 - 7_000);
        assertEq(_balance(serviceProvider, address(token)), 25_000 + 7_000);
    }

    function testAddSetsRateLocksAMonthAndPaysFee() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        uint256 payerBefore = _balance(payer, address(mockUSDFC));
        uint256 rate = _rateForLeaves(2 * Cids.leafCount(0, PIECE_HEIGHT));

        // The script runs with no permissions: setRate, lock and disburse need no grant from the payer
        vm.expectCall(
            address(filecoinPayV2),
            abi.encodePacked(bytes4(keccak256("executeScript(uint256,bytes)")), abi.encode(uint256(0)))
        );
        vm.expectEmit(true, false, false, true, address(pdpServiceWithPayments));
        emit RailRateUpdated(dataSetId, pdpRailId, rate);
        _addPieces(dataSetId, 2, PIECE_HEIGHT);

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, 0, "no fee waits");
        assertEq(info.lifecycleReserveBalance, TERMINATE_FEE, "reserve unchanged");
        assertEq(_rail(pdpRailId).incomingRate, rate);
        assertEq(_rail(pdpRailId).available, TERMINATE_FEE + rate * DEFAULT_LOCKUP_PERIOD, "a month of the rate");
        assertEq(payerBefore - _balance(payer, address(mockUSDFC)), rate * DEFAULT_LOCKUP_PERIOD + _addFee(2));
        assertEq(_balance(serviceProvider, address(mockUSDFC)), CREATE_DATA_SET_FEE + _addFee(2), "payee paid");
    }

    function testLaterAddsMoveTheLockWithTheRate() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;

        // A later block makes setRate settle the rail, so the settleRail callback runs before each rate change
        vm.roll(vm.getBlockNumber() + 10);
        _addPieces(dataSetId, 1, PIECE_HEIGHT);
        uint256 firstRate = _rateFor(dataSetId);
        vm.roll(vm.getBlockNumber() + 100);
        uint256 payerBefore = _balance(payer, address(mockUSDFC));
        _addPieces(dataSetId, 3, PIECE_HEIGHT);
        uint256 rate = _rateFor(dataSetId);

        // Before proving starts the callback refunds the accrued payment and keeps the lock
        assertEq(_rail(pdpRailId).available, TERMINATE_FEE + rate * DEFAULT_LOCKUP_PERIOD, "lock follows the rate");
        assertEq(
            payerBefore - _balance(payer, address(mockUSDFC)),
            (rate - firstRate) * DEFAULT_LOCKUP_PERIOD + _addFee(3) - 100 * firstRate,
            "payer locks only the rate increase"
        );
    }

    function testAddAfterDeletionsUnlocksTheRateDecrease() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        _addPieces(dataSetId, 4, PIECE_HEIGHT);
        uint256 oldRate = _rateFor(dataSetId);

        // processPieceDeletions shrinks the data set without a callback, so the next add lowers the rate
        mockPDPVerifier.setDataSetLeafCount(dataSetId, 0);
        uint256 payerBefore = _balance(payer, address(mockUSDFC));
        _addPieces(dataSetId, 1, PIECE_HEIGHT);
        uint256 rate = _rateFor(dataSetId);

        assertLt(rate, oldRate);
        assertEq(_rail(pdpRailId).incomingRate, rate);
        assertEq(_rail(pdpRailId).available, TERMINATE_FEE + rate * DEFAULT_LOCKUP_PERIOD, "lock follows the rate");
        assertEq(
            _balance(payer, address(mockUSDFC)) - payerBefore,
            (oldRate - rate) * DEFAULT_LOCKUP_PERIOD - _addFee(1),
            "payer gets the lock decrease back, less the fee"
        );
    }

    function testAddKeepsHeldPayment() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        uint256 held = 3e18;
        vm.prank(address(pdpServiceWithPayments));
        filecoinPayV2.lock(
            payer, serviceProvider, FLAG_CALLBACK | uint64(dataSetId), uint256(uint160(address(mockUSDFC))), held
        );

        _addPieces(dataSetId, 1, PIECE_HEIGHT);

        assertEq(
            _rail(pdpRailId).available,
            TERMINATE_FEE + _rateFor(dataSetId) * DEFAULT_LOCKUP_PERIOD + held,
            "held payment kept"
        );
    }

    function testAddInOpenPeriodKeepsHeldPaymentBesideTheLock() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        _addPieces(dataSetId, 1, PIECE_HEIGHT);
        uint256 firstRate = _rateFor(dataSetId);
        (uint64 maxProvingPeriod, uint256 challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 activationEpoch = vm.getBlockNumber();
        _nextProvingPeriod(
            dataSetId,
            activationEpoch + maxProvingPeriod - challengeWindow / 2,
            mockPDPVerifier.getDataSetLeafCount(dataSetId)
        );

        uint256 midPeriod = activationEpoch + maxProvingPeriod / 2;
        vm.roll(midPeriod);
        _addPieces(dataSetId, 2, PIECE_HEIGHT);

        // The settleRail callback holds the open period's payment and leaves the old lock for the script to move
        uint256 held = (midPeriod - activationEpoch) * firstRate;
        assertEq(_rail(pdpRailId).available, TERMINATE_FEE + _rateFor(dataSetId) * DEFAULT_LOCKUP_PERIOD + held);
        assertEq(
            _balance(serviceProvider, address(mockUSDFC)),
            CREATE_DATA_SET_FEE + _addFee(1) + _addFee(2),
            "the open period pays nothing yet"
        );
    }

    function testAddRevertsWhenPayerCannotLock() public {
        _fundV2Payer(payer, TERMINATE_FEE + CREATE_DATA_SET_FEE + _addFee(1));
        uint256 dataSetId = _create(v2Terms, false);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, PIECE_HEIGHT, keccak256("short"));
        makeSignaturePass(payer);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            0,
            pieceData,
            1,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );
    }

    function testAddRevertsWhenPayerIsBehind() public {
        uint256 rate = _rateForLeaves(Cids.leafCount(0, PIECE_HEIGHT));
        uint256 fundedEpochs = 10;
        _fundV2Payer(
            payer, TERMINATE_FEE + CREATE_DATA_SET_FEE + _addFee(1) + rate * DEFAULT_LOCKUP_PERIOD + fundedEpochs * rate
        );
        uint256 dataSetId = _create(v2Terms, false);
        _addPieces(dataSetId, 1, PIECE_HEIGHT);
        assertEq(_balance(payer, address(mockUSDFC)), fundedEpochs * rate, "only the streaming balance is free");
        vm.roll(vm.getBlockNumber() + fundedEpochs + 5);

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, PIECE_HEIGHT, keccak256("behind"));
        makeSignaturePass(payer);
        vm.expectRevert(FilecoinPayV2.Behind.selector);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)),
            dataSetId,
            1,
            pieceData,
            2,
            FAKE_SIGNATURE,
            new string[](0),
            new string[](0)
        );
    }

    function testAddRevertsWhenRateOverflowsTheRail() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(_registerV2Terms(address(mockUSDFC), 18, type(uint96).max), false);

        // A PiB at the highest price streams more per epoch than a FilecoinPayV2 rate holds
        mockPDPVerifier.setDataSetLeafCount(dataSetId, 1 << 45);
        vm.expectPartialRevert(LibRailsV2.RateTooLarge.selector);
        _addPieces(dataSetId, 1, PIECE_HEIGHT);
    }

    function testAddLocksOnlyPdpRailWithCDN() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, true);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint256 cacheMissBefore = _rail(info.cacheMissRailId).available;
        uint256 cdnBefore = _rail(info.cdnRailId).available;

        _addPieces(dataSetId, 1, PIECE_HEIGHT);

        assertEq(_rail(info.pdpRailId).available, TERMINATE_FEE + _rateFor(dataSetId) * DEFAULT_LOCKUP_PERIOD);
        assertEq(_rail(info.cacheMissRailId).available, cacheMissBefore, "cache-miss rail untouched");
        assertEq(_rail(info.cdnRailId).available, cdnBefore, "CDN rail untouched");
        assertEq(_rail(info.cacheMissRailId).incomingRate, 0);
        assertEq(_rail(info.cdnRailId).incomingRate, 0);
    }

    function testAddFeeAndLockScaleToSixDecimalTerms() public {
        CreationSixDecimalToken token = new CreationSixDecimalToken();
        bytes32 termsId = _registerV2Terms(address(token), 6, 2_500_000);
        require(token.transfer(payer, 10e6));
        vm.startPrank(payer);
        token.approve(address(filecoinPayV2), 10e6);
        filecoinPayV2.deposit(address(token), 10e6);
        filecoinPayV2.authorize(address(pdpServiceWithPayments), CREATE_RAIL);
        vm.stopPrank();
        uint256 dataSetId = _create(termsId, false);

        _addPieces(dataSetId, 1, PIECE_HEIGHT);

        // 0.006 termination fee locked, 0.025 creation and 0.008 + 0.003 add fees paid, in six decimals
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint256 rate = _rail(info.pdpRailId).incomingRate;
        assertGt(rate, 0);
        assertEq(_rail(info.pdpRailId).available, 6_000 + rate * DEFAULT_LOCKUP_PERIOD);
        assertEq(_balance(serviceProvider, address(token)), 25_000 + 11_000);
        assertEq(_balance(payer, address(token)), 10e6 - 6_000 - 25_000 - 11_000 - rate * DEFAULT_LOCKUP_PERIOD);
    }
}
