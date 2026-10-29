// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Cids} from "@pdp/Cids.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IFilecoinWarmStorageService} from "../src/interfaces/IFilecoinWarmStorageService.sol";
import {Errors} from "../src/Errors.sol";
import {CHALLENGES_PER_PROOF} from "../src/lib/FWSSConstants.sol";
import {DataSetInfoView} from "../src/lib/FWSSViewTypes.sol";
import {DATA_SET_INFO_SLOT} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {DataSetAbandoned, RailRateUpdated} from "../src/lib/LibRails.sol";
import {LibSignatureVerification} from "../src/lib/LibSignatureVerification.sol";
import {calculateStorageRate} from "../src/lib/PriceListUSDFC.sol";
import {StorageTerms} from "../src/lib/StorageTerms.sol";
import {STORAGE_TERMS_STORAGE_LOCATION} from "../src/storage/FWSSStorageTerms.sol";
import {FilecoinWarmStorageServiceFixture} from "./helpers/FilecoinWarmStorageServiceFixture.sol";
import {SixDecimalToken} from "./mocks/SixDecimalToken.sol";

/// @dev Storage terms through the dispatcher and every facet. Every creation signs for real over the proxy's
///      EIP-712 domain, so signature shape and session-key scope are exercised rather than mocked.
contract StorageTermsTest is FilecoinWarmStorageServiceFixture {
    using SafeERC20 for IERC20;

    uint256 internal constant PAYER_KEY = 0xA11CE;
    bytes32 internal constant CREATE_DATA_SET_WITH_STORAGE_TERMS_TYPEHASH = keccak256(
        "CreateDataSetWithStorageTerms(uint256 clientDataSetId,address payee,MetadataEntry[] metadata,bytes32 storageTermsId)"
        "MetadataEntry(string key,string value)"
    );
    uint256 internal constant LEAVES_2_35 = 1 << 35;

    SixDecimalToken internal six;
    address internal payer;

    function setUp() public override {
        super.setUp();
        payer = vm.addr(PAYER_KEY);
        six = new SixDecimalToken();
        IERC20(address(mockUSDFC)).safeTransfer(payer, 1000e18);
        IERC20(address(six)).safeTransfer(payer, 1000e6);
        _fund(IERC20(address(mockUSDFC)), 1000e18);
        _fund(six, 1000e6);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _fund(IERC20 token, uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(address(payments), amount);
        payments.deposit(token, payer, amount);
        payments.setOperatorApproval(token, address(pdpServiceWithPayments), true, amount, amount, 86400);
        vm.stopPrank();
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FilecoinWarmStorageService"),
                keccak256("1"),
                block.chainid,
                address(pdpServiceWithPayments)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _metadata(bool cdn) internal pure returns (string[] memory keys, string[] memory values) {
        keys = new string[](cdn ? 1 : 0);
        values = new string[](cdn ? 1 : 0);
        if (cdn) {
            keys[0] = "withCDN";
            values[0] = "true";
        }
    }

    function _legacyStructHash(uint256 nonce, bool cdn) internal view returns (bytes32) {
        (string[] memory keys, string[] memory values) = _metadata(cdn);
        return LibSignatureVerification.createDataSetStructHash(nonce, serviceProvider, keys, values);
    }

    function _termsStructHash(uint256 nonce, bytes32 id, bool cdn) internal view returns (bytes32) {
        (string[] memory keys, string[] memory values) = _metadata(cdn);
        return keccak256(
            abi.encode(
                CREATE_DATA_SET_WITH_STORAGE_TERMS_TYPEHASH,
                nonce,
                serviceProvider,
                LibSignatureVerification.hashMetadataEntries(keys, values),
                id
            )
        );
    }

    function _encodeLegacy(uint256 nonce, bool cdn, bytes memory signature) internal view returns (bytes memory) {
        (string[] memory keys, string[] memory values) = _metadata(cdn);
        return abi.encode(payer, nonce, keys, values, signature);
    }

    function _encodeTerms(uint256 nonce, bytes32 id, bool cdn, bytes memory signature)
        internal
        view
        returns (bytes memory)
    {
        (string[] memory keys, string[] memory values) = _metadata(cdn);
        return abi.encode(payer, nonce, keys, values, signature, id);
    }

    /// @dev id == 0 builds the legacy 5-tuple; any other id builds the storage terms 6-tuple.
    function _payload(uint256 nonce, bytes32 id, bool cdn, uint256 key) internal view returns (bytes memory) {
        if (id == bytes32(0)) {
            return _encodeLegacy(nonce, cdn, _sign(key, _legacyStructHash(nonce, cdn)));
        }
        return _encodeTerms(nonce, id, cdn, _sign(key, _termsStructHash(nonce, id, cdn)));
    }

    function _submit(bytes memory payload) internal returns (uint256) {
        vm.prank(serviceProvider);
        return mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);
    }

    function _create(uint256 nonce, bytes32 id) internal returns (uint256) {
        return _submit(_payload(nonce, id, false, PAYER_KEY));
    }

    function _defaultTerms() internal view returns (StorageTerms memory) {
        return
            StorageTerms({token: address(mockUSDFC), tokenDecimals: 18, pricePerTiBPerMonth: 2.5e18, salt: bytes32(0)});
    }

    function _saltedDefaultTerms(uint256 salt) internal view returns (StorageTerms memory terms) {
        terms = _defaultTerms();
        terms.salt = bytes32(salt);
    }

    function _sixTerms() internal view returns (StorageTerms memory) {
        return
            StorageTerms({token: address(six), tokenDecimals: 6, pricePerTiBPerMonth: 5e6, salt: bytes32(uint256(6))});
    }

    function _expectedLegacyId() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("filecoin.FWSS.StorageTerms.v1"), address(mockUSDFC), uint8(18), uint256(2.5e18), bytes32(0)
            )
        );
    }

    function _dataSetSlot(uint256 dataSetId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(dataSetId, DATA_SET_INFO_SLOT)));
    }

    function _storedTermsId(uint256 dataSetId) internal view returns (bytes32) {
        return vm.load(address(pdpServiceWithPayments), bytes32(_dataSetSlot(dataSetId) + 11));
    }

    function _login(uint256 sessionKey, bytes32[] memory permissions) internal {
        vm.prank(payer);
        sessionKeyRegistry.login(vm.addr(sessionKey), type(uint256).max, permissions, "storage-terms");
    }

    function _permissions(bytes32 a) internal pure returns (bytes32[] memory permissions) {
        permissions = new bytes32[](1);
        permissions[0] = a;
    }

    /// @dev Adds one piece of 2^height leaves, signed by the payer.
    function _addPiece(uint256 dataSetId, uint256 clientDataSetId, uint256 nonce, uint256 firstAdded, uint8 height)
        internal
    {
        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, height, keccak256(abi.encode("storage-terms-piece", nonce)));
        string[][] memory keys = new string[][](1);
        string[][] memory values = new string[][](1);
        keys[0] = new string[](0);
        values[0] = new string[](0);
        bytes memory signature = _sign(
            PAYER_KEY, LibSignatureVerification.addPiecesStructHash(clientDataSetId, nonce, pieces, keys, values)
        );
        mockPDPVerifier.addPieces(
            pdpServiceWithPayments, dataSetId, firstAdded, pieces, nonce, signature, keys[0], values[0]
        );
    }

    /// @dev Starts proving and returns the first deadline.
    function _activate(uint256 dataSetId, uint256 leafCount) internal returns (uint256 deadline) {
        (uint64 maxPeriod, uint256 window,,) = pdpServiceWithPayments.getPDPConfig();
        deadline = block.number + maxPeriod;
        mockPDPVerifier.nextProvingPeriod(pdpServiceWithPayments, dataSetId, deadline - window / 2, leafCount, "");
    }

    function _prove(uint256 dataSetId, uint256 deadline, uint256 leafCount) internal {
        vm.roll(deadline - 1);
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.possessionProven(dataSetId, leafCount, 12345, CHALLENGES_PER_PROOF);
    }

    function _funds(IERC20 token, address owner) internal view returns (uint256 funds) {
        (funds,,,) = payments.accounts(token, owner);
    }

    function _lockup(IERC20 token, address owner) internal view returns (uint256 lockupCurrent) {
        (, lockupCurrent,,) = payments.accounts(token, owner);
    }

    function _netOfNetworkFee(uint256 amount) internal pure returns (uint256) {
        return amount - (amount + 199) / 200;
    }

    // ------------------------------------------------------------------
    // Registration and the catalogue
    // ------------------------------------------------------------------

    function testOnlyOwnerCanRegisterAndDisable() public {
        StorageTerms memory terms = _saltedDefaultTerms(1);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        pdpServiceWithPayments.registerStorageTerms(terms);
        bytes32 id = pdpServiceWithPayments.registerStorageTerms(terms);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        pdpServiceWithPayments.disableStorageTerms(id);
    }

    function testRegistrationRejectsBadMetadataAndPrice() public {
        StorageTerms memory terms = _defaultTerms();
        terms.tokenDecimals = 19;
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedTokenDecimals.selector, uint8(19)));
        pdpServiceWithPayments.registerStorageTerms(terms);

        terms = _sixTerms();
        terms.pricePerTiBPerMonth = 2_499_999;
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StoragePriceBelowDefault.selector, uint256(2_499_999), uint256(2_500_000))
        );
        pdpServiceWithPayments.registerStorageTerms(terms);

        terms.pricePerTiBPerMonth = 2_500_000;
        terms.tokenDecimals = 18;
        vm.expectRevert(
            abi.encodeWithSelector(Errors.TokenDecimalsMismatch.selector, address(six), uint8(18), uint8(6))
        );
        pdpServiceWithPayments.registerStorageTerms(terms);
    }

    function testSaltsSeparateTermsAndReregistrationEnables() public {
        StorageTerms memory a = _saltedDefaultTerms(1);
        bytes32 aId = pdpServiceWithPayments.registerStorageTerms(a);
        bytes32 bId = pdpServiceWithPayments.registerStorageTerms(_saltedDefaultTerms(2));
        assertTrue(aId != bId);

        uint256 dataSet = _create(0, aId);
        pdpServiceWithPayments.disableStorageTerms(aId);
        (, bool enabled) = pdpServiceWithPayments.getStorageTerms(aId);
        assertFalse(enabled);

        bytes memory payload = _payload(1, aId, false, PAYER_KEY);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.StorageTermsNotEnabled.selector, aId));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);

        vm.expectEmit(true, false, false, true, address(pdpServiceWithPayments));
        emit IFilecoinWarmStorageService.StorageTermsRegistered(
            aId, a.token, a.tokenDecimals, a.pricePerTiBPerMonth, a.salt
        );
        assertEq(pdpServiceWithPayments.registerStorageTerms(a), aId);
        (, enabled) = pdpServiceWithPayments.getStorageTerms(aId);
        assertTrue(enabled);

        uint256 second = _create(1, aId);
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(dataSet), aId);
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(second), aId);
    }

    function testNativeTokenUsesVersionSentinelAndCanBeReenabled() public {
        StorageTerms memory terms =
            StorageTerms({token: address(0), tokenDecimals: 18, pricePerTiBPerMonth: 5e18, salt: bytes32(uint256(7))});
        bytes32 id = pdpServiceWithPayments.registerStorageTerms(terms);
        (StorageTerms memory registered, bool enabled) = pdpServiceWithPayments.getStorageTerms(id);
        assertTrue(enabled);
        assertEq(registered.token, address(0));
        assertEq(registered.tokenDecimals, 18);

        vm.deal(payer, 100 ether);
        vm.startPrank(payer);
        payments.deposit{value: 100 ether}(IERC20(address(0)), payer, 100 ether);
        payments.setOperatorApproval(
            IERC20(address(0)), address(pdpServiceWithPayments), true, 100 ether, 100 ether, 86400
        );
        vm.stopPrank();

        uint256 dataSet = _create(0, id);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSet);
        assertEq(address(payments.getRail(info.pdpRailId).token), address(0));

        pdpServiceWithPayments.disableStorageTerms(id);
        (registered, enabled) = pdpServiceWithPayments.getStorageTerms(id);
        assertFalse(enabled);
        assertEq(registered.pricePerTiBPerMonth, 5e18);

        vm.expectEmit(true, false, false, true, address(pdpServiceWithPayments));
        emit IFilecoinWarmStorageService.StorageTermsRegistered(
            id, terms.token, terms.tokenDecimals, terms.pricePerTiBPerMonth, terms.salt
        );
        assertEq(pdpServiceWithPayments.registerStorageTerms(terms), id);
        (, enabled) = pdpServiceWithPayments.getStorageTerms(id);
        assertTrue(enabled);
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(dataSet), id);
    }

    function testDisableUnknownTermsReverts() public {
        bytes32 unknown = bytes32(uint256(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownStorageTerms.selector, unknown));
        pdpServiceWithPayments.disableStorageTerms(unknown);
    }

    function testGetDataSetStorageTermsIdUnknownDataSet() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.DataSetNotRegistered.selector, uint256(999)));
        pdpServiceWithPayments.getDataSetStorageTermsId(999);
    }

    // ------------------------------------------------------------------
    // Creation: extraData shapes, signatures and session keys
    // ------------------------------------------------------------------

    function testSignatureRejectsSubstitutedTerms() public {
        bytes32 aId = pdpServiceWithPayments.registerStorageTerms(_saltedDefaultTerms(1));
        bytes32 bId = pdpServiceWithPayments.registerStorageTerms(_saltedDefaultTerms(2));
        bytes memory payload = _payload(0, aId, false, PAYER_KEY);
        // The terms ID is ABI head word 5 (payload byte 160), after the 32-byte length word in memory
        assembly ("memory-safe") {
            mstore(add(payload, 192), bId)
        }
        vm.prank(serviceProvider);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);
        assertEq(_create(0, aId), 1, "failed request must not consume nonce or dataset ID");
    }

    function testNewSessionPermissionDoesNotAcceptOldPermission() public {
        uint256 sessionKey = 0xB0B;
        address session = vm.addr(sessionKey);
        _login(sessionKey, _permissions(CREATE_DATA_SET_TYPEHASH));
        bytes32 id = pdpServiceWithPayments.legacyStorageTermsId();
        bytes memory payload = _payload(0, id, false, sessionKey);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, payer, session));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);

        _login(sessionKey, _permissions(CREATE_DATA_SET_WITH_STORAGE_TERMS_TYPEHASH));
        uint256 dataSet = _submit(payload);
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(dataSet), id);
    }

    function testSignaturesDoNotVerifyAcrossShapes() public {
        bytes32 legacyId = _expectedLegacyId();

        // CreateDataSet signature submitted in the storage terms shape
        bytes memory payload = _encodeTerms(0, legacyId, false, _sign(PAYER_KEY, _legacyStructHash(0, false)));
        vm.prank(serviceProvider);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);

        // CreateDataSetWithStorageTerms signature submitted in the legacy shape
        payload = _encodeLegacy(0, false, _sign(PAYER_KEY, _termsStructHash(0, legacyId, false)));
        vm.prank(serviceProvider);
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);
    }

    function testSessionKeyScopesAreSeparate() public {
        bytes32 aId = pdpServiceWithPayments.registerStorageTerms(_saltedDefaultTerms(1));

        uint256 newOnly = 0xB0B1;
        _login(newOnly, _permissions(CREATE_DATA_SET_WITH_STORAGE_TERMS_TYPEHASH));
        bytes memory payload = _payload(0, bytes32(0), false, newOnly);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, payer, vm.addr(newOnly)));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);

        uint256 legacyOnly = 0xB0B2;
        _login(legacyOnly, _permissions(CREATE_DATA_SET_TYPEHASH));
        payload = _payload(0, aId, false, legacyOnly);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, payer, vm.addr(legacyOnly)));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);

        uint256 both = 0xB0B3;
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = CREATE_DATA_SET_TYPEHASH;
        permissions[1] = CREATE_DATA_SET_WITH_STORAGE_TERMS_TYPEHASH;
        _login(both, permissions);
        uint256 legacyDataSet = _submit(_payload(0, bytes32(0), false, both));
        uint256 termsDataSet = _submit(_payload(1, aId, false, both));
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(legacyDataSet), _expectedLegacyId());
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(termsDataSet), aId);
    }

    function testUnknownExplicitTermsAndZeroIdRejectWithoutFallback() public {
        bytes32 unknown = bytes32(uint256(123));
        bytes memory payload = _payload(0, unknown, false, PAYER_KEY);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownStorageTerms.selector, unknown));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);

        payload = _payload(0, _expectedLegacyId(), false, PAYER_KEY);
        // Zero the terms ID word (ABI head word 5)
        assembly ("memory-safe") {
            mstore(add(payload, 192), 0)
        }
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidStorageTermsId.selector, bytes32(0)));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);
    }

    function testExtraDataVariantErrors() public {
        for (uint256 len = 1; len < 160; len++) {
            bytes memory short = new bytes(len);
            vm.prank(serviceProvider);
            vm.expectRevert(Errors.ExtraDataRequired.selector);
            mockPDPVerifier.createDataSet(pdpServiceWithPayments, short);
        }

        bytes memory payload = _payload(0, bytes32(0), false, PAYER_KEY);
        // Head word 2 is the offset of the metadata keys: 0xa0 legacy, 0xc0 storage terms
        assembly ("memory-safe") {
            mstore(add(payload, 96), 0xe0)
        }
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedExtraDataVariant.selector, uint256(0xe0)));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);
    }

    function testNonDefaultCurrencyRejectsCDN() public {
        bytes32 id = pdpServiceWithPayments.registerStorageTerms(_sixTerms());
        bytes memory payload = _payload(0, id, true, PAYER_KEY);
        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.CDNUnsupportedCurrency.selector, address(six)));
        mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);
    }

    // ------------------------------------------------------------------
    // Legacy terms
    // ------------------------------------------------------------------

    function testLegacyCreationAndPreUpgradeSentinel() public {
        bytes32 legacy = pdpServiceWithPayments.legacyStorageTermsId();
        uint256 dataSet = _create(0, bytes32(0));
        assertEq(_storedTermsId(dataSet), bytes32(0), "legacy terms are stored as zero");
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(dataSet), legacy);

        vm.expectRevert(Errors.LegacyStorageTermsCannotBeDisabled.selector);
        pdpServiceWithPayments.disableStorageTerms(legacy);

        mockPDPVerifier.nextProvingPeriod(pdpServiceWithPayments, dataSet, block.number + 2880, LEAVES_2_35, "");
        assertEq(
            address(payments.getRail(pdpServiceWithPayments.getDataSet(dataSet).pdpRailId).token), address(mockUSDFC)
        );

        assertEq(pdpServiceWithPayments.registerStorageTerms(_defaultTerms()), legacy);
        uint256 second = _create(1, bytes32(0));
        uint256 explicitLegacy = _create(2, legacy);
        assertEq(_storedTermsId(second), bytes32(0));
        assertEq(_storedTermsId(explicitLegacy), bytes32(0), "explicit legacy terms are stored as zero");
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(second), legacy);
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(explicitLegacy), legacy);

        vm.expectRevert(Errors.LegacyStorageTermsCannotBeDisabled.selector);
        pdpServiceWithPayments.disableStorageTerms(legacy);
    }

    function testLegacyRateAndFeesUnchanged() public {
        vm.expectEmit(true, true, false, false, address(pdpServiceWithPayments));
        emit IFilecoinWarmStorageService.DataSetStorageTermsSelected(1, _expectedLegacyId());
        uint256 dataSet = _create(0, bytes32(0));

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSet);
        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        assertEq(address(rail.token), address(mockUSDFC));
        assertEq(rail.lockupFixed, 0.5e18);
        assertEq(info.lifecycleReserveBalance, 0.5e18);
        assertEq(info.pendingOneTimePayments, 0.025e18);

        _addPiece(dataSet, 0, 1, 0, 35);
        info = pdpServiceWithPayments.getDataSet(dataSet);
        rail = payments.getRail(info.pdpRailId);
        assertEq(rail.paymentRate, calculateStorageRate(LEAVES_2_35));
        assertEq(rail.paymentRate, 30_098_017_939_813);
        assertEq(info.lifecycleReserveBalance, 0.5e18 - 0.025e18 - 0.008e18 - 0.003e18);
        assertEq(rail.lockupFixed, 0.464e18);
    }

    // ------------------------------------------------------------------
    // Six-decimal terms: fees, rates and payments
    // ------------------------------------------------------------------

    function testSixDecimalPaymentsContinueAfterDisable() public {
        bytes32 id = pdpServiceWithPayments.registerStorageTerms(_sixTerms());
        uint256 dataSet = _create(0, id);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSet);
        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        assertEq(address(rail.token), address(six));
        assertEq(rail.lockupFixed, 500000);
        assertEq(info.pendingOneTimePayments, 25000);

        pdpServiceWithPayments.disableStorageTerms(id);
        mockPDPVerifier.nextProvingPeriod(pdpServiceWithPayments, dataSet, block.number + 2880, LEAVES_2_35, "");
        rail = payments.getRail(info.pdpRailId);
        assertEq(rail.paymentRate, 58); // floor(5e6 * 127/128 / 86400) + floor(0.12e6 / 86400)
        assertEq(rail.lockupFixed, 475000);
        info = pdpServiceWithPayments.getDataSet(dataSet);
        assertEq(info.lifecycleReserveBalance, 475000);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(pdpServiceWithPayments.getDataSetStorageTermsId(dataSet), id);
        (StorageTerms memory resolved, bool enabled) = pdpServiceWithPayments.getStorageTerms(id);
        assertFalse(enabled);
        assertEq(resolved.pricePerTiBPerMonth, 5e6);
    }

    function testSixDecimalRemovalAndConsentTerminationFees() public {
        uint256 dataSet = _create(0, pdpServiceWithPayments.registerStorageTerms(_sixTerms()));
        uint256[] memory pieces = new uint256[](1);
        bytes32 removalHash = keccak256(
            abi.encode(
                LibSignatureVerification.SCHEDULE_PIECE_REMOVALS_TYPEHASH,
                uint256(0),
                keccak256(abi.encodePacked(pieces))
            )
        );
        vm.prank(address(mockPDPVerifier));
        pdpServiceWithPayments.piecesScheduledRemove(dataSet, pieces, abi.encode(_sign(PAYER_KEY, removalHash)));
        assertEq(pdpServiceWithPayments.getDataSet(dataSet).pendingOneTimePayments, 32000);

        bytes32 terminationHash = keccak256(abi.encode(LibSignatureVerification.TERMINATE_SERVICE_TYPEHASH, dataSet));
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSet, abi.encode(_sign(PAYER_KEY, terminationHash)));

        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSet);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(info.lifecycleReserveBalance, 0);
        assertEq(payments.getRail(info.pdpRailId).lockupFixed, 0);
        assertEq(_funds(six, serviceProvider), 37810); // gross fees 38000 less FilecoinPay's 0.5% network fee
        assertEq(_funds(six, address(payments)), 190);
    }

    function testSixDecimalAddPiecesChargesScaledFees() public {
        uint256 dataSet = _create(0, pdpServiceWithPayments.registerStorageTerms(_sixTerms()));
        _addPiece(dataSet, 0, 1, 0, 4);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSet);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(info.lifecycleReserveBalance, 464000);
        assertEq(payments.getRail(info.pdpRailId).lockupFixed, 464000);
        assertEq(_funds(six, serviceProvider), 35820); // 36000 gross, less 0.5% network fee
    }

    function testSixDecimalRateUpdatesOnPiecesAdded() public {
        uint256 dataSet = _create(0, pdpServiceWithPayments.registerStorageTerms(_sixTerms()));
        uint256 railId = pdpServiceWithPayments.getDataSet(dataSet).pdpRailId;

        vm.expectEmit(true, false, false, true, address(pdpServiceWithPayments));
        emit RailRateUpdated(dataSet, railId, 58);
        _addPiece(dataSet, 0, 1, 0, 35);
        assertEq(mockPDPVerifier.getDataSetLeafCount(dataSet), LEAVES_2_35);
        assertEq(payments.getRail(railId).paymentRate, 58);

        // 2^36 leaves: floor(2 * 5e6 * 127/128 / 86400) + 1
        vm.expectEmit(true, false, false, true, address(pdpServiceWithPayments));
        emit RailRateUpdated(dataSet, railId, 115);
        _addPiece(dataSet, 0, 2, 1, 35);
        assertEq(payments.getRail(railId).paymentRate, 115);
        assertEq(pdpServiceWithPayments.getDataSet(dataSet).lifecycleReserveBalance, 500000 - 25000 - 2 * 11000);
    }

    function testSixDecimalSettlementPaysProvenEpochs() public {
        uint256 dataSet = _create(0, pdpServiceWithPayments.registerStorageTerms(_sixTerms()));
        uint256 railId = pdpServiceWithPayments.getDataSet(dataSet).pdpRailId;
        uint256 payerUsdfc = _funds(IERC20(address(mockUSDFC)), payer);
        uint256 payeeUsdfc = _funds(IERC20(address(mockUSDFC)), serviceProvider);

        _addPiece(dataSet, 0, 1, 0, 35);
        uint256 deadline = _activate(dataSet, LEAVES_2_35);
        _prove(dataSet, deadline, LEAVES_2_35);
        vm.roll(deadline + 1);

        uint256 payeeBefore = _funds(six, serviceProvider);
        (uint256 settled,,,, uint256 settledEpoch,) = payments.settleRail(railId, deadline);
        assertEq(settledEpoch, deadline);
        assertEq(settled, 58 * 2880, "rate times proven epochs");
        assertEq(_funds(six, serviceProvider) - payeeBefore, _netOfNetworkFee(58 * 2880));
        assertEq(_funds(six, serviceProvider) - payeeBefore, 166204);

        assertEq(_funds(IERC20(address(mockUSDFC)), payer), payerUsdfc);
        assertEq(_funds(IERC20(address(mockUSDFC)), serviceProvider), payeeUsdfc);
    }

    function testSixDecimalPayerTerminationSettlesToEndEpoch() public {
        uint256 dataSet = _create(0, pdpServiceWithPayments.registerStorageTerms(_sixTerms()));
        uint256 railId = pdpServiceWithPayments.getDataSet(dataSet).pdpRailId;
        _addPiece(dataSet, 0, 1, 0, 35);
        uint256 deadline = _activate(dataSet, LEAVES_2_35);
        _prove(dataSet, deadline, LEAVES_2_35);
        vm.roll(deadline + 1);

        vm.prank(payer);
        pdpServiceWithPayments.terminateService(dataSet);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSet);
        assertEq(info.pendingOneTimePayments, 0, "payer termination charges no terminate fee");
        assertEq(info.lifecycleReserveBalance, 464000);
        FilecoinPayV1.RailView memory rail = payments.getRail(railId);
        assertGt(rail.endEpoch, 0);
        assertEq(info.pdpEndEpoch, rail.endEpoch);

        // Let every period through endEpoch resolve, then settle to it
        (uint64 maxPeriod,,,) = pdpServiceWithPayments.getPDPConfig();
        vm.roll(rail.endEpoch + maxPeriod + 1);
        uint256 payeeBefore = _funds(six, serviceProvider);
        (,,,, uint256 settledEpoch,) = payments.settleRail(railId, rail.endEpoch);
        assertEq(settledEpoch, rail.endEpoch);
        assertEq(_funds(six, serviceProvider) - payeeBefore, _netOfNetworkFee(58 * 2880));
        assertEq(_lockup(six, payer), 0, "rail lockup, including the reserve, is released");
    }

    function testSixDecimalDeletionClearsTermsSlot() public {
        bytes32 id = pdpServiceWithPayments.registerStorageTerms(_sixTerms());
        uint256 dataSet = _create(0, id);
        assertEq(_storedTermsId(dataSet), id);

        bytes32 terminationHash = keccak256(abi.encode(LibSignatureVerification.TERMINATE_SERVICE_TYPEHASH, dataSet));
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(dataSet, abi.encode(_sign(PAYER_KEY, terminationHash)));
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSet);
        payments.settleRail(info.pdpRailId, info.pdpEndEpoch);
        vm.roll(info.pdpEndEpoch + 1);

        vm.prank(serviceProvider);
        mockPDPVerifier.deleteDataSet(pdpServiceWithPayments, dataSet, "");
        assertEq(_storedTermsId(dataSet), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Errors.DataSetNotRegistered.selector, dataSet));
        pdpServiceWithPayments.getDataSetStorageTermsId(dataSet);
    }

    function testSixDecimalAbandonmentReturnsReserveInTermsToken() public {
        uint256 dataSet = _create(0, pdpServiceWithPayments.registerStorageTerms(_sixTerms()));
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSet);
        uint256 payerUsdfc = _funds(IERC20(address(mockUSDFC)), payer);
        assertEq(_lockup(six, payer), 500000);

        vm.expectEmit(true, false, false, true, address(pdpServiceWithPayments));
        emit DataSetAbandoned(dataSet, info.pdpRailId, 0, 0);
        vm.prank(serviceProvider);
        mockPDPVerifier.deleteDataSet(pdpServiceWithPayments, dataSet, "");

        assertEq(_lockup(six, payer), 0, "reserve returns to the payer");
        assertEq(_funds(six, payer), 1000e6, "the pending creation fee is forfeited, not paid");
        assertEq(_funds(IERC20(address(mockUSDFC)), payer), payerUsdfc);
    }

    // ------------------------------------------------------------------
    // Pins
    // ------------------------------------------------------------------

    function testLayoutPins() public {
        assertEq(
            STORAGE_TERMS_STORAGE_LOCATION,
            keccak256(abi.encode(uint256(keccak256("filecoin.FWSS.StorageTerms")) - 1)) & ~bytes32(uint256(0xff))
        );
        assertEq(STORAGE_TERMS_STORAGE_LOCATION, 0xffe2107a587f9a58b0aaa87110a43c1dc6de9e3d39b63f9be37b80538b60ff00);

        StorageTerms memory terms = _sixTerms();
        bytes32 id = pdpServiceWithPayments.registerStorageTerms(terms);
        uint256 dataSet = _create(0, id);
        uint256 base = _dataSetSlot(dataSet);
        address proxy = address(pdpServiceWithPayments);
        assertEq(vm.load(proxy, bytes32(base + 11)), id, "DataSetInfo.storageTermsId is relative slot 11");
        assertEq(uint256(vm.load(proxy, bytes32(base + 10))), 25000 | (500000 << 96), "slot 10 packing unchanged");

        uint256 record = uint256(keccak256(abi.encode(id, STORAGE_TERMS_STORAGE_LOCATION)));
        assertEq(
            uint256(vm.load(proxy, bytes32(record))),
            uint256(uint160(address(six))) | (6 << 160) | (1 << 168) | (1 << 176),
            "slot 0: token | decimals | version | enabled"
        );
        assertEq(uint256(vm.load(proxy, bytes32(record + 1))), 5e6, "slot 1: price");
        assertEq(vm.load(proxy, bytes32(record + 2)), terms.salt, "slot 2: salt");
        assertEq(vm.load(proxy, bytes32(record + 3)), bytes32(0), "the record is three slots");
    }

    function testIdFormulaAndTypehashPins() public view {
        assertEq(pdpServiceWithPayments.legacyStorageTermsId(), _expectedLegacyId());
        assertEq(pdpServiceWithPayments.getStorageTermsId(_defaultTerms()), _expectedLegacyId());
        assertEq(
            LibSignatureVerification.CREATE_DATA_SET_WITH_STORAGE_TERMS_TYPEHASH,
            CREATE_DATA_SET_WITH_STORAGE_TERMS_TYPEHASH
        );
        assertEq(
            CREATE_DATA_SET_WITH_STORAGE_TERMS_TYPEHASH,
            0xb19322c85f3947e48dc1192c27f98b6b00f24a273e66fb3288a08fd82449bc4d
        );
    }
}
