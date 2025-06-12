import { BigInt, Bytes, log, ethereum, Address } from "@graphprotocol/graph-ts";
import {
  NextProvingPeriod as NextProvingPeriodEvent,
  PossessionProven as PossessionProvenEvent,
  ProofSetDeleted as ProofSetDeletedEvent,
  ProofSetEmpty as ProofSetEmptyEvent,
  ProofSetOwnerChanged as ProofSetOwnerChangedEvent,
  RootsAdded as RootsAddedEvent,
  RootsRemoved as RootsRemovedEvent,
} from "../generated/PDPVerifier/PDPVerifier";
import { Provider, ProofSet, Root } from "../generated/schema";
import { SumTree } from "./sumTree";
import { decodeBytesString } from "./decode";
import { LeafSize } from "../utils";

// --- Helper Functions for ID Generation ---
function getProofSetEntityId(setId: BigInt): Bytes {
  return Bytes.fromByteArray(Bytes.fromBigInt(setId));
}

function getRootEntityId(setId: BigInt, rootId: BigInt): Bytes {
  return Bytes.fromUTF8(setId.toString() + "-" + rootId.toString());
}

// -----------------------------------------

/**
 * Handles the ProofSetDeleted event.
 * Deletes a proof set and updates the provider's stats.
 */
export function handleProofSetDeleted(event: ProofSetDeletedEvent): void {
  const setId = event.params.setId;

  const proofSetEntityId = getProofSetEntityId(setId);

  // Load ProofSet
  const proofSet = ProofSet.load(proofSetEntityId);
  if (!proofSet) {
    // proofSet doesn't belong to Pandora Service
    return;
  }

  const ownerAddress = proofSet.owner;

  // Load Provider (to update stats before changing owner)
  const provider = Provider.load(ownerAddress);
  if (provider) {
    provider.totalDataSize = provider.totalDataSize.minus(
      proofSet.totalDataSize
    );
    if (provider.totalDataSize.lt(BigInt.fromI32(0))) {
      provider.totalDataSize = BigInt.fromI32(0);
    }
    provider.totalProofSets = provider.totalProofSets.minus(BigInt.fromI32(1));
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("ProofSetDeleted: Provider {} for ProofSet {} not found", [
      ownerAddress.toHexString(),
      setId.toString(),
    ]);
  }

  // Update ProofSet
  proofSet.isActive = false;
  proofSet.owner = Bytes.empty();
  proofSet.totalRoots = BigInt.fromI32(0);
  proofSet.totalDataSize = BigInt.fromI32(0);
  proofSet.nextChallengeEpoch = BigInt.fromI32(0);
  proofSet.lastProvenEpoch = BigInt.fromI32(0);
  proofSet.updatedAt = event.block.timestamp;
  proofSet.blockNumber = event.block.number;
  proofSet.save();

  // Note: Roots associated with this ProofSet are not automatically removed or updated here.
  // They still exist but are linked to an inactive ProofSet.
  // Consider if Roots should be marked as inactive or removed in handleRootsRemoved if needed.
}

/**
 * Handles the ProofSetOwnerChanged event.
 * Changes the owner of a proof set and updates the provider's stats.
 */
