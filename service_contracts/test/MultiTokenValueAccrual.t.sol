// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {BURN_ADDRESS} from "@fvm-solidity/FVMActors.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Cids} from "@pdp/Cids.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {Dutch} from "@fws-payments/Dutch.sol";
import {FIRST_AUCTION_START_PRICE, FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";

import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {ValueAccrualRouter} from "../src/ValueAccrualRouter.sol";
import {Errors} from "../src/Errors.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {LIFECYCLE_RESERVE_TARGET, calculateStorageSizeBasedRatePerEpoch} from "../src/lib/PriceListUSDFC.sol";
import {
    MAX_USDC_SERVICE_COMMISSION_BPS,
    USDC_ADD_PIECES_BASE_FEE,
    USDC_ADD_PIECES_PER_PIECE_FEE,
    USDC_CREATE_DATA_SET_FEE,
    USDC_DATASET_FEE_PER_MONTH,
    USDC_DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
    USDC_DEFAULT_CDN_LOCKUP_AMOUNT,
    USDC_LIFECYCLE_RESERVE_TARGET,
    USDC_SCHEDULE_PIECE_REMOVALS_FEE,
    USDC_SERVICE_COMMISSION_BPS,
    USDC_STORAGE_PRICE_PER_TIB_PER_MONTH,
    USDC_TERMINATE_FEE
} from "../src/lib/PriceListUSDC.sol";
import {EPOCHS_PER_MONTH, PriceList, storageSizeBasedRatePerEpoch} from "../src/lib/PriceList.sol";
import {MockERC20, MockPDPVerifier, MockUSDC} from "./mocks/SharedMocks.sol";
import {PDPOffering} from "./PDPOffering.sol";

contract MultiTokenValueAccrualTest is MockFVMTest {
    using SafeERC20 for MockERC20;
    using SafeERC20 for MockUSDC;
    using PDPOffering for PDPOffering.Schema;

    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // r
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // s
        uint8(27) // v
    );

    uint256 constant COMMISSION_MAX_BPS = 10000;

    FilecoinWarmStorageService public service;
    FilecoinWarmStorageServiceStateView public viewContract;
    MockPDPVerifier public mockPDPVerifier;
    FilecoinPayV1 public payments;
    MockERC20 public mockUSDFC;
    MockUSDC public mockUSDC;
    ValueAccrualRouter public router;
    ServiceProviderRegistry public serviceProviderRegistry;
    SessionKeyRegistry public sessionKeyRegistry = new SessionKeyRegistry();

    address public client;
    address public serviceProvider;
    address public filBeamController;
    address public filBeamBeneficiary;

    uint256 nextClientDataSetId = 0;
    uint256 nextNonce = 1000;

    function setUp() public override {
        super.setUp(); // etch FVM precompile mocks (burn actor support)

        client = address(0xf1);
        serviceProvider = address(0xf2);
        filBeamController = address(0xf3);
        filBeamBeneficiary = address(0xf4);

        vm.deal(client, 100 ether);
        vm.deal(serviceProvider, 100 ether);

        mockUSDFC = new MockERC20();
        mockUSDC = new MockUSDC();
        mockPDPVerifier = new MockPDPVerifier();

        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry(1);
        bytes memory registryInitData = abi.encodeWithSelector(ServiceProviderRegistry.initialize.selector);
        MyERC1967Proxy registryProxy = new MyERC1967Proxy(address(registryImpl), registryInitData);
        serviceProviderRegistry = ServiceProviderRegistry(address(registryProxy));

        PDPOffering.Schema memory pdpData = PDPOffering.Schema({
            serviceURL: "https://provider.com",
            minPieceSizeInBytes: 1024,
            maxPieceSizeInBytes: 1024 * 1024,
            ipniPiece: true,
            ipniIpfs: false,
            storagePricePerTibPerDay: 1 ether,
            minProvingPeriodInEpochs: 2880,
            location: "US-Central",
            paymentTokenAddress: IERC20(address(0))
        });
        (string[] memory keys, bytes[] memory values) = pdpData.toCapabilities();

        vm.prank(serviceProvider);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            serviceProvider,
            "Service Provider",
            "Service Provider Description",
            ServiceProviderRegistryStorage.ProductType.PDP,
            keys,
            values
        );

        payments = new FilecoinPayV1();
        router = new ValueAccrualRouter(payments);

        FilecoinWarmStorageService serviceImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            mockUSDC,
            address(router),
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry,
            4
        );
        bytes memory initializeData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filBeamController,
            "Filecoin Warm Storage Service",
            "Multi-token warm storage with value accrual"
        );
        MyERC1967Proxy serviceProxy = new MyERC1967Proxy(address(serviceImpl), initializeData);
        service = FilecoinWarmStorageService(address(serviceProxy));
        service.addApprovedProvider(1);

        viewContract = new FilecoinWarmStorageServiceStateView(service);
        service.setViewContract(address(viewContract));

        // Fund the client with both tokens and set up payments approvals + deposits
        mockUSDFC.safeTransfer(client, 10_000e18);
        mockUSDC.safeTransfer(client, 10_000e6);

        vm.startPrank(client);
        payments.setOperatorApproval(mockUSDFC, address(service), true, 1000e18, 1000e18, 365 days);
        mockUSDFC.approve(address(payments), 1000e18);
        payments.deposit(mockUSDFC, client, 1000e18);

        payments.setOperatorApproval(mockUSDC, address(service), true, 1000e6, 1000e6, 365 days);
        mockUSDC.approve(address(payments), 1000e6);
        payments.deposit(mockUSDC, client, 1000e6);
        vm.stopPrank();
    }

    // ==================== Helpers ====================

    function makeSignaturePass(address signer) public {
        vm.mockCall(address(0x01), bytes(hex""), abi.encode(signer));
    }

    function createDataSet(string[] memory metadataKeys, string[] memory metadataValues) internal returns (uint256) {
        bytes memory encodedData =
            abi.encode(client, nextClientDataSetId++, metadataKeys, metadataValues, FAKE_SIGNATURE);
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        return mockPDPVerifier.createDataSet(service, encodedData);
    }

    function usdcMetadata() internal pure returns (string[] memory keys, string[] memory values) {
        keys = new string[](1);
        values = new string[](1);
        keys[0] = "paymentToken";
        values[0] = "USDC";
    }

    function noMetadata() internal pure returns (string[] memory keys, string[] memory values) {
        keys = new string[](0);
        values = new string[](0);
    }

    /// Adds a single 1 TiB piece (height 35 => 2**35 leaves => 2**40 raw bytes)
    function addOneTiBPiece(uint256 dataSetId) internal {
        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256(abi.encodePacked("1tib_piece", dataSetId)));
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        makeSignaturePass(client);
        mockPDPVerifier.addPieces(service, dataSetId, 0, pieceData, nextNonce++, FAKE_SIGNATURE, emptyKeys, emptyValues);
    }

    function networkFee(uint256 amount) internal pure returns (uint256) {
        return (amount + 199) / 200; // ceil(amount * 1/200), mirrors FilecoinPayV1
    }

    function commissionOn(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return ((amount - networkFee(amount)) * bps) / COMMISSION_MAX_BPS;
    }

    // ==================== Token selection ====================

    function testUSDCDataSetCreatesUSDCRailWithCommission() public {
        (string[] memory keys, string[] memory values) = usdcMetadata();

        vm.expectEmit(true, false, false, true);
        emit FilecoinWarmStorageService.PaymentTokenSelected(1, mockUSDC, USDC_SERVICE_COMMISSION_BPS);
        uint256 dataSetId = createDataSet(keys, values);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertEq(address(pdpRail.token), address(mockUSDC), "PDP rail should be denominated in USDC");
        assertEq(pdpRail.commissionRateBps, USDC_SERVICE_COMMISSION_BPS, "NVAF commission should be locked in");
        assertEq(pdpRail.serviceFeeRecipient, address(router), "commission should route to the ValueAccrualRouter");
        assertEq(pdpRail.lockupFixed, USDC_LIFECYCLE_RESERVE_TARGET, "lifecycle reserve in 6-decimal units");

        assertEq(info.commissionBps, USDC_SERVICE_COMMISSION_BPS, "data set should record the commission");
        assertEq(address(viewContract.getDataSetPaymentToken(dataSetId)), address(mockUSDC), "stored payment token");
    }

    function testUSDCDataSetWithCDNAppliesCommissionToAllRails() public {
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "paymentToken";
        values[0] = "USDC";
        keys[1] = "withCDN";
        values[1] = "true";

        uint256 dataSetId = createDataSet(keys, values);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        FilecoinPayV1.RailView memory cacheMissRail = payments.getRail(info.cacheMissRailId);
        assertEq(address(cacheMissRail.token), address(mockUSDC), "cache-miss rail in USDC");
        assertEq(cacheMissRail.commissionRateBps, USDC_SERVICE_COMMISSION_BPS, "NVAF on cache-miss rail");
        assertEq(cacheMissRail.serviceFeeRecipient, address(router), "router on cache-miss rail");

        FilecoinPayV1.RailView memory cdnRail = payments.getRail(info.cdnRailId);
        assertEq(address(cdnRail.token), address(mockUSDC), "CDN rail in USDC");
        assertEq(cdnRail.commissionRateBps, USDC_SERVICE_COMMISSION_BPS, "NVAF on CDN rail");
        assertEq(cdnRail.serviceFeeRecipient, address(router), "router on CDN rail");
    }

    function testUSDFCDataSetUnchangedByDefault() public {
        (string[] memory keys, string[] memory values) = noMetadata();
        uint256 dataSetId = createDataSet(keys, values);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertEq(address(pdpRail.token), address(mockUSDFC), "default rail stays USDFC");
        assertEq(pdpRail.commissionRateBps, 0, "USDFC rails carry no commission");
        assertEq(pdpRail.lockupFixed, LIFECYCLE_RESERVE_TARGET, "18-decimal lifecycle reserve");
        assertEq(info.commissionBps, 0, "no commission recorded");
        assertEq(address(viewContract.getDataSetPaymentToken(dataSetId)), address(mockUSDFC), "stored token is USDFC");
    }

    function testExplicitUSDFCKeywordSelectsDefault() public {
        string[] memory keys = new string[](1);
        string[] memory values = new string[](1);
        keys[0] = "paymentToken";
        values[0] = "USDFC";
        uint256 dataSetId = createDataSet(keys, values);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        assertEq(address(pdpRail.token), address(mockUSDFC), "explicit USDFC keyword");
        assertEq(pdpRail.commissionRateBps, 0, "no commission");
    }

    function testUnknownPaymentTokenReverts() public {
        string[] memory keys = new string[](1);
        string[] memory values = new string[](1);
        keys[0] = "paymentToken";
        values[0] = "DOGE";

        bytes memory encodedData = abi.encode(client, nextClientDataSetId++, keys, values, FAKE_SIGNATURE);
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedPaymentToken.selector, "DOGE"));
        mockPDPVerifier.createDataSet(service, encodedData);
    }

    function testUSDCRevertsWhenDisabled() public {
        // Deployment without a USDC instance
        FilecoinWarmStorageService disabledImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            MockERC20(address(0)), // USDC disabled
            address(0), // no ValueAccrualRouter
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry,
            4
        );
        bytes memory initializeData = abi.encodeWithSelector(
            FilecoinWarmStorageService.initialize.selector,
            uint64(2880),
            uint256(60),
            filBeamController,
            "USDFC-only deployment",
            "No USDC configured"
        );
        FilecoinWarmStorageService disabledService =
            FilecoinWarmStorageService(address(new MyERC1967Proxy(address(disabledImpl), initializeData)));
        disabledService.addApprovedProvider(1);

        (string[] memory keys, string[] memory values) = usdcMetadata();
        bytes memory encodedData = abi.encode(client, nextClientDataSetId++, keys, values, FAKE_SIGNATURE);
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedPaymentToken.selector, "USDC"));
        mockPDPVerifier.createDataSet(disabledService, encodedData);
    }

    // ==================== Constructor validation ====================

    function testConstructorRequiresRouterWhenUSDCConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.ValueAccrualRouter));
        new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            mockUSDC,
            address(0), // missing router
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry,
            4
        );
    }

    function testConstructorRejectsWrongUSDCDecimals() public {
        MockERC20 eighteenDecimalToken = new MockERC20();
        vm.expectRevert();
        new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            eighteenDecimalToken, // 18 decimals, must be 6
            address(router),
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry,
            4
        );
    }

    // ==================== Commission staging ====================

    function testInitializeSetsDefaultCommission() public view {
        assertEq(viewContract.getUSDCCommissionBps(), USDC_SERVICE_COMMISSION_BPS, "default NVAF");
    }

    function testSetUSDCCommissionBpsAppliesToNewDataSetsOnly() public {
        (string[] memory keys, string[] memory values) = usdcMetadata();
        uint256 before = createDataSet(keys, values);

        vm.expectEmit(false, false, false, true);
        emit FilecoinWarmStorageService.USDCCommissionBpsUpdated(USDC_SERVICE_COMMISSION_BPS, 150);
        service.setUSDCCommissionBps(150);
        assertEq(viewContract.getUSDCCommissionBps(), 150, "staged commission");

        uint256 afterChange = createDataSet(keys, values);

        FilecoinWarmStorageService.DataSetInfoView memory beforeInfo = viewContract.getDataSet(before);
        FilecoinWarmStorageService.DataSetInfoView memory afterInfo = viewContract.getDataSet(afterChange);
        assertEq(
            payments.getRail(beforeInfo.pdpRailId).commissionRateBps,
            USDC_SERVICE_COMMISSION_BPS,
            "existing rail keeps its commission"
        );
        assertEq(payments.getRail(afterInfo.pdpRailId).commissionRateBps, 150, "new rail uses the staged commission");
    }

    function testSetUSDCCommissionBpsRejectsAboveCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.CommissionExceedsMaximum.selector,
                Errors.CommissionType.Service,
                MAX_USDC_SERVICE_COMMISSION_BPS,
                MAX_USDC_SERVICE_COMMISSION_BPS + 1
            )
        );
        service.setUSDCCommissionBps(MAX_USDC_SERVICE_COMMISSION_BPS + 1);
    }

    function testSetUSDCCommissionBpsOnlyOwner() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, client));
        service.setUSDCCommissionBps(100);
    }

    // ==================== Pricing ====================

    function testUSDCStorageRateFor1TiB() public {
        (string[] memory keys, string[] memory values) = usdcMetadata();
        uint256 dataSetId = createDataSet(keys, values);
        addOneTiBPiece(dataSetId);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);

        uint256 expectedRate = usdcRatePerEpochFor1TiB();
        assertEq(pdpRail.paymentRate, expectedRate, "1 TiB USDC rate per epoch");
        // floor(127/128 * 5_102_041 / 86_400) = 58 size-based + 1 dataset-fee floor
        // ($5/TiB/month base grossed up for the NVAF; 127/128 is the Fr32 raw-size factor)
        assertEq(expectedRate, 59, "expected 59 microUSDC per epoch for 1 TiB");
    }

    /// The PDP rail rate for the 1 TiB test piece under the USDC price list
    function usdcRatePerEpochFor1TiB() internal view returns (uint256) {
        return storageSizeBasedRatePerEpoch(viewContract.getPriceListUSDC(), Cids.leafCountToRawSize(2 ** 35));
    }

    function testGetPriceListUSDCView() public view {
        PriceList memory pl = viewContract.getPriceListUSDC();
        assertEq(address(pl.token), address(mockUSDC), "token populated from immutable");
        assertEq(pl.rates.storagePerTibPerMonth, USDC_STORAGE_PRICE_PER_TIB_PER_MONTH, "grossed-up storage price");
        assertEq(pl.rates.datasetFeePerMonth, USDC_DATASET_FEE_PER_MONTH, "dataset fee at quantization floor");
        assertEq(pl.fees.createDataSetFee, USDC_CREATE_DATA_SET_FEE, "grossed-up create fee");
        assertEq(pl.lockups.lifecycleReserveTarget, USDC_LIFECYCLE_RESERVE_TARGET, "reserve target");

        // The USDFC list is untouched
        PriceList memory usdfcList = viewContract.getPriceList();
        assertEq(address(usdfcList.token), address(mockUSDFC), "USDFC list token");
    }

    // ==================== Commission flow on settlement ====================

    /// Drives a USDC data set through creation, piece-add, a proven period, and settlement;
    /// returns the rail and amounts observed.
    function _settleProvenUSDCPeriod() internal returns (uint256 dataSetId, uint256 settled, uint256 commission) {
        (string[] memory keys, string[] memory values) = usdcMetadata();
        dataSetId = createDataSet(keys, values);
        addOneTiBPiece(dataSetId);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // One-time op fees (create + addPieces) were paid at piecesAdded time; their commission
        // is already credited to the router.
        uint256 opFees = USDC_CREATE_DATA_SET_FEE + USDC_ADD_PIECES_BASE_FEE + USDC_ADD_PIECES_PER_PIECE_FEE;
        uint256 opFeeCommission = commissionOn(opFees, USDC_SERVICE_COMMISSION_BPS);
        (uint256 routerFunds,,,) = payments.accounts(mockUSDC, address(router));
        assertEq(routerFunds, opFeeCommission, "op-fee commission accrues to router at piecesAdded");

        // Start proving, prove the first period, then settle past its deadline
        uint256 challengeEpoch = block.number + 2880 - 30;
        mockPDPVerifier.nextProvingPeriod(service, dataSetId, challengeEpoch, 2 ** 35, "");

        uint256 deadline = viewContract.provingDeadline(dataSetId);
        vm.roll(deadline - 30);
        vm.prank(address(mockPDPVerifier));
        service.possessionProven(dataSetId, 2 ** 35, 12345, 5);

        vm.roll(deadline + 1);
        (uint256 totalSettledAmount,, uint256 totalOperatorCommission,,,) =
            payments.settleRail(info.pdpRailId, deadline);

        return (dataSetId, totalSettledAmount, totalOperatorCommission);
    }

    function testUSDCSettlementSkimsCommissionToRouter() public {
        (, uint256 settled, uint256 commission) = _settleProvenUSDCPeriod();

        // One full proven proving period at the 1 TiB USDC rate
        assertEq(settled, usdcRatePerEpochFor1TiB() * 2880, "settled amount for one proven period");
        assertEq(commission, commissionOn(settled, USDC_SERVICE_COMMISSION_BPS), "2% NVAF after network fee");

        // Router account holds the op-fee commission (asserted inside the helper) plus the
        // streaming-settlement commission
        uint256 opFees = USDC_CREATE_DATA_SET_FEE + USDC_ADD_PIECES_BASE_FEE + USDC_ADD_PIECES_PER_PIECE_FEE;
        (uint256 routerFunds,,,) = payments.accounts(mockUSDC, address(router));
        assertEq(
            routerFunds,
            commissionOn(opFees, USDC_SERVICE_COMMISSION_BPS) + commission,
            "router account holds op-fee and settlement commission"
        );
    }

    function testUSDFCSettlementHasNoCommission() public {
        (string[] memory keys, string[] memory values) = noMetadata();
        uint256 dataSetId = createDataSet(keys, values);
        addOneTiBPiece(dataSetId);

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        uint256 challengeEpoch = block.number + 2880 - 30;
        mockPDPVerifier.nextProvingPeriod(service, dataSetId, challengeEpoch, 2 ** 35, "");
        uint256 deadline = viewContract.provingDeadline(dataSetId);
        vm.roll(deadline - 30);
        vm.prank(address(mockPDPVerifier));
        service.possessionProven(dataSetId, 2 ** 35, 12345, 5);
        vm.roll(deadline + 1);

        (uint256 settled,, uint256 commission,,,) = payments.settleRail(info.pdpRailId, deadline);
        assertGt(settled, 0, "USDFC settlement pays out");
        assertEq(commission, 0, "USDFC rails carry no commission");
    }

    // ==================== ValueAccrualRouter ====================

    function testRouterCollectPullsCommission() public {
        _settleProvenUSDCPeriod();

        (uint256 accrued,,,) = payments.accounts(mockUSDC, address(router));
        assertGt(accrued, 0, "commission accrued in payments");

        vm.expectEmit(true, false, false, true);
        emit ValueAccrualRouter.CommissionCollected(mockUSDC, accrued);
        uint256 collected = router.collect(mockUSDC);

        assertEq(collected, accrued, "collect returns the pulled amount");
        assertEq(mockUSDC.balanceOf(address(router)), accrued, "router holds the tokens");
        (uint256 remaining,,,) = payments.accounts(mockUSDC, address(router));
        assertEq(remaining, 0, "payments account drained");

        (uint88 startPrice,) = router.auctionInfo(mockUSDC);
        assertEq(uint256(startPrice), uint256(FIRST_AUCTION_START_PRICE), "auction armed at first price");
    }

    function testRouterBurnForCommissionBurnsFILAndPaysTokens() public {
        _settleProvenUSDCPeriod();
        router.collect(mockUSDC);
        uint256 available = mockUSDC.balanceOf(address(router));

        address buyer = address(0xbeef);
        vm.deal(buyer, 1 ether);
        uint256 burnBalanceBefore = BURN_ADDRESS.balance;

        // Underpaying the auction price reverts
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InsufficientNativeTokenForBurn.selector, FIRST_AUCTION_START_PRICE - 1, FIRST_AUCTION_START_PRICE
            )
        );
        router.burnForCommission{value: FIRST_AUCTION_START_PRICE - 1}(mockUSDC, buyer, available);

        // Requesting more than available reverts
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Errors.CommissionExceedsAvailable.selector, available + 1, available));
        router.burnForCommission{value: FIRST_AUCTION_START_PRICE}(mockUSDC, buyer, available + 1);

        // Paying the price takes the lot and burns the FIL
        vm.prank(buyer);
        router.burnForCommission{value: FIRST_AUCTION_START_PRICE}(mockUSDC, buyer, available);

        assertEq(mockUSDC.balanceOf(buyer), available, "buyer receives the commission tokens");
        assertEq(mockUSDC.balanceOf(address(router)), 0, "router emptied");
        assertEq(BURN_ADDRESS.balance - burnBalanceBefore, FIRST_AUCTION_START_PRICE, "FIL destroyed at the burn actor");

        (uint88 startPrice,) = router.auctionInfo(mockUSDC);
        assertEq(
            uint256(startPrice), uint256(FIRST_AUCTION_START_PRICE) * Dutch.RESET_FACTOR, "auction price reset to 4x"
        );
    }

    function testRouterBurnCollectsImplicitly() public {
        // burnForCommission pulls pending commission from payments without a prior collect()
        _settleProvenUSDCPeriod();
        (uint256 accrued,,,) = payments.accounts(mockUSDC, address(router));

        address buyer = address(0xbeef);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        router.burnForCommission{value: FIRST_AUCTION_START_PRICE}(mockUSDC, buyer, accrued);
        assertEq(mockUSDC.balanceOf(buyer), accrued, "implicit collect during burn");
    }

    function testRouterAuctionPriceDecays() public {
        _settleProvenUSDCPeriod();
        router.collect(mockUSDC);

        uint256 priceAtStart = router.currentPrice(mockUSDC);
        assertEq(priceAtStart, FIRST_AUCTION_START_PRICE, "starts at first auction price");

        vm.warp(block.timestamp + 3.5 days);
        uint256 priceAfterHalving = router.currentPrice(mockUSDC);
        assertEq(priceAfterHalving, FIRST_AUCTION_START_PRICE / 2, "halves per 3.5 days");

        // A fully decayed auction clears at zero, and the next collect re-arms it
        vm.warp(block.timestamp + 365 days);
        assertEq(router.currentPrice(mockUSDC), 0, "fully decayed");

        address buyer = address(0xbeef);
        uint256 available = mockUSDC.balanceOf(address(router));
        vm.prank(buyer);
        router.burnForCommission(mockUSDC, buyer, available);
        assertEq(mockUSDC.balanceOf(buyer), available, "free claim after full decay");
    }

    function testRouterConstructorRejectsZeroPayments() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, Errors.AddressField.FilecoinPayV1));
        new ValueAccrualRouter(FilecoinPayV1(address(0)));
    }

    // ==================== Legacy data sets and token-drift guard ====================

    function _paymentTokenSlot(uint256 dataSetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(dataSetId, uint256(23))); // DATA_SET_PAYMENT_TOKEN_SLOT
    }

    function testLegacyDataSetWithoutStoredTokenResolvesToUSDFC() public {
        // Simulate a data set created before multi-token support: stored payment token is zero
        (string[] memory keys, string[] memory values) = noMetadata();
        uint256 dataSetId = createDataSet(keys, values);
        vm.store(address(service), _paymentTokenSlot(dataSetId), bytes32(0));

        assertEq(
            address(viewContract.getDataSetPaymentToken(dataSetId)),
            address(mockUSDFC),
            "legacy data set resolves to USDFC"
        );

        // Fee paths use USDFC (18-decimal) pricing: adding a 1 TiB piece sets the USDFC rate
        addOneTiBPiece(dataSetId);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        FilecoinPayV1.RailView memory pdpRail = payments.getRail(info.pdpRailId);
        uint256 expectedRate = calculateStorageSizeBasedRatePerEpoch(Cids.leafCountToRawSize(2 ** 35));
        assertEq(pdpRail.paymentRate, expectedRate, "legacy data set streams at USDFC rates");
        (uint256 routerFunds,,,) = payments.accounts(mockUSDFC, address(router));
        assertEq(routerFunds, 0, "no commission accrues on legacy USDFC data sets");
    }

    function testUnknownStoredRailTokenRevertsLoudly() public {
        // Simulate upgrade drift: the stored token matches neither token immutable
        (string[] memory keys, string[] memory values) = usdcMetadata();
        uint256 dataSetId = createDataSet(keys, values);
        address strayToken = address(0xdead);
        vm.store(address(service), _paymentTokenSlot(dataSetId), bytes32(uint256(uint160(strayToken))));

        Cids.Cid[] memory pieceData = new Cids.Cid[](1);
        pieceData[0] = Cids.CommPv2FromDigest(0, 35, keccak256("drift_piece"));
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        makeSignaturePass(client);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownRailToken.selector, strayToken));
        mockPDPVerifier.addPieces(service, dataSetId, 0, pieceData, nextNonce++, FAKE_SIGNATURE, emptyKeys, emptyValues);
    }

    // ==================== USDC fee paths beyond piece adds ====================

    function testUSDCConsentTerminationChargesTerminateFeeAndCommission() public {
        (string[] memory keys, string[] memory values) = usdcMetadata();
        uint256 dataSetId = createDataSet(keys, values);

        // Consent termination (SP submits with payer signature) charges the terminate fee and
        // flushes all pending one-time fees immediately
        makeSignaturePass(client);
        vm.prank(serviceProvider);
        service.terminateService(dataSetId, abi.encode(FAKE_SIGNATURE));

        uint256 opFees = USDC_CREATE_DATA_SET_FEE + USDC_TERMINATE_FEE;
        (uint256 routerFunds,,,) = payments.accounts(mockUSDC, address(router));
        assertEq(
            routerFunds,
            commissionOn(opFees, USDC_SERVICE_COMMISSION_BPS),
            "NVAF skimmed from USDC create+terminate fees"
        );

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertGt(info.pdpEndEpoch, 0, "PDP rail terminated");
    }

    function testUSDCSchedulePieceRemovalsChargesUSDCFee() public {
        (string[] memory keys, string[] memory values) = usdcMetadata();
        uint256 dataSetId = createDataSet(keys, values);
        addOneTiBPiece(dataSetId); // flushes creation + add fees

        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        makeSignaturePass(client);
        mockPDPVerifier.piecesScheduledRemove(dataSetId, pieceIds, address(service), abi.encode(FAKE_SIGNATURE));

        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);
        assertEq(
            uint256(info.pendingOneTimePayments),
            USDC_SCHEDULE_PIECE_REMOVALS_FEE,
            "pending fee is the 6-decimal removal-scheduling fee"
        );
    }

    // ==================== USDC CDN rails: lockups, top-up, settlement ====================

    function testUSDCCDNLockupAmountsAndTopUp() public {
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "paymentToken";
        values[0] = "USDC";
        keys[1] = "withCDN";
        values[1] = "true";
        uint256 dataSetId = createDataSet(keys, values);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        assertEq(
            payments.getRail(info.cdnRailId).lockupFixed,
            USDC_DEFAULT_CDN_LOCKUP_AMOUNT,
            "6-decimal CDN lockup at creation"
        );
        assertEq(
            payments.getRail(info.cacheMissRailId).lockupFixed,
            USDC_DEFAULT_CACHE_MISS_LOCKUP_AMOUNT,
            "6-decimal cache-miss lockup at creation"
        );

        vm.prank(client);
        service.topUpCDNPaymentRails(dataSetId, 500_000, 200_000);
        assertEq(
            payments.getRail(info.cdnRailId).lockupFixed,
            USDC_DEFAULT_CDN_LOCKUP_AMOUNT + 500_000,
            "CDN lockup topped up in 6-decimal units"
        );
        assertEq(
            payments.getRail(info.cacheMissRailId).lockupFixed,
            USDC_DEFAULT_CACHE_MISS_LOCKUP_AMOUNT + 200_000,
            "cache-miss lockup topped up in 6-decimal units"
        );
    }

    function testUSDCFilBeamSettlementSkimsCommission() public {
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        keys[0] = "paymentToken";
        values[0] = "USDC";
        keys[1] = "withCDN";
        values[1] = "true";
        uint256 dataSetId = createDataSet(keys, values);

        (uint256 routerBefore,,,) = payments.accounts(mockUSDC, address(router));
        (uint256 filBeamBefore,,,) = payments.accounts(mockUSDC, filBeamBeneficiary);

        uint256 cdnAmount = 400_000; // microUSDC, within the CDN lockup
        uint256 cacheMissAmount = 100_000; // within the cache-miss lockup
        vm.prank(filBeamController);
        service.settleFilBeamPaymentRails(dataSetId, cdnAmount, cacheMissAmount);

        (uint256 routerAfter,,,) = payments.accounts(mockUSDC, address(router));
        assertEq(
            routerAfter - routerBefore,
            commissionOn(cdnAmount, USDC_SERVICE_COMMISSION_BPS)
                + commissionOn(cacheMissAmount, USDC_SERVICE_COMMISSION_BPS),
            "NVAF skimmed from both FilBeam settlements"
        );

        (uint256 filBeamAfter,,,) = payments.accounts(mockUSDC, filBeamBeneficiary);
        assertEq(
            filBeamAfter - filBeamBefore,
            cdnAmount - networkFee(cdnAmount) - commissionOn(cdnAmount, USDC_SERVICE_COMMISSION_BPS),
            "FilBeam beneficiary nets the CDN amount less network fee and NVAF"
        );
    }

    // ==================== USDC lifecycle close-out ====================

    function testUSDCDataSetDeletionReturnsReserveAndClearsToken() public {
        (string[] memory keys, string[] memory values) = usdcMetadata();
        uint256 dataSetId = createDataSet(keys, values);
        FilecoinWarmStorageService.DataSetInfoView memory info = viewContract.getDataSet(dataSetId);

        // Payer-initiated termination flushes the creation fee as a one-time payment
        vm.prank(client);
        service.terminateService(dataSetId);

        FilecoinWarmStorageService.DataSetInfoView memory terminated = viewContract.getDataSet(dataSetId);
        vm.roll(terminated.pdpEndEpoch + 1);
        payments.settleRail(info.pdpRailId, terminated.pdpEndEpoch);

        vm.prank(serviceProvider);
        mockPDPVerifier.deleteDataSet(service, dataSetId, bytes(""));

        // Stored token cleaned up alongside the rest of the data set state
        assertEq(uint256(service.extsload(_paymentTokenSlot(dataSetId))), 0, "dataSetPaymentToken cleared on deletion");

        // The payer spent exactly the creation fee; reserve and rate lockup fully released
        (, uint256 funds, uint256 available,) = payments.getAccountInfoIfSettled(mockUSDC, client);
        assertEq(funds, 1000e6 - USDC_CREATE_DATA_SET_FEE, "payer recovers everything but the creation fee");
        assertEq(available, funds, "no residual lockup after finalization");
    }

    // ==================== Funding requirements ====================

    function testUSDCCreateRevertsWithExactRequiredLockup() public {
        address poorClient = address(0xf9);
        mockUSDC.safeTransfer(poorClient, 1e6);
        vm.startPrank(poorClient);
        payments.setOperatorApproval(mockUSDC, address(service), true, 1000e6, 1000e6, 365 days);
        mockUSDC.approve(address(payments), 1e6);
        payments.deposit(mockUSDC, poorClient, 100_000); // below the 186_400 requirement
        vm.stopPrank();

        // requiredLockup = dataset fee for the default lockup period + lifecycle reserve
        uint256 requiredLockup =
            (USDC_DATASET_FEE_PER_MONTH * 86_400) / EPOCHS_PER_MONTH + USDC_LIFECYCLE_RESERVE_TARGET;

        (string[] memory keys, string[] memory values) = usdcMetadata();
        bytes memory encodedData = abi.encode(poorClient, nextClientDataSetId++, keys, values, FAKE_SIGNATURE);
        makeSignaturePass(poorClient);
        vm.prank(serviceProvider);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InsufficientLockupFunds.selector, poorClient, requiredLockup, 100_000)
        );
        mockPDPVerifier.createDataSet(service, encodedData);
    }

    // ==================== Upgrade path ====================

    function testMigrateBackfillsCommissionFromPreUpgradeState() public {
        // Simulate a proxy upgraded from the single-token implementation: slot 24 was never
        // initialized (initialize() in setUp wrote 200; zero it to reproduce the upgrade state)
        vm.store(address(service), bytes32(uint256(24)), bytes32(0)); // USDC_COMMISSION_BPS_SLOT
        assertEq(viewContract.getUSDCCommissionBps(), 0, "pre-upgrade state has no staged NVAF");

        FilecoinWarmStorageService newImpl = new FilecoinWarmStorageService(
            address(mockPDPVerifier),
            address(payments),
            mockUSDFC,
            mockUSDC,
            address(router),
            filBeamBeneficiary,
            serviceProviderRegistry,
            sessionKeyRegistry,
            5
        );

        FilecoinWarmStorageService.PlannedUpgrade memory plan;
        plan.nextImplementation = address(newImpl);
        plan.afterEpoch = uint96(vm.getBlockNumber()) + 100;
        service.announcePlannedUpgrade(plan);
        vm.roll(plan.afterEpoch);

        vm.expectEmit(false, false, false, true, address(service));
        emit FilecoinWarmStorageService.USDCCommissionBpsUpdated(0, USDC_SERVICE_COMMISSION_BPS);
        service.upgradeToAndCall(
            address(newImpl), abi.encodeWithSelector(FilecoinWarmStorageService.migrate.selector, address(0))
        );

        assertEq(
            viewContract.getUSDCCommissionBps(),
            USDC_SERVICE_COMMISSION_BPS,
            "migrate backfills the default NVAF from the pre-upgrade zero state"
        );
    }
}
