// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinWarmStorageService} from "./FilecoinWarmStorageService.sol";
import {FilecoinPayV1 as FilecoinPay} from "@fws-payments/FilecoinPayV1.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignatureVerificationLib} from "./lib/SignatureVerificationLib.sol";
import {FilecoinWarmStorageServiceStateInternalLibrary} from "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";
import {IPDPVerifier} from "@pdp/interfaces/IPDPVerifier.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";

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

    string private constant ORIGIN = "SponsoredDataSet";

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
        require(LibRLP.computeAddress(address(factory), thisNonce) == address(this), FactoryMismatch());
        SponsoredDataSet successor = SponsoredDataSet(LibRLP.computeAddress(address(factory), successorNonce));

        require(isFinalized(), NotFinalized());
        require(successor.isFinalized(), SuccessorNotFinalized());

        require(dataSetId != 0, DataSetNotBound());
        FilecoinWarmStorageService.DataSetInfoView memory info = WARM_STORAGE_SERVICE.getDataSet(dataSetId);
        require(info.payer != address(0), DataSetDeleted());
        require(info.pdpEndEpoch != 0, DataSetNotTerminated());

        uint256 successorDataSetId = successor.dataSetId();
        require(successorDataSetId != 0, SuccessorNotBound());

        IPDPVerifier pdpVerifier = IPDPVerifier(WARM_STORAGE_SERVICE.pdpVerifierAddress());
        require(
            pdpVerifier.getDataSetLastProvenEpoch(successorDataSetId) > successor.finalizedEpoch(), SuccessorNotProven()
        );

        _verifyPiecesMatch(pdpVerifier, dataSetId, successorDataSetId);

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
                    LibBytes.eq(pdpVerifier.getPieceCid(srcId, i), pdpVerifier.getPieceCid(dstId, i)), PieceMismatch()
                );
            }
        }
    }
}
