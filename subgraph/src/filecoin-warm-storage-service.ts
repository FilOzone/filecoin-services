import { BigInt, Bytes, crypto, log } from "@graphprotocol/graph-ts";
import {
  DataSetCreated as DataSetCreatedEvent,
  FaultRecord as FaultRecordEvent,
  ProviderApproved as ProviderApprovedEvent,
  ProviderUnapproved as ProviderUnapprovedEvent,
  RailRateUpdated as RailRateUpdatedEvent,
  PieceAdded as PieceAddedEventV1,
  PieceAdded1 as PieceAddedEventV2,
  DataSetServiceProviderChanged as DataSetServiceProviderChangedEvent,
  PDPPaymentTerminated as PDPPaymentTerminatedEvent,
  CDNPaymentTerminated as CDNPaymentTerminatedEvent,
  PaymentArbitrated as PaymentArbitratedEvent,
} from "../generated/FilecoinWarmStorageService/FilecoinWarmStorageService";
import { PDPVerifier } from "../generated/PDPVerifier/PDPVerifier";
import { DataSet, FaultRecord, Piece, Provider, Rail, RateChangeQueue } from "../generated/schema";
import {
  BIGINT_ONE,
  BIGINT_ZERO,
  ContractAddresses,
  LeafSize,
  METADATA_KEY_WITH_CDN,
  NumChallenges,
} from "./utils/constants";
import { SumTree } from "./utils/sumTree";
import { createRails } from "./utils/entity";
import { ProviderStatus, RailType } from "./utils/types";
import { getPieceCidData, getServiceProviderInfo } from "./utils/contract-calls";
import {
  getDataSetEntityId,
  getPieceEntityId,
  getRailEntityId,
  getEventLogEntityId,
  getRateChangeQueueEntityId,
} from "./utils/keys";
import { unpaddedSize, validateCommPv2 } from "./utils/cid";

/**
 * Pads a Buffer or Uint8Array to 32 bytes with leading zeros.
 */
function padTo32Bytes(input: Uint8Array): Uint8Array {
  if (input.length >= 32) return input;
  const out = new Uint8Array(32);
  out.set(input, 32 - input.length);
  return out;
}

/**
 * Generates a deterministic challenge index using seed, dataSetID, proofIndex, and totalLeaves.
 * Mirrors the logic from Go's generateChallengeIndex.
 */
export function generateChallengeIndex(
  seed: Uint8Array,
  dataSetID: BigInt,
  proofIndex: i32,
  totalLeaves: BigInt,
): BigInt {
  const data = new Uint8Array(32 + 32 + 8);

  const paddedSeed = padTo32Bytes(seed);
  data.set(paddedSeed, 0);

  // Convert dataSetID to Bytes and pad to 32 bytes (Big-Endian padding implied by padTo32Bytes)
  const dsIDBytes = Bytes.fromBigInt(dataSetID);
  const dsIDPadded = padTo32Bytes(dsIDBytes);
  data.set(dsIDPadded, 32); // Write 32 bytes at offset 32

  // Convert proofIndex (i32) to an 8-byte Uint8Array (uint64 Big-Endian)
  const idxBuf = new Uint8Array(8); // Create 8-byte buffer, initialized to zeros
  idxBuf[7] = u8(proofIndex & 0xff); // Least significant byte
  idxBuf[6] = u8((proofIndex >> 8) & 0xff);
  idxBuf[5] = u8((proofIndex >> 16) & 0xff);
  idxBuf[4] = u8((proofIndex >> 24) & 0xff); // Most significant byte of the i32

  data.set(idxBuf, 64); // Write the 8 bytes at offset 64

  const hashBytes = crypto.keccak256(Bytes.fromUint8Array(data));
  // hashBytes is big-endian, so expected to be reversed
  const hashIntUnsignedR = BigInt.fromUnsignedBytes(
    Bytes.fromUint8Array(Bytes.fromHexString(hashBytes.toHexString()).reverse()),
  );

  if (totalLeaves.isZero()) {
    log.error("generateChallengeIndex: totalLeaves is zero, cannot calculate modulus. DataSetID: {}. Seed: {}", [
      dataSetID.toString(),
      Bytes.fromUint8Array(seed).toHex(),
    ]);
    return BIGINT_ZERO;
  }

  const challengeIndex = hashIntUnsignedR.mod(totalLeaves);
  return challengeIndex;
}

