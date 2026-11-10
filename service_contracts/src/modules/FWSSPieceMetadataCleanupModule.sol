// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity 0.8.37;

import {FWSSStorage} from "../storage/FWSSStorage.sol";

/// @title FWSSPieceMetadataCleanupModule
/// @notice Lets anyone zero the legacy piece metadata that FWSS no longer writes: `dataSetPieceMetadata`,
/// `dataSetPieceMetadataKeys` and `scheduledPieceMetadataRemovals`.
/// This facet is temporary: it is removed once that state is gone, and its function and errors leave the FWSS ABI then.
/// @dev On FEVM, storage writes that are adjacent in slot-key order are much cheaper than scattered ones, and storage
/// is flushed before every external call. So each operation zeroes one slot or a short run of adjacent slots without
/// reading what other operations zero, operations run in any order and any number of times, and the loop makes no
/// external calls. PopQueue is the exception: it reads the queue length and pops from the end.
contract FWSSPieceMetadataCleanupModule is FWSSStorage {
    uint256 private constant VALUE_HEAD = 0;
    uint256 private constant VALUE_DATA = 1;
    uint256 private constant KEYS_LENGTH = 2;
    uint256 private constant KEY_HEAD = 3;
    uint256 private constant POP_QUEUE = 4;

    // Bounds of the legacy data (5 keys per piece, 128-byte values), above today's limits in FWSSConstants.
    // The 1-byte field plus this bound stops `keccak256(slot) + offset` from addressing an arbitrary slot.
    uint256 private constant LEGACY_MAX_KEYS_PER_PIECE = 5;
    uint256 private constant LEGACY_MAX_VALUE_DATA_SLOTS = 4;

    error UnknownCleanupOp(uint256 opOffset, uint256 kind);
    error TruncatedCleanupOp(uint256 opOffset);
    error ValueDataSlotsOutOfRange(uint256 opOffset, uint256 count);
    error KeyIndexOutOfRange(uint256 opOffset, uint256 index);

    /// @notice Zeroes legacy piece metadata slots.
    /// `ops` concatenates packed operations: big-endian unsigned integers, no padding, no length prefix.
    /// Each operation starts with `kind` (1 byte) and `dataSetId` (5 bytes), followed by a body that depends on kind:
    /// - 0 ValueHead: `pieceId` (5), `keyLength` (1), `key` (keyLength bytes). Zeroes the head slot of
    ///   `dataSetPieceMetadata[dataSetId][pieceId][key]`, which holds a short value and the length of a long one.
    /// - 1 ValueData: `pieceId` (5), `count` (1, at most 4), `keyLength` (1), `key` (keyLength bytes). Zeroes the
    ///   first `count` data slots of that value's long-string storage.
    /// - 2 KeysLength: `pieceId` (5). Zeroes the length slot of `dataSetPieceMetadataKeys[dataSetId][pieceId]`.
    /// - 3 KeyHead: `pieceId` (5), `index` (1, at most 4). Zeroes element `index` of that key array.
    /// - 4 PopQueue: `count` (2). Pops up to `count` entries from the end of
    ///   `scheduledPieceMetadataRemovals[dataSetId]`, and marks a live data set's next proving period to refresh its
    ///   rate if it popped any.
    /// Operations never check what they zero, so a batch with already-cleaned or deleted entries still succeeds.
    /// @param ops The packed operations; empty is a no-op.
    function cleanupLegacyPieceMetadata(bytes calldata ops) external {
        uint256 offset = 0;
        while (offset < ops.length) {
            offset = _apply(ops, offset);
        }
    }

    function _apply(bytes calldata ops, uint256 start) private returns (uint256 next) {
        uint256 kind = _read(ops, start, start, 1);
        require(kind <= POP_QUEUE, UnknownCleanupOp(start, kind));
        uint256 dataSetId = _read(ops, start, start + 1, 5);

        if (kind == POP_QUEUE) {
            _popQueue(dataSetId, _read(ops, start, start + 6, 2));
            return start + 8;
        }

        uint256 pieceId = _read(ops, start, start + 6, 5);
        next = start + 11;

        if (kind == KEYS_LENGTH) {
            _zero(_slot(dataSetPieceMetadataKeys[dataSetId][pieceId]));
            return next;
        }

        if (kind == KEY_HEAD) {
            uint256 index = _read(ops, start, next, 1);
            require(index < LEGACY_MAX_KEYS_PER_PIECE, KeyIndexOutOfRange(start, index));
            _zero(uint256(keccak256(abi.encode(_slot(dataSetPieceMetadataKeys[dataSetId][pieceId])))) + index);
            return next + 1;
        }

        uint256 count;
        if (kind == VALUE_DATA) {
            count = _read(ops, start, next, 1);
            require(count <= LEGACY_MAX_VALUE_DATA_SLOTS, ValueDataSlotsOutOfRange(start, count));
            next += 1;
        }

        uint256 keyLength = _read(ops, start, next, 1);
        next += 1;
        require(next + keyLength <= ops.length, TruncatedCleanupOp(start));
        uint256 head = _slot(dataSetPieceMetadata[dataSetId][pieceId][string(ops[next:next + keyLength])]);
        next += keyLength;

        if (kind == VALUE_HEAD) {
            _zero(head);
        } else {
            uint256 data = uint256(keccak256(abi.encode(head)));
            for (uint256 i = 0; i < count; i++) {
                _zero(data + i);
            }
        }
    }

    /// @dev The queue used to signal a rate refresh at the next proving period; the flag keeps that signal.
    /// A deleted data set has no rail and keeps its info slots empty.
    function _popQueue(uint256 dataSetId, uint256 count) private {
        uint256[] storage queue = scheduledPieceMetadataRemovals[dataSetId];
        uint256 length = queue.length;
        uint256 pops = count < length ? count : length;
        if (pops == 0) return;

        for (uint256 i = 0; i < pops; i++) {
            queue.pop();
        }

        DataSetInfo storage info = dataSetInfo[dataSetId];
        if (info.pdpRailId != 0) info.pieceRemovalsPending = true;
    }

    /// @dev Reads a big-endian unsigned integer of `size` bytes at `offset`, reverting if it runs past `ops`.
    function _read(bytes calldata ops, uint256 start, uint256 offset, uint256 size) private pure returns (uint256 v) {
        require(offset + size <= ops.length, TruncatedCleanupOp(start));
        assembly ("memory-safe") {
            v := shr(sub(256, shl(3, size)), calldataload(add(ops.offset, offset)))
        }
    }

    function _slot(string storage s) private pure returns (uint256 slot) {
        assembly ("memory-safe") {
            slot := s.slot
        }
    }

    function _slot(string[] storage s) private pure returns (uint256 slot) {
        assembly ("memory-safe") {
            slot := s.slot
        }
    }

    function _zero(uint256 slot) private {
        assembly ("memory-safe") {
            sstore(slot, 0)
        }
    }
}
