// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.30;

import {FilecoinWarmStorageService} from "./FilecoinWarmStorageService.sol";
import {FilecoinPayV1 as FilecoinPay} from "@fws-payments/FilecoinPayV1.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SignatureVerificationLib} from "./lib/SignatureVerificationLib.sol";
import {FilecoinWarmStorageServiceStateInternalLibrary} from "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";

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
    error DataSetNotBound();
    error DataSetNotDeleted();

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
        bytes32[] memory curatorPerms = new bytes32[](2);
        curatorPerms[0] = SignatureVerificationLib.ADD_PIECES_TYPEHASH;
        curatorPerms[1] = SignatureVerificationLib.SCHEDULE_PIECE_REMOVALS_TYPEHASH;
        SESSION_KEY_REGISTRY.revoke(CURATOR, curatorPerms, ORIGIN);
    }

    function isFinalized() external view returns (bool) {
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
}
