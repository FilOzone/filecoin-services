import { keccak256 } from 'viem';

// Root slots of the legacy mappings in the FWSS proxy (FilecoinWarmStorageServiceLayout.sol).
export const PIECE_METADATA_ROOT = 13n;
export const PIECE_METADATA_KEYS_ROOT = 14n;
export const PIECE_METADATA_REMOVALS_ROOT = 22n;

const WORD = 32;
const MAX_UINT256 = (1n << 256n) - 1n;

export function word(value: bigint): Uint8Array {
  if (value < 0n || value > MAX_UINT256) throw new Error(`not a uint256: ${value}`);
  return Buffer.from(value.toString(16).padStart(2 * WORD, '0'), 'hex');
}

export function toBigInt(bytes: Uint8Array): bigint {
  return bytes.length === 0 ? 0n : BigInt('0x' + Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length).toString('hex'));
}

function hash(...parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((n, p) => n + p.length, 0);
  const buf = new Uint8Array(length);
  let offset = 0;
  for (const p of parts) {
    buf.set(p, offset);
    offset += p.length;
  }
  return keccak256(buf, 'bytes');
}

// Slot of `m[key]` for a mapping with an integer key at `slot`: keccak256(abi.encode(key, slot)).
export function mappingSlot(key: bigint, slot: bigint): bigint {
  return toBigInt(hash(word(key), word(slot)));
}

// First data slot of a dynamic array or long string whose head is at `slot`: keccak256(slot).
export function dataSlot(slot: bigint): bigint {
  return toBigInt(hash(word(slot)));
}

// `slot + offset` with the EVM's 256-bit wraparound.
export function addSlot(slot: bigint, offset: number): bigint {
  return (slot + BigInt(offset)) & MAX_UINT256;
}

export function keysSlot(dataSetId: number, pieceId: number): bigint {
  return mappingSlot(BigInt(pieceId), mappingSlot(BigInt(dataSetId), PIECE_METADATA_KEYS_ROOT));
}

// Head slot of each value of one piece, keyed by the key's UTF-8 bytes:
// keccak256(abi.encodePacked(bytes(key), pieceSlot)).
export function valueSlots(dataSetId: number, pieceId: number): (key: Uint8Array) => bigint {
  const pieceSlot = word(mappingSlot(BigInt(pieceId), mappingSlot(BigInt(dataSetId), PIECE_METADATA_ROOT)));
  return (key) => toBigInt(hash(key, pieceSlot));
}

export function queueSlot(dataSetId: number): bigint {
  return mappingSlot(BigInt(dataSetId), PIECE_METADATA_REMOVALS_ROOT);
}

// Number of data slots a Solidity string of `length` bytes occupies besides its head slot.
export function stringDataSlots(length: number): number {
  return length < WORD ? 0 : Math.ceil(length / WORD);
}

// The head slot Solidity stores for a string: short strings hold their bytes left-aligned and `length * 2` in the
// lowest byte; long strings hold `length * 2 + 1`.
export function stringHead(value: Uint8Array): bigint {
  if (value.length >= WORD) return BigInt(value.length * 2 + 1);
  const head = new Uint8Array(WORD);
  head.set(value);
  head[WORD - 1] = value.length * 2;
  return toBigInt(head);
}

// Byte length of a stored string from its head slot, and whether its bytes sit in data slots.
export function storedStringLength(head: bigint): { length: number; long: boolean } {
  if ((head & 1n) === 1n) return { length: Number((head - 1n) / 2n), long: true };
  return { length: Number(head & 0xffn) / 2, long: false };
}

// The inverse of `stringHead`: a stored string's bytes from its head and, for a long string, its
// `stringDataSlots(length)` data slots. Throws on a head Solidity never writes.
export function decodeString(head: bigint, data: readonly bigint[]): Uint8Array {
  const { length, long } = storedStringLength(head);
  if (!long) {
    const bytes = word(head);
    if (length >= WORD || bytes.subarray(length, WORD - 1).some((b) => b !== 0)) throw new Error(`malformed short string head ${hex32(head)}`);
    return bytes.slice(0, length);
  }

  if (length < WORD) throw new Error(`long string head ${hex32(head)} holds only ${length} bytes`);
  if (data.length !== stringDataSlots(length)) throw new Error(`string of ${length} bytes needs ${stringDataSlots(length)} data slots`);
  return Buffer.concat(data.map(word)).subarray(0, length);
}

export function hex32(slot: bigint): `0x${string}` {
  return `0x${slot.toString(16).padStart(64, '0')}`;
}
