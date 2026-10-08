// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Cids} from "@pdp/Cids.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {SignatureVerificationLib} from "../src/lib/SignatureVerificationLib.sol";
import {DATA_SET_INFO_SLOT} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {StorageTerms} from "../src/lib/StorageTerms.sol";
import {Errors} from "../src/Errors.sol";
import {MockERC20, MockPDPVerifier} from "./mocks/SharedMocks.sol";
import {PDPOffering} from "./PDPOffering.sol";

contract SixDecimalToken is ERC20 {
    constructor() ERC20("Six Decimal USD", "SIX") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract StorageTermsTest is MockFVMTest {
    using PDPOffering for PDPOffering.Schema;
    uint256 internal constant PAYER_KEY = 0xA11CE;
    FilecoinWarmStorageService internal service;
    FilecoinWarmStorageServiceStateView internal stateView;
    FilecoinPayV1 internal payments;
    MockERC20 internal usdfc;
    MockPDPVerifier internal verifier;
    ServiceProviderRegistry internal registry;
    SessionKeyRegistry internal sessions;
    SixDecimalToken internal six;
    address internal payer;
    address internal provider = address(0x1001);
    address internal payee = address(0x1002);

    event StorageTermsRegistered(
        bytes32 indexed storageTermsId, address token, uint8 tokenDecimals, uint256 pricePerTiBPerMonth, bytes32 salt
    );

    function setUp() public override {
        super.setUp();
        payer = vm.addr(PAYER_KEY);
        usdfc = new MockERC20();
        verifier = new MockPDPVerifier();
        sessions = new SessionKeyRegistry();
        six = new SixDecimalToken();
        ServiceProviderRegistry impl = new ServiceProviderRegistry(1);
        registry = ServiceProviderRegistry(
            address(new MyERC1967Proxy(address(impl), abi.encodeCall(ServiceProviderRegistry.initialize, ())))
        );
        payments = new FilecoinPayV1();
        FilecoinWarmStorageService serviceImpl = new FilecoinWarmStorageService(
            address(verifier), address(payments), usdfc, address(0xBEEF), registry, sessions, 1
        );
        service = FilecoinWarmStorageService(
            address(
                new MyERC1967Proxy(
                    address(serviceImpl),
                    abi.encodeCall(FilecoinWarmStorageService.initialize, (uint64(2880), uint256(60), address(0xCAFE)))
                )
            )
        );
        stateView = new FilecoinWarmStorageServiceStateView(service);
        PDPOffering.Schema memory offering = PDPOffering.Schema(
            "https://provider.example", 1024, 1 << 40, true, false, 1 ether, 2880, "US", IERC20(address(0))
        );
        (string[] memory keys, bytes[] memory values) = offering.toCapabilities();
        vm.deal(provider, 5 ether);
        vm.prank(provider);
        registry.registerProvider{value: 5 ether}(
            payee, "Provider", "Storage", ServiceProviderRegistryStorage.ProductType.PDP, keys, values
        );
        service.addApprovedProvider(1);
        usdfc.transfer(payer, 1000e18);
        six.transfer(payer, 1000e6);
        _fund(usdfc, 1000e18);
        _fund(six, 1000e6);
    }

    function _fund(IERC20 token, uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(address(payments), amount);
        payments.deposit(token, payer, amount);
        payments.setOperatorApproval(token, address(service), true, amount, amount, 86400);
        vm.stopPrank();
    }

    function _signature(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FilecoinWarmStorageService"),
                keccak256("1"),
                block.chainid,
                address(service)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _payload(uint256 nonce, bytes32 id, bool cdn, uint256 key) internal view returns (bytes memory) {
        string[] memory keys = new string[](cdn ? 1 : 0);
        string[] memory values = new string[](cdn ? 1 : 0);
        if (cdn) {
            keys[0] = "withCDN";
            values[0] = "true";
        }
        bytes32 structHash = id == bytes32(0)
            ? SignatureVerificationLib.createDataSetStructHash(nonce, payee, keys, values)
            : SignatureVerificationLib.createDataSetWithStorageTermsStructHash(nonce, payee, keys, values, id);
        bytes memory signature = _signature(key, structHash);
        return id == bytes32(0)
            ? abi.encode(payer, nonce, keys, values, signature)
            : abi.encode(payer, nonce, keys, values, signature, id);
    }

    function _create(uint256 nonce, bytes32 id) internal returns (uint256) {
        bytes memory payload = _payload(nonce, id, false, PAYER_KEY);
        vm.prank(provider);
        return verifier.createDataSet(service, payload);
    }

    function _defaultTerms() internal view returns (StorageTerms memory terms) {
        (terms,) = service.getStorageTerms(service.legacyStorageTermsId());
    }

    function _sixTerms() internal view returns (StorageTerms memory) {
        return StorageTerms(address(six), 6, 5e6, bytes32(uint256(6)));
    }

    function testOnlyOwnerCanRegisterAndDisable() public {
        StorageTerms memory terms = _defaultTerms();
        terms.salt = bytes32(uint256(1));
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        service.registerStorageTerms(terms);
        bytes32 id = service.registerStorageTerms(terms);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        service.disableStorageTerms(id);
    }

    function testRegistrationRejectsBadMetadataAndPrice() public {
        StorageTerms memory terms = _defaultTerms();
        terms.tokenDecimals = 19;
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedTokenDecimals.selector, 19));
        service.registerStorageTerms(terms);
        terms = _sixTerms();
        terms.pricePerTiBPerMonth = 2_499_999;
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StoragePriceBelowDefault.selector, uint256(2_499_999), uint256(2_500_000))
        );
        service.registerStorageTerms(terms);
        terms.pricePerTiBPerMonth = 2_500_000;
        terms.tokenDecimals = 18;
        vm.expectRevert(
            abi.encodeWithSelector(Errors.TokenDecimalsMismatch.selector, address(six), uint8(18), uint8(6))
        );
        service.registerStorageTerms(terms);
    }

    function testSaltsSeparateTermsAndReregistrationEnables() public {
        StorageTerms memory a = _defaultTerms();
        a.salt = bytes32(uint256(1));
        bytes32 aId = service.registerStorageTerms(a);
        StorageTerms memory b = StorageTerms(a.token, a.tokenDecimals, a.pricePerTiBPerMonth, bytes32(uint256(2)));
        bytes32 bId = service.registerStorageTerms(b);
        assertTrue(aId != bId);
        uint256 dataset = _create(0, aId);
        service.disableStorageTerms(aId);
        (, bool enabled) = service.getStorageTerms(aId);
        assertFalse(enabled);
        bytes memory payload = _payload(1, aId, false, PAYER_KEY);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(Errors.StorageTermsDisabled.selector, aId));
        verifier.createDataSet(service, payload);
        vm.expectEmit(true, false, false, true, address(service));
        emit StorageTermsRegistered(aId, a.token, a.tokenDecimals, a.pricePerTiBPerMonth, a.salt);
        assertEq(service.registerStorageTerms(a), aId);
        (, enabled) = service.getStorageTerms(aId);
        assertTrue(enabled);
        uint256 second = _create(1, aId);
        assertEq(service.getDataSetStorageTermsId(dataset), aId);
        assertEq(service.getDataSetStorageTermsId(second), aId);
    }

    function testSignatureRejectsSubstitutedTerms() public {
        StorageTerms memory a = _defaultTerms();
        a.salt = bytes32(uint256(1));
        bytes32 aId = service.registerStorageTerms(a);
        a.salt = bytes32(uint256(2));
        bytes32 bId = service.registerStorageTerms(a);
        bytes memory payload = _payload(0, aId, false, PAYER_KEY);
        assembly ("memory-safe") { mstore(add(payload, 192), bId) }
        vm.prank(provider);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        verifier.createDataSet(service, payload);
        assertEq(_create(0, aId), 1, "failed request must not consume nonce or dataset ID");
    }

    function testNewSessionPermissionDoesNotAcceptOldPermission() public {
        uint256 sessionKey = 0xB0B;
        address session = vm.addr(sessionKey);
        bytes32[] memory permissions = new bytes32[](1);
        permissions[0] = SignatureVerificationLib.CREATE_DATA_SET_TYPEHASH;
        vm.prank(payer);
        sessions.login(session, type(uint256).max, permissions, "old-only");
        bytes32 id = service.legacyStorageTermsId();
        bytes memory payload = _payload(0, id, false, sessionKey);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, payer, session));
        verifier.createDataSet(service, payload);
        permissions[0] = SignatureVerificationLib.CREATE_DATA_SET_WITH_STORAGE_TERMS_TYPEHASH;
        vm.prank(payer);
        sessions.login(session, type(uint256).max, permissions, "new");
        vm.prank(provider);
        uint256 dataset = verifier.createDataSet(service, payload);
        assertEq(service.getDataSetStorageTermsId(dataset), id);
    }

    function testSixDecimalPaymentsContinueAfterDisable() public {
        bytes32 id = service.registerStorageTerms(_sixTerms());
        uint256 dataset = _create(0, id);
        FilecoinWarmStorageService.DataSetInfoView memory info = stateView.getDataSet(dataset);
        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        assertEq(address(rail.token), address(six));
        assertEq(rail.lockupFixed, 500000);
        assertEq(info.pendingOneTimePayments, 25000);
        service.disableStorageTerms(id);
        verifier.nextProvingPeriod(service, dataset, block.number + 2880, 1 << 35, bytes(""));
        rail = payments.getRail(info.pdpRailId);
        assertEq(rail.paymentRate, 58); // floor(5e6 * 127/128 / 86400) + floor(0.12e6 / 86400)
        assertEq(rail.lockupFixed, 475000);
        info = stateView.getDataSet(dataset);
        assertEq(info.lifecycleReserveBalance, 475000);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(service.getDataSetStorageTermsId(dataset), id);
        (StorageTerms memory resolved, bool enabled) = service.getStorageTerms(id);
        assertFalse(enabled);
        assertEq(resolved.pricePerTiBPerMonth, 5e6);
    }

    function testSixDecimalRemovalAndConsentTerminationFees() public {
        uint256 dataset = _create(0, service.registerStorageTerms(_sixTerms()));
        uint256[] memory pieces = new uint256[](1);
        bytes32 removalHash = keccak256(
            abi.encode(
                SignatureVerificationLib.SCHEDULE_PIECE_REMOVALS_TYPEHASH,
                uint256(0),
                keccak256(abi.encodePacked(pieces))
            )
        );
        bytes memory signature = _signature(PAYER_KEY, removalHash);
        vm.prank(address(verifier));
        service.piecesScheduledRemove(dataset, pieces, abi.encode(signature));
        assertEq(stateView.getDataSet(dataset).pendingOneTimePayments, 32000);
        bytes32 terminationHash = keccak256(abi.encode(SignatureVerificationLib.TERMINATE_SERVICE_TYPEHASH, dataset));
        signature = _signature(PAYER_KEY, terminationHash);
        vm.prank(provider);
        service.terminateService(dataset, abi.encode(signature));
        FilecoinWarmStorageService.DataSetInfoView memory info = stateView.getDataSet(dataset);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(info.lifecycleReserveBalance, 0);
        assertEq(payments.getRail(info.pdpRailId).lockupFixed, 0);
        (uint256 funds,,,) = payments.accounts(six, payee);
        assertEq(funds, 37810); // gross fees 38000 less FilecoinPay's 0.5% network fee
        (uint256 networkFees,,,) = payments.accounts(six, address(payments));
        assertEq(networkFees, 190);
    }

    function testNonDefaultCurrencyRejectsCDN() public {
        bytes32 id = service.registerStorageTerms(_sixTerms());
        bytes memory payload = _payload(0, id, true, PAYER_KEY);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNUnsupportedCurrency.selector, address(six)));
        verifier.createDataSet(service, payload);
    }

    function testLegacyCreationAndPreUpgradeSentinel() public {
        uint256 dataset = _create(0, bytes32(0));
        bytes32 legacy = service.legacyStorageTermsId();
        assertEq(service.getDataSetStorageTermsId(dataset), legacy);
        bytes32 base = keccak256(abi.encode(dataset, DATA_SET_INFO_SLOT));
        vm.store(address(service), bytes32(uint256(base) + 11), bytes32(0));
        vm.expectRevert(Errors.LegacyStorageTermsCannotBeDisabled.selector);
        service.disableStorageTerms(legacy);
        assertEq(service.getDataSetStorageTermsId(dataset), legacy);
        verifier.nextProvingPeriod(service, dataset, block.number + 2880, 1 << 35, bytes(""));
        assertEq(address(payments.getRail(stateView.getDataSet(dataset).pdpRailId).token), address(usdfc));
        StorageTerms memory terms = _defaultTerms();
        assertEq(service.registerStorageTerms(terms), legacy);
        uint256 second = _create(1, bytes32(0));
        assertEq(service.getDataSetStorageTermsId(second), legacy);
        uint256 explicitLegacy = _create(2, legacy);
        assertEq(service.getDataSetStorageTermsId(explicitLegacy), legacy);
    }

    function testUnknownExplicitTermsAndZeroIdRejectWithoutFallback() public {
        bytes32 unknown = bytes32(uint256(123));
        bytes memory payload = _payload(0, unknown, false, PAYER_KEY);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownStorageTerms.selector, unknown));
        verifier.createDataSet(service, payload);
        payload = _payload(0, service.legacyStorageTermsId(), false, PAYER_KEY);
        assembly ("memory-safe") { mstore(add(payload, 192), 0) }
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidStorageTermsId.selector, bytes32(0)));
        verifier.createDataSet(service, payload);
    }

    function testNativeTokenUsesVersionSentinelAndCanBeReenabled() public {
        StorageTerms memory terms = StorageTerms(address(0), 18, 5e18, bytes32(uint256(7)));
        bytes32 id = service.registerStorageTerms(terms);
        (StorageTerms memory registered, bool enabled) = service.getStorageTerms(id);
        assertTrue(enabled);
        assertEq(registered.token, address(0));
        assertEq(registered.tokenDecimals, 18);
        vm.deal(payer, 100 ether);
        vm.startPrank(payer);
        payments.deposit{value: 100 ether}(IERC20(address(0)), payer, 100 ether);
        payments.setOperatorApproval(IERC20(address(0)), address(service), true, 100 ether, 100 ether, 86400);
        vm.stopPrank();
        uint256 dataset = _create(0, id);
        FilecoinWarmStorageService.DataSetInfoView memory info = stateView.getDataSet(dataset);
        assertEq(address(payments.getRail(info.pdpRailId).token), address(0));
        service.disableStorageTerms(id);
        (registered, enabled) = service.getStorageTerms(id);
        assertFalse(enabled);
        assertEq(registered.pricePerTiBPerMonth, 5e18);
        vm.expectEmit(true, false, false, true, address(service));
        emit StorageTermsRegistered(id, terms.token, terms.tokenDecimals, terms.pricePerTiBPerMonth, terms.salt);
        assertEq(service.registerStorageTerms(terms), id);
        (, enabled) = service.getStorageTerms(id);
        assertTrue(enabled);
        assertEq(service.getDataSetStorageTermsId(dataset), id);
    }

    function testSixDecimalAddPiecesChargesScaledFees() public {
        uint256 dataset = _create(0, service.registerStorageTerms(_sixTerms()));
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, 4, keccak256("six-decimal-piece"));
        string[][] memory keys = new string[][](1);
        string[][] memory values = new string[][](1);
        keys[0] = new string[](0);
        values[0] = new string[](0);
        bytes memory signature =
            _signature(PAYER_KEY, SignatureVerificationLib.addPiecesStructHash(0, 1, pieces, keys, values));
        verifier.addPieces(service, dataset, 0, pieces, 1, signature, keys[0], values[0]);
        FilecoinWarmStorageService.DataSetInfoView memory info = stateView.getDataSet(dataset);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(info.lifecycleReserveBalance, 464000);
        assertEq(payments.getRail(info.pdpRailId).lockupFixed, 464000);
        (uint256 providerFunds,,,) = payments.accounts(six, payee);
        assertEq(providerFunds, 35820); // 36000 gross, less 0.5% network fee
    }
}
