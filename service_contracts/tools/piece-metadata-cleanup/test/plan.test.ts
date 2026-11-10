import assert from 'node:assert/strict';
import { test } from 'node:test';
import { calldataBytes, cutBatches } from '../src/batches.ts';
import { batchCalldataOps, iterateOps, listBatches, openDb, opInserter, pieceUpserter, replaceQueues, setPieceStatus } from '../src/db.ts';
import { decodeOps, encodeOp, parsePiece, pieceOps, sortKey, type Op, type Piece, type PlannedOp } from '../src/ops.ts';
import { buildPlan } from '../src/plan.ts';
import { sendBatches } from '../src/send.ts';
import type { PublicClient } from 'viem';

const NETWORK = { name: 'test', fwss: '0x0000000000000000000000000000000000000001' };

function piece(metadata: Record<string, string>, dataSetId = 1, pieceId = 2): Piece {
  const parsed = parsePiece(dataSetId, pieceId, metadata);
  assert.ok('piece' in parsed, JSON.stringify(parsed));
  return parsed.piece;
}

function invalid(dataSetId: number, pieceId: number, metadata: unknown): boolean {
  return 'invalid' in parsePiece(dataSetId, pieceId, metadata);
}

test('rejects pieces the facet cannot fully clear, measuring UTF-8 bytes', () => {
  assert.ok(!invalid(2 ** 40 - 1, 2 ** 40 - 1, { k: 'v' }));
  assert.ok(invalid(2 ** 40, 0, { k: 'v' }));
  assert.ok(invalid(0, 2 ** 40, { k: 'v' }));

  assert.ok(!invalid(1, 1, { ['k'.repeat(31)]: 'v' }));
  assert.ok(invalid(1, 1, { ['k'.repeat(32)]: 'v' }), 'a 32-byte key has data slots the facet cannot clear');
  assert.ok(!invalid(1, 1, { ['ą'.repeat(15)]: 'v' }));
  assert.ok(invalid(1, 1, { ['ą'.repeat(16)]: 'v' }), '16 characters, 32 bytes');
  assert.ok(invalid(1, 1, { '': 'v' }));

  assert.ok(!invalid(1, 1, { k: 'v'.repeat(128) }));
  assert.ok(invalid(1, 1, { k: 'v'.repeat(129) }), '129 bytes need a fifth data slot');
  assert.ok(invalid(1, 1, { k: 'ż'.repeat(65) }), '65 characters, 130 bytes');

  assert.ok(!invalid(1, 1, { a: '1', b: '2', c: '3', d: '4', e: '5' }));
  assert.ok(invalid(1, 1, { a: '1', b: '2', c: '3', d: '4', e: '5', f: '6' }));
  assert.ok(invalid(1, 1, { k: 1 }));
  assert.ok(invalid(1, 1, {}));
});

test('emits the ops a piece needs for each value length', () => {
  const lengths = [0, 1, 31, 32, 33, 64, 65, 128];
  const ops = new Map<string, Op[]>();
  for (const length of lengths) {
    const p = piece({ k: 'x'.repeat(length) });
    ops.set(String(length), pieceOps(p));
  }
  const summary = (list: Op[]) => list.map((o) => (o.kind === 1 ? `1x${o.count}` : String(o.kind))).sort().join(',');
  assert.equal(summary(ops.get('0')!), '2,3', 'an empty value has no head slot, but its key has an element');
  assert.equal(summary(ops.get('1')!), '0,2,3');
  assert.equal(summary(ops.get('31')!), '0,2,3');
  assert.equal(summary(ops.get('32')!), '0,1x1,2,3');
  assert.equal(summary(ops.get('33')!), '0,1x2,2,3');
  assert.equal(summary(ops.get('64')!), '0,1x2,2,3');
  assert.equal(summary(ops.get('65')!), '0,1x3,2,3');
  assert.equal(summary(ops.get('128')!), '0,1x4,2,3');

  const five = pieceOps(piece({ a: '', b: 'x', c: 'y', d: 'z', e: 'w' }));
  assert.deepEqual(five.filter((o) => o.kind === 3).map((o) => (o.kind === 3 ? o.index : -1)), [0, 1, 2, 3, 4]);
});

