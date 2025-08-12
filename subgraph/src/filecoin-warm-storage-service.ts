import { Address, BigInt, Bytes, crypto, log } from "@graphprotocol/graph-ts";
import {
  DataSetRailCreated as DataSetRailCreatedEvent,
  FaultRecord as FaultRecordEvent,
  ProviderApproved as ProviderApprovedEvent,
  ProviderRegistered as ProviderRegisteredEvent,
  ProviderRejected as ProviderRejectedEvent,
  ProviderRemoved as ProviderRemovedEvent,
  RailRateUpdated as RailRateUpdatedEvent,
} from "../generated/FilecoinWarmStorageService/FilecoinWarmStorageService";
import { PDPVerifier } from "../generated/PDPVerifier/PDPVerifier";
import {
  DataSet,
  FaultRecord,
  Piece,
  Provider,
  Rail,
  RateChangeQueue,
} from "../generated/schema";
import {
  DefaultLockupPeriod,
  NumChallenges,
  PDPVerifierAddress,
  USDFCTokenAddress,
} from "../utils";
import { decodeStringAddressBoolBytes } from "./decode";
import { SumTree } from "./sumTree";

// --- Helper Functions
function getDataSetEntityId(setId: BigInt): Bytes {
  return Bytes.fromByteArray(Bytes.fromBigInt(setId));
}

function getPieceEntityId(setId: BigInt, pieceId: BigInt): Bytes {
  return Bytes.fromUTF8(setId.toString() + "-" + pieceId.toString());
}

function getRailEntityId(railId: BigInt): Bytes {
  return Bytes.fromByteArray(Bytes.fromBigInt(railId));
}

function getEventLogEntityId(txHash: Bytes, logIndex: BigInt): Bytes {
  return txHash.concatI32(logIndex.toI32());
}

