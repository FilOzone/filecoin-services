// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {FWSSPieceMetadataCleanupModule} from "../../src/modules/FWSSPieceMetadataCleanupModule.sol";

/// @title FWSSPieceMetadataCleanupHarness
/// @notice The cleanup facet as a standalone contract, plus writes through the legacy mappings and arrays, so the
/// cleanup tool's end-to-end test gets its storage slots from the compiler rather than from the tool.
/// Test only: deployed on a local anvil by tools/piece-metadata-cleanup, never as a facet.
contract FWSSPieceMetadataCleanupHarness is FWSSPieceMetadataCleanupModule {
    /// @notice Writes piece metadata the way FWSS did before it stopped storing it.
    /// @param dataSetId The data set of the piece
    /// @param pieceId The piece
    /// @param keys The keys, pushed in this order
    /// @param values The value of each key
    function seedPieceMetadata(uint256 dataSetId, uint256 pieceId, string[] calldata keys, string[] calldata values)
        external
    {
        require(keys.length == values.length, "keys and values differ in length");

        for (uint256 i = 0; i < keys.length; i++) {
            dataSetPieceMetadataKeys[dataSetId][pieceId].push(keys[i]);
            dataSetPieceMetadata[dataSetId][pieceId][keys[i]] = values[i];
        }
    }

    /// @notice Appends piece ids to the legacy removal queue of a data set.
    /// @param dataSetId The data set
    /// @param pieceIds The piece ids to push
    function seedRemovalQueue(uint256 dataSetId, uint256[] calldata pieceIds) external {
        for (uint256 i = 0; i < pieceIds.length; i++) {
            scheduledPieceMetadataRemovals[dataSetId].push(pieceIds[i]);
        }
    }

    /// @notice Gives a data set a PDP rail, which makes PopQueue set its pieceRemovalsPending flag.
    /// @param dataSetId The data set
    /// @param railId The rail id
    function setPdpRailId(uint256 dataSetId, uint256 railId) external {
        dataSetInfo[dataSetId].pdpRailId = railId;
    }

    /// @notice Whether PopQueue marked the data set for a rate refresh.
    /// @param dataSetId The data set
    /// @return pending The pieceRemovalsPending flag
    function pieceRemovalsPending(uint256 dataSetId) external view returns (bool pending) {
        return dataSetInfo[dataSetId].pieceRemovalsPending;
    }

    /// @notice The first storage slot of a data set's DataSetInfo.
    /// @param dataSetId The data set
    /// @return slot The slot of its pdpRailId field
    function dataSetInfoSlot(uint256 dataSetId) external view returns (uint256 slot) {
        DataSetInfo storage info = dataSetInfo[dataSetId];
        assembly ("memory-safe") {
            slot := info.slot
        }
    }

    /// @notice The head slot of one metadata value.
    /// @param dataSetId The data set of the piece
    /// @param pieceId The piece
    /// @param key The key
    /// @return slot The slot that holds a short value, or the length of a long one
    function valueSlot(uint256 dataSetId, uint256 pieceId, string calldata key) external view returns (uint256 slot) {
        string storage value = dataSetPieceMetadata[dataSetId][pieceId][key];
        assembly ("memory-safe") {
            slot := value.slot
        }
    }
}
