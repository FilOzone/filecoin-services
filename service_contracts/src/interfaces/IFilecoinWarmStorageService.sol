// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

// Code generated - DO NOT EDIT.
// This file is a generated binding and any changes will be lost.
// Generated with make src/interfaces/IFilecoinWarmStorageService.sol

import {Errors} from "../Errors.sol";
import {IFilecoinServiceMetadata} from "../IFilecoinServiceMetadata.sol";
import {ServiceProviderRegistry} from "../ServiceProviderRegistry.sol";
import {DataSetInfoView, DataSetStatus} from "../lib/FWSSViewTypes.sol";
import {PriceList} from "../lib/PriceList.sol";
import {FWSSDataSetModule} from "../modules/FWSSDataSetModule.sol";
import {FWSSStorage} from "../storage/FWSSStorage.sol";
import {IValidator} from "@fws-payments/FilecoinPayV1.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Cids} from "@pdp/Cids.sol";
import {IPDPProvingSchedule} from "@pdp/IPDPProvingSchedule.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {SessionKeyRegistry} from "@session-key-registry/SessionKeyRegistry.sol";

/// @title IFilecoinWarmStorageService
/// @notice The functions, events and errors of the facets the proxy routes to, per josuke abi.
interface IFilecoinWarmStorageService is IFilecoinServiceMetadata, IPDPProvingSchedule, IValidator, PDPListener {
    event CDNPaymentRailsToppedUp(
        uint256 indexed dataSetId,
        uint256 cdnAmountAdded,
        uint256 totalCdnLockup,
        uint256 cacheMissAmountAdded,
        uint256 totalCacheMissLockup
    );
    event CDNServiceTerminated(
        address indexed caller, uint256 indexed dataSetId, uint256 cacheMissRailId, uint256 cdnRailId
    );
    event DataSetAbandoned(uint256 indexed dataSetId, uint256 pdpRailId, uint256 cacheMissRailId, uint256 cdnRailId);
    event DataSetAuthorizerSet(uint256 indexed dataSetId, address indexed authorizer);
    event DataSetCreated(
        uint256 indexed dataSetId,
        uint256 indexed providerId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId,
        address payer,
        address serviceProvider,
        address payee,
        string[] metadataKeys,
        string[] metadataValues
    );
    event DataSetServiceProviderChanged(
        uint256 indexed dataSetId, address indexed oldServiceProvider, address indexed newServiceProvider
    );
    event DiamondDelegateCall(address indexed delegate, bytes delegateCalldata);
    event EIP712DomainChanged();
    event FaultRecord(uint256 indexed dataSetId, uint256 periodsFaulted, uint256 deadline);
    event FilBeamControllerChanged(address oldController, address newController);
    event Initialized(uint64 version);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PDPPaymentTerminated(uint256 indexed dataSetId, uint256 endEpoch, uint256 pdpRailId);
    event PieceAdded(
        uint256 indexed dataSetId, uint256 indexed pieceId, Cids.Cid pieceCid, string[] keys, string[] values
    );
    event ProviderApproved(uint256 indexed providerId);
    event ProviderUnapproved(uint256 indexed providerId);
    event RailRateUpdated(uint256 indexed dataSetId, uint256 railId, uint256 newRate);
    event ServiceTerminated(
        address indexed approver,
        uint256 indexed dataSetId,
        uint256 pdpRailId,
        uint256 cacheMissRailId,
        uint256 cdnRailId
    );
    event UpgradeAnnounced(FWSSStorage.PlannedUpgrade plannedUpgrade);

