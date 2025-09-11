import { BigInt, Bytes, log } from "@graphprotocol/graph-ts";
import {
  DataSetDeleted as DataSetDeletedEvent,
  DataSetEmpty as DataSetEmptyEvent,
  NextProvingPeriod as NextProvingPeriodEvent,
  PiecesRemoved as PiecesRemovedEvent,
  PossessionProven as PossessionProvenEvent,
} from "../generated/PDPVerifier/PDPVerifier";
import { DataSet, Piece, Provider } from "../generated/schema";
import { LeafSize, BIGINT_ZERO, BIGINT_ONE } from "./utils/constants";
import { SumTree } from "./utils/sumTree";
import { getDataSetEntityId, getPieceEntityId } from "./utils/keys";

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
    // dataSet doesn't belong to Warm Storage Service
    return;
  }

  const storageProvider = dataSet.serviceProvider;

  // Load Provider (to update stats before changing storageProvider)
  const provider = Provider.load(storageProvider);
  if (provider) {
    provider.totalDataSize = provider.totalDataSize.minus(dataSet.totalDataSize);
    if (provider.totalDataSize.lt(BIGINT_ZERO)) {
      provider.totalDataSize = BIGINT_ZERO;
    }
    provider.totalDataSets = provider.totalDataSets.minus(BIGINT_ONE);
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
  dataSet.serviceProvider = Bytes.empty();
  dataSet.totalPieces = BIGINT_ZERO;
  dataSet.totalDataSize = BIGINT_ZERO;
  dataSet.nextChallengeEpoch = BIGINT_ZERO;
  dataSet.lastProvenEpoch = BIGINT_ZERO;
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Note: Pieces associated with this DataSet are not automatically removed or updated here.
  // They still exist but are linked to an inactive DataSet.
  // Consider if Pieces should be marked as inactive or removed in handlePiecesRemoved if needed.
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

  if (!dataSet) return; // dataSet doesn't belong to Warm Storage Service

  const oldTotalDataSize = dataSet.totalDataSize; // Store size before zeroing

  dataSet.totalPieces = BIGINT_ZERO;
  dataSet.totalDataSize = BIGINT_ZERO;
  dataSet.leafCount = BIGINT_ZERO;
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Update Provider's total data size
  const provider = Provider.load(dataSet.serviceProvider);
  if (provider) {
    // Subtract the size this data set had *before* it was zeroed
    provider.totalDataSize = provider.totalDataSize.minus(oldTotalDataSize);
    if (provider.totalDataSize.lt(BIGINT_ZERO)) {
      provider.totalDataSize = BIGINT_ZERO; // Prevent negative size
    }
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    // It's possible the provider was deleted or storageProvider changed before this event
    log.warning("DataSetEmpty: Provider {} for DataSet {} not found", [
      dataSet.serviceProvider.toHexString(),
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

  // Load DataSet early to check if it belongs to Warm Storage Service
  const dataSet = DataSet.load(dataSetEntityId);

  if (!dataSet) return; // dataSet doesn't belong to Warm Storage Service

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
      piece.totalProofsSubmitted = piece.totalProofsSubmitted.plus(BIGINT_ONE);
      piece.updatedAt = currentTimestamp;
      piece.blockNumber = currentBlockNumber;
      piece.save();
    } else {
      log.warning("PossessionProven: Piece {} for Set {} not found during challenge processing", [
        pieceId.toString(),
        setId.toString(),
      ]);
    }
  }

  // Update DataSet

  dataSet.lastProvenEpoch = currentBlockNumber; // Update last proven epoch for the set
  dataSet.totalProvedPieces = dataSet.totalProvedPieces.plus(BigInt.fromI32(uniquePieces.length));
  dataSet.totalProofs = dataSet.totalProofs.plus(BIGINT_ONE);
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

  if (!dataSet) return; // dataSet doesn't belong to Warm Storage Service

  dataSet.nextChallengeEpoch = challengeEpoch;
  dataSet.challengeRange = leafCount;
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();
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
  if (!dataSet) return; // dataSet doesn't belong to Warm Storage Service

  let removedPieceCount = 0;
  let removedDataSize = BIGINT_ZERO;

  // Mark Piece entities as removed (soft delete)
  for (let i = 0; i < pieceIds.length; i++) {
    const pieceId = pieceIds[i];
    const pieceEntityId = getPieceEntityId(setId, pieceId);

    const piece = Piece.load(pieceEntityId);
    if (piece) {
      removedPieceCount += 1;
      removedDataSize = removedDataSize.plus(piece.rawSize);

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
        event.block.number,
      );
    } else {
      log.warning("handlePiecesRemoved: Piece {} for Set {} not found. Cannot remove.", [
        pieceId.toString(),
        setId.toString(),
      ]);
    }
  }

  // Update DataSet stats
  dataSet.totalPieces = dataSet.totalPieces.minus(BigInt.fromI32(removedPieceCount));
  dataSet.totalDataSize = dataSet.totalDataSize.minus(removedDataSize);
  dataSet.leafCount = dataSet.leafCount.minus(removedDataSize.div(BigInt.fromI32(LeafSize)));

  // Ensure stats don't go negative
  if (dataSet.totalPieces.lt(BIGINT_ZERO)) {
    log.warning("handlePiecesRemoved: DataSet {} pieceCount went negative. Setting to 0.", [setId.toString()]);
    dataSet.totalPieces = BIGINT_ZERO;
  }
  if (dataSet.totalDataSize.lt(BIGINT_ZERO)) {
    log.warning("handlePiecesRemoved: DataSet {} totalDataSize went negative. Setting to 0.", [setId.toString()]);
    dataSet.totalDataSize = BIGINT_ZERO;
  }
  if (dataSet.leafCount.lt(BIGINT_ZERO)) {
    log.warning("handlePiecesRemoved: DataSet {} leafCount went negative. Setting to 0.", [setId.toString()]);
    dataSet.leafCount = BIGINT_ZERO;
  }
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Update Provider stats
  const provider = Provider.load(dataSet.serviceProvider);
  if (provider) {
    provider.totalDataSize = provider.totalDataSize.minus(removedDataSize);
    // Ensure provider totalDataSize doesn't go negative
    if (provider.totalDataSize.lt(BIGINT_ZERO)) {
      log.warning("handlePiecesRemoved: Provider {} totalDataSize went negative. Setting to 0.", [
        dataSet.serviceProvider.toHex(),
      ]);
      provider.totalDataSize = BIGINT_ZERO;
    }
    provider.totalPieces = provider.totalPieces.minus(BigInt.fromI32(removedPieceCount));
    // Ensure provider totalPieces doesn't go negative
    if (provider.totalPieces.lt(BIGINT_ZERO)) {
      log.warning("handlePiecesRemoved: Provider {} totalPieces went negative. Setting to 0.", [
        dataSet.serviceProvider.toHex(),
      ]);
      provider.totalPieces = BIGINT_ZERO;
    }
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("handlePiecesRemoved: Provider {} for DataSet {} not found", [
      dataSet.serviceProvider.toHex(),
      setId.toString(),
    ]);
  }
}
