import { BigInt, Bytes, log } from "@graphprotocol/graph-ts";
import {
  DataSetDeleted as DataSetDeletedEvent,
  DataSetEmpty as DataSetEmptyEvent,
  NextProvingPeriod as NextProvingPeriodEvent,
  PiecesAdded as PiecesAddedEvent,
  PiecesRemoved as PiecesRemovedEvent,
  PossessionProven as PossessionProvenEvent,
  StorageProviderChanged as StorageProviderChangedEvent,
} from "../generated/PDPVerifier/PDPVerifier";
import { DataSet, Piece, Provider } from "../generated/schema";
import { LeafSize } from "../utils";
import { decodeBytesString } from "./decode";
import { SumTree } from "./sumTree";

// --- Helper Functions for ID Generation ---
function getDataSetEntityId(setId: BigInt): Bytes {
  return Bytes.fromByteArray(Bytes.fromBigInt(setId));
}

function getPieceEntityId(setId: BigInt, pieceId: BigInt): Bytes {
  return Bytes.fromUTF8(setId.toString() + "-" + pieceId.toString());
}

// -----------------------------------------

/**
 * Handles the DataSetDeleted event.
 * Deletes a data set and updates the provider's stats.
 */
export function handleDataSetDeleted(event: DataSetDeletedEvent): void {
  const setId = event.params.setId;

  const dataSetEntityId = getDataSetEntityId(setId);

  // Load DataSet
  const dataSet = DataSet.load(dataSetEntityId);
  if (!dataSet) {
    // dataSet doesn't belong to Pandora Service
    return;
  }

  const storageProvider = dataSet.storageProvider;

  // Load Provider (to update stats before changing storageProvider)
  const provider = Provider.load(storageProvider);
  if (provider) {
    provider.totalDataSize = provider.totalDataSize.minus(
      dataSet.totalDataSize
    );
    if (provider.totalDataSize.lt(BigInt.fromI32(0))) {
      provider.totalDataSize = BigInt.fromI32(0);
    }
    provider.totalDataSets = provider.totalDataSets.minus(BigInt.fromI32(1));
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("DataSetDeleted: Provider {} for DataSet {} not found", [
      storageProvider.toHexString(),
      setId.toString(),
    ]);
  }

  // Update DataSet
  dataSet.isActive = false;
  dataSet.storageProvider = Bytes.empty();
  dataSet.totalPieces = BigInt.fromI32(0);
  dataSet.totalDataSize = BigInt.fromI32(0);
  dataSet.nextChallengeEpoch = BigInt.fromI32(0);
  dataSet.lastProvenEpoch = BigInt.fromI32(0);
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Note: Pieces associated with this DataSet are not automatically removed or updated here.
  // They still exist but are linked to an inactive DataSet.
  // Consider if Pieces should be marked as inactive or removed in handlePiecesRemoved if needed.
}

/**
 * Handles the StorageProviderChanged event.
 * Changes the storageProvider of a data set and updates the provider's stats.
 */