test('stores and reads ops in numeric slot order, queue pops first', () => {
  const db = openDb(':memory:', NETWORK);
  const op = encodeOp({ kind: 2, dataSetId: 1, pieceId: 1 });
  const slots = [1n << 255n, 1n, (1n << 248n) + 5n, 0xff00n, 0x01_00n, (1n << 256n) - 1n, 2n ** 64n];
  const insert = opInserter(db);
  for (const s of slots) insert({ sortKey: sortKey(1, s), op });
  insert({ sortKey: sortKey(0, (1n << 256n) - 1n), op: encodeOp({ kind: 4, dataSetId: 1, count: 1 }) });

  const read = [...iterateOps(db)].map((o) => [o.sortKey[0], BigInt('0x' + Buffer.from(o.sortKey.subarray(1)).toString('hex'))]);
  assert.deepEqual(read, [[0, (1n << 256n) - 1n], ...[...slots].sort((a, b) => (a < b ? -1 : 1)).map((s) => [1, s])]);
});

// ValueHead ops of the given byte sizes, in slot order.
function plannedOps(sizes: number[]): PlannedOp[] {
  return sizes.map((size, i) => ({
    sortKey: sortKey(1, BigInt(i)),
    op: encodeOp({ kind: 0, dataSetId: 1, pieceId: i, key: new Uint8Array(size - 12).fill(0x61) }),
  }));
}

test('cuts batches at the calldata and op limits', () => {
  // 30-byte ops: two fit in 4 + 64 + 64 = 132 calldata bytes, three need 164.
  const ops = plannedOps([30, 30, 30, 30, 30]);
  assert.equal(calldataBytes(60), 132);
  assert.deepEqual([...cutBatches(ops, { maxCalldataBytes: 132, maxOps: 100 })].map((b) => b.opCount), [2, 2, 1]);
  assert.deepEqual([...cutBatches(ops, { maxCalldataBytes: 164, maxOps: 100 })].map((b) => b.opCount), [3, 2]);
  assert.deepEqual([...cutBatches(ops, { maxCalldataBytes: 60_000, maxOps: 2 })].map((b) => b.opCount), [2, 2, 1]);
  assert.throws(() => [...cutBatches(ops, { maxCalldataBytes: 99, maxOps: 100 })], 'one op over the limit');

  const pops = [{ sortKey: sortKey(0, 0n), op: encodeOp({ kind: 4, dataSetId: 1, count: 3 }) }];
  const mixed = [...cutBatches([...pops, ...plannedOps([12, 12])], { maxCalldataBytes: 60_000, maxOps: 5 })];
  assert.deepEqual(mixed.map((b) => [b.phase, b.opCount, b.weight]), [[0, 1, 3], [1, 2, 2]], 'pops weigh by count and get their own batch');

  assert.throws(() => [...cutBatches([...ops].reverse(), { maxCalldataBytes: 60_000, maxOps: 100 })], 'unsorted input');
});