export function ensureEvenHex(value: BigInt): string {
  const hexRaw = value.toHex().slice(2);
  let paddedHex = hexRaw;
  if (hexRaw.length % 2 === 1) {
    paddedHex = "0" + hexRaw;
  }
  return "0x" + paddedHex;
}

export function findChallengedPieces(
  dataSetId: BigInt,
  nextPieceId: BigInt,
  challengeEpoch: BigInt,
  totalLeaves: BigInt,
  blockNumber: BigInt,
): BigInt[] {
  const instance = PDPVerifier.bind(ContractAddresses.PDPVerifier);

  const seedIntResult = instance.try_getRandomness(challengeEpoch);
  if (seedIntResult.reverted) {
    log.warning("findChallengedPieces: Failed to get randomness for epoch {}", [challengeEpoch.toString()]);
    return [];
  }

  const seedInt = seedIntResult.value;
  const seedHex = ensureEvenHex(seedInt);

  const challenges: BigInt[] = [];
  if (totalLeaves.isZero()) {
    log.warning("findChallengedPieces: totalLeaves is zero for DataSet {}. Cannot generate challenges.", [
      dataSetId.toString(),
    ]);
    return [];
  }
  for (let i = 0; i < NumChallenges; i++) {
    const leafIdx = generateChallengeIndex(Bytes.fromHexString(seedHex), dataSetId, i32(i), totalLeaves);
    challenges.push(leafIdx);
  }

  const sumTreeInstance = new SumTree();
  const pieceIds = sumTreeInstance.findPieceIds(dataSetId.toI32(), nextPieceId.toI32(), challenges, blockNumber);
  if (!pieceIds) {
    log.warning("findChallengedPieces: findPieceIds reverted for dataSetId {}", [dataSetId.toString()]);
    return [];
  }

  const pieceIdsArray: BigInt[] = [];
  for (let i = 0; i < pieceIds.length; i++) {
    pieceIdsArray.push(pieceIds[i].pieceId);
  }
  return pieceIdsArray;
}

/**
 * Handles the FaultRecord event.
 * Records a fault for a specific data set.
 */
