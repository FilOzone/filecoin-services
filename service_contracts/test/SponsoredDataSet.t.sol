// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {Cids} from "@pdp/Cids.sol";
import {PDPVerifier} from "@pdp/PDPVerifier.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FilecoinWarmStorageService} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {SponsoredDataSet, SponsoredDataSetFactory} from "../src/SponsoredDataSet.sol";
import {Errors} from "../src/Errors.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {MockERC20} from "./mocks/SharedMocks.sol";
import {PDPOffering} from "./PDPOffering.sol";

contract SponsoredDataSetTest is MockFVMTest {
    using PDPOffering for PDPOffering.Schema;

    uint256 constant CLEANUP_DEPOSIT = 0.1 ether;

    bytes32 constant CID_TYPEHASH = keccak256("Cid(bytes data)");
    bytes32 constant PIECE_METADATA_TYPEHASH =
        keccak256("PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)MetadataEntry(string key,string value)");
    bytes32 constant ADD_PIECES_TYPEHASH = keccak256(
        "AddPieces(uint256 clientDataSetId,uint256 nonce,Cid[] pieceData,PieceMetadata[] pieceMetadata)"
        "Cid(bytes data)" "MetadataEntry(string key,string value)"
        "PieceMetadata(uint256 pieceIndex,MetadataEntry[] metadata)"
    );
    bytes32 constant SCHEDULE_PIECE_REMOVALS_TYPEHASH =
        keccak256("SchedulePieceRemovals(uint256 clientDataSetId,uint256[] pieceIds)");

    PDPVerifier pdpVerifier;
    FilecoinWarmStorageService fwss;
    FilecoinWarmStorageServiceStateView viewContract;
    FilecoinPayV1 payments;
    MockERC20 token;
    SessionKeyRegistry sessionKeyRegistry;
    ServiceProviderRegistry serviceProviderRegistry;
    SponsoredDataSetFactory factory;

    address serviceProvider;
    address payee;
    address beneficiary;

    uint256 curatorPrivKey = uint256(keccak256("curator"));
    address curator;

    uint256 addPiecesNonce;

    function setUp() public override {
        super.setUp();

        serviceProvider = address(0xf1);
        payee = address(0xf2);
        beneficiary = address(0xf3);
        curator = vm.addr(curatorPrivKey);

        vm.deal(address(this), 1000 ether);
        vm.deal(serviceProvider, 100 ether);

        token = new MockERC20();
        payments = new FilecoinPayV1();
        sessionKeyRegistry = new SessionKeyRegistry();

        ServiceProviderRegistry registryImpl = new ServiceProviderRegistry(1);
        serviceProviderRegistry = ServiceProviderRegistry(
            address(new MyERC1967Proxy(address(registryImpl), abi.encodeCall(ServiceProviderRegistry.initialize, ())))
        );

        PDPVerifier pdpImpl = new PDPVerifier(1, 0);
        pdpVerifier =
            PDPVerifier(address(new MyERC1967Proxy(address(pdpImpl), abi.encodeCall(PDPVerifier.initialize, ()))));

        FilecoinWarmStorageService fwssImpl = new FilecoinWarmStorageService(
            address(pdpVerifier),
            address(payments),
            token,
            address(0xfb),
            serviceProviderRegistry,
            sessionKeyRegistry,
            4
        );
        fwss = FilecoinWarmStorageService(
            address(
                new MyERC1967Proxy(
                    address(fwssImpl),
                    abi.encodeCall(
                        FilecoinWarmStorageService.initialize,
                        (uint64(2880), uint256(60), address(0xfc), "FWSS Test", "Filecoin Warm Storage Service Test")
                    )
                )
            )
        );

        viewContract = new FilecoinWarmStorageServiceStateView(fwss);
        fwss.setViewContract(address(viewContract));

        PDPOffering.Schema memory schema = PDPOffering.Schema({
            serviceURL: "https://sp.test",
            minPieceSizeInBytes: 128,
            maxPieceSizeInBytes: 1 << 30,
            ipniPiece: false,
            ipniIpfs: false,
            storagePricePerTibPerDay: 1 ether,
            minProvingPeriodInEpochs: 2880,
            location: "US",
            paymentTokenAddress: IERC20(address(0))
        });
        (string[] memory spKeys, bytes[] memory spValues) = schema.toCapabilities();
        vm.prank(serviceProvider);
        serviceProviderRegistry.registerProvider{value: 5 ether}(
            serviceProvider,
            "Test SP",
            "Test storage provider",
            ServiceProviderRegistryStorage.ProductType.PDP,
            spKeys,
            spValues
        );
        fwss.addApprovedProvider(1);

        factory = new SponsoredDataSetFactory(fwss);
    }

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            fwss.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _addPiecesStructHash(Cids.Cid memory piece, uint256 nonce) internal pure returns (bytes32) {
        bytes32 cidHash = keccak256(abi.encode(CID_TYPEHASH, keccak256(piece.data)));
        bytes32 cidsHash = keccak256(abi.encodePacked(cidHash));

        bytes32 emptyMetadataEntriesHash = keccak256(abi.encodePacked(new bytes32[](0)));
        bytes32 pieceMetaHash = keccak256(abi.encode(PIECE_METADATA_TYPEHASH, uint256(0), emptyMetadataEntriesHash));
        bytes32 pieceMetasHash = keccak256(abi.encodePacked(pieceMetaHash));

        return keccak256(abi.encode(ADD_PIECES_TYPEHASH, uint256(0), nonce, cidsHash, pieceMetasHash));
    }

    // Deploys a SponsoredDataSet, funds it, creates the data set on-chain, and binds it.
    function _setupDataSet(uint256 fundAmount) internal returns (SponsoredDataSet dataSet, uint256 dataSetId) {
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        dataSet = factory.initDataSet(payee, emptyKeys, emptyValues, curator, beneficiary);

        token.approve(address(payments), fundAmount);
        payments.deposit(IERC20(address(token)), address(dataSet), fundAmount);

        bytes memory zeroSig = new bytes(65);
        bytes memory extraData = abi.encode(address(dataSet), uint256(0), emptyKeys, emptyValues, zeroSig);
        vm.prank(serviceProvider);
        dataSetId = pdpVerifier.createDataSet{value: CLEANUP_DEPOSIT}(address(fwss), extraData);

        dataSet.bind(dataSetId);
    }

    // Adds a single piece to the data set; curator signs the AddPieces message.
    function _addPiece(SponsoredDataSet dataSet, Cids.Cid memory piece) internal {
        uint256 nonce = ++addPiecesNonce;
        uint256 dataSetId = dataSet.dataSetId();

        bytes32 digest = _hashTypedDataV4(_addPiecesStructHash(piece, nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(curatorPrivKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = piece;
        string[][] memory emptyKeys = new string[][](1);
        emptyKeys[0] = new string[](0);
        string[][] memory emptyValues = new string[][](1);
        emptyValues[0] = new string[](0);

        vm.prank(serviceProvider);
        pdpVerifier.addPieces(dataSetId, address(0), pieces, abi.encode(nonce, emptyKeys, emptyValues, sig));
    }

    // Schedules removal of pieces from the data set; curator signs the SchedulePieceRemovals message.
    function _scheduleRemoval(SponsoredDataSet dataSet, uint256[] memory pieceIds) internal {
        uint256 dataSetId = dataSet.dataSetId();

        bytes32 structHash =
            keccak256(abi.encode(SCHEDULE_PIECE_REMOVALS_TYPEHASH, uint256(0), keccak256(abi.encodePacked(pieceIds))));
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(curatorPrivKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(serviceProvider);
        pdpVerifier.schedulePieceDeletions(dataSetId, pieceIds, abi.encode(sig));
    }

    function testAddPiece() public {
        (SponsoredDataSet dataSet,) = _setupDataSet(100 * 10 ** token.decimals());
        Cids.Cid memory piece = Cids.CommPv2FromDigest(0, 4, keccak256("test piece"));
        _addPiece(dataSet, piece);
    }

    function testIsNotFinalizedInitially() public {
        (SponsoredDataSet dataSet,) = _setupDataSet(100 * 10 ** token.decimals());
        assertFalse(dataSet.isFinalized());
    }

    function testFinalizeByCurator() public {
        (SponsoredDataSet dataSet,) = _setupDataSet(100 * 10 ** token.decimals());
        vm.prank(curator);
        dataSet.finalize();
        assertTrue(dataSet.isFinalized());
    }

    function testFinalizeRevokesCuratorPermissions() public {
        (SponsoredDataSet dataSet, uint256 dsId) = _setupDataSet(100 * 10 ** token.decimals());
        vm.prank(curator);
        dataSet.finalize();

        Cids.Cid memory piece = Cids.CommPv2FromDigest(0, 4, keccak256("test piece after finalize"));
        uint256 nonce = ++addPiecesNonce;
        bytes32 digest = _hashTypedDataV4(_addPiecesStructHash(piece, nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(curatorPrivKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        Cids.Cid[] memory pieces = new Cids.Cid[](1);
        pieces[0] = piece;
        string[][] memory emptyKeys = new string[][](1);
        emptyKeys[0] = new string[](0);
        string[][] memory emptyValues = new string[][](1);
        emptyValues[0] = new string[](0);

        vm.prank(serviceProvider);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSignature.selector, address(dataSet), curator));
        pdpVerifier.addPieces(dsId, address(0), pieces, abi.encode(nonce, emptyKeys, emptyValues, sig));
    }

    function testFinalizeRevertsIfNotCurator() public {
        (SponsoredDataSet dataSet,) = _setupDataSet(100 * 10 ** token.decimals());
        vm.expectRevert(abi.encodeWithSelector(SponsoredDataSet.NotCurator.selector, curator, address(this)));
        dataSet.finalize();
    }
}
