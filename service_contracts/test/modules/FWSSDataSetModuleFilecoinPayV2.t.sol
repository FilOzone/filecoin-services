// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {FilecoinPayV2} from "@filecoin-pay-v2/FilecoinPayV2.sol";
import {IExtsload} from "@filecoin-pay-v2/interfaces/IExtsload.sol";
import {CREATE_RAIL, DEPOSIT} from "@filecoin-pay-v2/lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, Stream, StreamState} from "@filecoin-pay-v2/lib/RailId.sol";
import {Errors} from "../../src/Errors.sol";
import {ServiceProviderRegistryStorage} from "../../src/ServiceProviderRegistryStorage.sol";
import {DataSetInfoView} from "../../src/lib/FWSSViewTypes.sol";
import {FWSSFilecoinPayV2} from "../../src/lib/FWSSFilecoinPayV2.sol";
import {CDNPaymentRailsToppedUp} from "../../src/lib/LibRails.sol";
import {
    CREATE_DATA_SET_FEE,
    DATASET_FEE_PER_MONTH,
    DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
    DEFAULT_CDN_LOCKUP_AMOUNT,
    LIFECYCLE_RESERVE_TARGET,
    STORAGE_PRICE_PER_TIB_PER_MONTH
} from "../../src/lib/PriceListUSDFC.sol";
import {PAY_VERSION_FILECOIN_PAY_V2, StorageTerms} from "../../src/lib/StorageTerms.sol";
import {FWSSDataSetModule} from "../../src/modules/FWSSDataSetModule.sol";
import {FWSSStorageTermsModule} from "../../src/modules/FWSSStorageTermsModule.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";
import {PDPOffering} from "../PDPOffering.sol";
import {CreationSixDecimalToken} from "../StorageTermsCreation.t.sol";

contract RailVersionHarness is FWSSFilecoinPayV2 {
    constructor(address filecoinPayV2Address) FWSSFilecoinPayV2(filecoinPayV2Address) {}

    function isV1Rail(uint256 railId) external pure returns (bool) {
        return _isV1Rail(railId);
    }
}