export function handleFaultRecord(event: FaultRecordEvent): void {
  const setId = event.params.dataSetId;
  const periodsFaultedParam = event.params.periodsFaulted;
  const dataSetEntityId = getDataSetEntityId(setId);
  const entityId = getEventLogEntityId(event.transaction.hash, event.logIndex);

  const dataSet = DataSet.load(dataSetEntityId);
  if (!dataSet) return; // dataSet doesn't belong to Warm Storage Service

  const challengeEpoch = dataSet.nextChallengeEpoch;
  const challengeRange = dataSet.challengeRange;
  const serviceProvider = dataSet.serviceProvider;
  const nextPieceId = dataSet.totalPieces;

  let nextChallengeEpoch = BIGINT_ZERO;
  const inputData = event.transaction.input;
  if (inputData.length >= 4 + 32) {
    const potentialNextEpochBytes = inputData.slice(4 + 32, 4 + 32 + 32);
    if (potentialNextEpochBytes.length == 32) {
      // Convert reversed Uint8Array to Bytes before converting to BigInt
      nextChallengeEpoch = BigInt.fromUnsignedBytes(Bytes.fromUint8Array(potentialNextEpochBytes.reverse()));
    }
  } else {
    log.warning("handleFaultRecord: Transaction input data too short to parse potential nextChallengeEpoch.", []);
  }

  const pieceIds = findChallengedPieces(setId, nextPieceId, challengeEpoch, challengeRange, event.block.number);

  if (pieceIds.length === 0) {
    log.info("handleFaultRecord: No pieces found for challenge epoch {} in DataSet {}", [
      challengeEpoch.toString(),
      setId.toString(),
    ]);
  }

  let uniquePieceIds: BigInt[] = [];
  let pieceIdMap = new Map<string, boolean>();
  for (let i = 0; i < pieceIds.length; i++) {
    const pieceIdStr = pieceIds[i].toString();
    if (!pieceIdMap.has(pieceIdStr)) {
      uniquePieceIds.push(pieceIds[i]);
      pieceIdMap.set(pieceIdStr, true);
    }
  }

  let pieceEntityIds: Bytes[] = [];
  for (let i = 0; i < uniquePieceIds.length; i++) {
    const pieceId = uniquePieceIds[i];
    const pieceEntityId = getPieceEntityId(setId, pieceId);

    const piece = Piece.load(pieceEntityId);
    if (piece) {
      if (!piece.lastFaultedEpoch.equals(challengeEpoch)) {
        piece.totalPeriodsFaulted = piece.totalPeriodsFaulted.plus(periodsFaultedParam);
      } else {
        log.info("handleFaultRecord: Piece {} in Set {} already marked faulted for epoch {}", [
          pieceId.toString(),
          setId.toString(),
          challengeEpoch.toString(),
        ]);
      }
      piece.lastFaultedEpoch = challengeEpoch;
      piece.lastFaultedAt = event.block.timestamp;
      piece.updatedAt = event.block.timestamp;
      piece.blockNumber = event.block.number;
      piece.save();
    } else {
      log.warning("handleFaultRecord: Piece {} for Set {} not found while recording fault", [
        pieceId.toString(),
        setId.toString(),
      ]);
    }
    pieceEntityIds.push(pieceEntityId);
  }

  const faultRecord = new FaultRecord(entityId);
  faultRecord.dataSetId = setId;
  faultRecord.pieceIds = uniquePieceIds;
  faultRecord.currentChallengeEpoch = challengeEpoch;
  faultRecord.nextChallengeEpoch = nextChallengeEpoch;
  faultRecord.periodsFaulted = periodsFaultedParam;
  faultRecord.deadline = event.params.deadline;
  faultRecord.createdAt = event.block.timestamp;
  faultRecord.blockNumber = event.block.number;

  faultRecord.dataSet = dataSetEntityId;
  faultRecord.pieces = pieceEntityIds;

  faultRecord.save();

  dataSet.totalFaultedPeriods = dataSet.totalFaultedPeriods.plus(periodsFaultedParam);
  dataSet.totalFaultedPieces = dataSet.totalFaultedPieces.plus(BigInt.fromI32(uniquePieceIds.length));
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  const provider = Provider.load(serviceProvider);
  if (provider) {
    provider.totalFaultedPeriods = provider.totalFaultedPeriods.plus(periodsFaultedParam);
    provider.totalFaultedPieces = provider.totalFaultedPieces.plus(BigInt.fromI32(uniquePieceIds.length));
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("handleFaultRecord: Provider {} not found for DataSet {}", [serviceProvider.toHex(), setId.toString()]);
  }
}

/**
 * Handles the DataSetCreated event.
 * Creates a new data set.
 */
export function handleDataSetCreated(event: DataSetCreatedEvent): void {
  const listenerAddr = event.address;
  const providerId = event.params.providerId;
  const setId = event.params.dataSetId;
  const pdpRailId = event.params.pdpRailId;
  const cacheMissRailId = event.params.cacheMissRailId;
  const cdnRailId = event.params.cdnRailId;
  const payer = event.params.payer;
  const serviceProvider = event.params.serviceProvider;
  const payee = event.params.payee;
  const metadataKeys = event.params.metadataKeys;
  const metadataValues = event.params.metadataValues;
  const dataSetEntityId = getDataSetEntityId(setId);
  const withCDN = !!metadataKeys.includes(METADATA_KEY_WITH_CDN);

  let dataSet = new DataSet(dataSetEntityId);

  // Create DataSet
  dataSet.setId = setId;
  dataSet.providerId = providerId;
  dataSet.metadataKeys = metadataKeys;
  dataSet.metadataValues = metadataValues;
  dataSet.listener = listenerAddr;
  dataSet.payer = payer;
  dataSet.payee = payee;
  dataSet.serviceProvider = serviceProvider;
  dataSet.withCDN = withCDN;
  dataSet.isActive = true;
  dataSet.pdpEndEpoch = BIGINT_ZERO;
  dataSet.leafCount = BIGINT_ZERO;
  dataSet.challengeRange = BIGINT_ZERO;
  dataSet.lastProvenEpoch = BIGINT_ZERO;
  dataSet.nextChallengeEpoch = BIGINT_ZERO;
  dataSet.totalPieces = BIGINT_ZERO;
  dataSet.nextPieceId = BIGINT_ZERO;
  dataSet.totalDataSize = BIGINT_ZERO;
  dataSet.totalFaultedPeriods = BIGINT_ZERO;
  dataSet.totalFaultedPieces = BIGINT_ZERO;
  dataSet.totalProofs = BIGINT_ZERO;
  dataSet.totalProvedPieces = BIGINT_ZERO;
  dataSet.createdAt = event.block.timestamp;
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Create Rails
  createRails(
    [pdpRailId, cacheMissRailId, cdnRailId],
    [RailType.PDP, RailType.CACHE_MISS, RailType.CDN],
    payer,
    serviceProvider,
    listenerAddr,
    dataSetEntityId,
  );

  // Update Provider
  let provider = Provider.load(serviceProvider);
  if (provider == null) {
    log.warning("DataSetCreated: existing provider not found for address: {}", [serviceProvider.toHexString()]);
    return;
  }

  provider.totalDataSets = provider.totalDataSets.plus(BIGINT_ONE);
  provider.blockNumber = event.block.number;
  provider.updatedAt = event.block.timestamp;
  provider.save();
}

