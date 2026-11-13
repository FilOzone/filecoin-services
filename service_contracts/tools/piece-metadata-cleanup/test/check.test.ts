import assert from 'node:assert/strict';
import { test } from 'node:test';
import { checkPieces } from '../src/check.ts';
import { openDb, pieceUpserter, setPieceStatus, statusCounts } from '../src/db.ts';
import { addSlot, dataSlot, keysSlot, valueSlots } from '../src/slots.ts';
import type { StorageReader } from '../src/storage.ts';
import { verifyPlan } from '../src/verify.ts';

const NETWORK = { name: 'test', fwss: '0x0000000000000000000000000000000000000001' };
const utf8 = (s: string) => new TextEncoder().encode(s);

// A short string as Solidity stores it: bytes left-aligned, length * 2 in the low byte.
const short = (s: string) => BigInt('0x' + Buffer.from(s).toString('hex').padEnd(62, '0') + (utf8(s).length * 2).toString(16).padStart(2, '0'));
// "index.ts", written out once so the helper above is not the only source of an expected word.
const INDEX_TS = 0x696e6465782e7473000000000000000000000000000000000000000000000010n;
// 40 x "ż" is 80 bytes, a long string: its head holds 80 * 2 + 1.
const LONG_HEAD = 161n;

// Data set 5, written by hand: per piece the stored keys length, the key elements in push order and the value heads.
// The indexer view of each piece is in the test below.
function fakeChain(): StorageReader & { reads: number } {
  const storage = new Map<bigint, bigint>();
  const piece = (pieceId: number, keysLength: number, elements: string[], values: [string, bigint][]) => {
    storage.set(keysSlot(5, pieceId), BigInt(keysLength));
    elements.forEach((key, j) => storage.set(addSlot(dataSlot(keysSlot(5, pieceId)), j), short(key)));
    for (const [key, head] of values) storage.set(valueSlots(5, pieceId)(utf8(key)), head);
  };
  piece(0, 1, ['name'], [['name', INDEX_TS]]);
  piece(1, 2, ['empty', 'note'], [['note', LONG_HEAD]]);
  piece(2, 2, ['name', 'more'], [['name', INDEX_TS], ['more', short('x')]]);
  // Piece 3 was deleted by the old removal queue: nothing in storage.
  piece(10, 1, ['name'], [['name', INDEX_TS]]);
  piece(11, 1, ['name'], [['name', INDEX_TS]]);
  piece(12, 2, ['note', 'empty'], [['note', LONG_HEAD]]);
  piece(13, 2, ['kept', 'hidden'], [['kept', short('x')], ['hidden', short('legacy')]]);
  // Piece 14 is partly cleaned: its length and value head are zero, its key element is not.
  piece(14, 0, ['name'], []);

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
  const db = openDb(':memory:', NETWORK);
  const upsert = pieceUpserter(db);
  const indexer: [number, Record<string, string>][] = [
    [0, { name: 'index.ts' }],
    [1, { note: 'ż'.repeat(40), empty: '' }], // keys in another order than on chain
    [2, { name: 'index.ts' }], // storage has a second key
    [3, { name: 'gone.bin' }],
    [10, { name: 'index.t' }], // wrong value
    [11, { nam: 'index.ts' }], // wrong key
    [12, { note: 'ż'.repeat(41), empty: '' }], // wrong length of a long value
    [13, { kept: 'x', phantom: '' }], // same key count, and the value slot of the absent key reads zero as expected
    [14, { name: 'index.ts' }],
  ];
  for (const [pieceId, m] of indexer) upsert({ dataSetId: 5, pieceId, metadata: JSON.stringify(m) });

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
      [13, 'mismatch'],
      [14, 'mismatch'],
    ],
  );
  const detail = (pieceId: number) => rows.find((r) => r.piece_id === pieceId)!.detail!;
  assert.match(detail(2), /^keys length 2, expected 1$/);
  assert.match(detail(13), /^key elements lack "phantom" and hold 0x68696464656e0{50}0c instead$/);
  assert.match(detail(14), /^keys length 0, expected 1; value "name" at 0x[0-9a-f]{64} holds 0x0{64}, expected 0x696e/);

  const before = chain.reads;
  await checkPieces(db, chain, { all: true });
  assert.equal(chain.reads, before, 'a second run resumes past checked pieces');
  assert.deepEqual(statusCounts(db), { match: 2, mismatch: 6, clean: 1 });
});

test('check and verify take exactly one of sample and all', async () => {
  const db = openDb(':memory:', NETWORK);
  const chain = fakeChain();
  await assert.rejects(checkPieces(db, chain, { all: true, sample: 5 }), /exactly one/);
  await assert.rejects(checkPieces(db, chain, {}), /exactly one/);
  await assert.rejects(verifyPlan(db, chain, { all: true, sample: 5 }), /exactly one/);
  await assert.rejects(verifyPlan(db, chain, {}), /exactly one/);
  await assert.rejects(verifyPlan(db, chain, { all: true, done: true }), /exactly one/);
  assert.equal(chain.reads, 0);
});

test('a fetch rerun keeps a check result while the metadata is unchanged', () => {
  const db = openDb(':memory:', NETWORK);
  const upsert = pieceUpserter(db);
  const row = (pieceId: number) =>
    db.prepare('SELECT status, detail FROM pieces WHERE piece_id = ?').get(pieceId) as { status: string; detail: string | null };
  const first = JSON.stringify({ name: 'a.bin' });
  upsert({ dataSetId: 1, pieceId: 1, metadata: first });
  upsert({ dataSetId: 1, pieceId: 2, metadata: first });
  setPieceStatus(db)(1, 1, 'match', null);
  setPieceStatus(db)(1, 2, 'mismatch', 'keys length 2, expected 1');

  upsert({ dataSetId: 1, pieceId: 1, metadata: first });
  upsert({ dataSetId: 1, pieceId: 2, metadata: JSON.stringify({ name: 'a.bin', more: 'x' }) });

  assert.deepEqual({ ...row(1) }, { status: 'match', detail: null });
  assert.deepEqual({ ...row(2) }, { status: 'unchecked', detail: null }, 'new metadata needs a new check');
});
