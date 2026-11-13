import { opWeight, type PlannedOp } from './ops.ts';

export type BatchLimits = { maxCalldataBytes: number; maxOps: number };
export const DEFAULT_LIMITS: BatchLimits = { maxCalldataBytes: 60_000, maxOps: 1500 };

export type Batch = {
  phase: number;
  firstKey: Uint8Array;
  lastKey: Uint8Array;
  opCount: number;
  weight: number;
  opsBytes: number;
};

// ABI calldata of cleanupLegacyPieceMetadata(bytes): selector, offset word, length word, data padded to 32 bytes.
export function calldataBytes(opsBytes: number): number {
  return 4 + 32 + 32 + Math.ceil(opsBytes / 32) * 32;
}

// Cuts ops, already in sort-key order, into consecutive batches. A batch never spans two phases, so queue pops get
// batches of their own ahead of the metadata.
export function* cutBatches(ops: Iterable<PlannedOp>, limits: BatchLimits): Generator<Batch> {
  let current: Batch | undefined;
  let previous: Uint8Array | undefined;
  for (const { sortKey, op } of ops) {
    if (previous && Buffer.compare(previous, sortKey) >= 0) throw new Error('ops are not in strictly increasing sort-key order');
    previous = sortKey;

    const weight = opWeight(op);
    if (weight > limits.maxOps || calldataBytes(op.length) > limits.maxCalldataBytes) {
      throw new Error('a single op exceeds the batch limits');
    }

    const phase = sortKey[0]!;
    if (
      current &&
      (current.phase !== phase ||
        current.weight + weight > limits.maxOps ||
        calldataBytes(current.opsBytes + op.length) > limits.maxCalldataBytes)
    ) {
      yield current;
      current = undefined;
    }

    if (!current) {
      current = { phase, firstKey: sortKey, lastKey: sortKey, opCount: 0, weight: 0, opsBytes: 0 };
    }
    current.lastKey = sortKey;
    current.opCount += 1;
    current.weight += weight;
    current.opsBytes += op.length;
  }
  if (current) yield current;
}
