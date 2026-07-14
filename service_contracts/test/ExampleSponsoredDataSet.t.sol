// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockFVMTest} from "@fvm-solidity/mocks/MockFVMTest.sol";
import {Cids} from "@pdp/Cids.sol";
import {PDPVerifier} from "@pdp/PDPVerifier.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FilecoinWarmStorageService, PDP_INACTIVITY_WINDOW} from "../src/FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateView} from "../src/FilecoinWarmStorageServiceStateView.sol";
import {ExampleSponsoredDataSet, ExampleSponsoredDataSetFactory} from "../src/ExampleSponsoredDataSet.sol";
import {SignatureVerificationLib} from "../src/lib/SignatureVerificationLib.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {Errors} from "../src/Errors.sol";
import {ServiceProviderRegistry} from "../src/ServiceProviderRegistry.sol";
import {ServiceProviderRegistryStorage} from "../src/ServiceProviderRegistryStorage.sol";
import {MockERC20} from "./mocks/SharedMocks.sol";
import {PDPOffering} from "./PDPOffering.sol";
import {PROVING_ACTIVATION_EPOCH_SLOT, PROVEN_THIS_PERIOD_SLOT} from "../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {DATA_SET_LAST_PROVEN_EPOCH_SLOT} from "../lib/pdp/src/PDPVerifierLayout.sol";