export function handleProofSetOwnerChanged(
  event: ProofSetOwnerChangedEvent
): void {
  const setId = event.params.setId;
  const oldOwner = event.params.oldOwner;
  const newOwner = event.params.newOwner;

  const proofSetEntityId = getProofSetEntityId(setId);

  // Load ProofSet
  const proofSet = ProofSet.load(proofSetEntityId);
  if (!proofSet) {
    // proofSet doesn't belong to Pandora Service
    return;
  }

  // Load Old Provider (if exists) - Just update timestamp, derived field handles removal
  const oldProvider = Provider.load(oldOwner);
  if (oldProvider) {
    oldProvider.totalProofSets = oldProvider.totalProofSets.minus(
      BigInt.fromI32(1)
    );
    oldProvider.updatedAt = event.block.timestamp;
    oldProvider.blockNumber = event.block.number;
    oldProvider.save();
  } else {
    log.warning("ProofSetOwnerChanged: Old Provider {} not found", [
      oldOwner.toHexString(),
    ]);
  }

  // Load or Create New Provider - Just update timestamp/create, derived field handles addition
  let newProvider = Provider.load(newOwner);
  if (newProvider == null) {
    newProvider = new Provider(newOwner);
    newProvider.address = newOwner;
    newProvider.status = "Created";
    newProvider.totalRoots = BigInt.fromI32(0);
    newProvider.totalFaultedPeriods = BigInt.fromI32(0);
    newProvider.totalFaultedRoots = BigInt.fromI32(0);
    newProvider.totalDataSize = BigInt.fromI32(0);
    newProvider.totalProofSets = BigInt.fromI32(1);
    newProvider.createdAt = event.block.timestamp;
    newProvider.blockNumber = event.block.number;
  } else {
    newProvider.totalProofSets = newProvider.totalProofSets.plus(
      BigInt.fromI32(1)
    );
    newProvider.blockNumber = event.block.number;
  }
  newProvider.updatedAt = event.block.timestamp;
  newProvider.save();

  // Update ProofSet Owner (this updates the derived relationship on both old and new Provider)
  proofSet.owner = newOwner; // Set owner to the new provider's ID
  proofSet.updatedAt = event.block.timestamp;
  proofSet.blockNumber = event.block.number;
  proofSet.save();
}

/**
 * Handles the ProofSetEmpty event.
 * Empties a proof set and updates the provider's stats.
 */
export function handleProofSetEmpty(event: ProofSetEmptyEvent): void {
  const setId = event.params.setId;

  const proofSetEntityId = getProofSetEntityId(setId);

  // Update ProofSet
  const proofSet = ProofSet.load(proofSetEntityId);

  if (!proofSet) return; // proofSet doesn't belong to Pandora Service

  const oldTotalDataSize = proofSet.totalDataSize; // Store size before zeroing

  proofSet.totalRoots = BigInt.fromI32(0);
  proofSet.totalDataSize = BigInt.fromI32(0);
  proofSet.leafCount = BigInt.fromI32(0);
  proofSet.updatedAt = event.block.timestamp;
  proofSet.blockNumber = event.block.number;
  proofSet.save();

  // Update Provider's total data size
  const provider = Provider.load(proofSet.owner);
  if (provider) {
    // Subtract the size this proof set had *before* it was zeroed
    provider.totalDataSize = provider.totalDataSize.minus(oldTotalDataSize);
    if (provider.totalDataSize.lt(BigInt.fromI32(0))) {
      provider.totalDataSize = BigInt.fromI32(0); // Prevent negative size
    }
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    // It's possible the provider was deleted or owner changed before this event
    log.warning("ProofSetEmpty: Provider {} for ProofSet {} not found", [
      proofSet.owner.toHexString(),
      setId.toString(),
    ]);
  }
}

/**
 * Handles the PossessionProven event.
 * Proves possession of a proof set and updates the provider's stats.
 */
export function handlePossessionProven(event: PossessionProvenEvent): void {
  const setId = event.params.setId;
  const challenges = event.params.challenges; // Array of { rootId: BigInt, offset: BigInt }
  const currentBlockNumber = event.block.number; // Use block number as epoch indicator
  const currentTimestamp = event.block.timestamp;

  const proofSetEntityId = getProofSetEntityId(setId);

  // Load ProofSet early to check if it belongs to Pandora Service
  const proofSet = ProofSet.load(proofSetEntityId);

  if (!proofSet) return; // proofSet doesn't belong to Pandora Service

  let uniqueRoots: BigInt[] = [];
  let rootIdMap = new Map<string, boolean>();

  // Process each challenge
  for (let i = 0; i < challenges.length; i++) {
    const challenge = challenges[i];
    const rootId = challenge.rootId;

    const rootIdStr = rootId.toString();
    if (!rootIdMap.has(rootIdStr)) {
      uniqueRoots.push(rootId);
      rootIdMap.set(rootIdStr, true);
    }
  }

  for (let i = 0; i < uniqueRoots.length; i++) {
    const rootId = uniqueRoots[i];
    const rootEntityId = getRootEntityId(setId, rootId);
    const root = Root.load(rootEntityId);
    if (root) {
      root.lastProvenEpoch = currentBlockNumber;
      root.lastProvenAt = currentTimestamp;
      root.totalProofsSubmitted = root.totalProofsSubmitted.plus(
        BigInt.fromI32(1)
      );
      root.updatedAt = currentTimestamp;
      root.blockNumber = currentBlockNumber;
      root.save();
    } else {
      log.warning(
        "PossessionProven: Root {} for Set {} not found during challenge processing",
        [rootId.toString(), setId.toString()]
      );
    }
  }

  // Update ProofSet

  proofSet.lastProvenEpoch = currentBlockNumber; // Update last proven epoch for the set
  proofSet.totalProvedRoots = proofSet.totalProvedRoots.plus(
    BigInt.fromI32(uniqueRoots.length)
  );
  proofSet.totalProofs = proofSet.totalProofs.plus(BigInt.fromI32(1));
  proofSet.updatedAt = currentTimestamp;
  proofSet.blockNumber = currentBlockNumber;
  proofSet.save();
}