test('plans queues first, plans clean pieces too, skips mismatched pieces, and covers every op once', () => {
  const db = openDb(':memory:', NETWORK);
  const upsert = pieceUpserter(db);
  const metadata: Record<string, Record<string, string>> = {
    '1/0': { name: 'a.bin', trace: 'x'.repeat(100) },
    '1/1': { name: 'b.bin' },
    '2/0': { a: '', b: 'y'.repeat(32), c: 'z', d: 'w', e: 'v' },
    '2/1': { name: 'clean' },
    '2/2': { name: 'mismatch' },
  };
  for (const [id, m] of Object.entries(metadata)) {
    const [dataSetId, pieceId] = id.split('/').map(Number) as [number, number];
    upsert({ dataSetId, pieceId, metadata: JSON.stringify(m) });
  }
  upsert({ dataSetId: 3, pieceId: 0, metadata: JSON.stringify({ ['k'.repeat(40)]: 'v' }), invalid: 'key too long' });
  for (const id of ['1/0', '1/1', '2/0']) setPieceStatus(db)(...(id.split('/').map(Number) as [number, number]), 'match', null);
  setPieceStatus(db)(2, 1, 'clean', null);
  setPieceStatus(db)(2, 2, 'mismatch', 'keys length 2, expected 1');

  assert.throws(() => buildPlan(db, { maxCalldataBytes: 200, maxOps: 4 }), /queues/);
  replaceQueues(db, [{ dataSetId: 9, length: 10 }], 'test');
  const totals = buildPlan(db, { maxCalldataBytes: 200, maxOps: 4 });

  const expected = ['1/0', '1/1', '2/0', '2/1'].flatMap((id) => pieceOps(piece(metadata[id]!, ...(id.split('/').map(Number) as [number, number]))));
  const batches = listBatches(db);
  const sent = batches.flatMap((b) => decodeOps(batchCalldataOps(db, b)));
  const pops = sent.filter((o) => o.kind === 4);

  assert.deepEqual(batches.slice(0, 3).map((b) => b.phase), [0, 0, 0], 'pops of up to 4 entries come first');
  assert.ok(batches.slice(3).every((b) => b.phase === 1));
  assert.equal(pops.reduce((n, o) => n + (o.kind === 4 ? o.count : 0), 0), 10);
  assert.equal(sent.length - pops.length, expected.length);
  const key = (o: Op) => Buffer.from(encodeOp(o)).toString('hex');
  assert.deepEqual(sent.filter((o) => o.kind !== 4).map(key).sort(), expected.map(key).sort());
  assert.deepEqual([totals.pieces, totals.unchecked], [4, 0]);
  assert.deepEqual(totals.skipped, { invalid: 1, mismatch: 1 });
  for (const b of batches) assert.ok(calldataBytes(b.ops_bytes) <= 200 && b.weight <= 4);
});

test('plans only checked pieces unless told otherwise', () => {
  const db = openDb(':memory:', NETWORK);
  const upsert = pieceUpserter(db);
  upsert({ dataSetId: 1, pieceId: 0, metadata: JSON.stringify({ name: 'a.bin' }) });
  upsert({ dataSetId: 1, pieceId: 1, metadata: JSON.stringify({ name: 'b.bin' }) });
  setPieceStatus(db)(1, 0, 'match', null);
  replaceQueues(db, [], 'test');
  const limits = { maxCalldataBytes: 60_000, maxOps: 1500 };

  assert.throws(() => buildPlan(db, limits), /1 pieces are unchecked/);
  assert.equal(listBatches(db).length, 0);

  const allowed = buildPlan(db, limits, { allowUnchecked: true });
  assert.deepEqual([allowed.pieces, allowed.unchecked], [2, 1]);

  setPieceStatus(db)(1, 1, 'mismatch', 'wrong key');
  const checked = buildPlan(db, limits);
  assert.deepEqual([checked.pieces, checked.unchecked, checked.ops], [1, 0, 3]);
});

test('a plan that fails keeps the earlier plan, and send refuses a state file without batches', async () => {
  const db = openDb(':memory:', NETWORK);
  const noClient = {} as PublicClient;
  const address = NETWORK.fwss as `0x${string}`;
  const opts = { to: address, from: address, chainId: 1, dryRun: true };
  await assert.rejects(sendBatches(db, noClient, opts), /no batches; run plan first/);

  pieceUpserter(db)({ dataSetId: 1, pieceId: 0, metadata: JSON.stringify({ name: 'a.bin' }) });
  setPieceStatus(db)(1, 0, 'match', null);
  replaceQueues(db, [{ dataSetId: 1, length: 2 }], 'test');
  const limits = { maxCalldataBytes: 60_000, maxOps: 1500 };
  buildPlan(db, limits);
  const before = listBatches(db);
  assert.equal(before.length, 2);

  // The stored row no longer parses, so the rebuild throws after it deleted the old plan.
  db.prepare("UPDATE pieces SET metadata = '{}'").run();
  assert.throws(() => buildPlan(db, limits), /became invalid/);
  assert.deepEqual(listBatches(db), before);
  assert.equal([...iterateOps(db)].length, 4);
});
