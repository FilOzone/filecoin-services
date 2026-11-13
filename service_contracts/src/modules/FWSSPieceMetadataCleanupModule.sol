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
    uint256 private constant KEY_DATA = 5;
    uint256 private constant CLEANUP_OP_COUNT = 6;

    // Bytes of each kind's operation before its key, one byte per kind with kind 0 in the lowest byte.
    uint256 private constant FIXED_SIZES = 0x080608070908;

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
    /// Each operation starts with `kind` (1 byte) and `dataSetId` (3 bytes), followed by a body that depends on kind.
    /// Three bytes cover every data set and piece ID that has legacy state.
    /// - 0 ValueHead: `pieceId` (3), `keyLength` (1), `key` (keyLength bytes). Zeroes the head slot of
    ///   `dataSetPieceMetadata[dataSetId][pieceId][key]`, which holds a short value and the length of a long one.
    /// - 1 ValueData: `pieceId` (3), `count` (1, at most 4), `keyLength` (1), `key` (keyLength bytes). Zeroes the
    ///   first `count` data slots of that value's long-string storage.
    /// - 2 KeysLength: `pieceId` (3). Zeroes the length slot of `dataSetPieceMetadataKeys[dataSetId][pieceId]`.
    /// - 3 KeyHead: `pieceId` (3), `index` (1, at most 4). Zeroes element `index` of that key array.
    /// - 4 PopQueue: `count` (2). Pops up to `count` entries from the end of
    ///   `scheduledPieceMetadataRemovals[dataSetId]`, and marks a live data set's next proving period to refresh its
    ///   rate if it popped any.
    /// - 5 KeyData: `pieceId` (3), `index` (1, at most 4). Zeroes the single out-of-line data slot of a
    ///   32-byte key at that index. Separate from KeyHead so operations can follow storage-key order.
    /// Operations never check what they zero, so a batch with already-cleaned or deleted entries still succeeds.
    /// @param ops The packed operations; empty is a no-op.
    function cleanupLegacyPieceMetadata(bytes calldata ops) external {
        // Calldata positions instead of offsets into `ops`, so a read does not add `ops.offset` each time.
        uint256 base;
        assembly ("memory-safe") {
            base := ops.offset
        }
        uint256 end = base + ops.length;

        uint256 position = base;
        while (position < end) {
            position = _apply(base, position, end);
        }
    }

    /// @dev Applies the operation at calldata position `start`, which is below `end`, and returns where the next
    /// one starts. `base` is where `ops` starts, for the offsets that errors report.
    function _apply(uint256 base, uint256 start, uint256 end) private returns (uint256 next) {
        uint256 kind = _read(start, 1);
        require(kind < CLEANUP_OP_COUNT, UnknownCleanupOp(start - base, kind));

        next = start + ((FIXED_SIZES >> (kind << 3)) & 0xff);
        require(next <= end, TruncatedCleanupOp(start - base));
        uint256 dataSetId = _read(start + 1, 3);

        if (kind == POP_QUEUE) {
            _popQueue(dataSetId, _read(start + 4, 2));
            return next;
        }

        uint256 pieceId = _read(start + 4, 3);

        if (kind == KEYS_LENGTH) {
            _zero(_slot(dataSetPieceMetadataKeys[dataSetId][pieceId]));
            return next;
        }

        if (kind == KEY_HEAD || kind == KEY_DATA) {
            uint256 index = _read(start + 7, 1);
            require(index < LEGACY_MAX_KEYS_PER_PIECE, KeyIndexOutOfRange(start - base, index));
            uint256 element = _dataSlot(_slot(dataSetPieceMetadataKeys[dataSetId][pieceId])) + index;
            _zero(kind == KEY_HEAD ? element : _dataSlot(element));
            return next;
        }

        // keyLength is the last byte before the key.
        uint256 keyLength = _read(next - 1, 1);
        require(next + keyLength <= end, TruncatedCleanupOp(start - base));

        uint256 count;
        if (kind == VALUE_DATA) {
            count = _read(start + 7, 1);
            require(count <= LEGACY_MAX_VALUE_DATA_SLOTS, ValueDataSlotsOutOfRange(start - base, count));
        }

        string calldata key;
        assembly ("memory-safe") {
            key.offset := next
            key.length := keyLength
        }
        uint256 head = _slot(dataSetPieceMetadata[dataSetId][pieceId][key]);
        next += keyLength;

        if (kind == VALUE_HEAD) {
            _zero(head);
        } else {
            uint256 data = _dataSlot(head);
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

        // `queue.pop()` would write the length once per entry.
        uint256 lengthSlot = _slot(queue);
        uint256 kept = length - pops;
        uint256 data = _dataSlot(lengthSlot);
        for (uint256 i = kept; i < length; i++) {
            _zero(data + i);
        }
        assembly ("memory-safe") {
            sstore(lengthSlot, kept)
        }

        DataSetInfo storage info = dataSetInfo[dataSetId];
        if (info.pdpRailId != 0) info.pieceRemovalsPending = true;
    }

    /// @dev Reads a big-endian unsigned integer of `size` bytes at calldata position `position`.
    /// The caller checks that it ends inside `ops`.
    function _read(uint256 position, uint256 size) private pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := shr(sub(256, shl(3, size)), calldataload(position))
        }
    }

    /// @dev Where Solidity keeps the elements of the array, or the data of the long string, whose slot is `slot`.
    /// Hashes in scratch space: `abi.encode` would allocate memory for every operation of a batch.
    function _dataSlot(uint256 slot) private pure returns (uint256 data) {
        assembly ("memory-safe") {
            mstore(0x00, slot)
            data := keccak256(0x00, 0x20)
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

    function _slot(uint256[] storage s) private pure returns (uint256 slot) {
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
