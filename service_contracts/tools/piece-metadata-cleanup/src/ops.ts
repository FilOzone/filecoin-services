import { addSlot, dataSlot, keysSlot, queueSlot, stringDataSlots, valueSlots, word } from './slots.ts';

// Wire format of FWSSPieceMetadataCleanupModule.cleanupLegacyPieceMetadata; its natspec is the reference.
export const VALUE_HEAD = 0;
export const VALUE_DATA = 1;
export const KEYS_LENGTH = 2;
export const KEY_HEAD = 3;
export const POP_QUEUE = 4;
export const KEY_DATA = 5;
export const KIND_NAMES = ['ValueHead', 'ValueData', 'KeysLength', 'KeyHead', 'PopQueue', 'KeyData'] as const;

// Bounds of the legacy data the facet can clear; see the module's LEGACY_MAX_* constants.
export const MAX_ID = 2 ** 24 - 1;
export const MAX_KEYS = 5;
export const MAX_KEY_BYTES = 32;
export const MAX_VALUE_BYTES = 128;
export const MAX_POP_COUNT = 0xffff;

export type Op =
  | { kind: typeof VALUE_HEAD; dataSetId: number; pieceId: number; key: Uint8Array }
  | { kind: typeof VALUE_DATA; dataSetId: number; pieceId: number; count: number; key: Uint8Array }
  | { kind: typeof KEYS_LENGTH; dataSetId: number; pieceId: number }
  | { kind: typeof KEY_HEAD; dataSetId: number; pieceId: number; index: number }
  | { kind: typeof POP_QUEUE; dataSetId: number; count: number }
  | { kind: typeof KEY_DATA; dataSetId: number; pieceId: number; index: number };

export type Entry = { key: Uint8Array; value: Uint8Array };
export type Piece = { dataSetId: number; pieceId: number; entries: Entry[] };

const utf8 = new TextEncoder();

function validId(id: number): boolean {
  return Number.isSafeInteger(id) && id >= 0 && id <= MAX_ID;
}

// Turns an indexer row into a piece, or says why the facet cannot clear it. Never truncates: lengths are UTF-8 bytes,
// which is what Solidity hashed and stored.
export function parsePiece(dataSetId: number, pieceId: number, metadata: unknown): { piece: Piece } | { invalid: string } {
  if (!validId(dataSetId) || !validId(pieceId)) return { invalid: 'id does not fit in 24 bits' };
  if (metadata === null || typeof metadata !== 'object' || Array.isArray(metadata)) {
    return { invalid: 'metadata is not an object' };
  }

  const pairs = Object.entries(metadata);
  if (pairs.length === 0) return { invalid: 'no keys' };
  if (pairs.length > MAX_KEYS) return { invalid: `${pairs.length} keys, at most ${MAX_KEYS}` };

  const entries: Entry[] = [];
  for (const [k, v] of pairs) {
    if (typeof v !== 'string') return { invalid: `value of ${JSON.stringify(k)} is not a string` };
    const key = utf8.encode(k);
    const value = utf8.encode(v);
    if (key.length < 1 || key.length > MAX_KEY_BYTES) {
      return { invalid: `key ${JSON.stringify(k)} is ${key.length} bytes, allowed 1..${MAX_KEY_BYTES}` };
    }
    if (value.length > MAX_VALUE_BYTES) {
      return { invalid: `value of ${JSON.stringify(k)} is ${value.length} bytes, at most ${MAX_VALUE_BYTES}` };
    }
    entries.push({ key, value });
  }
  return { piece: { dataSetId, pieceId, entries } };
}