    error AddressEmptyCode(address target);
    error AuthorizerReentrancy();
    error CDNPaymentAlreadyTerminated(uint256 dataSetId);
    error CacheMissPaymentAlreadyTerminated(uint256 dataSetId);
    error CallerNotPayer(uint256 dataSetId, address expectedPayer, address caller);
    error CallerNotPayerOrPayee(uint256 dataSetId, address expectedPayer, address expectedPayee, address caller);
    error CallerNotPayments(address expected, address actual);
    error CallerNotServiceProvider(uint256 dataSetId, address expectedServiceProvider, address caller);
    error ChallengeWindowTooEarly(uint256 dataSetId, uint256 windowStart, uint256 nowBlock);
    error ClientDataSetAlreadyRegistered(uint256 clientDataSetId);
    error DataSetNotAbandoned(uint256 dataSetId, uint256 requiredEpoch, uint256 currentBlock);
    error DataSetNotFoundForRail(uint256 railId);
    error DataSetNotRegistered(uint256 dataSetId);
    error DataSetPaymentAlreadyTerminated(uint256 dataSetId);
    error DataSetPaymentBeyondEndEpoch(uint256 dataSetId, uint256 pdpEndEpoch, uint256 currentBlock);
    error DispatcherChanged(address implementation);
    error DuplicateMetadataKey(uint256 dataSetId, string key);
    error ExtraDataRequired();
    error ExtraDataTooLarge(uint256 actualSize, uint256 maxAllowedSize);
    error FailedCall();
    error FilBeamServiceNotConfigured(uint256 dataSetId);
    error InsufficientLockupAllowance(
        address payer, address operator, uint256 lockupAllowance, uint256 lockupUsage, uint256 lockupRequired
    );
    error InsufficientLockupFunds(address payer, uint256 required, uint256 available);
    error InsufficientMaxLockupPeriod(
        address payer, address operator, uint256 maxLockupPeriod, uint256 requiredLockupPeriod
    );
    error InsufficientRateAllowance(
        address payer, address operator, uint256 rateAllowance, uint256 rateUsage, uint256 rateRequired
    );
    error InvalidChallengeCount(uint256 dataSetId, uint256 minExpected, uint256 actual);
    error InvalidChallengeEpoch(uint256 dataSetId, uint256 minAllowed, uint256 maxAllowed, uint256 actual);
    error InvalidChallengeWindowSize(uint256 maxProvingPeriod, uint256 challengeWindowSize);
    error InvalidDataSetAuthorizer(address authorizer);
    error InvalidDataSetId(uint256 dataSetId);
    error InvalidEpochRange(uint256 fromEpoch, uint256 toEpoch);
    error InvalidInitialization();
    error InvalidMigration(address migration);
    error InvalidSignature(address expected, address actual);
    error InvalidSignatureLength(uint256 expectedLength, uint256 actualLength);
    error InvalidTopUpAmount(uint256 dataSetId);
    error MaxProvingPeriodZero();
    error MetadataArrayCountMismatch(uint256 metadataArrayCount, uint256 pieceCount);
    error MetadataKeyAndValueLengthMismatch(uint256 keysLength, uint256 valuesLength);
    error MetadataKeyExceedsMaxLength(uint256 index, uint256 maxAllowed, uint256 length);
    error MetadataValueExceedsMaxLength(uint256 index, uint256 maxAllowed, uint256 length);
    error MigrationNotAnnounced(address migration);
    error MigrationNotReady(uint96 afterEpoch);
    error MissingUpgradeRoute(bytes4 selector);
    error NextProvingPeriodAlreadyCalled(uint256 dataSetId, uint256 periodDeadline, uint256 nowBlock);
    error NoPDPPaymentRail(uint256 dataSetId);
    error NotInitializing();
    error OnlyDataSetPayer(uint256 dataSetId, address actual);
    error OnlyFilBeamControllerAllowed(address expected, address actual);
    error OnlyPDPVerifierAllowed(address expected, address actual);
    error OperatorNotApproved(address payer, address operator);
    error OwnableInvalidOwner(address owner);
    error OwnableUnauthorizedAccount(address account);
    error PaymentRailsNotFinalized(uint256 dataSetId, uint256 pdpEndEpoch);
    error ProofAlreadySubmitted(uint256 dataSetId);
    error ProviderAlreadyApproved(uint256 providerId);
    error ProviderIdMismatchAtIndex(uint256 index, uint256 providerId);
    error ProviderNotInApprovedList(uint256 providerId);
    error ProviderNotRegistered(address provider);
    error ProvingNotStarted(uint256 dataSetId);
    error ProvingPeriodNotInitialized(uint256 dataSetId);
    error ProvingPeriodPassed(uint256 dataSetId, uint256 deadline, uint256 nowBlock);
    error RailNotFullySettled(uint256 railId, uint256 settledUpTo, uint256 endEpoch);
    error ServiceContractMustTerminateRail();
    error StorageProviderChangesNotSupported();
    error TooManyMetadataKeys(uint256 maxAllowed, uint256 keysLength);
    error Unauthorized(address payer, bytes32 operation, bytes32 digest, bytes signature);
    error UnsupportedSignatureV(uint8 v);
    error ZeroAddress(Errors.AddressField field);

