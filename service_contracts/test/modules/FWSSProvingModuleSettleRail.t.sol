// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {PDPListener} from "@pdp/PDPVerifier.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IExtsload} from "@filecoin-pay-v2/interfaces/IExtsload.sol";
import {CREATE_RAIL} from "@filecoin-pay-v2/lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, Stream} from "@filecoin-pay-v2/lib/RailId.sol";
import {DISBURSE, UNLOCK, newScript} from "@filecoin-pay-v2/lib/Script.sol";
import {Errors} from "../../src/Errors.sol";
import {CHALLENGES_PER_PROOF} from "../../src/lib/FWSSConstants.sol";
import {DataSetInfoView} from "../../src/lib/FWSSViewTypes.sol";
import {RAIL_TO_DATA_SET_SLOT} from "../../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {LibHeldPayments} from "../../src/lib/LibHeldPayments.sol";
import {FWSSProvingModule} from "../../src/modules/FWSSProvingModule.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";

contract FWSSProvingModuleSettleRailTest is FilecoinWarmStorageServiceFixture {
    using RailIdLibrary for address;
    using RailIdLibrary for IExtsload;
    using RailIdLibrary for Stream;

    uint64 internal constant NONCE = FLAG_CALLBACK | 1;
    uint88 internal constant RATE = 1000;
    uint128 internal constant RESERVE = 1e6;
    uint256 internal constant DEPOSIT = 1e18;

    FWSSProvingModule internal provingModule;
    uint256 internal dataSetId;
    address internal payee;
    uint256 internal token;
    RailId internal railId;
    uint256 internal activationEpoch;
    uint64 internal maxProvingPeriod;
    uint256 internal challengeWindow;

    function setUp() public override {
        super.setUp();
        provingModule = FWSSProvingModule(address(pdpServiceWithPayments));
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "V2 rail");
        dataSetId = createDataSetForClient(sp1, client, keys, values);
        payee = pdpServiceWithPayments.getDataSet(dataSetId).payee;
        token = uint256(uint160(address(mockUSDFC)));
        (maxProvingPeriod, challengeWindow,,) = pdpServiceWithPayments.getPDPConfig();
    }

    // Rail setup, as dataSetCreated will do once it moves to FilecoinPayV2

    function _createRail(uint256 deposit, bool linked) internal {
        vm.startPrank(client);
        mockUSDFC.approve(address(filecoinPayV2), deposit);
        filecoinPayV2.deposit(address(mockUSDFC), deposit);
        filecoinPayV2.authorize(address(pdpServiceWithPayments), CREATE_RAIL);
        vm.stopPrank();

        vm.prank(address(pdpServiceWithPayments));
        filecoinPayV2.executeScript(
            newScript().setToken(address(mockUSDFC)).createRail(client, payee, NONCE).lock(RESERVE).setRate(RATE)
                .build()
        );
        railId = address(pdpServiceWithPayments).deriveRail(client, payee, token, NONCE).getRailId();
        if (linked) {
            vm.store(
                address(pdpServiceWithPayments),
                keccak256(abi.encode(RailId.unwrap(railId), RAIL_TO_DATA_SET_SLOT)),
                bytes32(dataSetId)
            );
        }
    }

    function _settle() internal returns (uint256 settledUpTo) {
        return filecoinPayV2.settleRail(address(pdpServiceWithPayments), client, payee, NONCE, token);
    }

    function _setRate(uint88 rate) internal {
        vm.prank(address(pdpServiceWithPayments));
        filecoinPayV2.executeScript(
            newScript().setToken(address(mockUSDFC)).setRail(client, payee, NONCE).setRate(rate).build()
        );
    }

    function _available() internal view returns (uint256) {
        return IExtsload(address(filecoinPayV2)).getRail(railId).available;
    }

    function _held() internal view returns (uint256 amount, uint256 fromEpoch, uint256 toEpoch) {
        uint256 word = _heldWord(railId);
        return (uint128(word), uint64(word >> 128), uint64(word >> 192));
    }

    function _heldWord(RailId rail) internal view returns (uint256) {
        return uint256(
            vm.load(
                address(pdpServiceWithPayments),
                keccak256(abi.encode(RailId.unwrap(rail), LibHeldPayments.STORAGE_LOCATION))
            )
        );
    }

    function _payerBalance() internal view returns (uint256) {
        return filecoinPayV2.balanceOf(client, token);
    }

    function _payeeBalance() internal view returns (uint256) {
        return filecoinPayV2.balanceOf(payee, token);
    }

    function _startProving() internal {
        activationEpoch = vm.getBlockNumber();
        _nextProvingPeriod(dataSetId, _deadline(0) - challengeWindow / 2, 100);
    }

    function _deadline(uint256 period) internal view returns (uint256) {
        return activationEpoch + (period + 1) * maxProvingPeriod;
    }

    function _prove(uint256 period) internal {
        vm.roll(_deadline(period) - challengeWindow / 2);
        vm.prank(address(mockPDPVerifier));
        provingModule.possessionProven(dataSetId, 100, 12345, CHALLENGES_PER_PROOF);
    }

    function _openPeriod(uint256 period) internal {
        vm.roll(_deadline(period - 1) + 1);
        _nextProvingPeriod(dataSetId, _deadline(period) - challengeWindow / 2, 100);
    }

    function _assertHeld(uint256 amount, uint256 fromEpoch, uint256 toEpoch) internal view {
        (uint256 heldAmount, uint256 heldFrom, uint256 heldTo) = _held();
        assertEq(heldAmount, amount, "held amount");
        assertEq(heldFrom, fromEpoch, "held from");
        assertEq(heldTo, toEpoch, "held to");
        assertEq(_available(), RESERVE + amount, "available holds the reserve and the held payment");
    }

    function _expectSettled(
        uint256 id,
        RailId rail,
        uint256 fromEpoch,
        uint256 toEpoch,
        uint256 payout,
        uint256 refund,
        uint256 held
    ) internal {
        vm.expectEmit(true, true, false, true, address(pdpServiceWithPayments));
        emit FWSSProvingModule.PDPPaymentSettled(id, RailId.unwrap(rail), fromEpoch, toEpoch, payout, refund, held);
    }

    // Arbitration

    function testSettleRailCallback_AllEpochsProven() public {
        _startProving();
        _createRail(DEPOSIT, true);
        _prove(0);
        _openPeriod(1);
        _prove(1);
        vm.roll(_deadline(1));

        uint256 payerBefore = _payerBalance();
        _settle();

        assertEq(_payeeBalance(), 2 * maxProvingPeriod * RATE, "pays every proven epoch");
        assertEq(_payerBalance(), payerBefore, "refunds nothing");
        _assertHeld(0, 0, 0);
    }

    function testSettleRailCallback_SomeEpochsProven() public {
        _startProving();
        _createRail(DEPOSIT, true);
        _prove(0);
        _openPeriod(1);
        vm.roll(_deadline(1) + 1);

        uint256 payerBefore = _payerBalance();
        _expectSettled(
            dataSetId, railId, activationEpoch, _deadline(1) + 1, maxProvingPeriod * RATE, maxProvingPeriod * RATE, RATE
        );
        _settle();

        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "pays the proven period");
        assertEq(_payerBalance(), payerBefore + maxProvingPeriod * RATE, "refunds the faulted period");
        _assertHeld(RATE, _deadline(1), _deadline(1) + 1);
    }

    function testSettleRailCallback_OpenPeriodHeldThenPaid() public {
        _startProving();
        _createRail(DEPOSIT, true);
        uint256 midPeriod = activationEpoch + maxProvingPeriod / 2;
        vm.roll(midPeriod);

        uint256 payerBefore = _payerBalance();
        _settle();
        assertEq(_payeeBalance(), 0, "the open period pays nothing yet");
        assertEq(_payerBalance(), payerBefore, "the open period refunds nothing yet");
        _assertHeld((midPeriod - activationEpoch) * RATE, activationEpoch, midPeriod);

        _prove(0);
        vm.roll(_deadline(0));
        _settle();
        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "the proof releases the held payment and the rest");
        assertEq(_payerBalance(), payerBefore - (_deadline(0) - midPeriod) * RATE, "only the accrual drained the payer");
        _assertHeld(0, 0, 0);
    }

    function testSettleRailCallback_ReleasedHeldPaymentIsNotPaidTwice() public {
        _startProving();
        _createRail(DEPOSIT, true);
        uint256 midPeriod = activationEpoch + maxProvingPeriod / 2;
        vm.roll(midPeriod);
        _settle();
        _prove(0);
        vm.roll(_deadline(0));
        _settle();
        assertEq(_payeeBalance(), maxProvingPeriod * RATE);

        // same block: FilecoinPayV2 has nothing new to accrue and skips the callback
        _settle();
        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "a repeated settle pays nothing");

        // next block: the new epoch belongs to the still open period 1 and is held, period 0 is not paid again
        vm.roll(_deadline(0) + 1);
        _settle();
        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "the released period is not paid twice");
        _assertHeld(RATE, _deadline(0), _deadline(0) + 1);
    }

    function testSettleRailCallback_ProvenHeldPaymentWaitsForNewAccrual() public {
        _startProving();
        uint256 fundedEpochs = maxProvingPeriod / 2;
        _createRail(RESERVE + fundedEpochs * RATE, true);
        vm.roll(activationEpoch + fundedEpochs + 10);
        uint256 fundedTo = _settle();
        assertEq(fundedTo, activationEpoch + fundedEpochs);
        _assertHeld(fundedEpochs * RATE, activationEpoch, fundedTo);

        // the proof resolves the held period, but an insolvent payer accrues nothing new, so no callback runs
        _prove(0);
        vm.roll(_deadline(0) + 1);
        assertEq(_settle(), fundedTo, "settlement cannot advance past the funded epoch");
        assertEq(_payeeBalance(), 0, "the proven held payment waits for the next callback");
        _assertHeld(fundedEpochs * RATE, activationEpoch, fundedTo);

        // a top-up lets settlement advance, and the callback releases the held payment with the new accrual
        vm.startPrank(client);
        mockUSDFC.approve(address(filecoinPayV2), DEPOSIT);
        filecoinPayV2.deposit(address(mockUSDFC), DEPOSIT);
        vm.stopPrank();
        _settle();
        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "pays the held and the newly accrued proven epochs once");
        _assertHeld(RATE, _deadline(0), _deadline(0) + 1);
    }

    function testSettleRailCallback_OpenPeriodHeldThenRefunded() public {
        _startProving();
        _createRail(DEPOSIT, true);
        uint256 midPeriod = activationEpoch + maxProvingPeriod / 2;
        vm.roll(midPeriod);
        _settle();
        _assertHeld((midPeriod - activationEpoch) * RATE, activationEpoch, midPeriod);

        vm.roll(_deadline(0) + 1);
        uint256 payerBefore = _payerBalance();
        _settle();

        assertEq(_payeeBalance(), 0, "the fault pays nothing");
        assertEq(
            _payerBalance(),
            payerBefore + maxProvingPeriod * RATE,
            "the fault refunds the held payment and the rest of the period"
        );
        _assertHeld(RATE, _deadline(0), _deadline(0) + 1);
    }

    function testSettleRailCallback_OpenPeriodHeldAcrossRepeatedSettles() public {
        _startProving();
        _createRail(DEPOSIT, true);
        uint256 quarter = maxProvingPeriod / 4;
        vm.roll(activationEpoch + quarter);
        _settle();
        vm.roll(activationEpoch + 2 * quarter);
        // the event reports the rail's whole held payment, not just this settlement's share
        _expectSettled(
            dataSetId, railId, activationEpoch + quarter, activationEpoch + 2 * quarter, 0, 0, 2 * quarter * RATE
        );
        _settle();
        _assertHeld(2 * quarter * RATE, activationEpoch, activationEpoch + 2 * quarter);
        assertEq(_payeeBalance(), 0);
    }

    function testSettleRailCallback_RangeBeforeActivationRefunds() public {
        _createRail(DEPOSIT, true);
        vm.roll(vm.getBlockNumber() + 100);

        uint256 payerBefore = _payerBalance();
        _startProving();
        _settle();

        assertEq(_payeeBalance(), 0);
        assertEq(_payerBalance(), payerBefore + 100 * RATE, "refunds the epochs before activation");
        _assertHeld(0, 0, 0);
    }

    function testSettleRailCallback_ProvingNeverActivatedRefunds() public {
        _createRail(DEPOSIT, true);
        vm.roll(vm.getBlockNumber() + 100);

        uint256 payerBefore = _payerBalance();
        _settle();

        assertEq(_payeeBalance(), 0);
        assertEq(_payerBalance(), payerBefore + 100 * RATE);
        assertEq(_available(), RESERVE);
    }

    function testSettleRailCallback_StraddlingActivationRefundsEpochsBeforeIt() public {
        uint256 createdAt = vm.getBlockNumber();
        _createRail(DEPOSIT, true);
        vm.roll(createdAt + 100);
        _startProving();
        _prove(0);
        vm.roll(_deadline(0));

        uint256 payerBefore = _payerBalance();
        _settle();

        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "pays the proven period");
        assertEq(_payerBalance(), payerBefore + 100 * RATE, "refunds the epochs before activation");
        _assertHeld(0, 0, 0);
    }

    function testSettleRailCallback_UnknownRailRefunds() public {
        _startProving();
        _createRail(DEPOSIT, false);
        _prove(0);
        vm.roll(_deadline(0));

        uint256 payerBefore = _payerBalance();
        _expectSettled(0, railId, activationEpoch, _deadline(0), 0, maxProvingPeriod * RATE, 0);
        _settle();

        assertEq(_payeeBalance(), 0, "a rail without a data set pays nothing");
        assertEq(_payerBalance(), payerBefore + maxProvingPeriod * RATE);
        assertEq(_available(), RESERVE);
    }

    function testSettleRailCallback_DeletedDataSetRefundsHeldPayment() public {
        _startProving();
        _createRail(DEPOSIT, true);
        vm.roll(activationEpoch + maxProvingPeriod / 2);
        _settle();
        (uint256 heldAmount,,) = _held();
        assertGt(heldAmount, 0);

        // Terminate the service and delete the data set through its FilecoinPayV1 rail
        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        vm.roll(info.pdpEndEpoch + maxProvingPeriod + 1);
        FilecoinPayV1.RailView memory v1Rail = payments.getRail(info.pdpRailId);
        payments.settleRail(info.pdpRailId, v1Rail.endEpoch);
        vm.prank(sp1);
        mockPDPVerifier.deleteDataSet(PDPListener(address(pdpServiceWithPayments)), dataSetId, bytes(""));

        uint256 payerBefore = _payerBalance();
        uint256 accrued = (vm.getBlockNumber() - (activationEpoch + maxProvingPeriod / 2)) * RATE;
        _expectSettled(
            dataSetId, railId, activationEpoch + maxProvingPeriod / 2, vm.getBlockNumber(), 0, accrued + heldAmount, 0
        );
        _settle();

        assertEq(_payeeBalance(), 0, "a deleted data set pays nothing");
        assertEq(_payerBalance(), payerBefore + accrued + heldAmount, "refunds the held payment too");
        assertEq(_available(), RESERVE);
        _assertHeld(0, 0, 0);
    }

    function testSettleRailCallback_RevertsIfCallerNotFilecoinPayV2() public {
        vm.expectRevert(
            abi.encodeWithSelector(Errors.CallerNotPayments.selector, address(filecoinPayV2), address(payments))
        );
        vm.prank(address(payments));
        provingModule.settleRail(RailId.wrap(1), 0, 1, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.CallerNotPayments.selector, address(filecoinPayV2), client));
        vm.prank(client);
        provingModule.settleRail(RailId.wrap(1), 0, 1, 0, 0);
    }

    // FilecoinPayV2 triggers

    function testSettleRailCallback_RateChangeSettlesHeldPaymentExactly() public {
        _startProving();
        _createRail(DEPOSIT, true);
        uint256 midPeriod = activationEpoch + maxProvingPeriod / 2;
        vm.roll(midPeriod);
        // FWSS changes the rate from its own script, which calls back into FWSS before setting the rate
        _setRate(3 * RATE);
        _assertHeld((midPeriod - activationEpoch) * RATE, activationEpoch, midPeriod);

        _prove(0);
        vm.roll(_deadline(0));
        _settle();

        assertEq(
            _payeeBalance(),
            (midPeriod - activationEpoch) * RATE + (_deadline(0) - midPeriod) * 3 * RATE,
            "each part of the period pays at its own rate"
        );
        _assertHeld(0, 0, 0);
    }

    function testSettleRailCallback_ZeroRateStillReleasesHeldPayment() public {
        _startProving();
        _createRail(DEPOSIT, true);
        uint256 midPeriod = activationEpoch + maxProvingPeriod / 2;
        vm.roll(midPeriod);
        _setRate(0);
        uint256 heldAmount = (midPeriod - activationEpoch) * RATE;
        _assertHeld(heldAmount, activationEpoch, midPeriod);

        _prove(0);
        vm.roll(_deadline(0));
        uint256 payerBefore = _payerBalance();
        _settle();

        assertEq(_payeeBalance(), heldAmount, "the proof releases the held payment with nothing new accrued");
        assertEq(_payerBalance(), payerBefore);
        _assertHeld(0, 0, 0);
    }

    function testSettleRailCallback_ModifyRateTriggersCallback() public {
        _startProving();
        _createRail(DEPOSIT, true);
        _prove(0);
        vm.roll(_deadline(0));

        vm.prank(address(pdpServiceWithPayments));
        filecoinPayV2.modifyRate(client, payee, NONCE, token, 0);

        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "settling for the rate change pays the proven period");
        assertEq(IExtsload(address(filecoinPayV2)).getRail(railId).incomingRate, 0);
        _assertHeld(0, 0, 0);
    }

    function testSettleRailCallback_TerminationRefundsHeldPayment() public {
        _startProving();
        _createRail(DEPOSIT, true);
        _prove(0);
        _openPeriod(1);
        uint256 midPeriod = _deadline(0) + maxProvingPeriod / 2;
        vm.roll(midPeriod);

        uint256 payerBefore = _payerBalance();
        vm.prank(client);
        filecoinPayV2.terminateRail(address(pdpServiceWithPayments), client, payee, NONCE, token);

        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "termination pays the proven period");
        assertEq(
            _payerBalance(),
            payerBefore + RESERVE + (midPeriod - _deadline(0)) * RATE,
            "termination returns the reserve and the held payment"
        );
        assertEq(_available(), 0);
    }

    function testSettleRailCallback_TerminationRefundsPreviouslyHeldPayment() public {
        _startProving();
        _createRail(DEPOSIT, true);
        _prove(0);
        _openPeriod(1);
        uint256 quarter = _deadline(0) + maxProvingPeriod / 4;
        vm.roll(quarter);
        _settle();
        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "pays the proven period");
        _assertHeld((quarter - _deadline(0)) * RATE, _deadline(0), quarter);

        uint256 midPeriod = _deadline(0) + maxProvingPeriod / 2;
        vm.roll(midPeriod);
        uint256 payerBefore = _payerBalance();
        vm.prank(client);
        filecoinPayV2.terminateRail(address(pdpServiceWithPayments), client, payee, NONCE, token);

        assertEq(_payeeBalance(), maxProvingPeriod * RATE, "termination pays nothing for the open period");
        assertEq(
            _payerBalance(),
            payerBefore + RESERVE + (midPeriod - _deadline(0)) * RATE,
            "termination returns the reserve, the earlier held payment and the new accrual"
        );
        assertEq(_available(), 0);
    }

    function testSettleRailCallback_InsolventPayerSettlesUpToFundedEpoch() public {
        _startProving();
        uint256 fundedEpochs = maxProvingPeriod / 2;
        _createRail(RESERVE + fundedEpochs * RATE, true);
        _prove(0);
        vm.roll(_deadline(0) + 10);

        uint256 settledUpTo = _settle();

        assertEq(settledUpTo, activationEpoch + fundedEpochs, "settles only as far as the payer funded");
        assertLt(settledUpTo, vm.getBlockNumber());
        assertEq(_payeeBalance(), fundedEpochs * RATE, "pays the funded proven epochs");
        _assertHeld(0, 0, 0);
    }

    // Accounting

    /// @dev Decodes the UNLOCK and DISBURSE ops of a settleRail script.
    function _decode(bytes memory script) internal pure returns (uint256 unlocked, uint256 disbursed) {
        uint256 i;
        while (i < script.length) {
            uint8 op = uint8(script[i]);
            uint256 amount;
            for (uint256 j = 1; j <= 16; ++j) {
                amount = (amount << 8) | uint8(script[i + j]);
            }
            if (op == UNLOCK) unlocked += amount;
            else if (op == DISBURSE) disbursed += amount;
            else revert("unexpected op");
            i += 17;
        }
    }

    /// @dev Expected split of `amount` over (fromEpoch, toEpoch] when period 0 is proven, period 1 faulted and
    /// period 2 open, counting epochs per region independently of the module's period walk.
    function _expectedSplit(uint256 fromEpoch, uint256 toEpoch, uint256 amount)
        internal
        view
        returns (uint256 payout, uint256 held)
    {
        uint256 total = toEpoch - fromEpoch;
        payout = (amount * _overlap(fromEpoch, toEpoch, activationEpoch, _deadline(0))) / total;
        held = (amount * _overlap(fromEpoch, toEpoch, _deadline(1), type(uint64).max)) / total;
    }

    /// @dev Number of epochs in both (aFrom, aTo] and (bFrom, bTo].
    function _overlap(uint256 aFrom, uint256 aTo, uint256 bFrom, uint256 bTo) internal pure returns (uint256) {
        uint256 lo = aFrom > bFrom ? aFrom : bFrom;
        uint256 hi = aTo < bTo ? aTo : bTo;
        return hi > lo ? hi - lo : 0;
    }

    /// @dev Calls the callback as FilecoinPayV2 and returns what it released and what the rail holds afterwards.
    function _callback(RailId rail, uint256 fromEpoch, uint256 toEpoch, uint256 prevBalance, uint256 amount)
        internal
        returns (uint256 unlocked, uint256 disbursed, uint256 held)
    {
        vm.prank(address(filecoinPayV2));
        (unlocked, disbursed) = _decode(provingModule.settleRail(rail, fromEpoch, toEpoch, prevBalance, amount));
        held = uint128(_heldWord(rail));
    }

    function testFuzz_SettleRailCallback_ReleasesExactlyWhatItAccounts(
        uint256 firstFrom,
        uint256 firstTo,
        uint256 firstAmount,
        uint256 secondAmount,
        uint256 reserve
    ) public {
        vm.roll(1000);
        _startProving();
        _prove(0);
        _openPeriod(1);
        _openPeriod(2);
        vm.roll(_deadline(1) + maxProvingPeriod / 3);

        firstFrom = bound(firstFrom, activationEpoch - 10, vm.getBlockNumber() - 2);
        firstTo = bound(firstTo, firstFrom + 1, vm.getBlockNumber() - 1);
        firstAmount = bound(firstAmount, 0, type(uint96).max);
        secondAmount = bound(secondAmount, 0, type(uint96).max);
        reserve = bound(reserve, 0, type(uint96).max);
        RailId rail = RailId.wrap(uint256(keccak256("fuzz rail")));
        vm.store(
            address(pdpServiceWithPayments),
            keccak256(abi.encode(RailId.unwrap(rail), RAIL_TO_DATA_SET_SLOT)),
            bytes32(dataSetId)
        );

        (uint256 unlocked, uint256 disbursed, uint256 held) = _callback(rail, firstFrom, firstTo, reserve, firstAmount);
        (uint256 payout, uint256 open) = _expectedSplit(firstFrom, firstTo, firstAmount);
        assertEq(disbursed, payout, "first settle pays the proven epochs");
        assertEq(held, open, "first settle holds the open epochs");
        assertEq(unlocked, firstAmount - payout - open, "first settle refunds the rest");

        // the period the first settle held is still open, so its payment stays held
        uint256 heldBefore = held;
        (unlocked, disbursed, held) = _callback(rail, firstTo, vm.getBlockNumber(), reserve + heldBefore, secondAmount);
        (payout, open) = _expectedSplit(firstTo, vm.getBlockNumber(), secondAmount);
        assertEq(disbursed, payout, "second settle pays the proven epochs");
        assertEq(held, heldBefore + open, "second settle keeps the open epochs held");
        assertEq(unlocked, secondAmount - payout - open, "second settle refunds the rest");
    }
}
