// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Cids} from "@pdp/Cids.sol";
import {PDPListener} from "@pdp/PDPVerifier.sol";
import {FilecoinPayV1} from "@fws-payments/FilecoinPayV1.sol";
import {DataSetInfoView} from "../../src/lib/FWSSViewTypes.sol";
import {
    DATA_SET_INFO_SLOT,
    DATA_SET_PIECE_METADATA_KEYS_SLOT,
    DATA_SET_PIECE_METADATA_SLOT,
    SCHEDULED_PIECE_METADATA_REMOVALS_SLOT
} from "../../src/lib/FilecoinWarmStorageServiceLayout.sol";
import {FWSSPieceMetadataCleanupModule} from "../../src/modules/FWSSPieceMetadataCleanupModule.sol";
import {FilecoinWarmStorageServiceFixture} from "../helpers/FilecoinWarmStorageServiceFixture.sol";

contract FWSSPieceMetadataCleanupModuleTest is FilecoinWarmStorageServiceFixture {
    // DataSetInfo.pieceRemovalsPending: relative slot 10, above pendingOneTimePayments and lifecycleReserveBalance.
    uint256 private constant FLAG_SLOT_OFFSET = 10;
    uint256 private constant FLAG_SHIFT = 192;

    FWSSPieceMetadataCleanupModule internal cleanup;
    address internal proxy;

    function setUp() public override {
        super.setUp();
        proxy = address(pdpServiceWithPayments);
        cleanup = FWSSPieceMetadataCleanupModule(proxy);
    }

    // Op encoder, the reference for off-chain tooling. Data set and piece IDs must fit in 24 bits.

    function _valueHeadOp(uint256 dataSetId, uint256 pieceId, bytes memory key) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), uint24(dataSetId), uint24(pieceId), uint8(key.length), key);
    }

    function _valueDataOp(uint256 dataSetId, uint256 pieceId, uint256 count, bytes memory key)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint8(1), uint24(dataSetId), uint24(pieceId), uint8(count), uint8(key.length), key);
    }

    function _keysLengthOp(uint256 dataSetId, uint256 pieceId) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(2), uint24(dataSetId), uint24(pieceId));
    }

    function _keyHeadOp(uint256 dataSetId, uint256 pieceId, uint256 index) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(3), uint24(dataSetId), uint24(pieceId), uint8(index));
    }

    function _popQueueOp(uint256 dataSetId, uint256 count) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(4), uint24(dataSetId), uint16(count));
    }

    function _keyDataOp(uint256 dataSetId, uint256 pieceId, uint256 index) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(5), uint24(dataSetId), uint24(pieceId), uint8(index));
    }

    /// @dev Ops that clear one piece: per key its value head, the data slots of a value of 32 bytes or more, and
    ///      its key head and the data slot of a 32-byte key; then the key list length.
    function _pieceOps(uint256 dataSetId, uint256 pieceId, string[] memory keys, string[] memory values)
        internal
        pure
        returns (bytes[] memory ops)
    {
        ops = new bytes[](4 * keys.length + 1);
        uint256 next = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            ops[next++] = _valueHeadOp(dataSetId, pieceId, bytes(keys[i]));
            ops[next++] = _keyHeadOp(dataSetId, pieceId, i);
            if (bytes(keys[i]).length == 32) {
                ops[next++] = _keyDataOp(dataSetId, pieceId, i);
            }
            if (bytes(values[i]).length >= 32) {
                ops[next++] = _valueDataOp(dataSetId, pieceId, (bytes(values[i]).length + 31) / 32, bytes(keys[i]));
            }
        }
        ops[next++] = _keysLengthOp(dataSetId, pieceId);

        // Drop the unused tail left by keys and values without data slots.
        assembly ("memory-safe") {
            mstore(ops, next)
        }
    }

    function _concat(bytes[] memory ops) internal pure returns (bytes memory batch) {
        for (uint256 i = 0; i < ops.length; i++) {
            batch = bytes.concat(batch, ops[i]);
        }
    }

    function _shuffle(bytes[] memory ops, uint256 seed) internal pure {
        for (uint256 i = ops.length; i > 1; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (ops[i - 1], ops[j]) = (ops[j], ops[i - 1]);
        }
    }

    function _contains(bytes32[] memory slots, uint256 length, bytes32 slot) internal pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (slots[i] == slot) return true;
        }
        return false;
    }

    function _repeat(bytes1 b, uint256 length) internal pure returns (string memory) {
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = b;
        }
        return string(out);
    }

    // Slots from the layout constants and Solidity's mapping, array and string formulas, independent of the module.

    function _valueHeadSlot(uint256 dataSetId, uint256 pieceId, bytes memory key) internal pure returns (bytes32) {
        bytes32 dataSetSlot = keccak256(abi.encode(dataSetId, DATA_SET_PIECE_METADATA_SLOT));
        return keccak256(abi.encodePacked(key, keccak256(abi.encode(pieceId, dataSetSlot))));
    }

    function _keysSlot(uint256 dataSetId, uint256 pieceId) internal pure returns (bytes32) {
        return keccak256(abi.encode(pieceId, keccak256(abi.encode(dataSetId, DATA_SET_PIECE_METADATA_KEYS_SLOT))));
    }

    function _queueSlot(uint256 dataSetId) internal pure returns (bytes32) {
        return keccak256(abi.encode(dataSetId, SCHEDULED_PIECE_METADATA_REMOVALS_SLOT));
    }

    function _flagSlot(uint256 dataSetId) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(dataSetId, DATA_SET_INFO_SLOT))) + FLAG_SLOT_OFFSET);
    }

    function _element(bytes32 base, uint256 index) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(base))) + index);
    }

    function _pieceRemovalsPending(uint256 dataSetId) internal view returns (bool) {
        return (uint256(vm.load(proxy, _flagSlot(dataSetId))) >> FLAG_SHIFT) & 0xff == 1;
    }

    function _createDataSet() internal returns (uint256) {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("label", "kept");
        return createDataSetForClient(sp1, client, keys, values);
    }

    function testFuzz_ClearsEverySlotThePieceWroteInAnyOrder(uint256 shuffleSeed) public {
        uint256 dataSetId = _createDataSet();

        string[] memory keys = new string[](5);
        string[] memory values = new string[](5);
        (keys[0], values[0]) = ("empty", "");
        (keys[1], values[1]) = ("filename", "b.bin");
        (keys[2], values[2]) = ("x31", _repeat("a", 31));
        (keys[3], values[3]) = ("x32", _repeat("b", 32));
        (keys[4], values[4]) = ("x-trace-id-01234567", _repeat("c", 128));
        _seedLegacyPieceMetadata(dataSetId, 8, keys, values);
        (string[] memory longKeys, string[] memory longValues) = _getSingleMetadataKV(_repeat("k", 32), "long-key");

        // Solidity's own writes are the oracle for what pieces 7 and 9 occupy.
        vm.record();
        _seedLegacyPieceMetadata(dataSetId, 7, keys, values);
        _seedLegacyPieceMetadata(dataSetId, 9, longKeys, longValues);
        (, bytes32[] memory seeded) = vm.accesses(proxy);
        assertGe(seeded.length, 20, "6 value heads, 5 value data slots, 6 key heads, 1 key data slot and 2 key counts");

        bytes[] memory ops = _pieceOps(dataSetId, 7, keys, values);
        _shuffle(ops, shuffleSeed);
        bytes[] memory longKeyOps = _pieceOps(dataSetId, 9, longKeys, longValues);
        _shuffle(longKeyOps, shuffleSeed);
        bytes memory batch = bytes.concat(_concat(ops), _concat(longKeyOps));

        vm.record();
        cleanup.cleanupLegacyPieceMetadata(batch);
        (, bytes32[] memory cleared) = vm.accesses(proxy);

        for (uint256 i = 0; i < seeded.length; i++) {
            assertEq(vm.load(proxy, seeded[i]), bytes32(0), "every slot the seeding wrote should be zero");
        }
        for (uint256 i = 0; i < cleared.length; i++) {
            assertEq(vm.load(proxy, cleared[i]), bytes32(0), "cleanup only writes zero");
        }

        vm.record();
        cleanup.cleanupLegacyPieceMetadata(batch);
        (, bytes32[] memory clearedAgain) = vm.accesses(proxy);
        for (uint256 i = 0; i < clearedAgain.length; i++) {
            assertTrue(_contains(cleared, cleared.length, clearedAgain[i]), "a repeat only rewrites zeroed slots");
        }

        assertEq(_legacyPieceMetadataKeysLength(dataSetId, 8), keys.length, "other piece's keys should stay");
        for (uint256 i = 0; i < keys.length; i++) {
            assertEq(_legacyPieceMetadataValue(dataSetId, 8, keys[i]), values[i], "other piece's values should stay");
        }
        (bool exists, string memory label) = pdpServiceWithPayments.getDataSetMetadata(dataSetId, "label");
        assertTrue(exists, "data set metadata should stay");
        assertEq(label, "kept");
    }

    function testFuzz_WritesStayInsideLegacyMappings(uint256 seed) public {
        // A live data set, and two that never existed; the ranges keep the three apart.
        uint256[3] memory dataSetIds = [_createDataSet(), (1 << 20) + uint16(seed >> 200), type(uint24).max];
        uint256[3] memory queueLengths;
        bytes32[3] memory flagsBefore;
        for (uint256 d = 0; d < 3; d++) {
            uint256[] memory pieceIds = new uint256[](uint256(keccak256(abi.encode(seed, "queue", d))) % 4);
            _seedLegacyPieceMetadataRemovals(dataSetIds[d], pieceIds);
            queueLengths[d] = pieceIds.length;
            flagsBefore[d] = vm.load(proxy, _flagSlot(dataSetIds[d]));
        }

        uint256 opCount = 1 + seed % 12;
        bytes memory batch;
        bytes32[] memory allowed = new bytes32[](opCount * 5 + 3 * 4);
        uint256 allowedLength = 0;
        for (uint256 d = 0; d < 3; d++) {
            for (uint256 j = 0; j < queueLengths[d]; j++) {
                allowed[allowedLength++] = _element(_queueSlot(dataSetIds[d]), j);
            }
        }

        for (uint256 i = 0; i < opCount; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 dataSetId = r % 4 == 3 ? uint256(uint24(r >> 8)) : dataSetIds[r % 3];
            uint256 pieceId = (r >> 48) % 3 == 0 ? type(uint24).max : uint24(r >> 56);
            uint256 kind = (r >> 96) % 6;
            uint256 small = (r >> 104) % 5;

            if (kind == 4) {
                uint256 popCount = [uint256(0), 1, 3, type(uint16).max, uint16(r >> 112)][small];
                batch = bytes.concat(batch, _popQueueOp(dataSetId, popCount));
            } else if (kind == 2) {
                batch = bytes.concat(batch, _keysLengthOp(dataSetId, pieceId));
                allowed[allowedLength++] = _keysSlot(dataSetId, pieceId);
            } else if (kind == 3) {
                batch = bytes.concat(batch, _keyHeadOp(dataSetId, pieceId, small));
                allowed[allowedLength++] = _element(_keysSlot(dataSetId, pieceId), small);
            } else if (kind == 5) {
                batch = bytes.concat(batch, _keyDataOp(dataSetId, pieceId, small));
                allowed[allowedLength++] = keccak256(abi.encode(_element(_keysSlot(dataSetId, pieceId), small)));
            } else {
                bytes memory key = abi.encodePacked(keccak256(abi.encode(r, "key")), keccak256(abi.encode(r)));
                uint256 keyLength = [uint256(0), 1, 19, 32, 64][(r >> 128) % 5];
                assembly ("memory-safe") {
                    mstore(key, keyLength)
                }

                bytes32 head = _valueHeadSlot(dataSetId, pieceId, key);
                if (kind == 0) {
                    batch = bytes.concat(batch, _valueHeadOp(dataSetId, pieceId, key));
                    allowed[allowedLength++] = head;
                } else {
                    batch = bytes.concat(batch, _valueDataOp(dataSetId, pieceId, small, key));
                    for (uint256 j = 0; j < small; j++) {
                        allowed[allowedLength++] = _element(head, j);
                    }
                }
            }
        }

        vm.record();
        cleanup.cleanupLegacyPieceMetadata(batch);
        (, bytes32[] memory written) = vm.accesses(proxy);

        for (uint256 i = 0; i < written.length; i++) {
            bytes32 slot = written[i];
            uint256 value = uint256(vm.load(proxy, slot));
            if (_contains(allowed, allowedLength, slot)) {
                assertEq(value, 0, "legacy slots are only zeroed");
                continue;
            }

            bool known = false;
            for (uint256 d = 0; d < 3; d++) {
                if (slot == _queueSlot(dataSetIds[d])) {
                    assertLe(value, queueLengths[d], "queue length only shrinks");
                    known = true;
                } else if (slot == _flagSlot(dataSetIds[d])) {
                    assertTrue(pdpServiceWithPayments.getDataSet(dataSetIds[d]).pdpRailId != 0, "flag on a live set");
                    uint256 before = uint256(flagsBefore[d]);
                    assertEq(uint192(value), uint192(before), "fees and reserve below the flag are unchanged");
                    assertEq(value >> FLAG_SHIFT, 1, "only the flag is set");
                    known = true;
                }
            }
            assertTrue(known, "write outside the legacy mappings");
        }
    }

    function testCleanup_AddressesTheLargestIds() public {
        uint256 id = type(uint24).max;
        string[] memory keys = new string[](2);
        string[] memory values = new string[](2);
        (keys[0], values[0]) = ("filename", _repeat("v", 64));
        (keys[1], values[1]) = (_repeat("k", 32), "short");

        vm.record();
        _seedLegacyPieceMetadata(id, id, keys, values);
        (, bytes32[] memory seeded) = vm.accesses(proxy);
        assertGe(seeded.length, 8, "2 value heads, 2 value data slots, 2 key heads, 1 key data slot and the key count");
        uint256[] memory pieceIds = new uint256[](2);
        (pieceIds[0], pieceIds[1]) = (id - 1, id);
        _seedLegacyPieceMetadataRemovals(id, pieceIds);

        cleanup.cleanupLegacyPieceMetadata(
            bytes.concat(_concat(_pieceOps(id, id, keys, values)), _popQueueOp(id, pieceIds.length))
        );

        for (uint256 i = 0; i < seeded.length; i++) {
            assertEq(vm.load(proxy, seeded[i]), bytes32(0), "every slot the seeding wrote should be zero");
        }
        assertEq(vm.load(proxy, _queueSlot(id)), bytes32(0), "queue length is zero");
        for (uint256 i = 0; i < pieceIds.length; i++) {
            assertEq(vm.load(proxy, _element(_queueSlot(id), i)), bytes32(0), "queue entry is zeroed");
        }
    }

    function testCleanup_RejectsMalformedOps() public {
        (string[] memory keys, string[] memory values) = _getSingleMetadataKV("k", "v");
        _seedLegacyPieceMetadata(1, 2, keys, values);

        // Each bad batch starts with an op that would clear the seeded value, so a revert must undo it.
        bytes memory valid = _valueHeadOp(1, 2, "k");
        uint256 at = valid.length;
        bytes4 truncated = FWSSPieceMetadataCleanupModule.TruncatedCleanupOp.selector;

        bytes[6] memory full = [
            _valueHeadOp(1, 2, "key"),
            _valueDataOp(1, 2, 4, "key"),
            _keysLengthOp(1, 2),
            _keyHeadOp(1, 2, 4),
            _popQueueOp(1, 3),
            _keyDataOp(1, 2, 4)
        ];
        for (uint256 k = 0; k < full.length; k++) {
            for (uint256 length = 1; length < full[k].length; length++) {
                bytes memory op = full[k];
                bytes memory cut = new bytes(length);
                for (uint256 b = 0; b < length; b++) {
                    cut[b] = op[b];
                }
                _expectRejected(bytes.concat(valid, cut), abi.encodeWithSelector(truncated, at));
            }
        }

        // A cut operation is truncated even when the part that is there is out of range.
        _expectRejected(
            bytes.concat(valid, abi.encodePacked(uint8(1), uint24(1), uint24(2), uint8(5), uint8(3))),
            abi.encodeWithSelector(truncated, at)
        );
        _expectRejected(
            bytes.concat(valid, hex"06"),
            abi.encodeWithSelector(FWSSPieceMetadataCleanupModule.UnknownCleanupOp.selector, at, 6)
        );
        _expectRejected(
            bytes.concat(valid, hex"ff0000000001"),
            abi.encodeWithSelector(FWSSPieceMetadataCleanupModule.UnknownCleanupOp.selector, at, 255)
        );
        _expectRejected(
            bytes.concat(valid, _valueDataOp(1, 2, 5, "key")),
            abi.encodeWithSelector(FWSSPieceMetadataCleanupModule.ValueDataSlotsOutOfRange.selector, at, 5)
        );
        _expectRejected(
            bytes.concat(valid, _keyHeadOp(1, 2, 5)),
            abi.encodeWithSelector(FWSSPieceMetadataCleanupModule.KeyIndexOutOfRange.selector, at, 5)
        );
        _expectRejected(
            bytes.concat(valid, _keyDataOp(1, 2, 5)),
            abi.encodeWithSelector(FWSSPieceMetadataCleanupModule.KeyIndexOutOfRange.selector, at, 5)
        );

        cleanup.cleanupLegacyPieceMetadata("");
        assertEq(_legacyPieceMetadataValue(1, 2, "k"), "v", "empty ops is a no-op");
    }

    function _expectRejected(bytes memory batch, bytes memory err) internal {
        vm.expectRevert(err);
        cleanup.cleanupLegacyPieceMetadata(batch);
        assertEq(_legacyPieceMetadataValue(1, 2, "k"), "v", "a rejected batch changes nothing");
    }

    function testPopQueue_KeepsTheRateRefreshTheQueueSignalled() public {
        uint256 dataSetId = _createDataSet();
        _addPiece(dataSetId, 0, "piece-a");
        _addPiece(dataSetId, 1, "piece-b");
        uint256 pieceLeaves = Cids.leafCount(0, 35);

        (uint64 provingPeriod,,,) = pdpServiceWithPayments.getPDPConfig();
        uint256 deadline = block.number + provingPeriod;
        _nextProvingPeriod(dataSetId, deadline, 2 * pieceLeaves);

        // The pre-flag implementation queued piece 1 behind two earlier removals; PDPVerifier has dropped piece 1.
        uint256[] memory pieceIds = new uint256[](3);
        (pieceIds[0], pieceIds[1], pieceIds[2]) = (1, 5, 6);
        _seedLegacyPieceMetadataRemovals(dataSetId, pieceIds);
        mockPDPVerifier.setDataSetLeafCount(dataSetId, pieceLeaves);

        vm.record();
        cleanup.cleanupLegacyPieceMetadata(_popQueueOp(dataSetId, 2));
        (, bytes32[] memory written) = vm.accesses(proxy);
        uint256 lengthWrites = 0;
        for (uint256 i = 0; i < written.length; i++) {
            if (written[i] == _queueSlot(dataSetId)) lengthWrites++;
        }
        assertEq(lengthWrites, 1, "length written once for the two entries");

        uint256[] memory left = _legacyPieceMetadataRemovals(dataSetId);
        assertEq(left.length, 1, "partial pop");
        assertEq(left[0], 1, "pops from the end");
        assertEq(vm.load(proxy, _element(_queueSlot(dataSetId), 1)), bytes32(0), "popped entry is zeroed");
        assertEq(vm.load(proxy, _element(_queueSlot(dataSetId), 2)), bytes32(0), "popped entry is zeroed");

        cleanup.cleanupLegacyPieceMetadata(_popQueueOp(dataSetId, type(uint16).max));
        assertEq(_legacyPieceMetadataRemovals(dataSetId).length, 0, "queue emptied");
        assertEq(vm.load(proxy, _element(_queueSlot(dataSetId), 0)), bytes32(0), "last entry is zeroed");
        assertTrue(_pieceRemovalsPending(dataSetId), "flag takes over the queue's refresh signal");
        assertEq(_pdpRate(dataSetId), _rateForLeaves(2 * pieceLeaves), "rate waits for the proving period");

        vm.roll(deadline + 1);
        deadline += provingPeriod;
        _nextProvingPeriod(dataSetId, deadline, pieceLeaves);
        assertEq(_pdpRate(dataSetId), _rateForLeaves(pieceLeaves), "next period prices the removal");
        assertFalse(_pieceRemovalsPending(dataSetId), "flag consumed");

        vm.roll(deadline + 1);
        vm.expectCall(address(payments), abi.encodeWithSelector(FilecoinPayV1.modifyRailPayment.selector), 0);
        _nextProvingPeriod(dataSetId, deadline + provingPeriod, pieceLeaves);
    }

    function testPopQueue_EmptyQueueLeavesFlagClear() public {
        uint256 dataSetId = _createDataSet();
        bytes32 before = vm.load(proxy, _flagSlot(dataSetId));

        cleanup.cleanupLegacyPieceMetadata(_popQueueOp(dataSetId, 10));

        assertEq(vm.load(proxy, _flagSlot(dataSetId)), before, "nothing popped, nothing to refresh");
    }

    function testPopQueue_DeletedDataSetKeepsInfoEmpty() public {
        uint256 dataSetId = _createDataSet();
        uint256[] memory pieceIds = new uint256[](2);
        (pieceIds[0], pieceIds[1]) = (0, 1);
        _seedLegacyPieceMetadataRemovals(dataSetId, pieceIds);

        vm.prank(client);
        pdpServiceWithPayments.terminateService(dataSetId);
        DataSetInfoView memory info = pdpServiceWithPayments.getDataSet(dataSetId);
        vm.roll(info.pdpEndEpoch + 1);
        payments.settleRail(info.pdpRailId, payments.getRail(info.pdpRailId).endEpoch);
        vm.prank(sp1);
        mockPDPVerifier.deleteDataSet(PDPListener(proxy), dataSetId, bytes(""));
        assertEq(pdpServiceWithPayments.getDataSet(dataSetId).pdpRailId, 0, "data set deleted");

        cleanup.cleanupLegacyPieceMetadata(_popQueueOp(dataSetId, 2));

        assertEq(_legacyPieceMetadataRemovals(dataSetId).length, 0, "queue emptied");
        assertEq(vm.load(proxy, _flagSlot(dataSetId)), bytes32(0), "deleted data set gets no flag");
    }
}