/**
 * Handles the RailRateUpdated event.
 * Updates the payment rate for a specific rail.
 */
export function handleRailRateUpdated(event: RailRateUpdatedEvent): void {
  const railId = event.params.railId;
  const newRate = event.params.newRate;

  const railEntityId = getRailEntityId(railId);

  const rail = Rail.load(railEntityId);

  if (!rail) return;

  // if initial paymentRate is 0 -> don't enqueue rate changes
  if (rail.paymentRate.equals(BIGINT_ZERO)) {
    rail.paymentRate = newRate;
  } else {
    const rateChangeQueue = new RateChangeQueue(getRateChangeQueueEntityId(railId, rail.queueLength));
    rateChangeQueue.untilEpoch = event.block.number;
    rateChangeQueue.rate = newRate;
    rateChangeQueue.rail = railEntityId;
    rateChangeQueue.save();
    rail.queueLength = rail.queueLength.plus(BIGINT_ONE);
  }
  rail.save();
}

/**
 * Common logic for handling PieceAdded events.
 * Creates a new piece and updates related entities.
 */
function handlePieceAddedCommon(
  setId: BigInt,
  pieceId: BigInt,
  metadataKeys: string[],
  metadataValues: string[],
  pieceBytes: Bytes,
  blockTimestamp: BigInt,
  blockNumber: BigInt,
): void {
  const commPData = validateCommPv2(pieceBytes);
  const rawSize = commPData.isValid ? unpaddedSize(commPData.padding, commPData.height) : BigInt.zero();

  const pieceEntityId = getPieceEntityId(setId, pieceId);
  const piece = new Piece(pieceEntityId);
  piece.pieceId = pieceId;
  piece.setId = setId;
  piece.rawSize = rawSize;
  piece.leafCount = rawSize.div(BigInt.fromI32(LeafSize));
  piece.cid = pieceBytes.length > 0 ? pieceBytes : Bytes.empty();
  piece.metadataKeys = metadataKeys;
  piece.metadataValues = metadataValues;
  piece.removed = false;
  piece.lastProvenEpoch = BIGINT_ZERO;
  piece.lastProvenAt = BIGINT_ZERO;
  piece.lastFaultedEpoch = BIGINT_ZERO;
  piece.lastFaultedAt = BIGINT_ZERO;
  piece.totalProofsSubmitted = BIGINT_ZERO;
  piece.totalPeriodsFaulted = BIGINT_ZERO;
  piece.createdAt = blockTimestamp;
  piece.updatedAt = blockTimestamp;
  piece.blockNumber = blockNumber;
  piece.dataSet = getDataSetEntityId(setId);

  piece.save();

  const dataSet = DataSet.load(getDataSetEntityId(setId));
  if (!dataSet) {
    log.warning("handlePieceAdded: DataSet not found for setId: {}", [setId.toString()]);
    return;
  }

  dataSet.totalPieces = dataSet.totalPieces.plus(BIGINT_ONE);
  dataSet.nextPieceId = dataSet.nextPieceId.plus(BIGINT_ONE);
  dataSet.totalDataSize = dataSet.totalDataSize.plus(piece.rawSize);
  dataSet.leafCount = dataSet.leafCount.plus(piece.rawSize.div(BigInt.fromI32(LeafSize)));
  dataSet.updatedAt = blockTimestamp;
  dataSet.blockNumber = blockNumber;
  dataSet.save();

  const provider = Provider.load(dataSet.serviceProvider);
  if (!provider) {
    log.warning("handlePieceAdded: Provider not found for DataSet: {}", [dataSet.id.toString()]);
    return;
  }

  provider.totalDataSize = provider.totalDataSize.plus(piece.rawSize);
  provider.totalPieces = provider.totalPieces.plus(BIGINT_ONE);
  provider.updatedAt = blockTimestamp;
  provider.blockNumber = blockNumber;
  provider.save();
}

