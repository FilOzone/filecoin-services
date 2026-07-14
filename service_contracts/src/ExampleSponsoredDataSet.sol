// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinWarmStorageService, PDP_INACTIVITY_WINDOW} from "./FilecoinWarmStorageService.sol";
import {FilecoinPayV1 as FilecoinPay} from "@fws-payments/FilecoinPayV1.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignatureVerificationLib} from "./lib/SignatureVerificationLib.sol";
import {FilecoinWarmStorageServiceStateInternalLibrary} from "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";
import {PDPVerifier} from "@pdp/PDPVerifier.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {FVMPay} from "@fvm-solidity/FVMPay.sol";

function hashTypedDataV4(FilecoinWarmStorageService fwss, bytes32 structHash) view returns (bytes32) {
    (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) = fwss.eip712Domain();
    bytes32 domainSeparator = keccak256(
        abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            chainId,
            verifyingContract
        )
    );
    return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
}

contract ExampleSponsoredDataSetFactory {
    event NewSponsoredDataSet(
        ExampleSponsoredDataSet indexed dataSet, address indexed curator, address indexed payee, address beneficiary
    );

    FilecoinWarmStorageService public immutable WARM_STORAGE_SERVICE;
    FilecoinPay public immutable PAYMENTS;
    SessionKeyRegistry public immutable SESSION_KEY_REGISTRY;
    IERC20 public immutable TOKEN;
    ExampleSponsoredDataSet public immutable IMPLEMENTATION;

    constructor(FilecoinWarmStorageService fwss) {
        WARM_STORAGE_SERVICE = fwss;
        FilecoinPay filecoinPay = FilecoinPay(fwss.paymentsContractAddress());
        PAYMENTS = filecoinPay;
        SessionKeyRegistry sessionKeyRegistry = fwss.sessionKeyRegistry();
        SESSION_KEY_REGISTRY = sessionKeyRegistry;
        IERC20 token = fwss.usdfcTokenAddress();
        TOKEN = token;
        IMPLEMENTATION = new ExampleSponsoredDataSet(fwss, filecoinPay, sessionKeyRegistry, token);
    }

    function initDataSet(
        address payee,
        string[] calldata metadataKeys,
        string[] calldata metadataValues,
        address curator,
        address beneficiary
    ) external returns (ExampleSponsoredDataSet) {
        bytes32 createDataSetStructHash =
            SignatureVerificationLib.createDataSetStructHash(0, payee, metadataKeys, metadataValues);
        bytes32 createDataSetHash = hashTypedDataV4(WARM_STORAGE_SERVICE, createDataSetStructHash);
        // Sign CreateDataSet using Nick's Method
        address createDataSetSigner = ecrecover(createDataSetHash, 27, bytes32(uint256(1)), bytes32(uint256(1)));
        ExampleSponsoredDataSet dataSet = ExampleSponsoredDataSet(LibClone.clone(address(IMPLEMENTATION)));
        dataSet.initialize(createDataSetSigner, curator, beneficiary);
        emit NewSponsoredDataSet(dataSet, curator, payee, beneficiary);
        return dataSet;
    }
}

