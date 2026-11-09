// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {FWSSStorage} from "../storage/FWSSStorage.sol";

/// @title FWSSPieceMetadataRemovals
/// @notice Shared cleanup for metadata of scheduled piece removals.
abstract contract FWSSPieceMetadataRemovals is FWSSStorage {
    /// @notice Clears metadata and the queue for pieces scheduled for removal.
    /// @param dataSetId The data set whose scheduled removals should be processed.
    /// @return hadRemovals Whether any pieces were scheduled, including pieces without metadata.
    function _processScheduledPieceMetadataRemovals(uint256 dataSetId) internal returns (bool hadRemovals) {
        uint256[] storage pieceIds = scheduledPieceMetadataRemovals[dataSetId];
        uint256 len = pieceIds.length;
        if (len == 0) {
            return false;
        }

        mapping(uint256 => string[]) storage pieceMetadataKeys = dataSetPieceMetadataKeys[dataSetId];
        mapping(uint256 => mapping(string => string)) storage pieceMetadata = dataSetPieceMetadata[dataSetId];

        for (uint256 i = 0; i < len; i++) {
            uint256 pieceId = pieceIds[i];
            string[] storage metadataKeys = pieceMetadataKeys[pieceId];
            mapping(string => string) storage metadata = pieceMetadata[pieceId];
            uint256 keyLen = metadataKeys.length;
            for (uint256 j = 0; j < keyLen; j++) {
                delete metadata[metadataKeys[j]];
            }
            delete pieceMetadataKeys[pieceId];
        }

        delete scheduledPieceMetadataRemovals[dataSetId];
        return true;
    }
}