export function handleStorageProviderChanged(
  event: StorageProviderChangedEvent
): void {
  const setId = event.params.setId;
  const oldStorageProvider = event.params.oldStorageProvider;
  const newStorageProvider = event.params.oldStorageProvider;

  const dataSetEntityId = getDataSetEntityId(setId);

  // Load DataSet
  const dataSet = DataSet.load(dataSetEntityId);
  if (!dataSet) {
    // dataSet doesn't belong to Pandora Service
    return;
  }

  // Load Old Provider (if exists) - Just update timestamp, derived field handles removal
  const oldProvider = Provider.load(oldStorageProvider);
  if (oldProvider) {
    oldProvider.totalDataSets = oldProvider.totalDataSets.minus(
      BigInt.fromI32(1)
    );
    oldProvider.updatedAt = event.block.timestamp;
    oldProvider.blockNumber = event.block.number;
    oldProvider.save();
  } else {
    log.warning("StorageProviderChanged: Old Provider {} not found", [
      oldStorageProvider.toHexString(),
    ]);
  }

  // Load or Create New Provider - Just update timestamp/create, derived field handles addition
  let newProvider = Provider.load(newStorageProvider);
  if (newProvider == null) {
    newProvider = new Provider(newStorageProvider);
    newProvider.address = newStorageProvider;
    newProvider.status = "Created";
    newProvider.totalPieces = BigInt.fromI32(0);
    newProvider.totalFaultedPeriods = BigInt.fromI32(0);
    newProvider.totalFaultedPieces = BigInt.fromI32(0);
    newProvider.totalDataSize = BigInt.fromI32(0);
    newProvider.totalDataSets = BigInt.fromI32(1);
    newProvider.createdAt = event.block.timestamp;
    newProvider.blockNumber = event.block.number;
  } else {
    newProvider.totalDataSets = newProvider.totalDataSets.plus(
      BigInt.fromI32(1)
    );
    newProvider.blockNumber = event.block.number;
  }
  newProvider.updatedAt = event.block.timestamp;
  newProvider.save();

  // Update DataSet storageProvider (this updates the derived relationship on both old and new Provider)
  dataSet.storageProvider = newStorageProvider; // Set storageProvider to the new provider's ID
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();
}

/**
 * Handles the DataSetEmpty event.
 * Empties a data set and updates the provider's stats.
 */
export function handleDataSetEmpty(event: DataSetEmptyEvent): void {
  const setId = event.params.setId;

  const dataSetEntityId = getDataSetEntityId(setId);

  // Update DataSet
  const dataSet = DataSet.load(dataSetEntityId);

  if (!dataSet) return; // dataSet doesn't belong to Pandora Service

  const oldTotalDataSize = dataSet.totalDataSize; // Store size before zeroing

  dataSet.totalPieces = BigInt.fromI32(0);
  dataSet.totalDataSize = BigInt.fromI32(0);
  dataSet.leafCount = BigInt.fromI32(0);
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Update Provider's total data size
  const provider = Provider.load(dataSet.storageProvider);
  if (provider) {
    // Subtract the size this data set had *before* it was zeroed
    provider.totalDataSize = provider.totalDataSize.minus(oldTotalDataSize);
    if (provider.totalDataSize.lt(BigInt.fromI32(0))) {
      provider.totalDataSize = BigInt.fromI32(0); // Prevent negative size
    }
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    // It's possible the provider was deleted or storageProvider changed before this event
    log.warning("DataSetEmpty: Provider {} for DataSet {} not found", [
      dataSet.storageProvider.toHexString(),
      setId.toString(),
    ]);
  }
}

/**
 * Handles the PossessionProven event.
 * Proves possession of a data set and updates the provider's stats.
 */
export function handlePossessionProven(event: PossessionProvenEvent): void {
  const setId = event.params.setId;
  const challenges = event.params.challenges; // Array of { pieceId: BigInt, offset: BigInt }
  const currentBlockNumber = event.block.number; // Use block number as epoch indicator
  const currentTimestamp = event.block.timestamp;

  const dataSetEntityId = getDataSetEntityId(setId);

  // Load DataSet early to check if it belongs to Pandora Service
  const dataSet = DataSet.load(dataSetEntityId);

  if (!dataSet) return; // dataSet doesn't belong to Pandora Service

  let uniquePieces: BigInt[] = [];
  let pieceIdMap = new Map<string, boolean>();

  // Process each challenge
  for (let i = 0; i < challenges.length; i++) {
    const challenge = challenges[i];
    const pieceId = challenge.pieceId; // Note: keeping .pieceId for now as it's the event field name

    const pieceIdStr = pieceId.toString();
    if (!pieceIdMap.has(pieceIdStr)) {
      uniquePieces.push(pieceId);
      pieceIdMap.set(pieceIdStr, true);
    }
  }

  for (let i = 0; i < uniquePieces.length; i++) {
    const pieceId = uniquePieces[i];
    const pieceEntityId = getPieceEntityId(setId, pieceId);
    const piece = Piece.load(pieceEntityId);
    if (piece) {
      piece.lastProvenEpoch = currentBlockNumber;
      piece.lastProvenAt = currentTimestamp;
      piece.totalProofsSubmitted = piece.totalProofsSubmitted.plus(
        BigInt.fromI32(1)
      );
      piece.updatedAt = currentTimestamp;
      piece.blockNumber = currentBlockNumber;
      piece.save();
    } else {
      log.warning(
        "PossessionProven: Piece {} for Set {} not found during challenge processing",
        [pieceId.toString(), setId.toString()]
      );
    }
  }

  // Update DataSet

  dataSet.lastProvenEpoch = currentBlockNumber; // Update last proven epoch for the set
  dataSet.totalProvedPieces = dataSet.totalProvedPieces.plus(
    BigInt.fromI32(uniquePieces.length)
  );
  dataSet.totalProofs = dataSet.totalProofs.plus(BigInt.fromI32(1));
  dataSet.updatedAt = currentTimestamp;
  dataSet.blockNumber = currentBlockNumber;
  dataSet.save();
}