/// @dev This is an example of how to implement a noncustodial data set.
/// This contract pays for the data set and authorizes a key to perform its curation.
contract ExampleSponsoredDataSet {
    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;

    error AlreadyInitialized();
    error NotPayer(address expected, address actual);
    error NotCurator(address expected, address actual);
    error AlreadyFinalized();
    error DataSetNotBound();
    error DataSetNotDeleted();
    error DataSetDeleted();
    error DataSetNotTerminated();
    error NotFinalized();
    error SuccessorNotBound();
    error SuccessorNotFinalized();
    error SuccessorNotProven();
    error PieceMismatch();
    error FactoryMismatch();
    error ChallengePeriodNotExpired();
    error ChallengePeriodExpired();
    error ChallengeFailed();
    error MigrationNotFound();
    error IncorrectDeposit();
    error PayFailed();
    error BurnFailed();
    error SuccessorCuratorMismatch();
    error SuccessorBeneficiaryMismatch();
    error SuccessorDeleted();

    event Migrated(address successor);
    event MigrationProposed(uint256 indexed migrationId, address depositor, uint256 successorDataSetId);
    event MigrationCompleted(uint256 indexed migrationId, address successor);
    event MigrationInvalid(uint256 indexed migrationId, uint256 atIndex);

    struct PendingMigration {
        address depositor;
        ExampleSponsoredDataSetFactory factory;
        uint64 thisNonce;
        uint64 successorNonce;
        uint256 depositEpoch;
    }

    string private constant ORIGIN = "ExampleSponsoredDataSet";

    uint256 public constant CHALLENGE_PERIOD = 2880;
    uint256 public constant MIGRATION_DEPOSIT = 1 ether;

    FilecoinWarmStorageService public immutable WARM_STORAGE_SERVICE;
    FilecoinPay public immutable PAYMENTS;
    SessionKeyRegistry public immutable SESSION_KEY_REGISTRY;
    IERC20 public immutable TOKEN;
    PDPVerifier public immutable PDP_VERIFIER;

    // The curator can add and remove pieces from the data set until they finalize it
    address public CURATOR;
    // The beneficiary receives the funds in the event the data set is deleted without a successful migration
    address public BENEFICIARY;

    uint256 public dataSetId;
    uint256 public railId;
    uint256 public finalizedEpoch;

    mapping(uint256 => PendingMigration) public pendingMigrations;
    uint256 public nextMigrationId;

    constructor(
        FilecoinWarmStorageService fwss,
        FilecoinPay filecoinPay,
        SessionKeyRegistry sessionKeyRegistry,
        IERC20 token
    ) {
        WARM_STORAGE_SERVICE = fwss;
        PAYMENTS = filecoinPay;
        SESSION_KEY_REGISTRY = sessionKeyRegistry;
        TOKEN = token;
        PDP_VERIFIER = PDPVerifier(fwss.pdpVerifierAddress());
    }

    function initialize(address createDataSetSigner, address curator, address beneficiary) external {
        require(CURATOR == address(0), AlreadyInitialized());

        bytes32[] memory createPerms = new bytes32[](1);
        createPerms[0] = SignatureVerificationLib.CREATE_DATA_SET_TYPEHASH;
        SESSION_KEY_REGISTRY.login(createDataSetSigner, type(uint256).max, createPerms, ORIGIN);

        bytes32[] memory curatorPerms = new bytes32[](2);
        curatorPerms[0] = SignatureVerificationLib.ADD_PIECES_TYPEHASH;
        curatorPerms[1] = SignatureVerificationLib.SCHEDULE_PIECE_REMOVALS_TYPEHASH;
        SESSION_KEY_REGISTRY.login(curator, type(uint256).max, curatorPerms, ORIGIN);
        PAYMENTS.setOperatorApproval(
            TOKEN, address(WARM_STORAGE_SERVICE), true, type(uint256).max, type(uint256).max, type(uint256).max
        );

        CURATOR = curator;
        BENEFICIARY = beneficiary;
    }

    function bind(uint256 _dataSetId) external {
        (address payer, uint256 pdpRailId) = WARM_STORAGE_SERVICE.getDataSetPayerAndRailId(_dataSetId);
        require(payer == address(this), NotPayer(address(this), payer));
        dataSetId = _dataSetId;
        railId = pdpRailId;
    }

    function finalize() external {
        require(msg.sender == CURATOR, NotCurator(CURATOR, msg.sender));
        require(finalizedEpoch == 0, AlreadyFinalized());
        bytes32[] memory curatorPerms = new bytes32[](2);
        curatorPerms[0] = SignatureVerificationLib.ADD_PIECES_TYPEHASH;
        curatorPerms[1] = SignatureVerificationLib.SCHEDULE_PIECE_REMOVALS_TYPEHASH;
        SESSION_KEY_REGISTRY.revoke(CURATOR, curatorPerms, ORIGIN);
        finalizedEpoch = block.number;
    }

    function isFinalized() public view returns (bool) {
        return SESSION_KEY_REGISTRY.authorizationExpiry(
            address(this), CURATOR, SignatureVerificationLib.ADD_PIECES_TYPEHASH
        ) == 0;
    }

    function release(IERC20 token) external {
        require(dataSetId != 0, DataSetNotBound());
        (address payer,) = WARM_STORAGE_SERVICE.getDataSetPayerAndRailId(dataSetId);
        require(payer == address(0), DataSetNotDeleted());
        (,, uint256 available,) = PAYMENTS.getAccountInfoIfSettled(token, address(this));
        PAYMENTS.withdrawTo(token, BENEFICIARY, available);
    }

    /// @notice Migrates available funds to a verified successor data set from the same factory.
    /// @dev Checks: both are finalized, source in FWSS is not deleted and either terminated or the
    ///      SP has been inactive for at least half the PDP inactivity window, successor is proven and has the
    ///      same active pieces in the same order as the source.
    ///      The source and successor addresses are derived deterministically from (factory, nonce)
    ///      using the EVM CREATE address formula, proving both were deployed by the same factory.
    function migrate(ExampleSponsoredDataSetFactory factory, uint64 thisNonce, uint64 successorNonce) external {
        ExampleSponsoredDataSet successor = _resolveSuccessor(factory, thisNonce, successorNonce);
        uint256 successorDataSetId = _checkMigrationConditions(successor);
        _verifyPiecesMatch(dataSetId, successorDataSetId);
        _transferFunds(factory, successor);
        emit Migrated(address(successor));
    }

    /// @notice The curator migrates funds from a non-finalized data set to a successor with the same curator and beneficiary.
    /// @dev Requires the caller to be the curator, the source to be non-finalized, and the successor to be
    ///      bound and proven. Pieces are not checked; the curator vouches for the transition.
    function migrateUnfinalized(ExampleSponsoredDataSetFactory factory, uint64 thisNonce, uint64 successorNonce)
        external
    {
        require(msg.sender == CURATOR, NotCurator(CURATOR, msg.sender));
        require(!isFinalized(), AlreadyFinalized());
        ExampleSponsoredDataSet successor = _resolveSuccessor(factory, thisNonce, successorNonce);
        require(successor.CURATOR() == CURATOR, SuccessorCuratorMismatch());
        require(successor.BENEFICIARY() == BENEFICIARY, SuccessorBeneficiaryMismatch());
        uint256 successorDataSetId = successor.dataSetId();
        require(successorDataSetId != 0, SuccessorNotBound());
        require(WARM_STORAGE_SERVICE.hasBeenProvenRecently(successorDataSetId), SuccessorNotProven());
        _transferFunds(factory, successor);
        emit Migrated(address(successor));
    }

    /// @notice Proposes a challenged migration to a large-data successor without iterating all pieces.
    /// @dev Opens a challenge window during which anyone can disprove piece equality by index.
    ///      Requires a FIL deposit as a bond; depositor gets it back after the challenge period.
    function proposeMigration(ExampleSponsoredDataSetFactory factory, uint64 thisNonce, uint64 successorNonce)
        external
        payable
        returns (uint256 migrationId)
    {
        require(msg.value == MIGRATION_DEPOSIT, IncorrectDeposit());
        ExampleSponsoredDataSet successor = _resolveSuccessor(factory, thisNonce, successorNonce);
        uint256 successorDataSetId = _checkMigrationConditions(successor);
        migrationId = nextMigrationId++;
        pendingMigrations[migrationId] = PendingMigration({
            depositor: msg.sender,
            factory: factory,
            thisNonce: thisNonce,
            successorNonce: successorNonce,
            depositEpoch: block.number
        });
        emit MigrationProposed(migrationId, msg.sender, successorDataSetId);
    }

    /// @notice Challenges a pending migration by proving pieces differ at a given index.
    /// @dev Half the deposit is paid to the challenger; the other half is burned.
    function challengeMigration(uint256 migrationId, uint256 pieceIndex) external {
        PendingMigration memory migration = pendingMigrations[migrationId];
        require(migration.depositor != address(0), MigrationNotFound());
        require(block.number <= migration.depositEpoch + CHALLENGE_PERIOD, ChallengePeriodExpired());

        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(migration.factory), migration.successorNonce));
        uint256 dstId = successor.dataSetId();

        bool mismatch;
        if (!PDP_VERIFIER.dataSetLive(dataSetId) || !PDP_VERIFIER.dataSetLive(dstId)) {
            // Either side was deleted since the migration was proposed, so equality can no
            // longer be verified. Treat this as a successful challenge rather than reverting,
            // since a silent revert here would let the migration complete unchallenged.
            mismatch = true;
        } else {
            uint256 srcLeafCount = PDP_VERIFIER.getPieceLeafCount(dataSetId, pieceIndex);
            uint256 dstLeafCount = PDP_VERIFIER.getPieceLeafCount(dstId, pieceIndex);
            mismatch = srcLeafCount != dstLeafCount;
            if (!mismatch && srcLeafCount != 0) {
                bytes memory srcCid = PDP_VERIFIER.getPieceCid(dataSetId, pieceIndex).data;
                bytes memory dstCid = PDP_VERIFIER.getPieceCid(dstId, pieceIndex).data;
                mismatch = !LibBytes.eq(srcCid, dstCid);
            }
        }
        require(mismatch, ChallengeFailed());

        delete pendingMigrations[migrationId];

        emit MigrationInvalid(migrationId, pieceIndex);
        uint256 half = MIGRATION_DEPOSIT / 2;
        require(FVMPay.pay(msg.sender, half), PayFailed());
        require(FVMPay.burn(half), BurnFailed());
    }

    /// @notice Completes a pending migration after the challenge period has elapsed.
    /// @dev Transfers available funds to the successor and refunds the deposit to the original depositor.
    function completeMigration(uint256 migrationId) external {
        PendingMigration memory migration = pendingMigrations[migrationId];
        require(migration.depositor != address(0), MigrationNotFound());
        require(block.number > migration.depositEpoch + CHALLENGE_PERIOD, ChallengePeriodNotExpired());

        ExampleSponsoredDataSet successor =
            ExampleSponsoredDataSet(LibRLP.computeAddress(address(migration.factory), migration.successorNonce));
        require(PDP_VERIFIER.dataSetLive(successor.dataSetId()), SuccessorDeleted());

        delete pendingMigrations[migrationId];

        _transferFunds(migration.factory, successor);
        emit MigrationCompleted(migrationId, address(successor));
        require(FVMPay.pay(migration.depositor, MIGRATION_DEPOSIT), PayFailed());
    }

    function _resolveSuccessor(ExampleSponsoredDataSetFactory factory, uint64 thisNonce, uint64 successorNonce)
        internal
        view
        returns (ExampleSponsoredDataSet)
    {
        require(LibRLP.computeAddress(address(factory), thisNonce) == address(this), FactoryMismatch());
        return ExampleSponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
    }

    function _checkMigrationConditions(ExampleSponsoredDataSet successor)
        internal
        view
        returns (uint256 successorDataSetId)
    {
        require(isFinalized(), NotFinalized());
        require(successor.isFinalized(), SuccessorNotFinalized());

        require(dataSetId != 0, DataSetNotBound());
        FilecoinWarmStorageService.DataSetInfoView memory info = WARM_STORAGE_SERVICE.getDataSet(dataSetId);
        require(info.payer != address(0), DataSetDeleted());

        // If not terminated, require the SP is in danger of abandonment (past half the inactivity window).
        if (info.pdpEndEpoch == 0) {
            uint256 lastProvenEpoch = PDP_VERIFIER.getDataSetLastProvenEpoch(dataSetId);
            require(
                lastProvenEpoch != 0 && block.number > lastProvenEpoch + PDP_INACTIVITY_WINDOW / 2,
                DataSetNotTerminated()
            );
        }

        successorDataSetId = successor.dataSetId();
        require(successorDataSetId != 0, SuccessorNotBound());

        require(
            PDP_VERIFIER.getDataSetLastProvenEpoch(successorDataSetId) > successor.finalizedEpoch(),
            SuccessorNotProven()
        );
        require(
            PDP_VERIFIER.getNextPieceId(dataSetId) == PDP_VERIFIER.getNextPieceId(successorDataSetId), PieceMismatch()
        );
    }

    function _transferFunds(ExampleSponsoredDataSetFactory factory, ExampleSponsoredDataSet successor) internal {
        IERC20 token = factory.TOKEN();
        (,, uint256 available,) = PAYMENTS.getAccountInfoIfSettled(token, address(this));
        if (available > 0) {
            PAYMENTS.withdrawTo(token, address(this), available);
            token.approve(address(PAYMENTS), available);
            PAYMENTS.deposit(token, address(successor), available);
        }
    }

    function _verifyPiecesMatch(uint256 srcId, uint256 dstId) private view {
        uint256 total = PDP_VERIFIER.getNextPieceId(srcId);
        require(total == PDP_VERIFIER.getNextPieceId(dstId), PieceMismatch());
        for (uint256 i = 0; i < total; i++) {
            uint256 srcLeafCount = PDP_VERIFIER.getPieceLeafCount(srcId, i);
            require(srcLeafCount == PDP_VERIFIER.getPieceLeafCount(dstId, i), PieceMismatch());
            if (srcLeafCount != 0) {
                require(
                    LibBytes.eq(PDP_VERIFIER.getPieceCid(srcId, i).data, PDP_VERIFIER.getPieceCid(dstId, i).data),
                    PieceMismatch()
                );
            }
        }
    }
}
