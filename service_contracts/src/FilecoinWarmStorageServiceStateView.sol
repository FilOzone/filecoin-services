// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

// Generated with tools/generate_view_contract.sh out/FilecoinWarmStorageServiceStateLibrary.sol/FilecoinWarmStorageServiceStateLibrary.json

import {IPDPProvingSchedule, PDPListener} from "@pdp/IPDPProvingSchedule.sol";
import "./FilecoinWarmStorageService.sol";
import "./lib/FilecoinWarmStorageServiceStateInternalLibrary.sol";

contract FilecoinWarmStorageServiceStateView is IPDPProvingSchedule {
    using FilecoinWarmStorageServiceStateInternalLibrary for FilecoinWarmStorageService;

    PDPListener public immutable service;
    FilecoinWarmStorageService private immutable warmStorageService;

    constructor(FilecoinWarmStorageService _service) {
        service = _service;
        warmStorageService = _service;
    }

    function challengeWindow() external view returns (uint256) {
        return warmStorageService.challengeWindow();
    }

    function clientDataSetIDs(address payer) external view returns (uint256) {
        return warmStorageService.clientDataSetIDs(payer);
    }

    function clientDataSets(address payer) external view returns (uint256[] memory dataSetIds) {
        return warmStorageService.clientDataSets(payer);
    }

    function getChallengesPerProof() external pure returns (uint64) {
        return FilecoinWarmStorageServiceStateInternalLibrary.getChallengesPerProof();
    }

    function getClientDataSets(address client)
        external
        view
        returns (FilecoinWarmStorageService.DataSetInfo[] memory infos)
    {
        return warmStorageService.getClientDataSets(client);
    }

    function getDataSet(uint256 dataSetId) external view returns (FilecoinWarmStorageService.DataSetInfo memory info) {
        return warmStorageService.getDataSet(dataSetId);
    }

    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256) {
        return FilecoinWarmStorageServiceStateInternalLibrary.getDataSetSizeInBytes(leafCount);
    }

    function getMaxProvingPeriod() external view returns (uint64) {
        return warmStorageService.getMaxProvingPeriod();
    }

    function getPieceMetadata(uint256 dataSetId, uint256 pieceId) external view returns (string memory) {
        return warmStorageService.getPieceMetadata(dataSetId, pieceId);
    }

    function initChallengeWindowStart() external view returns (uint256) {
        return warmStorageService.initChallengeWindowStart();
    }

    function nextChallengeWindowStart(uint256 setId) external view returns (uint256) {
        return warmStorageService.nextChallengeWindowStart(setId);
    }

    function provenPeriods(uint256 dataSetId, uint256 periodId) external view returns (bool) {
        return warmStorageService.provenPeriods(dataSetId, periodId);
    }

    function provenThisPeriod(uint256 dataSetId) external view returns (bool) {
        return warmStorageService.provenThisPeriod(dataSetId);
    }

    function provingActivationEpoch(uint256 dataSetId) external view returns (uint256) {
        return warmStorageService.provingActivationEpoch(dataSetId);
    }

    function provingDeadlines(uint256 setId) external view returns (uint256) {
        return warmStorageService.provingDeadlines(setId);
    }

    function railToDataSet(uint256 railId) external view returns (uint256) {
        return warmStorageService.railToDataSet(railId);
    }

    function thisChallengeWindowStart(uint256 setId) external view returns (uint256) {
        return warmStorageService.thisChallengeWindowStart(setId);
    }
}