/**
 * Handles the NextProvingPeriod event.
 * Updates the next challenge epoch and challenge range for a data set.
 */
export function handleNextProvingPeriod(event: NextProvingPeriodEvent): void {
  const setId = event.params.setId;
  const challengeEpoch = event.params.challengeEpoch;
  const leafCount = event.params.leafCount;

  const dataSetEntityId = getDataSetEntityId(setId);

  // Update Data Set
  const dataSet = DataSet.load(dataSetEntityId);

  if (!dataSet) return; // dataSet doesn't belong to Pandora Service

  dataSet.nextChallengeEpoch = challengeEpoch;
  dataSet.challengeRange = leafCount;
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();
}

/**
 * Handles the PiecesAdded event.
 * Adds pieces to a data set and updates the provider's stats.
 */
export function handlePiecesAdded(event: PiecesAddedEvent): void {
  const setId = event.params.setId;
  const pieceIdsFromEvent = event.params.pieceIds; // Get piece IDs from event params (keeping field name for compatibility)

  // Input parsing is necessary to get rawSize and piece bytes (cid)
  const txInput = event.transaction.input;

  if (txInput.length < 4) {
    log.error("Invalid tx input length in handlePiecesAdded: {}", [
      event.transaction.hash.toHex(),
    ]);
    return;
  }

  const dataSetEntityId = getDataSetEntityId(setId);

  // Load DataSet
  const dataSet = DataSet.load(dataSetEntityId);
  if (!dataSet) return; // dataSet doesn't belong to Pandora Service

  // --- Parse Transaction Input --- Requires helper functions
  // Skip function selector (first 4 bytes)
  const encodedData = Bytes.fromUint8Array(txInput.slice(4));

  // Decode setId (uint256 at offset 0)
  let decodedSetId: BigInt = readUint256(encodedData, 0);
  if (decodedSetId != setId) {
    log.warning(
      "Decoded setId {} does not match event param {} in handlePiecesAdded. Tx: {}. Using event param.",
      [
        decodedSetId.toString(),
        setId.toString(),
        event.transaction.hash.toHex(),
      ]
    );
  }

  // Decode extraData
  const extraDataStart = readUint256(encodedData, 64);
  const extraDataBytes = encodedData.subarray(extraDataStart.toI32() + 32);

  // Assuming extraData -> (metadata,signature)
  const decodedData = decodeBytesString(Bytes.fromUint8Array(extraDataBytes));
  let metadata: string = decodedData.stringValue;

  // Decode piecesData (tuple[])
  let piecesDataOffset = readUint256(encodedData, 32).toI32(); // Offset is at byte 32
  let piecesDataLength: i32;

  if (piecesDataOffset < 0 || encodedData.length < piecesDataOffset + 32) {
    log.error(
      "handlePiecesAdded: Invalid piecesDataOffset {} or data length {} for reading piecesData length. Tx: {}",
      [
        piecesDataOffset.toString(),
        encodedData.length.toString(),
        event.transaction.hash.toHex(),
      ]
    );
    return;
  }

  piecesDataLength = readUint256(encodedData, piecesDataOffset).toI32(); // Length is at the offset

  if (piecesDataLength < 0) {
    log.error(
      "handlePiecesAdded: Invalid negative piecesDataLength {}. Tx: {}",
      [piecesDataLength.toString(), event.transaction.hash.toHex()]
    );
    return;
  }

  // Check if number of pieces from input matches event param
  if (piecesDataLength != pieceIdsFromEvent.length) {
    log.error(
      "handlePiecesAdded: Decoded pieces count ({}) does not match event param count ({}). Tx: {}",
      [
        piecesDataLength.toString(),
        pieceIdsFromEvent.length.toString(),
        event.transaction.hash.toHex(),
      ]
    );
    // Decide how to proceed. For now, use the event length as the source of truth for iteration.
    piecesDataLength = pieceIdsFromEvent.length;
  }

  let addedPieceCount = 0;
  let totalDataSizeAdded = BigInt.fromI32(0);

  // Create Piece entities
  const structsBaseOffset = piecesDataOffset + 32; // Start of struct offsets/data

  for (let i = 0; i < piecesDataLength; i++) {
    const pieceId = pieceIdsFromEvent[i]; // Use pieceId from event params

    // Calculate offset for this struct's data
    const structDataRelOffset = readUint256(
      encodedData,
      structsBaseOffset + i * 32
    ).toI32();
    const structDataAbsOffset = piecesDataOffset + 32 + structDataRelOffset; // Correct absolute offset

    // Check bounds for reading struct content (piece offset + rawSize)
    if (
      structDataAbsOffset < 0 ||
      encodedData.length < structDataAbsOffset + 64
    ) {
      log.error(
        "handlePiecesAdded: Encoded data too short or invalid offset for piece struct content. Index: {}, Offset: {}, Len: {}. Tx: {}",
        [
          i.toString(),
          structDataAbsOffset.toString(),
          encodedData.length.toString(),
          event.transaction.hash.toHex(),
        ]
      );
      continue; // Skip this piece
    }

    // Decode piece tuple (bytes stored within the struct)
    const pieceBytes = readBytes(encodedData, structDataAbsOffset); // Reads dynamic bytes
    // Decode rawSize (uint256 stored after piece bytes offset)
    const rawSize = readUint256(encodedData, structDataAbsOffset + 32);

    const pieceEntityId = getPieceEntityId(setId, pieceId);

    let piece = Piece.load(pieceEntityId);
    if (piece) {
      log.warning(
        "handlePiecesAdded: Piece {} for Set {} already exists. This shouldn't happen. Skipping.",
        [pieceId.toString(), setId.toString()]
      );
      continue;
    }

    piece = new Piece(pieceEntityId);
    piece.pieceId = pieceId;
    piece.setId = setId;
    piece.metadata = metadata;
    piece.rawSize = rawSize; // Use correct field name
    piece.leafCount = rawSize.div(BigInt.fromI32(LeafSize));
    piece.cid = pieceBytes.length > 0 ? pieceBytes : Bytes.empty(); // Use correct field name
    piece.removed = false; // Explicitly set removed to false
    piece.lastProvenEpoch = BigInt.fromI32(0);
    piece.lastProvenAt = BigInt.fromI32(0);
    piece.lastFaultedEpoch = BigInt.fromI32(0);
    piece.lastFaultedAt = BigInt.fromI32(0);
    piece.totalProofsSubmitted = BigInt.fromI32(0);
    piece.totalPeriodsFaulted = BigInt.fromI32(0);
    piece.createdAt = event.block.timestamp;
    piece.updatedAt = event.block.timestamp;
    piece.blockNumber = event.block.number;
    piece.dataSet = dataSetEntityId; // Link to DataSet

    piece.save();

    // Update SumTree
    const sumTree = new SumTree();
    sumTree.sumTreeAdd(
      setId.toI32(),
      rawSize.div(BigInt.fromI32(LeafSize)),
      pieceId.toI32()
    );

    addedPieceCount += 1;
    totalDataSizeAdded = totalDataSizeAdded.plus(rawSize);
  }

  // Update DataSet stats
  dataSet.totalPieces = dataSet.totalPieces.plus(
    BigInt.fromI32(addedPieceCount)
  ); // Use correct field name
  dataSet.nextPieceId = dataSet.nextPieceId.plus(
    BigInt.fromI32(addedPieceCount)
  );
  dataSet.totalDataSize = dataSet.totalDataSize.plus(totalDataSizeAdded);
  dataSet.leafCount = dataSet.leafCount.plus(
    totalDataSizeAdded.div(BigInt.fromI32(LeafSize))
  );
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Update Provider stats
  const provider = Provider.load(dataSet.storageProvider);
  if (provider) {
    provider.totalDataSize = provider.totalDataSize.plus(totalDataSizeAdded);
    provider.totalPieces = provider.totalPieces.plus(
      BigInt.fromI32(addedPieceCount)
    );
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("handlePiecesAdded: Provider {} for DataSet {} not found", [
      dataSet.storageProvider.toHex(),
      setId.toString(),
    ]);
  }
}