// Every op that zeroes what the piece wrote: per key its array element, its value head unless the value is empty
// (Solidity writes no slot for an empty string), its data slots if the value is 32 bytes or more; then the length.
export function pieceOps(piece: Piece): Op[] {
  const { dataSetId, pieceId } = piece;
  const ops: Op[] = [];
  piece.entries.forEach(({ key, value }, index) => {
    ops.push({ kind: KEY_HEAD, dataSetId, pieceId, index });
    if (value.length > 0) ops.push({ kind: VALUE_HEAD, dataSetId, pieceId, key });
    const count = stringDataSlots(value.length);
    if (count > 0) ops.push({ kind: VALUE_DATA, dataSetId, pieceId, count, key });
  });

  // A 32-byte key keeps its bytes in a data slot of its element, and the indexer does not record at which index the
  // key sits, so every index gets a KeyData op; zeroing the unused data slot of a short key is harmless.
  if (piece.entries.some(({ key }) => key.length === MAX_KEY_BYTES)) {
    piece.entries.forEach((_, index) => ops.push({ kind: KEY_DATA, dataSetId, pieceId, index }));
  }
  ops.push({ kind: KEYS_LENGTH, dataSetId, pieceId });
  return ops;
}

// PopQueue ops that empty a queue of `length` entries, each popping at most `maxCount`.
type PopQueueOp = Extract<Op, { kind: typeof POP_QUEUE }>;

export function popQueueOps(dataSetId: number, length: number, maxCount: number): PopQueueOp[] {
  const per = Math.min(maxCount, MAX_POP_COUNT);
  const ops: PopQueueOp[] = [];
  for (let left = length; left > 0; left -= per) {
    ops.push({ kind: POP_QUEUE, dataSetId, count: Math.min(per, left) });
  }
  return ops;
}

function opLength(op: Op): number {
  switch (op.kind) {
    case VALUE_HEAD:
      return 8 + op.key.length;
    case VALUE_DATA:
      return 9 + op.key.length;
    case KEYS_LENGTH:
      return 7;
    case KEY_HEAD:
    case KEY_DATA:
      return 8;
    case POP_QUEUE:
      return 6;
  }
}

function writeUint(buf: Uint8Array, offset: number, size: number, value: number): void {
  for (let i = size - 1; i >= 0; i--) {
    buf[offset + i] = value % 256;
    value = Math.floor(value / 256);
  }
}

function readUint(buf: Uint8Array, offset: number, size: number): number {
  if (offset + size > buf.length) throw new Error(`truncated op at byte ${offset}`);
  let v = 0;
  for (let i = 0; i < size; i++) v = v * 256 + buf[offset + i]!;
  return v;
}

export function encodeOp(op: Op): Uint8Array {
  if (!validId(op.dataSetId)) throw new Error(`data set id out of range: ${op.dataSetId}`);
  const buf = new Uint8Array(opLength(op));
  buf[0] = op.kind;
  writeUint(buf, 1, 3, op.dataSetId);
  if (op.kind === POP_QUEUE) {
    if (op.count < 0 || op.count > MAX_POP_COUNT) throw new Error(`pop count out of range: ${op.count}`);
    writeUint(buf, 4, 2, op.count);
    return buf;
  }

  if (!validId(op.pieceId)) throw new Error(`piece id out of range: ${op.pieceId}`);
  writeUint(buf, 4, 3, op.pieceId);
  if (op.kind === KEYS_LENGTH) return buf;
  if (op.kind === KEY_HEAD || op.kind === KEY_DATA) {
    if (op.index < 0 || op.index >= MAX_KEYS) throw new Error(`key index out of range: ${op.index}`);
    buf[7] = op.index;
    return buf;
  }

  let offset = 7;
  if (op.kind === VALUE_DATA) {
    if (op.count < 1 || op.count > 4) throw new Error(`value data count out of range: ${op.count}`);
    buf[offset++] = op.count;
  }
  if (op.key.length > 0xff) throw new Error(`key too long: ${op.key.length}`);
  buf[offset++] = op.key.length;
  buf.set(op.key, offset);
  return buf;
}