function getRateChangeQueueEntityId(
  railId: BigInt,
  queueLength: BigInt
): Bytes {
  return Bytes.fromUTF8(railId.toString() + "-" + queueLength.toString());
}
// --- End Helper Functions

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
  totalLeaves: BigInt
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
    Bytes.fromUint8Array(Bytes.fromHexString(hashBytes.toHexString()).reverse())
  );

  if (totalLeaves.isZero()) {
    log.error(
      "generateChallengeIndex: totalLeaves is zero, cannot calculate modulus. DataSetID: {}. Seed: {}",
      [dataSetID.toString(), Bytes.fromUint8Array(seed).toHex()]
    );
    return BigInt.fromI32(0);
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
  blockNumber: BigInt
): BigInt[] {
  const instance = PDPVerifier.bind(
    Address.fromBytes(Bytes.fromHexString(PDPVerifierAddress))
  );

  const seedIntResult = instance.try_getRandomness(challengeEpoch);
  if (seedIntResult.reverted) {
    log.warning("findChallengedPieces: Failed to get randomness for epoch {}", [
      challengeEpoch.toString(),
    ]);
    return [];
  }

  const seedInt = seedIntResult.value;
  const seedHex = ensureEvenHex(seedInt);

  const challenges: BigInt[] = [];
  if (totalLeaves.isZero()) {
    log.warning(
      "findChallengedPieces: totalLeaves is zero for DataSet {}. Cannot generate challenges.",
      [dataSetId.toString()]
    );
    return [];
  }
  for (let i = 0; i < NumChallenges; i++) {
    const leafIdx = generateChallengeIndex(
      Bytes.fromHexString(seedHex),
      dataSetId,
      i32(i),
      totalLeaves
    );
    challenges.push(leafIdx);
  }

  const sumTreeInstance = new SumTree();
  const pieceIds = sumTreeInstance.findPieceIds(
    dataSetId.toI32(),
    nextPieceId.toI32(),
    challenges,
    blockNumber
  );
  if (!pieceIds) {
    log.warning(
      "findChallengedPieces: findPieceIds reverted for dataSetId {}",
      [dataSetId.toString()]
    );
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
  const serviceProvider = dataSet.storageProvider;
  const nextPieceId = dataSet.totalPieces;

  let nextChallengeEpoch = BigInt.fromI32(0);
  const inputData = event.transaction.input;
  if (inputData.length >= 4 + 32) {
    const potentialNextEpochBytes = inputData.slice(4 + 32, 4 + 32 + 32);
    if (potentialNextEpochBytes.length == 32) {
      // Convert reversed Uint8Array to Bytes before converting to BigInt
      nextChallengeEpoch = BigInt.fromUnsignedBytes(
        Bytes.fromUint8Array(potentialNextEpochBytes.reverse())
      );
    }
  } else {
    log.warning(
      "handleFaultRecord: Transaction input data too short to parse potential nextChallengeEpoch.",
      []
    );
  }

  const pieceIds = findChallengedPieces(
    setId,
    nextPieceId,
    challengeEpoch,
    challengeRange,
    event.block.number
  );

  if (pieceIds.length === 0) {
    log.info(
      "handleFaultRecord: No pieces found for challenge epoch {} in DataSet {}",
      [challengeEpoch.toString(), setId.toString()]
    );
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
        piece.totalPeriodsFaulted =
          piece.totalPeriodsFaulted.plus(periodsFaultedParam);
      } else {
        log.info(
          "handleFaultRecord: Piece {} in Set {} already marked faulted for epoch {}",
          [pieceId.toString(), setId.toString(), challengeEpoch.toString()]
        );
      }
      piece.lastFaultedEpoch = challengeEpoch;
      piece.lastFaultedAt = event.block.timestamp;
      piece.updatedAt = event.block.timestamp;
      piece.blockNumber = event.block.number;
      piece.save();
    } else {
      log.warning(
        "handleFaultRecord: Piece {} for Set {} not found while recording fault",
        [pieceId.toString(), setId.toString()]
      );
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

  dataSet.totalFaultedPeriods =
    dataSet.totalFaultedPeriods.plus(periodsFaultedParam);
  dataSet.totalFaultedPieces = dataSet.totalFaultedPieces.plus(
    BigInt.fromI32(uniquePieceIds.length)
  );
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  const provider = Provider.load(serviceProvider);
  if (provider) {
    provider.totalFaultedPeriods =
      provider.totalFaultedPeriods.plus(periodsFaultedParam);
    provider.totalFaultedPieces = provider.totalFaultedPieces.plus(
      BigInt.fromI32(uniquePieceIds.length)
    );
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("handleFaultRecord: Provider {} not found for DataSet {}", [
      serviceProvider.toHex(),
      setId.toString(),
    ]);
  }
}

/**
 * Handles the DataSetRailCreated event.
 * Creates a new rail for a data set.
 */
export function handleDataSetRailCreated(event: DataSetRailCreatedEvent): void {
  const listenerAddr = event.address;
  const setId = event.params.dataSetId;
  const railId = event.params.railId;
  const clientAddr = event.params.payer;
  const serviceProvider = event.params.payee;
  const withCDN = event.params.withCDN;
  const dataSetEntityId = getDataSetEntityId(setId);
  const railEntityId = getRailEntityId(railId);
  const providerEntityId = serviceProvider; // Provider ID is the serviceProvider address

  let dataSet = new DataSet(dataSetEntityId);

  const inputData = event.transaction.input;
  const extraDataStart = 4 + 32 + 32 + 32;
  const extraDataBytes = inputData.subarray(extraDataStart);

  // extraData -> (metadata,payer,withCDN,signature)
  const decodedData = decodeStringAddressBoolBytes(
    Bytes.fromUint8Array(extraDataBytes)
  );

  let metadata: string = decodedData.stringValue;

  // Create DataSet
  dataSet.setId = setId;
  dataSet.metadata = metadata;
  dataSet.clientAddr = clientAddr;
  dataSet.withCDN = withCDN;
  dataSet.serviceProvider = providerEntityId; // Link to Provider via serviceProvider address (which is Provider's ID)
  dataSet.listener = listenerAddr;
  dataSet.isActive = true;
  dataSet.leafCount = BigInt.fromI32(0);
  dataSet.challengeRange = BigInt.fromI32(0);
  dataSet.lastProvenEpoch = BigInt.fromI32(0);
  dataSet.nextChallengeEpoch = BigInt.fromI32(0);
  dataSet.totalPieces = BigInt.fromI32(0);
  dataSet.nextPieceId = BigInt.fromI32(0);
  dataSet.totalDataSize = BigInt.fromI32(0);
  dataSet.totalFaultedPeriods = BigInt.fromI32(0);
  dataSet.totalFaultedPieces = BigInt.fromI32(0);
  dataSet.totalProofs = BigInt.fromI32(0);
  dataSet.totalProvedPieces = BigInt.fromI32(0);
  dataSet.createdAt = event.block.timestamp;
  dataSet.updatedAt = event.block.timestamp;
  dataSet.blockNumber = event.block.number;
  dataSet.save();

  // Create Rail
  let rail = new Rail(railEntityId);
  rail.railId = railId;
  rail.token = Address.fromHexString(USDFCTokenAddress);
  rail.from = clientAddr;
  rail.to = serviceProvider;
  rail.operator = listenerAddr;
  rail.arbiter = listenerAddr;
  rail.paymentRate = BigInt.fromI32(0);
  rail.lockupPeriod = BigInt.fromI32(DefaultLockupPeriod);
  rail.lockupFixed = BigInt.fromI32(0); // lockupFixed - oneTimePayment
  rail.settledUpto = BigInt.fromI32(0);
  rail.endEpoch = BigInt.fromI32(0);
  rail.queueLength = BigInt.fromI32(0);
  rail.dataSet = dataSetEntityId;
  rail.save();

  // Create or Update Provider
  let provider = Provider.load(providerEntityId);
  if (provider == null) {
    provider = new Provider(providerEntityId);
    provider.address = serviceProvider;
    provider.status = "Created";
    provider.totalPieces = BigInt.fromI32(0);
    provider.totalDataSets = BigInt.fromI32(1);
    provider.totalFaultedPeriods = BigInt.fromI32(0);
    provider.totalFaultedPieces = BigInt.fromI32(0);
    provider.totalDataSize = BigInt.fromI32(0);
    provider.createdAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
  } else {
    // Update timestamp/block even if exists
    provider.totalDataSets = provider.totalDataSets.plus(BigInt.fromI32(1));
    provider.blockNumber = event.block.number;
  }
  // provider.dataSetIds = provider.dataSetIds.concat([event.params.setId]); // REMOVED - Handled by @derivedFrom
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
  if (rail.paymentRate.equals(BigInt.fromI32(0))) {
    rail.paymentRate = newRate;
  } else {
    const rateChangeQueue = new RateChangeQueue(
      getRateChangeQueueEntityId(railId, rail.queueLength)
    );
    rateChangeQueue.untilEpoch = event.block.number;
    rateChangeQueue.rate = newRate;
    rateChangeQueue.rail = railEntityId;
    rateChangeQueue.save();
    rail.queueLength = rail.queueLength.plus(BigInt.fromI32(1));
  }
  rail.save();
}

/**
 * Handler for ProviderRegistered event
 * Adds serviceUrl and peerId and updates registeredAt to block number with status update to "Registered"
 */
export function handleProviderRegistered(event: ProviderRegisteredEvent): void {
  const providerAddress = event.params.provider;
  const serviceUrl = event.params.serviceURL;
  const peerId = event.params.peerId;

  let provider = Provider.load(providerAddress);
  if (!provider) {
    provider = new Provider(providerAddress);
    provider.address = providerAddress;
    provider.totalFaultedPeriods = BigInt.fromI32(0);
    provider.totalFaultedPieces = BigInt.fromI32(0);
    provider.totalDataSets = BigInt.fromI32(0);
    provider.totalPieces = BigInt.fromI32(0);
    provider.totalDataSize = BigInt.fromI32(0);
    provider.createdAt = event.block.timestamp;
  }

  provider.serviceUrl = serviceUrl;
  provider.peerId = peerId;
  provider.registeredAt = event.block.number;
  provider.status = "Registered";
  provider.updatedAt = event.block.timestamp;
  provider.blockNumber = event.block.number;

  provider.save();
}

/**
 * Handler for ProviderApproved event
 * Follows the intended flow:
 * 1. Check if event is emitted in addServiceProvider function
 * 2. If yes, extract all addServiceProvider calldatas and find matching provider
 * 3. If no match found in calldatas, log warning
 * 4. If not addServiceProvider function, find existing provider and update status
 * 5. If no existing provider found, log warning
 */
export function handleProviderApproved(event: ProviderApprovedEvent): void {
  const providerAddress = event.params.provider;
  const providerId = event.params.providerId;

  const provider = Provider.load(providerAddress);

  if (provider === null) {
    log.warning(
      "ProviderApproved: existing provider not found for address: {}",
      [providerAddress.toHexString()]
    );
    return;
  }

  provider.providerId = providerId;
  provider.approvedAt = event.block.number;
  provider.status = "Approved";
  provider.updatedAt = event.block.timestamp;
  provider.blockNumber = event.block.number;

  provider.save();
}

/**
 * Handler for ProviderRejected event
 * Updates status to "Rejected"
 */
export function handleProviderRejected(event: ProviderRejectedEvent): void {
  const providerAddress = event.params.provider;

  let provider = Provider.load(providerAddress);
  if (!provider) return;

  provider.status = "Rejected";
  provider.updatedAt = event.block.timestamp;
  provider.blockNumber = event.block.number;

  provider.save();
}

/**
 * Handler for ProviderRemoved event
 * Sets status to "Removed"
 */
export function handleProviderRemoved(event: ProviderRemovedEvent): void {
  const providerAddress = event.params.provider;

  let provider = Provider.load(providerAddress);
  if (!provider) return;

  provider.status = "Removed";
  provider.updatedAt = event.block.timestamp;
  provider.blockNumber = event.block.number;

  provider.save();
}