/**
 * Handles the PieceAdded event with definition- PieceAdded(indexed uint256,indexed uint256,string[],string[])
 * Parses the pieceCid from the contract and creates a new piece.
 */
export function handlePieceAddedV1(event: PieceAddedEventV1): void {
  const setId = event.params.dataSetId;
  const pieceId = event.params.pieceId;
  const metadataKeys = event.params.keys;
  const metadataValues = event.params.values;

  const pieceBytes = getPieceCidData(ContractAddresses.PDPVerifier, setId, pieceId);

  handlePieceAddedCommon(
    setId,
    pieceId,
    metadataKeys,
    metadataValues,
    pieceBytes,
    event.block.timestamp,
    event.block.number,
  );
}

/**
 * Handles the PieceAdded event with definition- PieceAdded(indexed uint256,indexed uint256,(bytes),string[],string[])
 * Parses the pieceCid from the event and creates a new piece.
 */
export function handlePieceAddedV2(event: PieceAddedEventV2): void {
  const setId = event.params.dataSetId;
  const pieceId = event.params.pieceId;
  const metadataKeys = event.params.keys;
  const metadataValues = event.params.values;
  const pieceBytes = event.params.pieceCid.data;

  handlePieceAddedCommon(
    setId,
    pieceId,
    metadataKeys,
    metadataValues,
    pieceBytes,
    event.block.timestamp,
    event.block.number,
  );
}

/**
 * Handles the DataSetServiceProviderChanged event.
 * Updates the storage provider for a data set.
 */
export function handleDataSetServiceProviderChanged(event: DataSetServiceProviderChangedEvent): void {
  const setId = event.params.dataSetId;
  const oldServiceProvider = event.params.oldServiceProvider;
  const newServiceProvider = event.params.newServiceProvider;

  const dataSetEntityId = getDataSetEntityId(setId);

  // Load DataSet
  const dataSet = DataSet.load(dataSetEntityId);
  if (!dataSet) {
    log.warning("DataSetServiceProviderChanged: DataSet {} not found", [setId.toString()]);
    return;
  }

  // Update DataSet storageProvider (this updates the derived relationship on both old and new Provider)
  dataSet.serviceProvider = newServiceProvider; // Set storageProvider to the new provider's ID
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Load Old Provider (if exists) - Just update timestamp, derived field handles removal
  const oldProvider = Provider.load(oldServiceProvider);
  if (oldProvider) {
    oldProvider.totalDataSets = oldProvider.totalDataSets.minus(BIGINT_ONE);
    oldProvider.updatedAt = event.block.timestamp;
    oldProvider.blockNumber = event.block.number;
    oldProvider.save();
  } else {
    log.warning("DataSetServiceProviderChanged: Old Provider {} not found", [oldServiceProvider.toHexString()]);
  }

  // Load or Create New Provider - Just update timestamp/create, derived field handles addition
  let newProvider = Provider.load(newServiceProvider);
  if (!newProvider) {
    log.warning("DataSetServiceProviderChanged: New Provider {} not found", [newServiceProvider.toHexString()]);
    return;
  }
  newProvider.totalDataSets = newProvider.totalDataSets.plus(BIGINT_ONE);
  newProvider.blockNumber = event.block.number;
  newProvider.updatedAt = event.block.timestamp;
  newProvider.save();
}

/**
 * Handles the ProviderApproved event.
 * Approves a new storage provider.
 */