export function decodeOps(bytes: Uint8Array): Op[] {
  const ops: Op[] = [];
  let at = 0;
  while (at < bytes.length) {
    const kind = readUint(bytes, at, 1);
    const dataSetId = readUint(bytes, at + 1, 3);
    if (kind === POP_QUEUE) {
      ops.push({ kind, dataSetId, count: readUint(bytes, at + 4, 2) });
      at += 6;
      continue;
    }

    const pieceId = readUint(bytes, at + 4, 3);
    let next = at + 7;
    if (kind === KEYS_LENGTH) {
      ops.push({ kind, dataSetId, pieceId });
    } else if (kind === KEY_HEAD || kind === KEY_DATA) {
      ops.push({ kind, dataSetId, pieceId, index: readUint(bytes, next++, 1) });
    } else if (kind === VALUE_HEAD || kind === VALUE_DATA) {
      const count = kind === VALUE_DATA ? readUint(bytes, next++, 1) : 0;
      const keyLength = readUint(bytes, next++, 1);
      if (next + keyLength > bytes.length) throw new Error(`truncated op at byte ${at}`);
      const key = new Uint8Array(bytes.subarray(next, next + keyLength));
      next += keyLength;
      ops.push(kind === VALUE_HEAD ? { kind, dataSetId, pieceId, key } : { kind, dataSetId, pieceId, count, key });
    } else {
      throw new Error(`unknown op kind ${kind} at byte ${at}`);
    }
    at = next;
  }
  return ops;
}

// Slots a metadata op zeroes, first slot first. PopQueue has none here: what it pops depends on the queue length.
export function opSlots(op: Op): bigint[] {
  switch (op.kind) {
    case VALUE_HEAD:
      return [valueSlots(op.dataSetId, op.pieceId)(op.key)];
    case VALUE_DATA: {
      const first = dataSlot(valueSlots(op.dataSetId, op.pieceId)(op.key));
      return Array.from({ length: op.count }, (_, i) => addSlot(first, i));
    }
    case KEYS_LENGTH:
      return [keysSlot(op.dataSetId, op.pieceId)];
    case KEY_HEAD:
      return [addSlot(dataSlot(keysSlot(op.dataSetId, op.pieceId)), op.index)];
    case KEY_DATA:
      return [dataSlot(addSlot(dataSlot(keysSlot(op.dataSetId, op.pieceId)), op.index))];
    case POP_QUEUE:
      return [];
  }
}

// Sort keys order ops for sending: phase byte, then the op's first slot as a 32-byte big-endian number, so a bytewise
// comparison (JS or SQLite BLOB) is a numeric one. Queue pops go first so the queues empty before anything else.
export const PHASE_QUEUE = 0;
export const PHASE_METADATA = 1;

export function sortKey(phase: number, slot: bigint): Uint8Array {
  const key = new Uint8Array(33);
  key[0] = phase;
  key.set(word(slot), 1);
  return key;
}

export type PlannedOp = { sortKey: Uint8Array; op: Uint8Array };

export function plannedPieceOps(piece: Piece): PlannedOp[] {
  return pieceOps(piece).map((op) => ({ sortKey: sortKey(PHASE_METADATA, opSlots(op)[0]!), op: encodeOp(op) }));
}

// Planned pops of one queue, keyed by the lowest element each would pop if run in order; any order empties it.
export function plannedQueueOps(dataSetId: number, length: number, maxCount: number): PlannedOp[] {
  const elements = dataSlot(queueSlot(dataSetId));
  let top = length;
  return popQueueOps(dataSetId, length, maxCount).map((op) => {
    top -= op.count;
    return { sortKey: sortKey(PHASE_QUEUE, addSlot(elements, top)), op: encodeOp(op) };
  });
}

// How much of a batch's op budget an op takes: 1 per metadata op, as in the gas measurement behind the default, and
// 1 per popped entry, because one PopQueue op zeroes that many entries and then writes the queue length once.
export function opWeight(op: Uint8Array): number {
  return op[0] === POP_QUEUE ? op[4]! * 256 + op[5]! : 1;
}