/**
 * Handles the PiecesRemoved event.
 * Removes pieces from a data set and updates the provider's stats.
 */
export function handlePiecesRemoved(event: PiecesRemovedEvent): void {
  const setId = event.params.setId;
  const pieceIds = event.params.pieceIds; // Keeping field name for compatibility

  const dataSetEntityId = getDataSetEntityId(setId);

  // Load DataSet
  const dataSet = DataSet.load(dataSetEntityId);
  if (!dataSet) return; // dataSet doesn't belong to Pandora Service

  let removedPieceCount = 0;
  let removedDataSize = BigInt.fromI32(0);

  // Mark Piece entities as removed (soft delete)
  for (let i = 0; i < pieceIds.length; i++) {
    const pieceId = pieceIds[i];
    const pieceEntityId = getPieceEntityId(setId, pieceId);

    const piece = Piece.load(pieceEntityId);
    if (piece) {
      removedPieceCount += 1;
      removedDataSize = removedDataSize.plus(piece.rawSize); // Use correct field name

      // Mark the Piece entity as removed instead of deleting
      piece.removed = true;
      piece.updatedAt = event.block.timestamp;
      piece.blockNumber = event.block.number;
      piece.save();

      // Update SumTree
      const sumTree = new SumTree();
      sumTree.sumTreeRemove(
        setId.toI32(),
        dataSet.nextPieceId.toI32(),
        pieceId.toI32(),
        piece.rawSize.div(BigInt.fromI32(LeafSize)),
        event.block.number
      );
    } else {
      log.warning(
        "handlePiecesRemoved: Piece {} for Set {} not found. Cannot remove.",
        [pieceId.toString(), setId.toString()]
      );
    }
  }

  // Update DataSet stats
  dataSet.totalPieces = dataSet.totalPieces.minus(
    BigInt.fromI32(removedPieceCount)
  ); // Use correct field name
  dataSet.totalDataSize = dataSet.totalDataSize.minus(removedDataSize);
  dataSet.leafCount = dataSet.leafCount.minus(
    removedDataSize.div(BigInt.fromI32(LeafSize))
  );

  // Ensure stats don't go negative
  if (dataSet.totalPieces.lt(BigInt.fromI32(0))) {
    // Use correct field name
    log.warning(
      "handlePiecesRemoved: DataSet {} pieceCount went negative. Setting to 0.",
      [setId.toString()]
    );
    dataSet.totalPieces = BigInt.fromI32(0); // Use correct field name
  }
  if (dataSet.totalDataSize.lt(BigInt.fromI32(0))) {
    log.warning(
      "handlePiecesRemoved: DataSet {} totalDataSize went negative. Setting to 0.",
      [setId.toString()]
    );
    dataSet.totalDataSize = BigInt.fromI32(0);
  }
  if (dataSet.leafCount.lt(BigInt.fromI32(0))) {
    log.warning(
      "handlePiecesRemoved: DataSet {} leafCount went negative. Setting to 0.",
      [setId.toString()]
    );
    dataSet.leafCount = BigInt.fromI32(0);
  }
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Update Provider stats
  const provider = Provider.load(dataSet.storageProvider);
  if (provider) {
    provider.totalDataSize = provider.totalDataSize.minus(removedDataSize);
    // Ensure provider totalDataSize doesn't go negative
    if (provider.totalDataSize.lt(BigInt.fromI32(0))) {
      log.warning(
        "handlePiecesRemoved: Provider {} totalDataSize went negative. Setting to 0.",
        [dataSet.storageProvider.toHex()]
      );
      provider.totalDataSize = BigInt.fromI32(0);
    }
    provider.totalPieces = provider.totalPieces.minus(
      BigInt.fromI32(removedPieceCount)
    );
    // Ensure provider totalPieces doesn't go negative
    if (provider.totalPieces.lt(BigInt.fromI32(0))) {
      log.warning(
        "handlePiecesRemoved: Provider {} totalPieces went negative. Setting to 0.",
        [dataSet.storageProvider.toHex()]
      );
      provider.totalPieces = BigInt.fromI32(0);
    }
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("handlePiecesRemoved: Provider {} for DataSet {} not found", [
      dataSet.storageProvider.toHex(),
      setId.toString(),
    ]);
  }
}

