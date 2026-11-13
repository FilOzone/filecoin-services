import assert from 'node:assert/strict';
import { test } from 'node:test';
import { markSendStarted, openDb, replaceLegacyRanges } from '../src/db.ts';
import { candidates, discoverPieces } from '../src/discover.ts';

const NETWORK = { name: 'test', fwss: '0x0000000000000000000000000000000000000001' };

test('candidates are the ids without a row up to the largest legacy id plus the tail', () => {
  const known: Record<number, number[]> = { 0: [0, 2, 3, 9], 2: [1, 4] };
  const ids = [...candidates(4, new Map([[0, 3], [2, 1]]), 2, (id) => known[id] ?? [])].map((c) => `${c.dataSetId}/${c.pieceId}`);
  assert.deepEqual(ids, [
    // ids 0..3 plus a tail of 2; 9 is known and past the end
    '0/1',
    '0/4',
    '0/5',
    // no range: the tail only
    '1/0',
    '1/1',
    // ids 0..1 plus the tail; 4 is known
    '2/0',
    '2/2',
    '2/3',
    '3/0',
    '3/1',
  ]);

  assert.deepEqual([...candidates(2, new Map([[0, 1]]), 0, () => [])], [
    { dataSetId: 0, pieceId: 0 },
    { dataSetId: 0, pieceId: 1 },
  ]);
});

test('discover refuses without ranges and after a send, before reading', async () => {
  let reads = 0;
  const reader = {
    async read(slots: readonly bigint[]) {
      reads += slots.length;
      return slots.map(() => 0n);
    },
  };
  const db = openDb(':memory:', NETWORK);
  await assert.rejects(discoverPieces(db, reader, { dataSetIds: 3, tail: 2 }), /run fetch first/);

  replaceLegacyRanges(db, [{ dataSetId: 0, maxPieceId: 4 }]);
  const empty = await discoverPieces(db, reader, { dataSetIds: 3, tail: 2 });
  assert.deepEqual([empty.candidates, empty.hits, reads], [7 + 2 + 2, 0, 11]);

  markSendStarted(db);
  await assert.rejects(discoverPieces(db, reader, { dataSetIds: 3, tail: 2 }), /sending has started.*discover is only valid before/);
  assert.equal(reads, 11);
});