contract FWSSDataSetModuleFilecoinPayV2Test is FilecoinWarmStorageServiceFixture {
    using PDPOffering for PDPOffering.Schema;
    using RailIdLibrary for Stream;

    uint64 private constant CDN_RAIL_NONCE_FLAG = 1 << 62;
    uint256 private constant MIN_FUNDS = DATASET_FEE_PER_MONTH + LIFECYCLE_RESERVE_TARGET; // 0.62 USDFC
    uint256 private constant MIN_FUNDS_CDN = MIN_FUNDS + DEFAULT_CACHE_MISS_LOCKUP_AMOUNT + DEFAULT_CDN_LOCKUP_AMOUNT;

    address private payer;
    bytes32 private v2Terms;

    function setUp() public override {
        super.setUp();
        payer = makeAddr("v2Payer");
        vm.deal(payer, 100 ether);
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

    function _metadata(bool cdn) private pure returns (string[] memory keys, string[] memory values) {
        keys = new string[](cdn ? 1 : 0);
        values = new string[](cdn ? 1 : 0);
        if (cdn) {
            keys[0] = "withCDN";
            values[0] = "true";
        }
    }

    /// @dev Selects the FilecoinPayV2 USDFC terms registered in setUp.
    function _payload(uint256 clientDataSetId, bool cdn) private view returns (bytes memory) {
        return _termsPayload(clientDataSetId, v2Terms, cdn);
    }

    function _termsPayload(uint256 clientDataSetId, bytes32 storageTermsId, bool cdn)
        private
        view
        returns (bytes memory)
    {
        (string[] memory keys, string[] memory values) = _metadata(cdn);
        return abi.encode(payer, clientDataSetId, keys, values, FAKE_SIGNATURE, storageTermsId);
    }

    /// @dev The five-field payload, which selects legacy record zero.
    function _legacyPayload(uint256 clientDataSetId, bool cdn) private view returns (bytes memory) {
        (string[] memory keys, string[] memory values) = _metadata(cdn);
        return abi.encode(payer, clientDataSetId, keys, values, FAKE_SIGNATURE);
    }

    function _create(address provider, bytes memory payload) private returns (uint256) {
        makeSignaturePass(payer);
        vm.prank(provider);
        return mockPDPVerifier.createDataSet(PDPListener(address(pdpServiceWithPayments)), payload);
    }

    function _railId(address recipient, address token, uint64 nonce) private view returns (uint256) {
        return RailId.unwrap(
            RailIdLibrary.deriveRail(address(pdpServiceWithPayments), payer, recipient, uint256(uint160(token)), nonce)
                .getRailId()
        );
    }

    function _rail(uint256 railId) private view returns (StreamState memory) {
        return RailIdLibrary.getRail(IExtsload(address(filecoinPayV2)), RailId.wrap(railId));
    }

    function _usdfcBalance() private view returns (uint256) {
        return filecoinPayV2.balanceOf(payer, uint256(uint160(address(mockUSDFC))));
    }

    /// @dev The railIds of Pay's RailCreated events, in order, after checking their payer and operator.
    function _railsCreated(Vm.Log[] memory logs) private view returns (uint256[] memory railIds) {
        railIds = new uint256[](logs.length);
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(filecoinPayV2) || logs[i].topics[0] != FilecoinPayV2.RailCreated.selector) {
                continue;
            }
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(payer))), "rail payer");
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(pdpServiceWithPayments)))), "rail operator");
            (, RailId railId,) = abi.decode(logs[i].data, (uint256, RailId, uint64));
            railIds[count++] = RailId.unwrap(railId);
        }
        assembly ("memory-safe") {
            mstore(railIds, count)
        }
    }

    function testCreatesPdpRailOnFilecoinPayV2WithoutCDN() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = mockPDPVerifier.nextDataSetId();
        uint256 pdpRailId = _railId(serviceProvider, address(mockUSDFC), FLAG_CALLBACK | uint64(dataSetId));
        (string[] memory keys, string[] memory values) = _metadata(false);

        // FWSS asks for CREATE_RAIL only, never a wider scope
        vm.expectCall(
            address(filecoinPayV2),
            abi.encodePacked(bytes4(keccak256("executeScript(uint256,bytes)")), abi.encode(CREATE_RAIL))
        );
        vm.expectEmit(address(pdpServiceWithPayments));
        emit FWSSDataSetModule.DataSetCreated(
            dataSetId, 1, pdpRailId, 0, 0, payer, serviceProvider, serviceProvider, keys, values
        );
        vm.expectEmit(address(pdpServiceWithPayments));
        emit FWSSDataSetModule.DataSetStorageTermsSelected(dataSetId, v2Terms);
        vm.recordLogs();
        assertEq(_create(serviceProvider, _payload(7, false)), dataSetId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[] memory created = _railsCreated(logs);
        assertEq(created.length, 1, "one rail");
        assertEq(created[0], pdpRailId, "derived PDP rail id");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], CDNPaymentRailsToppedUp.selector, "no CDN top-up");
        }

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pdpRailId, pdpRailId);
        assertEq(info.cacheMissRailId, 0);
        assertEq(info.cdnRailId, 0);
        assertEq(info.payer, payer);
        assertEq(info.payee, serviceProvider);
        assertEq(info.lifecycleReserveBalance, LIFECYCLE_RESERVE_TARGET);
        assertEq(info.pendingOneTimePayments, CREATE_DATA_SET_FEE);
        assertEq(pdpServiceWithPayments.railToDataSet(pdpRailId), dataSetId);
        assertEq(pdpServiceWithPayments.clientNonces(payer, 7), dataSetId);

        StreamState memory rail = _rail(pdpRailId);
        assertTrue(RailIdLibrary.exists(rail), "PDP rail exists");
        assertEq(rail.available, LIFECYCLE_RESERVE_TARGET, "lifecycle reserve locked");
        assertEq(rail.incomingRate, 0);
        assertEq(_usdfcBalance(), 10e18 - LIFECYCLE_RESERVE_TARGET);
    }

    function testCreatesThreeRailsOnFilecoinPayV2WithCDN() public {
        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = mockPDPVerifier.nextDataSetId();
        address usdfc = address(mockUSDFC);
        uint256 pdpRailId = _railId(serviceProvider, usdfc, FLAG_CALLBACK | uint64(dataSetId));
        uint256 cacheMissRailId = _railId(serviceProvider, usdfc, uint64(dataSetId));
        uint256 cdnRailId = _railId(filBeamBeneficiary, usdfc, CDN_RAIL_NONCE_FLAG | uint64(dataSetId));
        (string[] memory keys, string[] memory values) = _metadata(true);

        vm.expectEmit(address(pdpServiceWithPayments));
        emit CDNPaymentRailsToppedUp(
            dataSetId,
            DEFAULT_CDN_LOCKUP_AMOUNT,
            DEFAULT_CDN_LOCKUP_AMOUNT,
            DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
            DEFAULT_CACHE_MISS_LOCKUP_AMOUNT
        );
        vm.expectEmit(address(pdpServiceWithPayments));
        emit FWSSDataSetModule.DataSetCreated(
            dataSetId, 1, pdpRailId, cacheMissRailId, cdnRailId, payer, serviceProvider, serviceProvider, keys, values
        );
        vm.expectEmit(address(pdpServiceWithPayments));
        emit FWSSDataSetModule.DataSetStorageTermsSelected(dataSetId, v2Terms);
        vm.recordLogs();
        _create(serviceProvider, _payload(0, true));

        uint256[] memory created = _railsCreated(vm.getRecordedLogs());
        assertEq(created.length, 3, "three rails");
        assertEq(created[0], pdpRailId, "derived PDP rail id");
        assertEq(created[1], cacheMissRailId, "derived cache-miss rail id");
        assertEq(created[2], cdnRailId, "derived CDN rail id");

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pdpRailId, pdpRailId);
        assertEq(info.cacheMissRailId, cacheMissRailId);
        assertEq(info.cdnRailId, cdnRailId);

        assertEq(_rail(pdpRailId).available, LIFECYCLE_RESERVE_TARGET);
        assertEq(_rail(cacheMissRailId).available, DEFAULT_CACHE_MISS_LOCKUP_AMOUNT);
        assertEq(_rail(cdnRailId).available, DEFAULT_CDN_LOCKUP_AMOUNT);
        assertEq(
            _usdfcBalance(),
            10e18 - LIFECYCLE_RESERVE_TARGET - DEFAULT_CACHE_MISS_LOCKUP_AMOUNT - DEFAULT_CDN_LOCKUP_AMOUNT
        );
    }

    function _fundV1Payer(uint256 amount) private {
        require(mockUSDFC.transfer(payer, amount));
        vm.startPrank(payer);
        mockUSDFC.approve(address(payments), amount);
        payments.deposit(mockUSDFC, payer, amount);
        payments.setOperatorApproval(mockUSDFC, address(pdpServiceWithPayments), true, 1000e18, 1000e18, 365 days);
        vm.stopPrank();
    }

    function testLegacyTermsStayOnFilecoinPayV1() public {
        _fundV2Payer(payer, 10e18);
        _fundV1Payer(10e18);

        uint256 dataSetId = _create(serviceProvider, _legacyPayload(0, true));

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertLt(info.pdpRailId, 1 << 64, "v1 PDP rail");
        assertLt(info.cacheMissRailId, 1 << 64, "v1 cache-miss rail");
        assertLt(info.cdnRailId, 1 << 64, "v1 CDN rail");
        assertEq(payments.getRail(info.pdpRailId).lockupFixed, LIFECYCLE_RESERVE_TARGET);
        assertEq(_usdfcBalance(), 10e18, "FilecoinPayV2 untouched");
    }

    function testV2TermsIgnoreFilecoinPayV1Funds() public {
        _fundV1Payer(10e18);

        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientLockupFunds.selector, payer, MIN_FUNDS, 0));
        _create(serviceProvider, _payload(0, false));
    }

    function testCreatesWithExactMinimumFunds() public {
        _fundV2Payer(payer, MIN_FUNDS);
        uint256 dataSetId = _create(serviceProvider, _payload(0, false));
        assertEq(_usdfcBalance(), MIN_FUNDS - LIFECYCLE_RESERVE_TARGET);

        _fundV2Payer(payer, MIN_FUNDS_CDN - _usdfcBalance());
        uint256 cdnDataSetId = _create(serviceProvider, _payload(1, true));
        assertNotEq(pdpServiceWithPayments.getDataSet(cdnDataSetId).cdnRailId, 0);
        assertNotEq(dataSetId, cdnDataSetId);
    }

    function testRevertsBelowMinimumFunds() public {
        _fundV2Payer(payer, MIN_FUNDS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InsufficientLockupFunds.selector, payer, MIN_FUNDS, MIN_FUNDS - 1)
        );
        _create(serviceProvider, _payload(0, false));

        _fundV2Payer(payer, MIN_FUNDS_CDN - MIN_FUNDS);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InsufficientLockupFunds.selector, payer, MIN_FUNDS_CDN, MIN_FUNDS_CDN - 1)
        );
        _create(serviceProvider, _payload(0, true));
    }

    function testRevertsWithoutCreateRailGrant() public {
        _fundV2Payer(payer, 10e18);
        vm.prank(payer);
        filecoinPayV2.authorize(address(pdpServiceWithPayments), DEPOSIT);

        vm.expectRevert(
            abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, payer, address(pdpServiceWithPayments))
        );
        _create(serviceProvider, _payload(0, false));
    }

    function testCdnRailsStayDistinctWhenPayeeIsFilBeamBeneficiary() public {
        address provider = makeAddr("beneficiaryProvider");
        vm.deal(provider, 10 ether);
        PDPOffering.Schema memory offering = PDPOffering.Schema({
            serviceURL: "https://beneficiary.example",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerDay: 1 ether,
            minProvingPeriodInEpochs: 2880,
            location: "US-Central",
            paymentTokenAddress: IERC20(address(0))
        });
        (string[] memory capabilityKeys, bytes[] memory capabilityValues) = offering.toCapabilities();
        vm.prank(provider);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            filBeamBeneficiary,
            "Beneficiary",
            "Payee is the FilBeam beneficiary",
            ServiceProviderRegistryStorage.ProductType.PDP,
            capabilityKeys,
            capabilityValues
        );

        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(provider, _payload(0, true));

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.payee, filBeamBeneficiary);
        assertEq(info.cacheMissRailId, _railId(filBeamBeneficiary, address(mockUSDFC), uint64(dataSetId)));
        assertEq(
            info.cdnRailId, _railId(filBeamBeneficiary, address(mockUSDFC), CDN_RAIL_NONCE_FLAG | uint64(dataSetId))
        );
        assertNotEq(info.cacheMissRailId, info.cdnRailId);
        assertEq(_rail(info.cacheMissRailId).available, DEFAULT_CACHE_MISS_LOCKUP_AMOUNT);
        assertEq(_rail(info.cdnRailId).available, DEFAULT_CDN_LOCKUP_AMOUNT);
    }

    function testRollsBackCreationWhenLastLockFails() public {
        uint256 lockedTotal = LIFECYCLE_RESERVE_TARGET + DEFAULT_CACHE_MISS_LOCKUP_AMOUNT + DEFAULT_CDN_LOCKUP_AMOUNT;
        _fundV2Payer(payer, lockedTotal - 1);
        uint256 dataSetId = mockPDPVerifier.nextDataSetId();
        uint256 pdpRailId = _railId(serviceProvider, address(mockUSDFC), FLAG_CALLBACK | uint64(dataSetId));

        // Pass the funding pre-check so the script runs until the CDN lock finds the balance short
        bytes memory balanceCall =
            abi.encodeCall(FilecoinPayV2.balanceOf, (payer, uint256(uint160(address(mockUSDFC)))));
        vm.mockCall(address(filecoinPayV2), balanceCall, abi.encode(MIN_FUNDS_CDN));
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        _create(serviceProvider, _payload(3, true));
        vm.clearMockedCalls();

        assertEq(pdpServiceWithPayments.clientNonces(payer, 3), 0);
        assertEq(pdpServiceWithPayments.clientDataSets(payer).length, 0);
        assertEq(pdpServiceWithPayments.railToDataSet(pdpRailId), 0);
        assertEq(pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId, 0);
        assertFalse(RailIdLibrary.exists(_rail(pdpRailId)), "PDP rail rolled back");
        assertEq(_usdfcBalance(), lockedTotal - 1);

        _fundV2Payer(payer, MIN_FUNDS_CDN - _usdfcBalance());
        assertEq(_create(serviceProvider, _payload(3, true)), dataSetId);
        assertEq(pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId, pdpRailId);
    }

    function testCreatesOnNativeFilTerms() public {
        bytes32 termsId = _registerV2Terms(address(0), 18, uint96(STORAGE_PRICE_PER_TIB_PER_MONTH));
        vm.startPrank(payer);
        filecoinPayV2.deposit{value: 1 ether}();
        filecoinPayV2.authorize(address(pdpServiceWithPayments), CREATE_RAIL);
        vm.stopPrank();

        uint256 dataSetId = _create(serviceProvider, _termsPayload(0, termsId, false));

        uint256 pdpRailId = _railId(serviceProvider, address(0), FLAG_CALLBACK | uint64(dataSetId));
        assertEq(pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId, pdpRailId);
        assertEq(_rail(pdpRailId).available, LIFECYCLE_RESERVE_TARGET);
        assertEq(filecoinPayV2.balanceOf(payer, 0), 1 ether - LIFECYCLE_RESERVE_TARGET);
        assertEq(_usdfcBalance(), 0);
    }

    function testCreatesOnSixDecimalTermsWithScaledLock() public {
        CreationSixDecimalToken token = new CreationSixDecimalToken();
        bytes32 termsId = _registerV2Terms(address(token), 6, 2_500_000);
        require(token.transfer(payer, 620_000));
        vm.startPrank(payer);
        token.approve(address(filecoinPayV2), 620_000);
        filecoinPayV2.deposit(address(token), 620_000);
        filecoinPayV2.authorize(address(pdpServiceWithPayments), CREATE_RAIL);
        vm.stopPrank();

        uint256 dataSetId = _create(serviceProvider, _termsPayload(0, termsId, false));

        uint256 pdpRailId = _railId(serviceProvider, address(token), FLAG_CALLBACK | uint64(dataSetId));
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        assertEq(info.pdpRailId, pdpRailId);
        assertEq(info.lifecycleReserveBalance, 500_000);
        assertEq(_rail(pdpRailId).available, 500_000);
        assertEq(filecoinPayV2.balanceOf(payer, uint256(uint160(address(token)))), 120_000);
    }

    function testRevertsWhenDataSetIdReachesCdnNonceFlag() public {
        _fundV2Payer(payer, 10e18);
        FWSSDataSetModule fwss = FWSSDataSetModule(address(pdpServiceWithPayments));
        makeSignaturePass(payer);

        vm.prank(address(mockPDPVerifier));
        vm.expectRevert(abi.encodeWithSelector(FWSSDataSetModule.DataSetIdTooLarge.selector, uint256(1 << 62)));
        fwss.dataSetCreated(1 << 62, serviceProvider, _payload(0, true));

        uint256 largestId = (1 << 62) - 1;
        vm.prank(address(mockPDPVerifier));
        fwss.dataSetCreated(largestId, serviceProvider, _payload(0, true));
        assertEq(
            pdpServiceWithPayments.getDataSet(largestId).cdnRailId,
            _railId(filBeamBeneficiary, address(mockUSDFC), CDN_RAIL_NONCE_FLAG | uint64(largestId))
        );
    }

    function testIsV1RailSplitsCountersFromHashes() public {
        RailVersionHarness harness = new RailVersionHarness(address(filecoinPayV2));
        assertTrue(harness.isV1Rail(1));
        assertTrue(harness.isV1Rail(type(uint64).max));
        assertFalse(harness.isV1Rail(uint256(type(uint64).max) + 1));

        _fundV2Payer(payer, 10e18);
        uint256 dataSetId = _create(serviceProvider, _payload(0, false));
        assertFalse(harness.isV1Rail(pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId));
    }
}
