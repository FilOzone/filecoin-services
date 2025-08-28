// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

// Code generated - DO NOT EDIT.
// This file is a generated binding and any changes will be lost.
// Generated with tools/generate_view_contract.sh out/FilecoinWarmStorageServiceStateLibrary.sol/FilecoinWarmStorageServiceStateLibrary.json

import "./FilecoinWarmStorageService.sol";
import "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";

contract FilecoinWarmStorageServiceStateView {
    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;

    FilecoinWarmStorageService public immutable service;

    constructor(FilecoinWarmStorageService _service) {
        service = _service;
    }

    function challengeWindow() external view returns (uint256) {
        return service.challengeWindow();
    }

    function clientDataSetIDs(address payer) external view returns (uint256) {
        return service.clientDataSetIDs(payer);
    }

    function clientDataSets(address payer) external view returns (uint256[] memory dataSetIds) {
        return service.clientDataSets(payer);
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

    function getChallengesPerProof() external pure returns (uint64) {
        return FilecoinWarmStorageServiceStateInternalLibrary.getChallengesPerProof();
    }

    function getClientDataSets(address client)
        external
        view
        returns (FilecoinWarmStorageService.DataSetInfo[] memory infos)
    {
        return service.getClientDataSets(client);
    }

    function getDataSet(uint256 dataSetId) external view returns (FilecoinWarmStorageService.DataSetInfo memory info) {
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

    function getMaxProvingPeriod() external view returns (uint64) {
        return service.getMaxProvingPeriod();
    }

    function getPieceMetadata(uint256 dataSetId, uint256 pieceId, string memory key)
        external
        view
        returns (bool exists, string memory value)
    {
        return service.getPieceMetadata(dataSetId, pieceId, key);
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

    function provingDeadlines(uint256 setId) external view returns (uint256) {
        return service.provingDeadlines(setId);
    }

    function railToDataSet(uint256 railId) external view returns (uint256) {
        return service.railToDataSet(railId);
    }

    function thisChallengeWindowStart(uint256 setId) external view returns (uint256) {
        return service.thisChallengeWindowStart(setId);
    }

    function isProviderApproved(uint256 providerId) external view returns (bool) {
        return service.isProviderApproved(providerId);
    }

}
