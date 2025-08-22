// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

// Code generated - DO NOT EDIT.
// This file is a generated binding and any changes will be lost.

import "./FilecoinWarmStorageService.sol";
import "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";
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

    function clientDataSetIDs(address payer) external view returns (uint256) {
        return service.clientDataSetIDs(payer);
    }

    function clientDataSets(address payer) external view returns (uint256[] memory dataSetIds) {
        return service.clientDataSets(payer);
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

    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256) {
        return FilecoinWarmStorageServiceStateInternalLibrary.getDataSetSizeInBytes(leafCount);
    }

    function getMaxProvingPeriod() external view returns (uint64) {
        return service.getMaxProvingPeriod();
    }

    function getPDPConfig()
        external
        view
        returns (
            uint64 maxProvingPeriod,
            uint256 challengeWindow_,
            uint256 challengesPerProof,
            uint256 initChallengeWindowStart_
        )
    {
        return service.getPDPConfig();
    }

    function getPieceMetadata(uint256 dataSetId, uint256 pieceId) external view returns (string memory) {
        return service.getPieceMetadata(dataSetId, pieceId);
    }

    function initChallengeWindowStart() external view returns (uint256) {
        return service.initChallengeWindowStart();
    }

    function nextPDPChallengeWindowStart(uint256 setId) external view returns (uint256) {
        return service.nextPDPChallengeWindowStart(setId);
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
}
