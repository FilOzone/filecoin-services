// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinWarmStorageService} from "./FilecoinWarmStorageService.sol";
import {FilecoinPayV1 as FilecoinPay} from "@fws-payments/FilecoinPayV1.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignatureVerificationLib} from "./lib/SignatureVerificationLib.sol";
import {FilecoinWarmStorageServiceStateInternalLibrary} from "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";
import {IPDPVerifier} from "@pdp/interfaces/IPDPVerifier.sol";
import {PDPVerifier} from "@pdp/PDPVerifier.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
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

contract SponsoredDataSetFactory {
    event NewSponsoredDataSet(
        SponsoredDataSet indexed dataSet, address indexed curator, address indexed payee, address beneficiary
    );

    FilecoinWarmStorageService public immutable WARM_STORAGE_SERVICE;
    FilecoinPay public immutable PAYMENTS;
    SessionKeyRegistry public immutable SESSION_KEY_REGISTRY;
    IERC20 public immutable TOKEN;

    constructor(FilecoinWarmStorageService fwss) {
        WARM_STORAGE_SERVICE = fwss;
        PAYMENTS = FilecoinPay(fwss.paymentsContractAddress());
        SESSION_KEY_REGISTRY = fwss.sessionKeyRegistry();
        TOKEN = fwss.usdfcTokenAddress();
    }

    function initDataSet(
        address payee,
        string[] calldata metadataKeys,
        string[] calldata metadataValues,
        address curator,
        address beneficiary
    ) external returns (SponsoredDataSet) {
        bytes32 createDataSetStructHash =
            SignatureVerificationLib.createDataSetStructHash(0, payee, metadataKeys, metadataValues);
        bytes32 createDataSetHash = hashTypedDataV4(WARM_STORAGE_SERVICE, createDataSetStructHash);
        address createDataSetSigner = ecrecover(createDataSetHash, 0, 0, 0);
        SponsoredDataSet dataSet = new SponsoredDataSet(
            WARM_STORAGE_SERVICE, PAYMENTS, SESSION_KEY_REGISTRY, TOKEN, createDataSetSigner, curator, beneficiary
        );
        emit NewSponsoredDataSet(dataSet, curator, payee, beneficiary);
        return dataSet;
    }
}

