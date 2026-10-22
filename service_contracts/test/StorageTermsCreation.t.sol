// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Cids} from "@pdp/Cids.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {FilecoinWarmStorageServiceFixture} from "./helpers/FilecoinWarmStorageServiceFixture.sol";
import {FWSSDataSetModule} from "../src/modules/FWSSDataSetModule.sol";
import {FWSSStorageTermsModule} from "../src/modules/FWSSStorageTermsModule.sol";
import {StorageTerms} from "../src/lib/StorageTerms.sol";
import {DataSetInfoView} from "../src/lib/FWSSViewTypes.sol";
import {Errors} from "../src/Errors.sol";

contract CreationSixDecimalToken is ERC20 {
    constructor() ERC20("Creation USD", "CUSD") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract StorageTermsCreationTest is FilecoinWarmStorageServiceFixture {
    uint256 private constant PAYER_KEY = 0x627;
    uint256 private constant SESSION_KEY = 0x614;
    address private payer;
    CreationSixDecimalToken private token;
    FWSSStorageTermsModule private termsModule;
    bytes32 private termsId;

    function setUp() public override {
        super.setUp();
        payer = vm.addr(PAYER_KEY);
        termsModule = FWSSStorageTermsModule(address(pdpServiceWithPayments));
        token = new CreationSixDecimalToken();
        termsId = termsModule.registerStorageTerms(StorageTerms(address(token), 6, bytes32(0), 2_500_000));
        _fund(IERC20(address(token)), 100e6);
        _fund(IERC20(address(mockUSDFC)), 100e18);
    }

    function _fund(IERC20 currency, uint256 amount) private {
        currency.transfer(payer, amount);
        vm.startPrank(payer);
        currency.approve(address(payments), amount);
        payments.deposit(currency, payer, amount);
        payments.setOperatorApproval(currency, address(pdpServiceWithPayments), true, amount, amount, 86400);
        vm.stopPrank();
    }

    function _payload(bytes32 id, uint256 nonce, uint256 signerKey, bool explicitTerms, bool cdn)
        private
        view
        returns (bytes memory)
    {
        string[] memory keys = new string[](cdn ? 1 : 0);
        string[] memory values = new string[](cdn ? 1 : 0);
        bytes32 metadataHash = keccak256("");
        if (cdn) {
            keys[0] = "withCDN";
            values[0] = "true";
            metadataHash = keccak256(
                abi.encodePacked(
                    keccak256(
                        abi.encode(
                            keccak256("MetadataEntry(string key,string value)"), keccak256("withCDN"), keccak256("true")
                        )
                    )
                )
            );
        }
        bytes32 structHash;
        if (explicitTerms) {
            structHash = keccak256(
                abi.encode(
                    keccak256(
                        "CreateDataSetWithStorageTerms(uint256 clientDataSetId,address payee,MetadataEntry[] metadata,bytes32 storageTermsId)MetadataEntry(string key,string value)"
                    ),
                    nonce,
                    serviceProvider,
                    metadataHash,
                    id
                )
            );
        } else {
            structHash = keccak256(abi.encode(CREATE_DATA_SET_TYPEHASH, nonce, serviceProvider, metadataHash));
        }
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FilecoinWarmStorageService"),
                keccak256("1"),
                block.chainid,
                address(pdpServiceWithPayments)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
        bytes memory signature = abi.encodePacked(r, s, v);
        if (explicitTerms) return abi.encode(payer, nonce, keys, values, signature, id);
        return abi.encode(payer, nonce, keys, values, signature);
    }

    function _create(bytes memory payload) private returns (uint256) {
        vm.prank(serviceProvider);
        return mockPDPVerifier.createDataSet(pdpServiceWithPayments, payload);
    }

    function testSignedTermsSelectCurrencyAndScaleInitialFees() public {
        uint256 id = _create(_payload(termsId, 1, PAYER_KEY, true, false));
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(id);
        FilecoinPayV1.RailView memory rail = payments.getRail(info.pdpRailId);
        assertEq(address(rail.token), address(token));
        assertEq(rail.from, payer);
        assertEq(rail.lockupFixed, 500_000);
        assertEq(info.lifecycleReserveBalance, 500_000);
        assertEq(info.pendingOneTimePayments, 25_000);
        assertEq(pdpServiceWithPayments.getDataSetV2(id).storageTermsId, termsId);
    }

    function testDisabledSixDecimalTermsContinueChargingAddPiecesAndReplenish() public {
        uint256 id = _create(_payload(termsId, 1, PAYER_KEY, true, false));
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(id);
        termsModule.disableStorageTerms(termsId);

        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = Cids.CommPv2FromDigest(0, 4, keccak256("six-decimal-piece"));
        string[] memory keys = new string[](0);
        string[] memory values = new string[](0);
        makeSignaturePass(payer);
        mockPDPVerifier.addPieces(
            PDPListener(address(pdpServiceWithPayments)), id, 0, pieces, 2, FAKE_SIGNATURE, keys, values
        );

        info = pdpServiceWithPayments.getDataSet(id);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(info.lifecycleReserveBalance, 464_000, "25k + 8k + 3k charged");
        assertEq(payments.getRail(info.pdpRailId).lockupFixed, 464_000);

        uint256[] memory pieceIds = new uint256[](1);
        pieceIds[0] = 0;
        for (uint256 i = 0; i < 63; i++) {
            makeSignaturePass(payer);
            mockPDPVerifier.piecesScheduledRemove(
                id, pieceIds, address(pdpServiceWithPayments), abi.encode(FAKE_SIGNATURE)
            );
        }

        info = pdpServiceWithPayments.getDataSet(id);
        assertEq(info.pendingOneTimePayments, 441_000, "63 scaled removal fees remain pending");
        assertEq(info.lifecycleReserveBalance, 941_000, "reserve replenishes in six-decimal units");
        assertEq(payments.getRail(info.pdpRailId).lockupFixed, 941_000);
    }

    function testDisabledSixDecimalTermsChargeSignedTermination() public {
        uint256 id = _create(_payload(termsId, 1, PAYER_KEY, true, false));
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(id);
        termsModule.disableStorageTerms(termsId);
        (, uint256 payeeBefore,,) = payments.getAccountInfoIfSettled(IERC20(address(token)), serviceProvider);

        makeSignaturePass(payer);
        vm.prank(serviceProvider);
        pdpServiceWithPayments.terminateService(id, abi.encode(FAKE_SIGNATURE));

        info = pdpServiceWithPayments.getDataSet(id);
        assertEq(info.pendingOneTimePayments, 0);
        assertEq(info.lifecycleReserveBalance, 0);
        uint256 networkFee = (31_000 * payments.NETWORK_FEE_NUMERATOR() + payments.NETWORK_FEE_DENOMINATOR() - 1)
            / payments.NETWORK_FEE_DENOMINATOR();
        (, uint256 payeeAfter,,) = payments.getAccountInfoIfSettled(IERC20(address(token)), serviceProvider);
        assertEq(payeeAfter - payeeBefore, 31_000 - networkFee, "scaled create and termination fees paid");
    }

    function testTermsIdIsBoundBySignature() public {
        bytes memory payload = _payload(termsId, 1, PAYER_KEY, true, false);
        // Replace the signed terms ID with another enabled ID (the legacy zero record).
        assembly ("memory-safe") {
            mstore(add(payload, 192), 0)
        }
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        _create(payload);
    }

    function testExplicitZeroUsesNewSignatureType() public {
        uint256 id = _create(_payload(bytes32(0), 1, PAYER_KEY, true, false));
        assertEq(pdpServiceWithPayments.getDataSetV2(id).storageTermsId, bytes32(0));
        assertEq(address(payments.getRail(pdpServiceWithPayments.getDataSet(id).pdpRailId).token), address(mockUSDFC));
    }

    function testLegacySignatureCannotAuthorizeNewPayload() public {
        bytes memory legacy = _payload(bytes32(0), 1, PAYER_KEY, false, false);
        (address p, uint256 nonce, string[] memory keys, string[] memory values, bytes memory signature) =
            abi.decode(legacy, (address, uint256, string[], string[], bytes));
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        _create(abi.encode(p, nonce, keys, values, signature, bytes32(0)));
    }

    function testExistingSessionScopeAuthorizesTermsAndRevocationApplies() public {
        bytes32[] memory scopes = new bytes32[](1);
        scopes[0] = CREATE_DATA_SET_TYPEHASH;
        vm.prank(payer);
        sessionKeyRegistry.login(vm.addr(SESSION_KEY), block.timestamp + 100, scopes, "terms");
        uint256 id = _create(_payload(termsId, 1, SESSION_KEY, true, false));
        assertEq(pdpServiceWithPayments.getDataSet(id).payer, payer);
        vm.prank(payer);
        sessionKeyRegistry.revoke(vm.addr(SESSION_KEY), scopes, "terms");
        vm.expectPartialRevert(Errors.InvalidSignature.selector);
        _create(_payload(termsId, 2, SESSION_KEY, true, false));
    }

    function testDisabledZeroBlocksBothPayloadVariantsAndCanBeReenabled() public {
        termsModule.disableStorageTerms(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(FWSSDataSetModule.StorageTermsNotEnabled.selector, bytes32(0)));
        _create(_payload(bytes32(0), 1, PAYER_KEY, false, false));
        vm.expectRevert(abi.encodeWithSelector(FWSSDataSetModule.StorageTermsNotEnabled.selector, bytes32(0)));
        _create(_payload(bytes32(0), 1, PAYER_KEY, true, false));
        assertEq(termsModule.registerStorageTerms(StorageTerms(address(mockUSDFC), 18, bytes32(0), 2.5e18)), bytes32(0));
        uint256 id = _create(_payload(bytes32(0), 1, PAYER_KEY, false, false));
        assertEq(pdpServiceWithPayments.getDataSet(id).payer, payer);
    }

    function testReplayProtectionIsSharedAcrossPayloadVariants() public {
        _create(_payload(bytes32(0), 1, PAYER_KEY, false, false));
        vm.expectRevert(abi.encodeWithSelector(Errors.ClientDataSetAlreadyRegistered.selector, 1));
        _create(_payload(termsId, 1, PAYER_KEY, true, false));
    }

    function testDisabledTermsBlockCreationUntilReregistered() public {
        termsModule.disableStorageTerms(termsId);
        bytes memory payload = _payload(termsId, 1, PAYER_KEY, true, false);
        vm.expectRevert(abi.encodeWithSelector(FWSSDataSetModule.StorageTermsNotEnabled.selector, termsId));
        _create(payload);
        termsModule.registerStorageTerms(StorageTerms(address(token), 6, bytes32(0), 2_500_000));
        uint256 id = _create(payload);
        assertEq(pdpServiceWithPayments.getDataSetV2(id).storageTermsId, termsId);
    }

    function testUnknownTermsCannotCreateDataSet() public {
        bytes32 unknownId = keccak256("unregistered");
        bytes memory payload = _payload(unknownId, 1, PAYER_KEY, true, false);
        vm.expectRevert(abi.encodeWithSignature("UnknownStorageTerms(bytes32)", unknownId));
        _create(payload);
    }

    function testUnsupportedPayloadHeadIsRejected() public {
        bytes memory payload = _payload(termsId, 1, PAYER_KEY, true, false);
        assembly ("memory-safe") {
            mstore(add(payload, 96), 224)
        }
        vm.expectRevert(abi.encodeWithSelector(FWSSDataSetModule.UnsupportedExtraDataVariant.selector, 224));
        _create(payload);
    }

    function testTruncatedTermsHeadIsRejected() public {
        bytes memory payload = _payload(termsId, 1, PAYER_KEY, true, false);
        assembly ("memory-safe") {
            mstore(payload, 160)
        }
        vm.expectRevert();
        _create(payload);
    }

    function testFilBeamRejectsNonUSDFCAndAcceptsSaltedUSDFCTerms() public {
        vm.expectRevert(abi.encodeWithSelector(FWSSDataSetModule.CDNUnsupportedCurrency.selector, address(token)));
        _create(_payload(termsId, 1, PAYER_KEY, true, true));
        bytes32 usdfcTerms =
            termsModule.registerStorageTerms(StorageTerms(address(mockUSDFC), 18, bytes32(uint256(1)), 3e18));
        uint256 id = _create(_payload(usdfcTerms, 1, PAYER_KEY, true, true));
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(id);
        assertEq(address(payments.getRail(info.cacheMissRailId).token), address(mockUSDFC));
        assertEq(address(payments.getRail(info.cdnRailId).token), address(mockUSDFC));
        assertEq(pdpServiceWithPayments.getDataSetV2(id).storageTermsId, usdfcTerms);
    }
}