contract ExampleSponsoredDataSetTest is MockFVMTest {
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
    ExampleSponsoredDataSetFactory factory;

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
            payee, "Test SP", "Test storage provider", ServiceProviderRegistryStorage.ProductType.PDP, spKeys, spValues
        );
        fwss.addApprovedProvider(1);

        factory = new ExampleSponsoredDataSetFactory(fwss);
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

    function _hashMetadataEntries(string[] memory keys, string[] memory values) internal pure returns (bytes32) {
        bytes32[] memory entryHashes = new bytes32[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            entryHashes[i] = keccak256(
                abi.encode(
                    SignatureVerificationLib.METADATA_ENTRY_TYPEHASH,
                    keccak256(bytes(keys[i])),
                    keccak256(bytes(values[i]))
                )
            );
        }
        return keccak256(abi.encodePacked(entryHashes));
    }

    function _createDataSetStructHash(address _payee, string[] memory keys, string[] memory values)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                SignatureVerificationLib.CREATE_DATA_SET_TYPEHASH,
                uint256(0),
                _payee,
                _hashMetadataEntries(keys, values)
            )
        );
    }

    function _createDataSetSigner(address _payee, string[] memory keys, string[] memory values)
        internal
        view
        returns (address)
    {
        bytes32 digest = _hashTypedDataV4(_createDataSetStructHash(_payee, keys, values));
        return ecrecover(digest, 27, bytes32(uint256(1)), bytes32(uint256(1)));
    }

    function _assertCreateDataSetSignerAuthorized(
        ExampleSponsoredDataSet dataSet,
        string[] memory keys,
        string[] memory values
    ) internal {
        address signer = _createDataSetSigner(payee, keys, values);
        assertTrue(signer != address(0));
        assertEq(
            sessionKeyRegistry.authorizationExpiry(
                address(dataSet), signer, SignatureVerificationLib.CREATE_DATA_SET_TYPEHASH
            ),
            type(uint256).max
        );
        assertEq(
            sessionKeyRegistry.authorizationExpiry(
                address(dataSet), address(0), SignatureVerificationLib.CREATE_DATA_SET_TYPEHASH
            ),
            0
        );
    }

    function _addPiecesStructHash(Cids.Cid memory piece, uint256 nonce) internal pure returns (bytes32) {
        bytes32 cidHash = keccak256(abi.encode(CID_TYPEHASH, keccak256(piece.data)));
        bytes32 cidsHash = keccak256(abi.encodePacked(cidHash));

        bytes32 emptyMetadataEntriesHash = keccak256(abi.encodePacked(new bytes32[](0)));
        bytes32 pieceMetaHash = keccak256(abi.encode(PIECE_METADATA_TYPEHASH, uint256(0), emptyMetadataEntriesHash));
        bytes32 pieceMetasHash = keccak256(abi.encodePacked(pieceMetaHash));

        return keccak256(abi.encode(ADD_PIECES_TYPEHASH, uint256(0), nonce, cidsHash, pieceMetasHash));
    }

    // Deploys a ExampleSponsoredDataSet with explicit curator/beneficiary, funds it, creates the data set on-chain, and binds it.
    function _setupDataSetWith(uint256 fundAmount, address _curator, address _beneficiary)
        internal
        returns (ExampleSponsoredDataSet dataSet, uint256 dataSetId)
    {
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);

        dataSet = factory.initDataSet(payee, emptyKeys, emptyValues, _curator, _beneficiary);
        _assertCreateDataSetSignerAuthorized(dataSet, emptyKeys, emptyValues);

        token.approve(address(payments), fundAmount);
        payments.deposit(IERC20(address(token)), address(dataSet), fundAmount);

        bytes memory nicksSig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1)), uint8(27));
        bytes memory extraData = abi.encode(address(dataSet), uint256(0), emptyKeys, emptyValues, nicksSig);
        vm.prank(serviceProvider);
        dataSetId = pdpVerifier.createDataSet{value: CLEANUP_DEPOSIT}(address(fwss), extraData);

        dataSet.bind(dataSetId);
    }

    // Deploys a ExampleSponsoredDataSet, funds it, creates the data set on-chain, and binds it.
    function _setupDataSet(uint256 fundAmount) internal returns (ExampleSponsoredDataSet dataSet, uint256 dataSetId) {
        return _setupDataSetWith(fundAmount, curator, beneficiary);
    }

    // Adds a single piece to the data set; curator signs the AddPieces message.
    function _addPiece(ExampleSponsoredDataSet dataSet, Cids.Cid memory piece) internal {
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
    function _scheduleRemoval(ExampleSponsoredDataSet dataSet, uint256[] memory pieceIds) internal {
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
        (ExampleSponsoredDataSet dataSet,) = _setupDataSet(100 * 10 ** token.decimals());
        Cids.Cid memory piece = Cids.CommPv2FromDigest(0, 4, keccak256("test piece"));
        _addPiece(dataSet, piece);
    }

    function testIsNotFinalizedInitially() public {
        (ExampleSponsoredDataSet dataSet,) = _setupDataSet(100 * 10 ** token.decimals());
        assertFalse(dataSet.isFinalized());
    }

    function testFinalizeByCurator() public {
        (ExampleSponsoredDataSet dataSet,) = _setupDataSet(100 * 10 ** token.decimals());
        vm.prank(curator);
        dataSet.finalize();
        assertTrue(dataSet.isFinalized());
    }

    function testFinalizeRevokesCuratorPermissions() public {
        (ExampleSponsoredDataSet dataSet, uint256 dsId) = _setupDataSet(100 * 10 ** token.decimals());
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
        (ExampleSponsoredDataSet dataSet,) = _setupDataSet(100 * 10 ** token.decimals());
        vm.expectRevert(abi.encodeWithSelector(ExampleSponsoredDataSet.NotCurator.selector, curator, address(this)));
        dataSet.finalize();
    }

    function testReleaseRevertsIfNotBound() public {
        string[] memory emptyKeys = new string[](0);
        string[] memory emptyValues = new string[](0);
        ExampleSponsoredDataSet dataSet = factory.initDataSet(payee, emptyKeys, emptyValues, curator, beneficiary);
        _assertCreateDataSetSignerAuthorized(dataSet, emptyKeys, emptyValues);
        vm.expectRevert(ExampleSponsoredDataSet.DataSetNotBound.selector);
        dataSet.release(IERC20(address(token)));
    }

    function testReleaseRevertsIfNotDeleted() public {
        (ExampleSponsoredDataSet dataSet,) = _setupDataSet(100 * 10 ** token.decimals());
        vm.expectRevert(ExampleSponsoredDataSet.DataSetNotDeleted.selector);
        dataSet.release(IERC20(address(token)));
    }

    function testRelease() public {
        (ExampleSponsoredDataSet dataSet, uint256 dsId) = _setupDataSet(100 * 10 ** token.decimals());

        vm.prank(serviceProvider);
        pdpVerifier.deleteDataSet(dsId, "");

        (uint256 funds, uint256 lockupCurrent,,) = payments.accounts(IERC20(address(token)), address(dataSet));
        uint256 available = funds - lockupCurrent;

        dataSet.release(IERC20(address(token)));
        assertEq(token.balanceOf(beneficiary), available);
    }

    // Returns the nonce the factory will use for its next initDataSet deployment.
    function _factoryNonce() internal view returns (uint64) {
        return uint64(vm.getNonce(address(factory)));
    }

    // Seeds proving state for a FWSS data set and PDPVerifier via vm.store, satisfying both
    // hasBeenProvenRecently (FWSS) and getDataSetLastProvenEpoch > finalizedEpoch (PDPVerifier).
    function _fakeProven(uint256 dsId) internal {
        if (vm.getBlockNumber() <= 1) {
            vm.roll(2);
        }
        uint256 activationEpoch = vm.getBlockNumber() - 1;
        vm.store(address(fwss), keccak256(abi.encode(dsId, PROVING_ACTIVATION_EPOCH_SLOT)), bytes32(activationEpoch));
        vm.store(address(fwss), keccak256(abi.encode(dsId, PROVEN_THIS_PERIOD_SLOT)), bytes32(uint256(1)));
        vm.store(
            address(pdpVerifier),
            keccak256(abi.encode(dsId, DATA_SET_LAST_PROVEN_EPOCH_SLOT)),
            bytes32(vm.getBlockNumber())
        );
    }

    function testMigrateRevertsIfNotFinalized() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source,) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        _setupDataSet(10 ** token.decimals());
        vm.expectRevert(ExampleSponsoredDataSet.NotFinalized.selector);
        source.migrate(factory, sourceNonce, successorNonce);
    }

    function testMigrateRevertsIfSuccessorNotFinalized() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        _setupDataSet(10 ** token.decimals());
        vm.prank(curator);
        source.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorNotFinalized.selector);
        source.migrate(factory, sourceNonce, successorNonce);
    }

    function testMigrateRevertsIfNotTerminated() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source,) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        (, uint256 dstId) = _setupDataSet(10 ** token.decimals());
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce)).finalize();
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
        vm.expectRevert(ExampleSponsoredDataSet.DataSetNotTerminated.selector);
        source.migrate(factory, sourceNonce, successorNonce);
    }

    function testMigrateRevertsIfSuccessorNotProven() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        _setupDataSet(10 ** token.decimals());
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce)).finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorNotProven.selector);
        source.migrate(factory, sourceNonce, successorNonce);
    }

    function testMigrateRevertsIfSuccessorBeneficiaryMismatch() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        address otherBeneficiary = address(0xbb);
        uint64 successorNonce = _factoryNonce();
        (ExampleSponsoredDataSet successor, uint256 dstId) =
            _setupDataSetWith(10 ** token.decimals(), curator, otherBeneficiary);
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorBeneficiaryMismatch.selector);
        source.migrate(factory, sourceNonce, successorNonce);
    }

    function testMigrate() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        (, uint256 dstId) = _setupDataSet(10 ** token.decimals());
        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);

        (uint256 funds, uint256 lockupCurrent,,) = payments.accounts(IERC20(address(token)), address(source));
        uint256 available = funds - lockupCurrent;

        vm.expectEmit(false, false, false, true);
        emit ExampleSponsoredDataSet.Migrated(address(successor));
        source.migrate(factory, sourceNonce, successorNonce);

        (uint256 dstFunds,,,) = payments.accounts(IERC20(address(token)), address(successor));
        assertEq(dstFunds, 10 ** token.decimals() + available);
    }

    // `_transferFunds` computes `available` from a raw `PAYMENTS.accounts()` read, which is just
    // the last-settled snapshot -- it doesn't account for lockup that has accrued on an active
    // (non-terminated) rail since `lockupLastSettledAt`. `migrate()` is specifically reachable
    // while the source rail is still active (the SP-inactivity branch of
    // `_checkMigrationConditions` fires with `pdpEndEpoch == 0`), so a long-idle account can have
    // a materially stale snapshot by the time `migrate()` runs. The migration should still
    // succeed and move exactly the true (fully-settled) available balance.
    function testMigrateSettlesStaleLockupBeforeTransferringFunds() public {
        uint64 sourceNonce = _factoryNonce();
        uint256 fundAmount = 500_000 * 10 ** token.decimals();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(fundAmount);
        uint64 successorNonce = _factoryNonce();
        (, uint256 dstId) = _setupDataSet(10 ** token.decimals());
        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();

        // Simulate the SP's rail still actively accruing lockup at a nonzero rate, as it would
        // while genuinely storing data (normally driven by nextProvingPeriod/addPieces via FWSS;
        // done directly here since FWSS is the rail operator).
        uint256 rate = 1 * 10 ** token.decimals();
        uint256 srcRailId = source.railId();
        vm.prank(address(fwss));
        payments.modifyRailPayment(srcRailId, rate, 0);
        uint256 rateSetEpoch = vm.getBlockNumber();

        // The source goes dark: nobody proves it, and -- crucially -- nobody touches its
        // Payments account (deposit/withdraw/rail modification), so its lockup is never
        // re-settled before migrate() is called.
        _fakeProven(srcId);
        vm.roll(rateSetEpoch + PDP_INACTIVITY_WINDOW / 2 + 10000);
        _fakeProven(dstId);

        (uint256 staleFunds, uint256 staleLockup,,) = payments.accounts(IERC20(address(token)), address(source));
        uint256 elapsed = vm.getBlockNumber() - rateSetEpoch;
        // True available if the account were settled right now -- the account is solvent
        // (rate * elapsed is well within staleFunds - staleLockup), this is purely about
        // `_transferFunds` trusting a stale read rather than the source running out of funds.
        uint256 trueAvailable = staleFunds - staleLockup - rate * elapsed;

        (uint256 dstFundsBefore,,,) = payments.accounts(IERC20(address(token)), address(successor));

        vm.expectEmit(false, false, false, true);
        emit ExampleSponsoredDataSet.Migrated(address(successor));
        source.migrate(factory, sourceNonce, successorNonce);

        (uint256 dstFunds,,,) = payments.accounts(IERC20(address(token)), address(successor));
        assertEq(dstFunds, dstFundsBefore + trueAvailable);
    }

    // -------- Challenged migration --------

    struct PropMig {
        uint64 sourceNonce;
        ExampleSponsoredDataSet source;
        uint256 srcId;
        uint64 successorNonce;
        ExampleSponsoredDataSet successor;
        uint256 dstId;
        uint256 migrationId;
    }

    function _setupProposedMigration() internal returns (PropMig memory m) {
        m.sourceNonce = _factoryNonce();
        (m.source, m.srcId) = _setupDataSet(100 * 10 ** token.decimals());
        m.successorNonce = _factoryNonce();
        (m.successor, m.dstId) = _setupDataSet(10 ** token.decimals());
        vm.prank(curator);
        m.source.finalize();
        vm.prank(curator);
        m.successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(m.srcId, "");
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(m.dstId);
        m.migrationId =
            m.source.proposeMigration{value: m.source.MIGRATION_DEPOSIT()}(factory, m.sourceNonce, m.successorNonce);
    }

    function testProposeMigration() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        (, uint256 dstId) = _setupDataSet(10 ** token.decimals());
        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);

        vm.expectEmit(true, false, false, true);
        emit ExampleSponsoredDataSet.MigrationProposed(0, address(this), dstId);
        uint256 migrationId =
            source.proposeMigration{value: source.MIGRATION_DEPOSIT()}(factory, sourceNonce, successorNonce);

        assertEq(migrationId, 0);
        assertEq(source.nextMigrationId(), 1);
        (address dep,,,,) = source.pendingMigrations(migrationId);
        assertEq(dep, address(this));
    }

    function testProposeMigrationRevertsIfIncorrectDeposit() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source,) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        _setupDataSet(10 ** token.decimals());
        uint256 deposit = source.MIGRATION_DEPOSIT();
        vm.expectRevert(ExampleSponsoredDataSet.IncorrectDeposit.selector);
        source.proposeMigration{value: deposit - 1}(factory, sourceNonce, successorNonce);
    }

    function testProposeMigrationRevertsIfNotFinalized() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source,) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        _setupDataSet(10 ** token.decimals());
        uint256 deposit = source.MIGRATION_DEPOSIT();
        vm.expectRevert(ExampleSponsoredDataSet.NotFinalized.selector);
        source.proposeMigration{value: deposit}(factory, sourceNonce, successorNonce);
    }

    function testProposeMigrationRevertsIfSuccessorNotFinalized() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        _setupDataSet(10 ** token.decimals());
        vm.prank(curator);
        source.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        uint256 deposit = source.MIGRATION_DEPOSIT();
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorNotFinalized.selector);
        source.proposeMigration{value: deposit}(factory, sourceNonce, successorNonce);
    }

    function testProposeMigrationRevertsIfNotTerminated() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source,) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        (, uint256 dstId) = _setupDataSet(10 ** token.decimals());
        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
        uint256 deposit = source.MIGRATION_DEPOSIT();
        vm.expectRevert(ExampleSponsoredDataSet.DataSetNotTerminated.selector);
        source.proposeMigration{value: deposit}(factory, sourceNonce, successorNonce);
    }

    function testProposeMigrationRevertsIfSuccessorNotProven() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        _setupDataSet(10 ** token.decimals());
        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        uint256 deposit = source.MIGRATION_DEPOSIT();
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorNotProven.selector);
        source.proposeMigration{value: deposit}(factory, sourceNonce, successorNonce);
    }

    function testProposeMigrationRevertsIfSuccessorBeneficiaryMismatch() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        address otherBeneficiary = address(0xbb);
        uint64 successorNonce = _factoryNonce();
        (ExampleSponsoredDataSet successor, uint256 dstId) =
            _setupDataSetWith(10 ** token.decimals(), curator, otherBeneficiary);
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
        uint256 deposit = source.MIGRATION_DEPOSIT();
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorBeneficiaryMismatch.selector);
        source.proposeMigration{value: deposit}(factory, sourceNonce, successorNonce);
    }

    function testProposeMigrationRevertsIfPieceMismatch() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        (, uint256 dstId) = _setupDataSet(10 ** token.decimals());
        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
        _addPiece(source, Cids.CommPv2FromDigest(0, 4, keccak256("piece A")));
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
        uint256 deposit = source.MIGRATION_DEPOSIT();
        vm.expectRevert(ExampleSponsoredDataSet.PieceMismatch.selector);
        source.proposeMigration{value: deposit}(factory, sourceNonce, successorNonce);
    }

    function testCompleteMigrationRevertsIfChallengePeriodNotExpired() public {
        PropMig memory m = _setupProposedMigration();
        vm.expectRevert(ExampleSponsoredDataSet.ChallengePeriodNotExpired.selector);
        m.source.completeMigration(m.migrationId);
    }

    function testCompleteMigration() public {
        PropMig memory m = _setupProposedMigration();
        vm.roll(vm.getBlockNumber() + m.source.CHALLENGE_PERIOD() + 1);

        (uint256 srcFunds, uint256 srcLockup,,) = payments.accounts(IERC20(address(token)), address(m.source));
        uint256 available = srcFunds - srcLockup;
        uint256 balanceBefore = address(this).balance;

        vm.expectEmit(true, false, false, true);
        emit ExampleSponsoredDataSet.MigrationCompleted(m.migrationId, address(m.successor));
        m.source.completeMigration(m.migrationId);

        (uint256 dstFunds,,,) = payments.accounts(IERC20(address(token)), address(m.successor));
        assertEq(dstFunds, 10 ** token.decimals() + available);
        assertEq(address(this).balance, balanceBefore + m.source.MIGRATION_DEPOSIT());
        (address dep,,,,) = m.source.pendingMigrations(m.migrationId);
        assertEq(dep, address(0));
    }

    function testCompleteMigrationSuccessorTerminated() public {
        PropMig memory m = _setupProposedMigration();
        vm.prank(serviceProvider);
        fwss.terminateService(m.dstId, "");
        vm.roll(vm.getBlockNumber() + m.source.CHALLENGE_PERIOD() + 1);

        uint256 balanceBefore = address(this).balance;
        m.source.completeMigration(m.migrationId);

        assertEq(address(this).balance, balanceBefore + m.source.MIGRATION_DEPOSIT());
        (address dep,,,,) = m.source.pendingMigrations(m.migrationId);
        assertEq(dep, address(0));
    }

    function testCompleteMigrationRevertsIfSuccessorDeleted() public {
        PropMig memory m = _setupProposedMigration();
        uint256 lastProvenEpoch = pdpVerifier.getDataSetLastProvenEpoch(m.dstId);
        vm.roll(lastProvenEpoch + pdpVerifier.INACTIVITY_WINDOW() + 1);
        vm.prank(serviceProvider);
        pdpVerifier.deleteDataSet(m.dstId, "");

        // Migrated funds must land on a live successor; a deleted successor can never
        // be completed to, even long after an uneventful challenge period.
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorDeleted.selector);
        m.source.completeMigration(m.migrationId);
    }

    function testCompleteMigrationOriginDeleted() public {
        PropMig memory m = _setupProposedMigration();
        // Origin can only be deleted after the payment lockup expires (endEpoch=86401).
        // Rolling past that also satisfies the challenge period (2880 << 86401).
        vm.roll(86402);
        payments.settleRail(m.source.railId(), 86401);
        vm.prank(serviceProvider);
        pdpVerifier.deleteDataSet(m.srcId, "");

        uint256 balanceBefore = address(this).balance;
        m.source.completeMigration(m.migrationId);

        assertEq(address(this).balance, balanceBefore + m.source.MIGRATION_DEPOSIT());
    }

    function testChallengeMigrationRevertsIfPiecesMatch() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        (, uint256 dstId) = _setupDataSet(10 ** token.decimals());
        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
        Cids.Cid memory piece = Cids.CommPv2FromDigest(0, 4, keccak256("matching piece"));
        _addPiece(source, piece);
        _addPiece(successor, piece);
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
        uint256 migrationId =
            source.proposeMigration{value: source.MIGRATION_DEPOSIT()}(factory, sourceNonce, successorNonce);
        vm.expectRevert(ExampleSponsoredDataSet.ChallengeFailed.selector);
        source.challengeMigration(migrationId, 0);
    }

    function testChallengeMigrationRevertsIfChallengePeriodExpired() public {
        PropMig memory m = _setupProposedMigration();
        vm.roll(vm.getBlockNumber() + m.source.CHALLENGE_PERIOD() + 1);
        vm.expectRevert(ExampleSponsoredDataSet.ChallengePeriodExpired.selector);
        m.source.challengeMigration(m.migrationId, 0);
    }

    function testChallengeMigration() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source, uint256 srcId) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        (, uint256 dstId) = _setupDataSet(10 ** token.decimals());
        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
        _addPiece(source, Cids.CommPv2FromDigest(0, 4, keccak256("piece A")));
        _addPiece(successor, Cids.CommPv2FromDigest(0, 4, keccak256("piece B")));
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(srcId, "");
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
        uint256 migrationId =
            source.proposeMigration{value: source.MIGRATION_DEPOSIT()}(factory, sourceNonce, successorNonce);

        address challenger = address(0xc1);
        vm.expectEmit(true, false, false, true);
        emit ExampleSponsoredDataSet.MigrationInvalid(migrationId, 0);
        vm.prank(challenger);
        source.challengeMigration(migrationId, 0);

        assertEq(challenger.balance, source.MIGRATION_DEPOSIT() / 2);
        (address dep,,,,) = source.pendingMigrations(migrationId);
        assertEq(dep, address(0));
    }

    // Sets up a proposed migration with mismatched pieces between source and successor, then
    // deletes the successor data set while the migration is still within its challenge period.
    // The successor is left dormant past the inactivity window before proposeMigration so it can
    // be deleted immediately afterward (proposeMigration's "proven after finalized" check still
    // holds, since the last-proven epoch doesn't move while time passes without a proof).
    function _setupProposedMigrationWithDeletedSuccessor() internal returns (PropMig memory m) {
        m.sourceNonce = _factoryNonce();
        (m.source, m.srcId) = _setupDataSet(100 * 10 ** token.decimals());
        m.successorNonce = _factoryNonce();
        (, m.dstId) = _setupDataSet(10 ** token.decimals());
        m.successor = ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), m.successorNonce));
        _addPiece(m.source, Cids.CommPv2FromDigest(0, 4, keccak256("piece A")));
        _addPiece(m.successor, Cids.CommPv2FromDigest(0, 4, keccak256("piece B")));
        vm.prank(curator);
        m.source.finalize();
        vm.prank(curator);
        m.successor.finalize();
        vm.prank(serviceProvider);
        fwss.terminateService(m.srcId, "");
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(m.dstId);

        vm.roll(vm.getBlockNumber() + pdpVerifier.INACTIVITY_WINDOW() + 1);

        m.migrationId =
            m.source.proposeMigration{value: m.source.MIGRATION_DEPOSIT()}(factory, m.sourceNonce, m.successorNonce);

        // The successor is now abandoned, so anyone can delete it immediately, hiding the piece
        // mismatch from challengers before the migration's challenge period (2880 blocks) elapses.
        pdpVerifier.deleteDataSet(m.dstId, "");
    }

    function testChallengeMigrationSucceedsIfSuccessorDeletedDuringChallenge() public {
        PropMig memory m = _setupProposedMigrationWithDeletedSuccessor();

        address challenger = address(0xc1);
        vm.expectEmit(true, false, false, true);
        emit ExampleSponsoredDataSet.MigrationInvalid(m.migrationId, 0);
        vm.prank(challenger);
        m.source.challengeMigration(m.migrationId, 0);

        assertEq(challenger.balance, m.source.MIGRATION_DEPOSIT() / 2);
        (address dep,,,,) = m.source.pendingMigrations(m.migrationId);
        assertEq(dep, address(0));
    }

    function testCompleteMigrationRevertsIfSuccessorDeletedDuringChallenge() public {
        PropMig memory m = _setupProposedMigrationWithDeletedSuccessor();
        vm.roll(vm.getBlockNumber() + m.source.CHALLENGE_PERIOD() + 1);

        vm.expectRevert(ExampleSponsoredDataSet.SuccessorDeleted.selector);
        m.source.completeMigration(m.migrationId);
    }

    // -------- Unfinalized migration --------

    function _setupUnfinalizedMigration(bool finalizeSuccessor)
        internal
        returns (
            uint64 sourceNonce,
            ExampleSponsoredDataSet source,
            uint64 successorNonce,
            ExampleSponsoredDataSet successor,
            uint256 dstId
        )
    {
        sourceNonce = _factoryNonce();
        (source,) = _setupDataSet(100 * 10 ** token.decimals());
        successorNonce = _factoryNonce();
        (successor, dstId) = _setupDataSet(10 ** token.decimals());
        if (finalizeSuccessor) {
            vm.prank(curator);
            successor.finalize();
        }
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
    }

    function testMigrateUnfinalized(bool finalizeSuccessor) public {
        (uint64 sourceNonce, ExampleSponsoredDataSet source, uint64 successorNonce, ExampleSponsoredDataSet successor,)
        = _setupUnfinalizedMigration(finalizeSuccessor);

        (uint256 srcFunds, uint256 srcLockup,,) = payments.accounts(IERC20(address(token)), address(source));
        uint256 available = srcFunds - srcLockup;
        (uint256 dstFundsBefore,,,) = payments.accounts(IERC20(address(token)), address(successor));

        vm.expectEmit(false, false, false, true);
        emit ExampleSponsoredDataSet.Migrated(address(successor));
        vm.prank(curator);
        source.migrateUnfinalized(factory, sourceNonce, successorNonce);

        (uint256 dstFunds,,,) = payments.accounts(IERC20(address(token)), address(successor));
        assertEq(dstFunds, dstFundsBefore + available);
    }

    function testMigrateUnfinalizedRevertsIfNotCurator() public {
        (uint64 sourceNonce, ExampleSponsoredDataSet source, uint64 successorNonce,,) = _setupUnfinalizedMigration(true);
        vm.expectRevert(abi.encodeWithSelector(ExampleSponsoredDataSet.NotCurator.selector, curator, address(this)));
        source.migrateUnfinalized(factory, sourceNonce, successorNonce);
    }

    function testMigrateUnfinalizedRevertsIfAlreadyFinalized() public {
        (uint64 sourceNonce, ExampleSponsoredDataSet source, uint64 successorNonce,,) = _setupUnfinalizedMigration(true);
        vm.prank(curator);
        source.finalize();
        vm.prank(curator);
        vm.expectRevert(ExampleSponsoredDataSet.AlreadyFinalized.selector);
        source.migrateUnfinalized(factory, sourceNonce, successorNonce);
    }

    function testMigrateUnfinalizedRevertsIfSuccessorNotProven() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source,) = _setupDataSet(100 * 10 ** token.decimals());
        uint64 successorNonce = _factoryNonce();
        (ExampleSponsoredDataSet successor,) = _setupDataSet(10 ** token.decimals());
        vm.prank(curator);
        successor.finalize();
        vm.prank(curator);
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorNotProven.selector);
        source.migrateUnfinalized(factory, sourceNonce, successorNonce);
    }

    function testMigrateUnfinalizedRevertsIfSuccessorCuratorMismatch() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source,) = _setupDataSet(100 * 10 ** token.decimals());
        address otherCurator = address(0xcc);
        uint64 successorNonce = _factoryNonce();
        (ExampleSponsoredDataSet successor, uint256 dstId) =
            _setupDataSetWith(10 ** token.decimals(), otherCurator, beneficiary);
        vm.prank(otherCurator);
        successor.finalize();
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
        vm.prank(curator);
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorCuratorMismatch.selector);
        source.migrateUnfinalized(factory, sourceNonce, successorNonce);
    }

    function testMigrateUnfinalizedRevertsIfSuccessorBeneficiaryMismatch() public {
        uint64 sourceNonce = _factoryNonce();
        (ExampleSponsoredDataSet source,) = _setupDataSet(100 * 10 ** token.decimals());
        address otherBeneficiary = address(0xbb);
        uint64 successorNonce = _factoryNonce();
        (ExampleSponsoredDataSet successor, uint256 dstId) =
            _setupDataSetWith(10 ** token.decimals(), curator, otherBeneficiary);
        vm.prank(curator);
        successor.finalize();
        vm.roll(vm.getBlockNumber() + 1);
        _fakeProven(dstId);
        vm.prank(curator);
        vm.expectRevert(ExampleSponsoredDataSet.SuccessorBeneficiaryMismatch.selector);
        source.migrateUnfinalized(factory, sourceNonce, successorNonce);
    }
}
