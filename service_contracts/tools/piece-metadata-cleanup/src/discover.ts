import type { DatabaseSync } from 'node:sqlite';
import { pieceUpserter, readLegacyRanges, sendStarted, transaction } from './db.ts';
import { MAX_KEY_BYTES, MAX_KEYS, MAX_VALUE_BYTES, parsePiece } from './ops.ts';
import { addSlot, dataSlot, decodeString, keysSlot, storedStringLength, stringDataSlots, valueSlots } from './slots.ts';
import type { StorageReader } from './storage.ts';

export type Discovered = { dataSetId: number; pieceId: number; keys: string[]; status: 'unchecked' | 'invalid'; detail: string | null };

export type DiscoverOptions = {
  // Data set ids 0..dataSetIds-1 are read: PDPVerifier's next data set id.
  dataSetIds: number;
  tail: number;
  pageSize?: number;
  log?: (line: string) => void;
};

export type DiscoverResult = { candidates: number; hits: number; unrepresentable: number; pieces: Discovered[] };

// Candidates of `discover`, data set by data set: the piece ids in [0, end) that `known` (ascending) lacks, where end
// is one past the largest legacy piece id of the data set plus `tail`, or `tail` for a data set without a range.
export function* candidates(
  dataSetIds: number,
  maxLegacy: ReadonlyMap<number, number>,
  tail: number,
  known: (dataSetId: number) => Iterable<number>,
): Generator<{ dataSetId: number; pieceId: number }> {
  for (let dataSetId = 0; dataSetId < dataSetIds; dataSetId++) {
    const max = maxLegacy.get(dataSetId);
    const end = (max === undefined ? 0 : max + 1) + tail;
    const ids = known(dataSetId)[Symbol.iterator]();
    let next = ids.next();
    for (let pieceId = 0; pieceId < end; pieceId++) {
      while (!next.done && next.value < pieceId) next = ids.next();
      if (!next.done && next.value === pieceId) continue;
      yield { dataSetId, pieceId };
    }
  }
}

// Piece ids of one data set that have a row, ascending, a page at a time so one large data set stays out of memory.
function* knownPieceIds(db: DatabaseSync, dataSetId: number): Generator<number> {
  const page = db.prepare('SELECT piece_id FROM pieces WHERE data_set_id = ? AND piece_id > ? ORDER BY piece_id LIMIT 10000');
  let after = -1;
  for (;;) {
    const rows = page.all(dataSetId, after) as { piece_id: number }[];
    if (rows.length === 0) return;
    for (const r of rows) yield r.piece_id;
    after = rows[rows.length - 1]!.piece_id;
  }
}

class Unrepresentable extends Error {}

// ignoreBOM keeps a leading U+FEFF, which is part of the bytes Solidity hashed.
const utf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

async function readString(reader: StorageReader, slot: bigint, head: bigint, maxBytes: number, what: string): Promise<string> {
  const { length, long } = storedStringLength(head);
  if (long && length > maxBytes) throw new Unrepresentable(`${what} is ${length} bytes, at most ${maxBytes}`);

  const first = dataSlot(slot);
  const data = long ? await reader.read(Array.from({ length: stringDataSlots(length) }, (_, i) => addSlot(first, i))) : [];
  let bytes: Uint8Array;
  try {
    bytes = decodeString(head, data);
  } catch (err) {
    throw new Unrepresentable(`${what}: ${(err as Error).message}`);
  }
  try {
    return utf8.decode(bytes);
  } catch {
    throw new Unrepresentable(`${what} is not valid UTF-8: 0x${Buffer.from(bytes).toString('hex')}`);
  }
}

