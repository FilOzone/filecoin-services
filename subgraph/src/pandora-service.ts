import {
  BigInt,
  Bytes,
  crypto,
  Address,
  log,
  ethereum,
} from "@graphprotocol/graph-ts";
import {
  FaultRecord as FaultRecordEvent,
  ProofSetRailCreated as ProofSetRailCreatedEvent,
  RailRateUpdated as RailRateUpdatedEvent,
  ProviderRegistered as ProviderRegisteredEvent,
  ProviderApproved as ProviderApprovedEvent,
  ProviderRemoved as ProviderRemovedEvent,
  ProviderRejected as ProviderRejectedEvent,
} from "../generated/PandoraService/PandoraService";
import { PDPVerifier } from "../generated/PDPVerifier/PDPVerifier";
import {
  PDPVerifierAddress,
  NumChallenges,
  USDFCTokenAddress,
  DefaultLockupPeriod,
} from "../utils";
import {
  ProofSet,
  Provider,
  FaultRecord,
  Root,
  Rail,
  RateChangeQueue,
} from "../generated/schema";
import { SumTree } from "./sumTree";
import { decodeStringAddressBoolBytes } from "./decode";

// --- Helper Functions
function getProofSetEntityId(setId: BigInt): Bytes {
  return Bytes.fromByteArray(Bytes.fromBigInt(setId));
}