/**
 * Handles the NextProvingPeriod event.
 * Updates the next challenge epoch and challenge range for a proof set.
 */
export function handleNextProvingPeriod(event: NextProvingPeriodEvent): void {
  const setId = event.params.setId;
  const challengeEpoch = event.params.challengeEpoch;
  const leafCount = event.params.leafCount;

  const proofSetEntityId = getProofSetEntityId(setId);

  // Update Proof Set
  const proofSet = ProofSet.load(proofSetEntityId);

  if (!proofSet) return; // proofSet doesn't belong to Pandora Service

  proofSet.nextChallengeEpoch = challengeEpoch;
  proofSet.challengeRange = leafCount;
  proofSet.updatedAt = event.block.timestamp;
  proofSet.blockNumber = event.block.number;
  proofSet.save();
}

/**
 * Handles the RootsAdded event.
 * Adds roots to a proof set and updates the provider's stats.
 */
export function handleRootsAdded(event: RootsAddedEvent): void {
  const setId = event.params.setId;
  const rootIdsFromEvent = event.params.rootIds; // Get root IDs from event params

  // Input parsing is necessary to get rawSize and root bytes (cid)
  const txInput = event.transaction.input;

  if (txInput.length < 4) {
    log.error("Invalid tx input length in handleRootsAdded: {}", [
      event.transaction.hash.toHex(),
    ]);
    return;
  }

  const proofSetEntityId = getProofSetEntityId(setId);

  // Load ProofSet
  const proofSet = ProofSet.load(proofSetEntityId);
  if (!proofSet) return; // proofSet doesn't belong to Pandora Service

  // --- Parse Transaction Input --- Requires helper functions
  // Skip function selector (first 4 bytes)
  const encodedData = Bytes.fromUint8Array(txInput.slice(4));

  // Decode setId (uint256 at offset 0)
  let decodedSetId: BigInt = readUint256(encodedData, 0);
  if (decodedSetId != setId) {
    log.warning(
      "Decoded setId {} does not match event param {} in handleRootsAdded. Tx: {}. Using event param.",
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

  // Decode rootsData (tuple[])
  let rootsDataOffset = readUint256(encodedData, 32).toI32(); // Offset is at byte 32
  let rootsDataLength: i32;

  if (rootsDataOffset < 0 || encodedData.length < rootsDataOffset + 32) {
    log.error(
      "handleRootsAdded: Invalid rootsDataOffset {} or data length {} for reading rootsData length. Tx: {}",
      [
        rootsDataOffset.toString(),
        encodedData.length.toString(),
        event.transaction.hash.toHex(),
      ]
    );
    return;
  }

  rootsDataLength = readUint256(encodedData, rootsDataOffset).toI32(); // Length is at the offset

  if (rootsDataLength < 0) {
    log.error("handleRootsAdded: Invalid negative rootsDataLength {}. Tx: {}", [
      rootsDataLength.toString(),
      event.transaction.hash.toHex(),
    ]);
    return;
  }

  // Check if number of roots from input matches event param
  if (rootsDataLength != rootIdsFromEvent.length) {
    log.error(
      "handleRootsAdded: Decoded roots count ({}) does not match event param count ({}). Tx: {}",
      [
        rootsDataLength.toString(),
        rootIdsFromEvent.length.toString(),
        event.transaction.hash.toHex(),
      ]
    );
    // Decide how to proceed. For now, use the event length as the source of truth for iteration.
    rootsDataLength = rootIdsFromEvent.length;
  }

  let addedRootCount = 0;
  let totalDataSizeAdded = BigInt.fromI32(0);

  // Create Root entities
  const structsBaseOffset = rootsDataOffset + 32; // Start of struct offsets/data

  for (let i = 0; i < rootsDataLength; i++) {
    const rootId = rootIdsFromEvent[i]; // Use rootId from event params

    // Calculate offset for this struct's data
    const structDataRelOffset = readUint256(
      encodedData,
      structsBaseOffset + i * 32
    ).toI32();
    const structDataAbsOffset = rootsDataOffset + 32 + structDataRelOffset; // Correct absolute offset

    // Check bounds for reading struct content (root offset + rawSize)
    if (
      structDataAbsOffset < 0 ||
      encodedData.length < structDataAbsOffset + 64
    ) {
      log.error(
        "handleRootsAdded: Encoded data too short or invalid offset for root struct content. Index: {}, Offset: {}, Len: {}. Tx: {}",
        [
          i.toString(),
          structDataAbsOffset.toString(),
          encodedData.length.toString(),
          event.transaction.hash.toHex(),
        ]
      );
      continue; // Skip this root
    }

    // Decode root tuple (bytes stored within the struct)
    const rootBytes = readBytes(encodedData, structDataAbsOffset); // Reads dynamic bytes
    // Decode rawSize (uint256 stored after root bytes offset)
    const rawSize = readUint256(encodedData, structDataAbsOffset + 32);

    const rootEntityId = getRootEntityId(setId, rootId);

    let root = Root.load(rootEntityId);
    if (root) {
      log.warning(
        "handleRootsAdded: Root {} for Set {} already exists. This shouldn't happen. Skipping.",
        [rootId.toString(), setId.toString()]
      );
      continue;
    }

    root = new Root(rootEntityId);
    root.rootId = rootId;
    root.setId = setId;
    root.metadata = metadata;
    root.rawSize = rawSize; // Use correct field name
    root.leafCount = rawSize.div(BigInt.fromI32(LeafSize));
    root.cid = rootBytes.length > 0 ? rootBytes : Bytes.empty(); // Use correct field name
    root.removed = false; // Explicitly set removed to false
    root.lastProvenEpoch = BigInt.fromI32(0);
    root.lastProvenAt = BigInt.fromI32(0);
    root.lastFaultedEpoch = BigInt.fromI32(0);
    root.lastFaultedAt = BigInt.fromI32(0);
    root.totalProofsSubmitted = BigInt.fromI32(0);
    root.totalPeriodsFaulted = BigInt.fromI32(0);
    root.createdAt = event.block.timestamp;
    root.updatedAt = event.block.timestamp;
    root.blockNumber = event.block.number;
    root.proofSet = proofSetEntityId; // Link to ProofSet

    root.save();

    // Update SumTree
    const sumTree = new SumTree();
    sumTree.sumTreeAdd(
      setId.toI32(),
      rawSize.div(BigInt.fromI32(LeafSize)),
      rootId.toI32()
    );

    addedRootCount += 1;
    totalDataSizeAdded = totalDataSizeAdded.plus(rawSize);
  }

  // Update ProofSet stats
  proofSet.totalRoots = proofSet.totalRoots.plus(
    BigInt.fromI32(addedRootCount)
  ); // Use correct field name
  proofSet.nextRootId = proofSet.nextRootId.plus(
    BigInt.fromI32(addedRootCount)
  );
  proofSet.totalDataSize = proofSet.totalDataSize.plus(totalDataSizeAdded);
  proofSet.leafCount = proofSet.leafCount.plus(
    totalDataSizeAdded.div(BigInt.fromI32(LeafSize))
  );
  proofSet.updatedAt = event.block.timestamp;
  proofSet.blockNumber = event.block.number;
  proofSet.save();

  // Update Provider stats
  const provider = Provider.load(proofSet.owner);
  if (provider) {
    provider.totalDataSize = provider.totalDataSize.plus(totalDataSizeAdded);
    provider.totalRoots = provider.totalRoots.plus(
      BigInt.fromI32(addedRootCount)
    );
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("handleRootsAdded: Provider {} for ProofSet {} not found", [
      proofSet.owner.toHex(),
      setId.toString(),
    ]);
  }
}

/**
 * Handles the RootsRemoved event.
 * Removes roots from a proof set and updates the provider's stats.
 */
export function handleRootsRemoved(event: RootsRemovedEvent): void {
  const setId = event.params.setId;
  const rootIds = event.params.rootIds;

  const proofSetEntityId = getProofSetEntityId(setId);

  // Load ProofSet
  const proofSet = ProofSet.load(proofSetEntityId);
  if (!proofSet) return; // proofSet doesn't belong to Pandora Service

  let removedRootCount = 0;
  let removedDataSize = BigInt.fromI32(0);

  // Mark Root entities as removed (soft delete)
  for (let i = 0; i < rootIds.length; i++) {
    const rootId = rootIds[i];
    const rootEntityId = getRootEntityId(setId, rootId);

    const root = Root.load(rootEntityId);
    if (root) {
      removedRootCount += 1;
      removedDataSize = removedDataSize.plus(root.rawSize); // Use correct field name

      // Mark the Root entity as removed instead of deleting
      root.removed = true;
      root.updatedAt = event.block.timestamp;
      root.blockNumber = event.block.number;
      root.save();

      // Update SumTree
      const sumTree = new SumTree();
      sumTree.sumTreeRemove(
        setId.toI32(),
        proofSet.nextRootId.toI32(),
        rootId.toI32(),
        root.rawSize.div(BigInt.fromI32(LeafSize)),
        event.block.number
      );
    } else {
      log.warning(
        "handleRootsRemoved: Root {} for Set {} not found. Cannot remove.",
        [rootId.toString(), setId.toString()]
      );
    }
  }

  // Update ProofSet stats
  proofSet.totalRoots = proofSet.totalRoots.minus(
    BigInt.fromI32(removedRootCount)
  ); // Use correct field name
  proofSet.totalDataSize = proofSet.totalDataSize.minus(removedDataSize);
  proofSet.leafCount = proofSet.leafCount.minus(
    removedDataSize.div(BigInt.fromI32(LeafSize))
  );

  // Ensure stats don't go negative
  if (proofSet.totalRoots.lt(BigInt.fromI32(0))) {
    // Use correct field name
    log.warning(
      "handleRootsRemoved: ProofSet {} rootCount went negative. Setting to 0.",
      [setId.toString()]
    );
    proofSet.totalRoots = BigInt.fromI32(0); // Use correct field name
  }
  if (proofSet.totalDataSize.lt(BigInt.fromI32(0))) {
    log.warning(
      "handleRootsRemoved: ProofSet {} totalDataSize went negative. Setting to 0.",
      [setId.toString()]
    );
    proofSet.totalDataSize = BigInt.fromI32(0);
  }
  if (proofSet.leafCount.lt(BigInt.fromI32(0))) {
    log.warning(
      "handleRootsRemoved: ProofSet {} leafCount went negative. Setting to 0.",
      [setId.toString()]
    );
    proofSet.leafCount = BigInt.fromI32(0);
  }
  proofSet.updatedAt = event.block.timestamp;
  proofSet.blockNumber = event.block.number;
  proofSet.save();

  // Update Provider stats
  const provider = Provider.load(proofSet.owner);
  if (provider) {
    provider.totalDataSize = provider.totalDataSize.minus(removedDataSize);
    // Ensure provider totalDataSize doesn't go negative
    if (provider.totalDataSize.lt(BigInt.fromI32(0))) {
      log.warning(
        "handleRootsRemoved: Provider {} totalDataSize went negative. Setting to 0.",
        [proofSet.owner.toHex()]
      );
      provider.totalDataSize = BigInt.fromI32(0);
    }
    provider.totalRoots = provider.totalRoots.minus(
      BigInt.fromI32(removedRootCount)
    );
    // Ensure provider totalRoots doesn't go negative
    if (provider.totalRoots.lt(BigInt.fromI32(0))) {
      log.warning(
        "handleRootsRemoved: Provider {} totalRoots went negative. Setting to 0.",
        [proofSet.owner.toHex()]
      );
      provider.totalRoots = BigInt.fromI32(0);
    }
    provider.updatedAt = event.block.timestamp;
    provider.blockNumber = event.block.number;
    provider.save();
  } else {
    log.warning("handleRootsRemoved: Provider {} for ProofSet {} not found", [
      proofSet.owner.toHex(),
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
