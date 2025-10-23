// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

// Code generated - DO NOT EDIT.
// This file is a generated binding and any changes will be lost.
// Generated with tools/generate_view_contract.sh

import {FilecoinWarmStorageService} from "./FilecoinWarmStorageService.sol";
import {FilecoinWarmStorageServiceStateInternalLibrary} from "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";
import {IPDPProvingSchedule} from "@pdp/IPDPProvingSchedule.sol";

contract FilecoinWarmStorageServiceStateView is IPDPProvingSchedule {
    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;

    FilecoinWarmStorageService public immutable service;

    constructor(FilecoinWarmStorageService _service) {
        service = _service;
    }

    function challengeWindow() external view returns (uint256) {
        return service.challengeWindow();
    }

    function clientDataSets(address payer) external view returns (uint256[] memory dataSetIds) {
        return service.clientDataSets(payer);
    }

    function clientNonces(address payer, uint256 nonce) external view returns (uint256) {
        return service.clientNonces(payer, nonce);
    }

    function filBeamControllerAddress() external view returns (address) {
        return service.filBeamControllerAddress();
    }

    function getAllDataSetMetadata(uint256 dataSetId)
        external
        view
        returns (string[] memory keys, string[] memory values)
    {
        return service.getAllDataSetMetadata(dataSetId);
    }

    function getAllPieceMetadata(uint256 dataSetId, uint256 pieceId)
        external
        view
        returns (string[] memory keys, string[] memory values)
    {
        return service.getAllPieceMetadata(dataSetId, pieceId);
    }

    function getApprovedProviders(uint256 offset, uint256 limit) external view returns (uint256[] memory providerIds) {
        return service.getApprovedProviders(offset, limit);
    }

    function getApprovedProvidersLength() external view returns (uint256 count) {
        return service.getApprovedProvidersLength();
    }

    function getChallengesPerProof() external pure returns (uint64) {
        return FilecoinWarmStorageServiceStateInternalLibrary.getChallengesPerProof();
    }

    function getClientDataSets(address client)
        external
        view
        returns (FilecoinWarmStorageService.DataSetInfoView[] memory infos)
    {
        return service.getClientDataSets(client);
    }

    function getDataSet(uint256 dataSetId)
        external
        view
        returns (FilecoinWarmStorageService.DataSetInfoView memory info)
    {
        return service.getDataSet(dataSetId);
    }

    function getDataSetMetadata(uint256 dataSetId, string memory key)
        external
        view
        returns (bool exists, string memory value)
    {
        return service.getDataSetMetadata(dataSetId, key);
    }

    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256) {
        return FilecoinWarmStorageServiceStateInternalLibrary.getDataSetSizeInBytes(leafCount);
    }

    function getDataSetStatus(uint256 dataSetId)
        external
        view
        returns (FilecoinWarmStorageService.DataSetStatus status)
    {
        return service.getDataSetStatus(dataSetId);
    }

    function getDataSetStatusDetails(uint256 dataSetId)
        external
        view
        returns (FilecoinWarmStorageService.DataSetStatus status, bool hasProving, bool isTerminated)
    {
        return service.getDataSetStatusDetails(dataSetId);
    }

    function getMaxProvingPeriod() external view returns (uint64) {
        return service.getMaxProvingPeriod();
    }

    function getPDPConfig()
        external
        view
        returns (
            uint64 maxProvingPeriod,
            uint256 challengeWindowSize,
            uint256 challengesPerProof,
            uint256 initChallengeWindowStart
        )
    {
        return service.getPDPConfig();
    }

    function getPieceMetadata(uint256 dataSetId, uint256 pieceId, string memory key)
        external
        view
        returns (bool exists, string memory value)
    {
        return service.getPieceMetadata(dataSetId, pieceId, key);
    }

    function isDataSetActive(uint256 dataSetId) external view returns (bool) {
        return service.isDataSetActive(dataSetId);
    }

    function isProviderApproved(uint256 providerId) external view returns (bool) {
        return service.isProviderApproved(providerId);
    }

    function nextPDPChallengeWindowStart(uint256 setId) external view returns (uint256) {
        return service.nextPDPChallengeWindowStart(setId);
    }

    function nextUpgrade() external view returns (address nextImplementation, uint96 afterEpoch) {
        return service.nextUpgrade();
    }

    function provenPeriods(uint256 dataSetId, uint256 periodId) external view returns (bool) {
        return service.provenPeriods(dataSetId, periodId);
    }

    function provenThisPeriod(uint256 dataSetId) external view returns (bool) {
        return service.provenThisPeriod(dataSetId);
    }

    function provingActivationEpoch(uint256 dataSetId) external view returns (uint256) {
        return service.provingActivationEpoch(dataSetId);
    }

    function provingDeadline(uint256 setId) external view returns (uint256) {
        return service.provingDeadline(setId);
    }

    function railToDataSet(uint256 railId) external view returns (uint256) {
        return service.railToDataSet(railId);
    }

    function serviceCommissionBps() external view returns (uint256) {
        return service.serviceCommissionBps();
    }
}