// Helper function to read Uint256 from Bytes at a specific offset
function readUint256(data: Bytes, offset: i32): BigInt {
  if (offset < 0 || data.length < offset + 32) {
    log.error(
      "readUint256: Invalid offset {} or data length {} for reading Uint256",
      [offset.toString(), data.length.toString()]
    );
    return BigInt.zero();
  }
  // Slice 32 bytes and convert to BigInt (assuming big-endian)
  const slicedBytes = Bytes.fromUint8Array(data.slice(offset, offset + 32));
  // Ensure bytes are reversed for correct BigInt conversion if needed (depends on source endianness)
  // AssemblyScript's BigInt.fromUnsignedBytes assumes little-endian by default, reverse for big-endian
  const reversedBytesArray = slicedBytes.reverse(); // Returns Uint8Array
  const reversedBytes = Bytes.fromUint8Array(reversedBytesArray); // Create Bytes object
  return BigInt.fromUnsignedBytes(reversedBytes);
}

// Helper function to read dynamic Bytes from ABI-encoded data
function readBytes(data: Bytes, offset: i32): Bytes {
  // First, read the offset to the actual bytes data (uint256)
  const bytesTupleOffset = readUint256(data, offset).toI32();

  // Check if the bytes offset is valid
  if (bytesTupleOffset < 0 || data.length < offset + bytesTupleOffset + 32) {
    log.error(
      "readBytes: Invalid offset {} or data length {} for reading bytes length",
      [bytesTupleOffset.toString(), data.length.toString()]
    );
    return Bytes.empty();
  }

  const bytesOffset = readUint256(data, offset + bytesTupleOffset).toI32();
  const bytesAbsOffset = offset + bytesTupleOffset + bytesOffset;
  // Read the length of the bytes (uint256)
  const bytesLength = readUint256(data, bytesAbsOffset).toI32();

  // Check if the length is valid
  if (bytesLength < 0 || data.length < bytesAbsOffset + 32 + bytesLength) {
    log.error(
      "readBytes: Invalid length {} or data length {} for reading bytes data",
      [bytesLength.toString(), data.length.toString()]
    );
    return Bytes.empty();
  }

  // Slice the actual bytes
  return Bytes.fromUint8Array(
    data.slice(bytesAbsOffset + 32, bytesAbsOffset + 32 + bytesLength)
  );
}