    function VERSION() external view returns (string memory);
    function addApprovedProvider(uint256 providerId) external;
    function announceMigration(address migration, uint96 delayEpochs) external;
    function clientDataSets(address payer) external view returns (uint256[] memory dataSetIds);
    function clientDataSets(address payer, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory dataSetIds);
    function clientNonces(address payer, uint256 nonce) external view returns (uint256);
    function configureProvingPeriod(uint64 _maxProvingPeriod, uint256 _challengeWindowSize) external;
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
    function extsload(bytes32 slot) external view returns (bytes32);
    function extsloadStruct(bytes32 slot, uint256 size) external view returns (bytes32[] memory);
    function filBeamBeneficiaryAddress() external view returns (address);
    function filBeamControllerAddress() external view returns (address);
    function getAllDataSetMetadata(uint256 dataSetId)
        external
        view
        returns (string[] memory keys, string[] memory values);
    function getApprovedProviders(uint256 offset, uint256 limit) external view returns (uint256[] memory providerIds);
    function getApprovedProvidersLength() external view returns (uint256 count);
    function getClientDataSets(address client) external view returns (DataSetInfoView[] memory infos);
    function getClientDataSets(address client, uint256 offset, uint256 limit)
        external
        view
        returns (DataSetInfoView[] memory infos);
    function getClientDataSetsLength(address payer) external view returns (uint256);
    function getCurrentPricingRates() external pure returns (uint256 storagePrice, uint256 datasetFee);
    function getDataSet(uint256 dataSetId) external view returns (DataSetInfoView memory info);
    function getDataSetAuthorizer(uint256 dataSetId) external view returns (address);
    function getDataSetMetadata(uint256 dataSetId, string calldata key)
        external
        view
        returns (bool exists, string memory value);
    function getDataSetPayerAndRailId(uint256 dataSetId) external view returns (address payer, uint256 pdpRailId);
    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256);
    function getDataSetStatus(uint256 dataSetId) external view returns (DataSetStatus status);
    function getEffectiveRates() external pure returns (uint256 serviceFee, uint256 spPayment);
    function getPriceList() external view returns (PriceList memory list);
    function getProvingPeriodForEpoch(uint256 dataSetId, uint256 epoch) external view returns (uint256);
    function getServicePrice() external view returns (FWSSDataSetModule.ServicePricing memory pricing);
    function hasBeenProvenRecently(uint256 dataSetId) external view returns (bool);
    function implementation(bytes4 selector) external view returns (address delegate);
    function isProviderApproved(uint256 providerId) external view returns (bool);
    function migrate(address migration) external;
    function nextUpgrade() external view returns (address nextImplementation, uint96 afterEpoch);
    function owner() external view returns (address);
    function paymentsContractAddress() external view returns (address);
    function pdpVerifierAddress() external view returns (address);
    function provenPeriods(uint256 dataSetId, uint256 periodId) external view returns (bool);
    function provenThisPeriod(uint256 dataSetId) external view returns (bool);
    function provingActivationEpoch(uint256 dataSetId) external view returns (uint256);
    function provingDeadline(uint256 setId) external view returns (uint256);
    function railToDataSet(uint256 railId) external view returns (uint256);
    function removeApprovedProvider(uint256 providerId, uint256 index) external;
    function renounceOwnership() external;
    function selectors() external view returns (bytes4[] memory);
    function serviceCommissionBps() external pure returns (uint256);
    function serviceProviderRegistry() external view returns (ServiceProviderRegistry);
    function sessionKeyRegistry() external view returns (SessionKeyRegistry);
    function setDataSetAuthorizer(uint256 dataSetId, address authorizer) external;
    function settleFilBeamPaymentRails(uint256 dataSetId, uint256 cdnAmount, uint256 cacheMissAmount) external;
    function terminateCDNService(uint256 dataSetId) external;
    function terminateService(uint256 dataSetId) external;
    function terminateService(uint256 dataSetId, bytes calldata extraData) external;
    function topUpCDNPaymentRails(uint256 dataSetId, uint256 cdnAmountToAdd, uint256 cacheMissAmountToAdd) external;
    function topUpLifecycleReserve(uint256 dataSetId, uint256 amount) external;
    function transferFilBeamController(address newController) external;
    function transferOwnership(address newOwner) external;
    function usdfcTokenAddress() external view returns (IERC20Metadata);
    function viewContractAddress() external view returns (address);
}
