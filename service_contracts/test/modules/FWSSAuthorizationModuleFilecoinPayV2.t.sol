// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {PDPListener} from "@pdp/PDPVerifier.sol";
import {FilecoinPayV2} from "@filecoin-pay-v2/FilecoinPayV2.sol";
import {IExtsload} from "@filecoin-pay-v2/interfaces/IExtsload.sol";
import {CREATE_RAIL} from "@filecoin-pay-v2/lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, StreamState} from "@filecoin-pay-v2/lib/RailId.sol";
import {DataSetInfoView} from "../../src/lib/FWSSViewTypes.sol";
import {
    CREATE_DATA_SET_FEE,
    LIFECYCLE_RESERVE_TARGET,
    REPLENISH_THRESHOLD,
    SCHEDULE_PIECE_REMOVALS_FEE,
    STORAGE_PRICE_PER_TIB_PER_MONTH
} from "../../src/lib/PriceListUSDFC.sol";
import {PAY_VERSION_FILECOIN_PAY_V2, StorageTerms} from "../../src/lib/StorageTerms.sol";
import {FWSSStorageTermsModule} from "../../src/modules/FWSSStorageTermsModule.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";
import {CreationSixDecimalToken} from "../StorageTermsCreation.t.sol";

contract FWSSAuthorizationModuleFilecoinPayV2Test is FilecoinWarmStorageServiceFixture {
    // Removals that fit in the reserve left after the creation fee; the next one refills it.
    uint256 private constant REMOVALS_BEFORE_REFILL =
        (LIFECYCLE_RESERVE_TARGET - REPLENISH_THRESHOLD - CREATE_DATA_SET_FEE) / SCHEDULE_PIECE_REMOVALS_FEE;
    uint256 private constant PENDING_AT_REFILL =
        CREATE_DATA_SET_FEE + (REMOVALS_BEFORE_REFILL + 1) * SCHEDULE_PIECE_REMOVALS_FEE;

    address private payer;
    bytes32 private v2Terms;

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

    function _rail(uint256 railId) private view returns (StreamState memory) {
        return RailIdLibrary.getRail(IExtsload(address(filecoinPayV2)), RailId.wrap(railId));
    }

    function _balance(address token) private view returns (uint256) {
        return filecoinPayV2.balanceOf(payer, uint256(uint160(token)));
    }

    function testRemovalAboveThresholdOnlyAddsFee() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        uint256 balanceBefore = _balance(address(mockUSDFC));

        _scheduleRemovals(dataSetId, REMOVALS_BEFORE_REFILL);

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(
            info.pendingOneTimePayments, CREATE_DATA_SET_FEE + REMOVALS_BEFORE_REFILL * SCHEDULE_PIECE_REMOVALS_FEE
        );
        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET, "reserve unchanged");
        assertEq(_rail(pdpRailId).available, LIFECYCLE_RESERVE_TARGET, "nothing locked");
        assertEq(_balance(address(mockUSDFC)), balanceBefore, "payer balance unchanged");
    }

    function testRemovalRefillsReserveWithLockOnPdpRail() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        _scheduleRemovals(dataSetId, REMOVALS_BEFORE_REFILL);
        uint256 balanceBefore = _balance(address(mockUSDFC));

        // The refill runs with no permissions: lock needs no grant from the payer
        vm.expectCall(
            address(filecoinPayV2),
            abi.encodePacked(bytes4(keccak256("executeScript(uint256,bytes)")), abi.encode(uint256(0)))
        );
        _scheduleRemovals(dataSetId, 1);

        uint256 refilled = LIFECYCLE_RESERVE_TARGET + PENDING_AT_REFILL;
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pendingOneTimePayments, PENDING_AT_REFILL);
        assertEq(info.lifecycleReserveBalance, refilled, "reserve refilled to target plus pending");
        assertEq(_rail(pdpRailId).available, refilled, "rail holds the refilled reserve");
        assertEq(balanceBefore - _balance(address(mockUSDFC)), refilled - LIFECYCLE_RESERVE_TARGET, "lock pays delta");
    }

    function testRemovalRefillAddsToSettledBalance() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, false);
        uint256 pdpRailId = pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId;
        _scheduleRemovals(dataSetId, REMOVALS_BEFORE_REFILL);

        // Payment held by the settlement callback sits in the same available balance as the reserve
        uint256 held = 3e18;
        vm.prank(address(pdpServiceWithPayments));
        filecoinPayV2.lock(
            payer, serviceProvider, FLAG_CALLBACK | uint64(dataSetId), uint256(uint160(address(mockUSDFC))), held
        );

        _scheduleRemovals(dataSetId, 1);

        assertEq(_rail(pdpRailId).available, held + LIFECYCLE_RESERVE_TARGET + PENDING_AT_REFILL, "held payment kept");
    }

    function testRemovalRevertsWhenPayerCannotRefill() public {
        _fundV2Payer(payer, LIFECYCLE_RESERVE_TARGET);
        uint256 dataSetId = _create(v2Terms, false);
        _scheduleRemovals(dataSetId, REMOVALS_BEFORE_REFILL);

        uint256[] memory pieceIds = new uint256[](1);
        makeSignaturePass(payer);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        mockPDPVerifier.piecesScheduledRemove(
            dataSetId, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
        );
    }

    function testRemovalRefillLocksOnlyPdpRailWithCDN() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(v2Terms, true);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        uint256 cacheMissBefore = _rail(info.cacheMissRailId).available;
        uint256 cdnBefore = _rail(info.cdnRailId).available;

        _scheduleRemovals(dataSetId, REMOVALS_BEFORE_REFILL + 1);

        assertEq(_rail(info.pdpRailId).available, LIFECYCLE_RESERVE_TARGET + PENDING_AT_REFILL);
        assertEq(_rail(info.cacheMissRailId).available, cacheMissBefore, "cache-miss rail untouched");
        assertEq(_rail(info.cdnRailId).available, cdnBefore, "CDN rail untouched");
    }

    function testRemovalRefillScalesToSixDecimalTerms() public {
        CreationSixDecimalToken token = new CreationSixDecimalToken();
        bytes32 termsId = _registerV2Terms(address(token), 6, 2_500_000);
        require(token.transfer(payer, 10e6));
        vm.startPrank(payer);
        token.approve(address(filecoinPayV2), 10e6);
        filecoinPayV2.deposit(address(token), 10e6);
        filecoinPayV2.authorize(address(pdpServiceWithPayments), CREATE_RAIL);
        vm.stopPrank();
        uint256 dataSetId = _create(termsId, false);

        _scheduleRemovals(dataSetId, REMOVALS_BEFORE_REFILL + 1);

        // 0.50 target + 0.48 pending, in six decimals
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.lifecycleReserveBalance, 980_000);
        assertEq(_rail(info.pdpRailId).available, 980_000);
        assertEq(_balance(address(token)), 10e6 - 980_000);
    }
}