function getRootEntityId(setId: BigInt, rootId: BigInt): Bytes {
  return Bytes.fromUTF8(setId.toString() + "-" + rootId.toString());
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
 * Generates a deterministic challenge index using seed, proofSetID, proofIndex, and totalLeaves.
 * Mirrors the logic from Go's generateChallengeIndex.
 */
export function generateChallengeIndex(
  seed: Uint8Array,
  proofSetID: BigInt,
  proofIndex: i32,
  totalLeaves: BigInt
): BigInt {
  const data = new Uint8Array(32 + 32 + 8);

  const paddedSeed = padTo32Bytes(seed);
  data.set(paddedSeed, 0);

  // Convert proofSetID to Bytes and pad to 32 bytes (Big-Endian padding implied by padTo32Bytes)
  const psIDBytes = Bytes.fromBigInt(proofSetID);
  const psIDPadded = padTo32Bytes(psIDBytes);
  data.set(psIDPadded, 32); // Write 32 bytes at offset 32

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
      "generateChallengeIndex: totalLeaves is zero, cannot calculate modulus. ProofSetID: {}. Seed: {}",
      [proofSetID.toString(), Bytes.fromUint8Array(seed).toHex()]
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

export function findChallengedRoots(
  proofSetId: BigInt,
  nextRootId: BigInt,
  challengeEpoch: BigInt,
  totalLeaves: BigInt,
  blockNumber: BigInt
): BigInt[] {
  const instance = PDPVerifier.bind(
    Address.fromBytes(Bytes.fromHexString(PDPVerifierAddress))
  );

  const seedIntResult = instance.try_getRandomness(challengeEpoch);
  if (seedIntResult.reverted) {
    log.warning("findChallengedRoots: Failed to get randomness for epoch {}", [
      challengeEpoch.toString(),
    ]);
    return [];
  }

  const seedInt = seedIntResult.value;
  const seedHex = ensureEvenHex(seedInt);

  const challenges: BigInt[] = [];
  if (totalLeaves.isZero()) {
    log.warning(
      "findChallengedRoots: totalLeaves is zero for ProofSet {}. Cannot generate challenges.",
      [proofSetId.toString()]
    );
    return [];
  }
  for (let i = 0; i < NumChallenges; i++) {
    const leafIdx = generateChallengeIndex(
      Bytes.fromHexString(seedHex),
      proofSetId,
      i32(i),
      totalLeaves
    );
    challenges.push(leafIdx);
  }

  const sumTreeInstance = new SumTree();
  const rootIds = sumTreeInstance.findRootIds(
    proofSetId.toI32(),
    nextRootId.toI32(),
    challenges,
    blockNumber
  );
  if (!rootIds) {
    log.warning("findChallengedRoots: findRootIds reverted for proofSetId {}", [
      proofSetId.toString(),
    ]);
    return [];
  }

  const rootIdsArray: BigInt[] = [];
  for (let i = 0; i < rootIds.length; i++) {
    rootIdsArray.push(rootIds[i].rootId);
  }
  return rootIdsArray;
}

/**
 * Handles the FaultRecord event.
 * Records a fault for a specific proof set.
 */
export function handleFaultRecord(event: FaultRecordEvent): void {
  const setId = event.params.proofSetId;
  const periodsFaultedParam = event.params.periodsFaulted;
  const proofSetEntityId = getProofSetEntityId(setId);
  const entityId = getEventLogEntityId(event.transaction.hash, event.logIndex);

  const proofSet = ProofSet.load(proofSetEntityId);
  if (!proofSet) return; // proofSet doesn't belong to Pandora Service

  const challengeEpoch = proofSet.nextChallengeEpoch;
  const challengeRange = proofSet.challengeRange;
  const proofSetOwner = proofSet.owner;
  const nextRootId = proofSet.totalRoots;

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

  const rootIds = findChallengedRoots(
    setId,
    nextRootId,
    challengeEpoch,
    challengeRange,
    event.block.number
  );

  if (rootIds.length === 0) {
    log.info(
      "handleFaultRecord: No roots found for challenge epoch {} in ProofSet {}",
      [challengeEpoch.toString(), setId.toString()]
    );
  }

  let uniqueRootIds: BigInt[] = [];
  let rootIdMap = new Map<string, boolean>();
  for (let i = 0; i < rootIds.length; i++) {
    const rootIdStr = rootIds[i].toString();
    if (!rootIdMap.has(rootIdStr)) {
      uniqueRootIds.push(rootIds[i]);
      rootIdMap.set(rootIdStr, true);
    }
  }

  let rootEntityIds: Bytes[] = [];
  for (let i = 0; i < uniqueRootIds.length; i++) {
    const rootId = uniqueRootIds[i];
    const rootEntityId = getRootEntityId(setId, rootId);

    const root = Root.load(rootEntityId);
    if (root) {
      if (!root.lastFaultedEpoch.equals(challengeEpoch)) {
        root.totalPeriodsFaulted =
          root.totalPeriodsFaulted.plus(periodsFaultedParam);
      } else {
        log.info(
          "handleFaultRecord: Root {} in Set {} already marked faulted for epoch {}",
          [rootId.toString(), setId.toString(), challengeEpoch.toString()]
        );
      }
      root.lastFaultedEpoch = challengeEpoch;
      root.lastFaultedAt = event.block.timestamp;
      root.updatedAt = event.block.timestamp;
      root.blockNumber = event.block.number;
      root.save();
    } else {
      log.warning(
        "handleFaultRecord: Root {} for Set {} not found while recording fault",
        [rootId.toString(), setId.toString()]
      );
    }
    rootEntityIds.push(rootEntityId);
  }

  const faultRecord = new FaultRecord(entityId);
  faultRecord.proofSetId = setId;
  faultRecord.rootIds = uniqueRootIds;
  faultRecord.currentChallengeEpoch = challengeEpoch;
  faultRecord.nextChallengeEpoch = nextChallengeEpoch;
  faultRecord.periodsFaulted = periodsFaultedParam;
  faultRecord.deadline = event.params.deadline;
  faultRecord.createdAt = event.block.timestamp;
  faultRecord.blockNumber = event.block.number;

  faultRecord.proofSet = proofSetEntityId;
  faultRecord.roots = rootEntityIds;

  faultRecord.save();

  proofSet.totalFaultedPeriods =
    proofSet.totalFaultedPeriods.plus(periodsFaultedParam);
  proofSet.totalFaultedRoots = proofSet.totalFaultedRoots.plus(
    BigInt.fromI32(uniqueRootIds.length)
  );
  proofSet.updatedAt = event.block.timestamp;
  proofSet.blockNumber = event.block.number;
  proofSet.save();

  const provider = Provider.load(proofSetOwner);
  if (provider) {
    provider.totalFaultedPeriods =
      provider.totalFaultedPeriods.plus(periodsFaultedParam);
    provider.totalFaultedRoots = provider.totalFaultedRoots.plus(
      BigInt.fromI32(uniqueRootIds.length)
    );
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("handleFaultRecord: Provider {} not found for ProofSet {}", [
      proofSetOwner.toHex(),
      setId.toString(),
    ]);
  }
}

/**
 * Handles the ProofSetRailCreated event.
 * Creates a new rail for a proof set.
 */
export function handleProofSetRailCreated(
  event: ProofSetRailCreatedEvent
): void {
  const listenerAddr = event.address;
  const setId = event.params.proofSetId;
  const railId = event.params.railId;
  const clientAddr = event.params.payer;
  const owner = event.params.payee;
  const withCDN = event.params.withCDN;
  const proofSetEntityId = getProofSetEntityId(setId);
  const railEntityId = getRailEntityId(railId);
  const providerEntityId = owner; // Provider ID is the owner address

  let proofSet = new ProofSet(proofSetEntityId);

  const inputData = event.transaction.input;
  const extraDataStart = 4 + 32 + 32 + 32;
  const extraDataBytes = inputData.subarray(extraDataStart);

  // extraData -> (metadata,payer,withCDN,signature)
  const decodedData = decodeStringAddressBoolBytes(
    Bytes.fromUint8Array(extraDataBytes)
  );

  let metadata: string = decodedData.stringValue;

  // Create ProofSet
  proofSet.setId = setId;
  proofSet.metadata = metadata;
  proofSet.clientAddr = clientAddr;
  proofSet.withCDN = withCDN;
  proofSet.owner = providerEntityId; // Link to Provider via owner address (which is Provider's ID)
  proofSet.listener = listenerAddr;
  proofSet.isActive = true;
  proofSet.leafCount = BigInt.fromI32(0);
  proofSet.challengeRange = BigInt.fromI32(0);
  proofSet.lastProvenEpoch = BigInt.fromI32(0);
  proofSet.nextChallengeEpoch = BigInt.fromI32(0);
  proofSet.totalRoots = BigInt.fromI32(0);
  proofSet.nextRootId = BigInt.fromI32(0);
  proofSet.totalDataSize = BigInt.fromI32(0);
  proofSet.totalFaultedPeriods = BigInt.fromI32(0);
  proofSet.totalFaultedRoots = BigInt.fromI32(0);
  proofSet.totalProofs = BigInt.fromI32(0);
  proofSet.totalProvedRoots = BigInt.fromI32(0);
  proofSet.createdAt = event.block.timestamp;
  proofSet.updatedAt = event.block.timestamp;
  proofSet.blockNumber = event.block.number;
  proofSet.save();

  // Create Rail
  let rail = new Rail(railEntityId);
  rail.railId = railId;
  rail.token = Address.fromHexString(USDFCTokenAddress);
  rail.from = clientAddr;
  rail.to = owner;
  rail.operator = listenerAddr;
  rail.arbiter = listenerAddr;
  rail.paymentRate = BigInt.fromI32(0);
  rail.lockupPeriod = BigInt.fromI32(DefaultLockupPeriod);
  rail.lockupFixed = BigInt.fromI32(0); // lockupFixed - oneTimePayment
  rail.settledUpto = BigInt.fromI32(0);
  rail.endEpoch = BigInt.fromI32(0);
  rail.queueLength = BigInt.fromI32(0);
  rail.proofSet = proofSetEntityId;
  rail.save();

  // Create or Update Provider
  let provider = Provider.load(providerEntityId);
  if (provider == null) {
    provider = new Provider(providerEntityId);
    provider.address = owner;
    provider.status = "Created";
    provider.totalRoots = BigInt.fromI32(0);
    provider.totalProofSets = BigInt.fromI32(1);
    provider.totalFaultedPeriods = BigInt.fromI32(0);
    provider.totalFaultedRoots = BigInt.fromI32(0);
    provider.totalDataSize = BigInt.fromI32(0);
    provider.createdAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
  } else {
    // Update timestamp/block even if exists
    provider.totalProofSets = provider.totalProofSets.plus(BigInt.fromI32(1));
    provider.blockNumber = event.block.number;
  }
  // provider.proofSetIds = provider.proofSetIds.concat([event.params.setId]); // REMOVED - Handled by @derivedFrom
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
 * Adds pdpUrl and pieceRetrievalUrl and updates registeredAt to block number with status update to "Registered"
 */
export function handleProviderRegistered(event: ProviderRegisteredEvent): void {
  const providerAddress = event.params.provider;
  const pdpUrl = event.params.pdpUrl;
  const pieceRetrievalUrl = event.params.pieceRetrievalUrl;

  let provider = Provider.load(providerAddress);
  if (!provider) {
    provider = new Provider(providerAddress);
    provider.address = providerAddress;
    provider.totalFaultedPeriods = BigInt.fromI32(0);
    provider.totalFaultedRoots = BigInt.fromI32(0);
    provider.totalProofSets = BigInt.fromI32(0);
    provider.totalRoots = BigInt.fromI32(0);
    provider.totalDataSize = BigInt.fromI32(0);
    provider.createdAt = event.block.timestamp;
  }

  provider.pdpUrl = pdpUrl;
  provider.pieceRetrievalUrl = pieceRetrievalUrl;
  provider.registeredAt = event.block.number;
  provider.status = "Registered";
  provider.updatedAt = event.block.timestamp;
  provider.blockNumber = event.block.number;

  provider.save();
}

/**
 * Handler for ProviderApproved event
 * Adds providerId with approvedAt = block.number and status = "Approved"
 */
export function handleProviderApproved(event: ProviderApprovedEvent): void {
  const providerAddress = event.params.provider;
  const providerId = event.params.providerId;

  let provider = Provider.load(providerAddress);
  if (!provider) return;

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
