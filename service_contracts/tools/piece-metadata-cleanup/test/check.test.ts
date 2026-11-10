import assert from 'node:assert/strict';
import { test } from 'node:test';
import { checkPieces } from '../src/check.ts';
import { openDb, pieceUpserter, statusCounts } from '../src/db.ts';
import { keysSlot, valueSlots } from '../src/slots.ts';
import type { StorageReader } from '../src/storage.ts';

const utf8 = (s: string) => new TextEncoder().encode(s);

// "index.ts" as Solidity stores a short string: bytes left-aligned, length * 2 = 0x10 in the low byte.
const INDEX_TS = 0x696e6465782e7473000000000000000000000000000000000000000000000010n;
// 40 x "ż" is 80 bytes, a long string: its head holds 80 * 2 + 1.
const LONG_HEAD = 161n;

// Data set 5, written by hand. The indexer view of each piece is in the test below.
function fakeChain(): StorageReader & { reads: number } {
  const storage = new Map<bigint, bigint>();
  const piece = (pieceId: number, keyCount: number, values: [string, bigint][]) => {
    storage.set(keysSlot(5, pieceId), BigInt(keyCount));
    for (const [key, head] of values) storage.set(valueSlots(5, pieceId)(utf8(key)), head);
  };
  piece(0, 1, [['name', INDEX_TS]]);
  piece(1, 2, [['note', LONG_HEAD]]);
  piece(2, 2, [['name', INDEX_TS]]);
  // Piece 3 was deleted by the old removal queue: nothing in storage.
  piece(10, 1, [['name', INDEX_TS]]);
  piece(11, 1, [['name', INDEX_TS]]);
  piece(12, 2, [['note', LONG_HEAD]]);

  const fake = {
    reads: 0,
    async read(slots: readonly bigint[]) {
      fake.reads += slots.length;
      return slots.map((s) => storage.get(s) ?? 0n);
    },
  };
  return fake;
}

test('classifies pieces as match, clean or mismatch against storage', async () => {
  const db = openDb(':memory:', { name: 'test', fwss: '0x0000000000000000000000000000000000000001' });
  const upsert = pieceUpserter(db);
  const indexer: [number, Record<string, string>][] = [
    [0, { name: 'index.ts' }],
    [1, { note: 'ż'.repeat(40), empty: '' }],
    [2, { name: 'index.ts' }], // storage has a second key
    [3, { name: 'gone.bin' }],
    [10, { name: 'index.t' }], // wrong value
    [11, { nam: 'index.ts' }], // wrong key
    [12, { note: 'ż'.repeat(41), empty: '' }], // wrong length of a long value
  ];
  for (const [pieceId, m] of indexer) upsert({ dataSetId: 5, pieceId, metadata: JSON.stringify(m), removed: false });

  const chain = fakeChain();
  await checkPieces(db, chain, { all: true, pageSize: 3 });

  const rows = db.prepare('SELECT piece_id, status, detail FROM pieces ORDER BY piece_id').all() as {
    piece_id: number;
    status: string;
    detail: string | null;
  }[];
  assert.deepEqual(
    rows.map((r) => [r.piece_id, r.status]),
    [
      [0, 'match'],
      [1, 'match'],
      [2, 'mismatch'],
      [3, 'clean'],
      [10, 'mismatch'],
      [11, 'mismatch'],
      [12, 'mismatch'],
    ],
  );
  assert.match(rows[2]!.detail!, /keys length 2, expected 1/);

  const before = chain.reads;
  await checkPieces(db, chain, { all: true });
  assert.equal(chain.reads, before, 'a second run resumes past checked pieces');
  assert.deepEqual(statusCounts(db), { match: 2, mismatch: 4, clean: 1 });
});
