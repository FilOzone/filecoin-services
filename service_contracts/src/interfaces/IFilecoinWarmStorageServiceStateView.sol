// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.20;

// Code generated - DO NOT EDIT.
// This file is a generated binding and any changes will be lost.
// Generated with tools/generate_view_interface.sh out/FilecoinWarmStorageServiceStateLibrary.sol/FilecoinWarmStorageServiceStateLibrary.json

import {IPDPProvingSchedule} from "@pdp/IPDPProvingSchedule.sol";

interface IFilecoinWarmStorageServiceStateView is IPDPProvingSchedule {
    function challengeWindow() external view returns (uint256);
    function clientDataSetIDs(address payer) external view returns (uint256);
    function clientDataSets(address payer) external view returns (uint256[] memory dataSetIds);
    function getChallengesPerProof() external pure returns (uint64);
    function getClientDataSets(address client)
        external
        view
        returns (FilecoinWarmStorageService.DataSetInfo[] memory infos);
    function getDataSet(uint256 dataSetId) external view returns (FilecoinWarmStorageService.DataSetInfo memory info);
    function getDataSetSizeInBytes(uint256 leafCount) external pure returns (uint256);
    function getMaxProvingPeriod() external view returns (uint64);
    function getPDPConfig()
        external
        view
        returns (
            uint64 maxProvingPeriod,
            uint256 challengeWindow_,
            uint256 challengesPerProof,
            uint256 initChallengeWindowStart_
        );
    function getPieceMetadata(uint256 dataSetId, uint256 pieceId) external view returns (string memory);
    function initChallengeWindowStart() external view returns (uint256);
    function nextPDPChallengeWindowStart(uint256 setId) external view returns (uint256);
    function provenPeriods(uint256 dataSetId, uint256 periodId) external view returns (bool);
    function provenThisPeriod(uint256 dataSetId) external view returns (bool);
    function provingActivationEpoch(uint256 dataSetId) external view returns (uint256);
    function provingDeadlines(uint256 setId) external view returns (uint256);
    function railToDataSet(uint256 railId) external view returns (uint256);
    function thisChallengeWindowStart(uint256 setId) external view returns (uint256);
}
