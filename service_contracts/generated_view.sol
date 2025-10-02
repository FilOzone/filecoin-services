// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

// Generated with ./tools/generate_view_contract.sh out/FilecoinWarmStorageService.sol/FilecoinWarmStorageService.json

import {IPDPProvingSchedule} from "@pdp/IPDPProvingSchedule.sol";
import "./FilecoinWarmStorageService.sol";
import "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";
contract FilecoinWarmStorageServiceStateView is IPDPProvingSchedule {
    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;
    FilecoinWarmStorageService public immutable service;
    constructor(FilecoinWarmStorageService _service) {
        service = _service;
    }
    function UPGRADE_INTERFACE_VERSION() external view returns (string memory) {
        return FilecoinWarmStorageServiceStateInternalLibrary.UPGRADE_INTERFACE_VERSION();
    }
    function calculateRatesPerEpoch(uint256 totalBytes) external view returns (uint256 storageRate, uint256 cacheMissRate, uint256 cdnRate) {
        return FilecoinWarmStorageServiceStateInternalLibrary.calculateRatesPerEpoch(totalBytes);
    }
    function configureProvingPeriod(uint64 _maxProvingPeriod, uint256 _challengeWindowSize) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.configureProvingPeriod(_maxProvingPeriod, _challengeWindowSize);
    }
    function dataSetCreated(uint256 dataSetId, address creator, bytes extraData) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.dataSetCreated(dataSetId, creator, extraData);
    }
    function dataSetDeleted(uint256 dataSetId, uint256 , bytes extraData) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.dataSetDeleted(dataSetId, , extraData);
    }
    function eip712Domain() external view returns (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] memory extensions) {
        return FilecoinWarmStorageServiceStateInternalLibrary.eip712Domain();
    }
    function extsload(bytes32 slot) external view returns (bytes32) {
        return FilecoinWarmStorageServiceStateInternalLibrary.extsload(slot);
    }
    function extsloadStruct(bytes32 slot, uint256 size) external view returns (bytes32[] memory) {
        return FilecoinWarmStorageServiceStateInternalLibrary.extsloadStruct(slot, size);
    }
    function filCDNAddress() external view returns (address) {
        return FilecoinWarmStorageServiceStateInternalLibrary.filCDNAddress();
    }
    function getEffectiveRates() external view returns (uint256 serviceFee, uint256 spPayment) {
        return FilecoinWarmStorageServiceStateInternalLibrary.getEffectiveRates();
    }
    function getProvingPeriodForEpoch(uint256 dataSetId, uint256 epoch) external view returns (uint256) {
        return FilecoinWarmStorageServiceStateInternalLibrary.getProvingPeriodForEpoch(dataSetId, epoch);
    }
    function getServicePrice() external view returns (FilecoinWarmStorageService.ServicePricing memory pricing) {
        return FilecoinWarmStorageServiceStateInternalLibrary.getServicePrice();
    }
    function initialize(uint64 _maxProvingPeriod, uint256 _challengeWindowSize) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.initialize(_maxProvingPeriod, _challengeWindowSize);
    }
    function isEpochProven(uint256 dataSetId, uint256 epoch) external view returns (bool) {
        return FilecoinWarmStorageServiceStateInternalLibrary.isEpochProven(dataSetId, epoch);
    }
    function migrate() external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.migrate();
    }
    function nextProvingPeriod(uint256 dataSetId, uint256 challengeEpoch, uint256 leafCount, bytes ) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.nextProvingPeriod(dataSetId, challengeEpoch, leafCount, );
    }
    function owner() external view returns (address) {
        return FilecoinWarmStorageServiceStateInternalLibrary.owner();
    }
    function paymentsContractAddress() external view returns (address) {
        return FilecoinWarmStorageServiceStateInternalLibrary.paymentsContractAddress();
    }
    function pdpVerifierAddress() external view returns (address) {
        return FilecoinWarmStorageServiceStateInternalLibrary.pdpVerifierAddress();
    }
    function piecesAdded(uint256 dataSetId, uint256 firstAdded, tuple[] pieceData, bytes extraData) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.piecesAdded(dataSetId, firstAdded, pieceData, extraData);
    }
    function piecesScheduledRemove(uint256 dataSetId, uint256[] pieceIds, bytes extraData) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.piecesScheduledRemove(dataSetId, pieceIds, extraData);
    }
    function possessionProven(uint256 dataSetId, uint256 , uint256 , uint256 challengeCount) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.possessionProven(dataSetId, , , challengeCount);
    }
    function proxiableUUID() external view returns (bytes32) {
        return FilecoinWarmStorageServiceStateInternalLibrary.proxiableUUID();
    }
    function railTerminated(uint256 railId, address terminator, uint256 endEpoch) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.railTerminated(railId, terminator, endEpoch);
    }
    function renounceOwnership() external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.renounceOwnership();
    }
    function serviceCommissionBps() external view returns (uint256) {
        return FilecoinWarmStorageServiceStateInternalLibrary.serviceCommissionBps();
    }
    function storageProviderChanged(uint256 dataSetId, address oldServiceProvider, address newServiceProvider, bytes extraData) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.storageProviderChanged(dataSetId, oldServiceProvider, newServiceProvider, extraData);
    }
    function terminateService(uint256 dataSetId) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.terminateService(dataSetId);
    }
    function transferOwnership(address newOwner) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.transferOwnership(newOwner);
    }
    function updateServiceCommission(uint256 newCommissionBps) external nonpayable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.updateServiceCommission(newCommissionBps);
    }
    function upgradeToAndCall(address newImplementation, bytes data) external payable returns () {
        return FilecoinWarmStorageServiceStateInternalLibrary.upgradeToAndCall(newImplementation, data);
    }
    function usdfcTokenAddress() external view returns (address) {
        return FilecoinWarmStorageServiceStateInternalLibrary.usdfcTokenAddress();
    }
    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 ) external nonpayable returns (IValidator.ValidationResult memory result) {
        return FilecoinWarmStorageServiceStateInternalLibrary.validatePayment(railId, proposedAmount, fromEpoch, toEpoch, );
    }

}