contract SponsoredDataSet {
    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;

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

    event MigrationProposed(uint256 indexed migrationId, address depositor, uint256 successorDataSetId);

    struct PendingMigration {
        address depositor;
        SponsoredDataSetFactory factory;
        uint64 thisNonce;
        uint64 successorNonce;
        uint256 depositEpoch;
    }

    string private constant ORIGIN = "SponsoredDataSet";

    uint256 public constant CHALLENGE_PERIOD = 2880;
    uint256 public constant MIGRATION_DEPOSIT = 1 ether;

    // The curator can add and remove pieces from the data set until they finalize it
    address public immutable CURATOR;
    // The beneficiary receives the funds in the event the data set is deleted without a successful migration
    address public immutable BENEFICIARY;

    FilecoinWarmStorageService public immutable WARM_STORAGE_SERVICE;
    FilecoinPay public immutable PAYMENTS;
    SessionKeyRegistry public immutable SESSION_KEY_REGISTRY;
    uint256 public dataSetId;
    uint256 public railId;
    uint256 public finalizedEpoch;

    mapping(uint256 => PendingMigration) public pendingMigrations;
    uint256 public nextMigrationId;

    constructor(
        FilecoinWarmStorageService fwss,
        FilecoinPay filecoinPay,
        SessionKeyRegistry sessionKeyRegistry,
        IERC20 token,
        address createDataSetSigner,
        address curator,
        address beneficiary
    ) {
        bytes32[] memory createPerms = new bytes32[](1);
        createPerms[0] = SignatureVerificationLib.CREATE_DATA_SET_TYPEHASH;
        sessionKeyRegistry.login(createDataSetSigner, type(uint256).max, createPerms, ORIGIN);

        bytes32[] memory curatorPerms = new bytes32[](2);
        curatorPerms[0] = SignatureVerificationLib.ADD_PIECES_TYPEHASH;
        curatorPerms[1] = SignatureVerificationLib.SCHEDULE_PIECE_REMOVALS_TYPEHASH;
        sessionKeyRegistry.login(curator, type(uint256).max, curatorPerms, ORIGIN);
        filecoinPay.setOperatorApproval(
            token, address(fwss), true, type(uint256).max, type(uint256).max, type(uint256).max
        );

        WARM_STORAGE_SERVICE = fwss;
        PAYMENTS = filecoinPay;
        SESSION_KEY_REGISTRY = sessionKeyRegistry;
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
        (uint256 funds, uint256 lockupCurrent,,) = PAYMENTS.accounts(token, address(this));
        PAYMENTS.withdrawTo(token, BENEFICIARY, funds - lockupCurrent);
    }

    /// @notice Migrates available funds to a verified successor data set from the same factory.
    /// @dev Checks: both are finalized, source is terminated (not deleted) in FWSS, successor is
    ///      proven and has the same active pieces in the same order as the source.
    ///      The source and successor addresses are derived deterministically from (factory, nonce)
    ///      using the EVM CREATE address formula, proving both were deployed by the same factory.
    function migrate(SponsoredDataSetFactory factory, uint64 thisNonce, uint64 successorNonce) external {
        SponsoredDataSet successor = _resolveSuccessor(factory, thisNonce, successorNonce);
        (IPDPVerifier pdpVerifier, uint256 successorDataSetId) = _checkMigrationConditions(successor);
        _verifyPiecesMatch(pdpVerifier, dataSetId, successorDataSetId);
        _transferFunds(factory, successor);
    }

    /// @notice The curator migrates funds from a non-finalized data set to a successor with the same curator and beneficiary.
    /// @dev Requires the caller to be the curator, the source to be non-finalized, and the successor to be
    ///      bound and proven. Pieces are not checked; the curator vouches for the transition.
    function migrateUnfinalized(SponsoredDataSetFactory factory, uint64 thisNonce, uint64 successorNonce) external {
        require(msg.sender == CURATOR, NotCurator(CURATOR, msg.sender));
        require(!isFinalized(), AlreadyFinalized());
        SponsoredDataSet successor = _resolveSuccessor(factory, thisNonce, successorNonce);
        require(successor.CURATOR() == CURATOR, SuccessorCuratorMismatch());
        require(successor.BENEFICIARY() == BENEFICIARY, SuccessorBeneficiaryMismatch());
        uint256 successorDataSetId = successor.dataSetId();
        require(successorDataSetId != 0, SuccessorNotBound());
        require(WARM_STORAGE_SERVICE.hasBeenProvenRecently(successorDataSetId), SuccessorNotProven());
        _transferFunds(factory, successor);
    }

    /// @notice Proposes a challenged migration to a large-data successor without iterating all pieces.
    /// @dev Opens a challenge window during which anyone can disprove piece equality by index.
    ///      Requires a FIL deposit as a bond; depositor gets it back after the challenge period.
    function proposeMigration(SponsoredDataSetFactory factory, uint64 thisNonce, uint64 successorNonce)
        external
        payable
        returns (uint256 migrationId)
    {
        require(msg.value == MIGRATION_DEPOSIT, IncorrectDeposit());
        SponsoredDataSet successor = _resolveSuccessor(factory, thisNonce, successorNonce);
        (, uint256 successorDataSetId) = _checkMigrationConditions(successor);
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

        SponsoredDataSet successor =
            SponsoredDataSet(LibRLP.computeAddress(address(migration.factory), migration.successorNonce));
        IPDPVerifier pdpVerifier = IPDPVerifier(WARM_STORAGE_SERVICE.pdpVerifierAddress());
        uint256 dstId = successor.dataSetId();

        bool srcActive = pdpVerifier.getPieceLeafCount(dataSetId, pieceIndex) != 0;
        bool dstActive = pdpVerifier.getPieceLeafCount(dstId, pieceIndex) != 0;
        bool mismatch = srcActive != dstActive;
        if (!mismatch && srcActive) {
            bytes memory srcCid = PDPVerifier(address(pdpVerifier)).getPieceCid(dataSetId, pieceIndex).data;
            bytes memory dstCid = PDPVerifier(address(pdpVerifier)).getPieceCid(dstId, pieceIndex).data;
            mismatch = !LibBytes.eq(srcCid, dstCid);
        }
        require(mismatch, ChallengeFailed());

        delete pendingMigrations[migrationId];

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

        delete pendingMigrations[migrationId];

        SponsoredDataSet successor =
            SponsoredDataSet(LibRLP.computeAddress(address(migration.factory), migration.successorNonce));
        _transferFunds(migration.factory, successor);
        require(FVMPay.pay(migration.depositor, MIGRATION_DEPOSIT), PayFailed());
    }

    function _resolveSuccessor(SponsoredDataSetFactory factory, uint64 thisNonce, uint64 successorNonce)
        internal
        view
        returns (SponsoredDataSet)
    {
        require(LibRLP.computeAddress(address(factory), thisNonce) == address(this), FactoryMismatch());
        return SponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));
    }

    function _checkMigrationConditions(SponsoredDataSet successor)
        internal
        view
        returns (IPDPVerifier pdpVerifier, uint256 successorDataSetId)
    {
        require(isFinalized(), NotFinalized());
        require(successor.isFinalized(), SuccessorNotFinalized());

        require(dataSetId != 0, DataSetNotBound());
        FilecoinWarmStorageService.DataSetInfoView memory info = WARM_STORAGE_SERVICE.getDataSet(dataSetId);
        require(info.payer != address(0), DataSetDeleted());
        require(info.pdpEndEpoch != 0, DataSetNotTerminated());

        successorDataSetId = successor.dataSetId();
        require(successorDataSetId != 0, SuccessorNotBound());

        pdpVerifier = IPDPVerifier(WARM_STORAGE_SERVICE.pdpVerifierAddress());
        require(
            pdpVerifier.getDataSetLastProvenEpoch(successorDataSetId) > successor.finalizedEpoch(), SuccessorNotProven()
        );
        require(
            pdpVerifier.getNextPieceId(dataSetId) == pdpVerifier.getNextPieceId(successorDataSetId), PieceMismatch()
        );
    }

    function _transferFunds(SponsoredDataSetFactory factory, SponsoredDataSet successor) internal {
        IERC20 token = factory.TOKEN();
        (uint256 funds, uint256 lockupCurrent,,) = PAYMENTS.accounts(token, address(this));
        uint256 available = funds - lockupCurrent;
        if (available > 0) {
            PAYMENTS.withdrawTo(token, address(this), available);
            token.approve(address(PAYMENTS), available);
            PAYMENTS.deposit(token, address(successor), available);
        }
    }

    function _verifyPiecesMatch(IPDPVerifier pdpVerifier, uint256 srcId, uint256 dstId) private view {
        uint256 total = pdpVerifier.getNextPieceId(srcId);
        require(total == pdpVerifier.getNextPieceId(dstId), PieceMismatch());
        for (uint256 i = 0; i < total; i++) {
            bool srcActive = pdpVerifier.getPieceLeafCount(srcId, i) != 0;
            require(srcActive == (pdpVerifier.getPieceLeafCount(dstId, i) != 0), PieceMismatch());
            if (srcActive) {
                require(
                    LibBytes.eq(
                        PDPVerifier(address(pdpVerifier)).getPieceCid(srcId, i).data,
                        PDPVerifier(address(pdpVerifier)).getPieceCid(dstId, i).data
                    ),
                    PieceMismatch()
                );
            }
        }
    }
}