// Recovers a piece's metadata from storage, in key array order. Anything metadata cannot hold is an Unrepresentable.
async function readPiece(reader: StorageReader, dataSetId: number, pieceId: number, length: bigint, keys: string[]): Promise<Record<string, string>> {
  if (length > BigInt(MAX_KEYS)) throw new Unrepresentable(`keys length ${length}, at most ${MAX_KEYS}`);

  const elements = dataSlot(keysSlot(dataSetId, pieceId));
  const slots = Array.from({ length: Number(length) }, (_, i) => addSlot(elements, i));
  const heads = await reader.read(slots);
  for (let i = 0; i < slots.length; i++) {
    const key = await readString(reader, slots[i]!, heads[i]!, MAX_KEY_BYTES, `key ${i}`);
    if (keys.includes(key)) throw new Unrepresentable(`key ${JSON.stringify(key)} appears twice`);
    keys.push(key);
  }

  const valueSlot = valueSlots(dataSetId, pieceId);
  const encoder = new TextEncoder();
  const valueSlotsOfKeys = keys.map((k) => valueSlot(encoder.encode(k)));
  const valueHeads = await reader.read(valueSlotsOfKeys);
  const entries: [string, string][] = [];
  for (let i = 0; i < keys.length; i++) {
    entries.push([keys[i]!, await readString(reader, valueSlotsOfKeys[i]!, valueHeads[i]!, MAX_VALUE_BYTES, `value of ${JSON.stringify(keys[i])}`)]);
  }
  return Object.fromEntries(entries);
}

// Finds legacy pieces with metadata on chain and no row in `pieces`, which the indexer missed, and stores them as
// `fetch` would. Before the upgrade a piece's values and its key array are written and deleted together, so a non-zero
// keys length is a complete marker. A hit metadata cannot hold is stored as `invalid` with the reason, so `plan`
// lists it. Like `check`, it is valid only before anything is sent.
export async function discoverPieces(db: DatabaseSync, reader: StorageReader, opts: DiscoverOptions): Promise<DiscoverResult> {
  if (sendStarted(db)) {
    throw new Error('sending has started on this state file, and discover is only valid before that; to recover, run verify --requeue, then send');
  }
  const ranges = readLegacyRanges(db);
  if (ranges.size === 0) throw new Error('no legacy piece id ranges stored; run fetch first');

  const pageSize = opts.pageSize ?? 5000;
  const log = opts.log ?? (() => {});
  const upsert = pieceUpserter(db);
  const result: DiscoverResult = { candidates: 0, hits: 0, unrepresentable: 0, pieces: [] };
  const started = Date.now();
  const all = candidates(opts.dataSetIds, ranges, opts.tail, (id) => knownPieceIds(db, id));

  for (;;) {
    const page: { dataSetId: number; pieceId: number }[] = [];
    while (page.length < pageSize) {
      const next = all.next();
      if (next.done) break;
      page.push(next.value);
    }
    if (page.length === 0) break;

    const lengths = await reader.read(page.map((c) => keysSlot(c.dataSetId, c.pieceId)));
    const found: (Discovered & { metadata: string })[] = [];
    for (let i = 0; i < page.length; i++) {
      if (lengths[i] === 0n) continue;
      const { dataSetId, pieceId } = page[i]!;
      const keys: string[] = [];
      let metadata = '{}';
      let detail: string | null;
      try {
        const object = await readPiece(reader, dataSetId, pieceId, lengths[i]!, keys);
        metadata = JSON.stringify(object);
        const parsed = parsePiece(dataSetId, pieceId, object);
        detail = 'invalid' in parsed ? parsed.invalid : null;
      } catch (err) {
        if (!(err instanceof Unrepresentable)) throw err;
        result.unrepresentable += 1;
        detail = `discover: ${err.message}`;
      }
      found.push({ dataSetId, pieceId, keys, status: detail === null ? 'unchecked' : 'invalid', detail, metadata });
    }

    transaction(db, () => {
      for (const f of found) upsert({ dataSetId: f.dataSetId, pieceId: f.pieceId, metadata: f.metadata, invalid: f.detail ?? undefined });
    });
    result.pieces.push(...found.map(({ metadata: _, ...f }) => f));
    result.candidates += page.length;
    result.hits += found.length;

    const secs = (Date.now() - started) / 1000;
    const last = page[page.length - 1]!;
    log(
      `discover: read ${result.candidates} candidates in ${secs.toFixed(0)} s (${(result.candidates / secs).toFixed(1)} reads/s), at ${last.dataSetId}/${last.pieceId}, ${result.hits} hits`,
    );
  }
  return result;
}