export function handleProviderApproved(event: ProviderApprovedEvent): void {
  const providerId = event.params.providerId;

  const providerInfo = getServiceProviderInfo(ContractAddresses.ServiceProviderRegistry, providerId);

  const provider = Provider.load(providerInfo.serviceProvider);

  if (provider === null) {
    log.warning("ProviderApproved: existing provider not found for address: {}", [
      providerInfo.serviceProvider.toHexString(),
    ]);
    return;
  }

  provider.approvedAt = event.block.number;
  provider.status = ProviderStatus.APPROVED;
  provider.updatedAt = event.block.timestamp;
  provider.blockNumber = event.block.number;

  provider.save();
}

/**
 * Handles the ProviderUnapproved event.
 * Unapproves a storage provider.
 */
export function handleProviderUnapproved(event: ProviderUnapprovedEvent): void {
  const providerId = event.params.providerId;

  const providerInfo = getServiceProviderInfo(ContractAddresses.ServiceProviderRegistry, providerId);

  const provider = Provider.load(providerInfo.serviceProvider);

  if (provider === null) {
    log.warning("ProviderUnapproved: existing provider not found for address: {}", [
      providerInfo.serviceProvider.toHexString(),
    ]);
    return;
  }

  provider.status = ProviderStatus.UNAPPROVED;
  provider.approvedAt = null;
  provider.updatedAt = event.block.timestamp;
  provider.blockNumber = event.block.number;

  provider.save();
}

/**
 * Handles the PDPPaymentTerminated event.
 * Terminates pdp rail.
 */
export function handlePDPPaymentTerminated(event: PDPPaymentTerminatedEvent): void {
  const dataSetId = event.params.dataSetId;
  const endEpoch = event.params.endEpoch;
  const pdpRailId = event.params.pdpRailId;

  const pdpRailEntityId = getRailEntityId(pdpRailId);
  const dataSetEntityId = getDataSetEntityId(dataSetId);

  const pdpRail = Rail.load(pdpRailEntityId);
  const dataSet = DataSet.load(dataSetEntityId);

  if (pdpRail) {
    pdpRail.isActive = false;
    pdpRail.endEpoch = endEpoch;
    pdpRail.save();
  }
  if (dataSet) {
    dataSet.isActive = false;
    dataSet.pdpEndEpoch = endEpoch;
    dataSet.save();
  }
}

/**
 * Handles the CDNPaymentTerminated event.
 * Terminates cdn rails.
 */
export function handleCDNPaymentTerminated(event: CDNPaymentTerminatedEvent): void {
  const dataSetId = event.params.dataSetId;
  const endEpoch = event.params.endEpoch;
  const cacheMissRailId = event.params.cacheMissRailId;
  const cdnRailId = event.params.cdnRailId;

  const dataSetEntityId = getDataSetEntityId(dataSetId);
  const cdnRailEntityId = getRailEntityId(cdnRailId);
  const cacheMissRailEntityId = getRailEntityId(cacheMissRailId);

  const cdnRail = Rail.load(cdnRailEntityId);
  const cacheMissRail = Rail.load(cacheMissRailEntityId);
  const dataSet = DataSet.load(dataSetEntityId);

  if (cdnRail) {
    cdnRail.isActive = false;
    cdnRail.endEpoch = endEpoch;
    cdnRail.save();
  }
  if (cacheMissRail) {
    cacheMissRail.isActive = false;
    cacheMissRail.endEpoch = endEpoch;
    cacheMissRail.save();
  }
  if (dataSet) {
    dataSet.isActive = false;
    dataSet.save();
  }
}

/**
 * Handles the PaymentArbitrated event.
 * Arbitrates a storage payment.
 */
export function handlePaymentArbitrated(event: PaymentArbitratedEvent): void {
  const railId = event.params.railId;
  const dataSetId = event.params.dataSetId;
  const arbitratedAmount = event.params.modifiedAmount;
  const faultedEpochs = event.params.faultedEpochs;

  const rail = Rail.load(getRailEntityId(railId));
  if (!rail) {
    log.warning("PaymentArbitrated: Rail {} not found", [railId.toString()]);
    return;
  }

  const dataSet = DataSet.load(getDataSetEntityId(dataSetId));

  rail.settledAmount = rail.settledAmount.plus(arbitratedAmount);
  rail.totalFaultedEpochs = rail.totalFaultedEpochs.plus(faultedEpochs);
  rail.settledUpto = dataSet ? dataSet.lastProvenEpoch : rail.settledUpto;

  rail.save();
}
