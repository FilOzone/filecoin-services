import assert from 'node:assert/strict';
import { test } from 'node:test';
import { decodeOps, encodeOp, type Op } from '../src/ops.ts';
import { dataSlot, hex32, keysSlot, queueSlot, stringHead, valueSlots } from '../src/slots.ts';

const utf8 = (s: string) => new TextEncoder().encode(s);
const hex = (b: Uint8Array) => '0x' + Buffer.from(b).toString('hex');

// Golden bytes from `cast abi-encode --packed`, the layout of the Solidity test encoder in
// test/modules/FWSSPieceMetadataCleanupModule.t.sol.
const GOLDEN: [Op, string][] = [
  [{ kind: 0, dataSetId: 7, pieceId: 3, key: utf8('name') }, '0x0000000000070000000003046e616d65'],
  [
    { kind: 1, dataSetId: 2 ** 40 - 1, pieceId: 0x0102030405, count: 4, key: utf8('x-trace-id-01234567') },
    '0x01ffffffffff01020304050413782d74726163652d69642d3031323334353637',
  ],
  [{ kind: 2, dataSetId: 2 ** 40 - 1, pieceId: 0 }, '0x02ffffffffff0000000000'],
  [{ kind: 3, dataSetId: 5, pieceId: 9, index: 4 }, '0x030000000005000000000904'],
  [{ kind: 4, dataSetId: 300, count: 65535 }, '0x04000000012cffff'],
];

test('encodes every op kind byte for byte like abi.encodePacked', () => {
  for (const [op, expected] of GOLDEN) assert.equal(hex(encodeOp(op)), expected, `kind ${op.kind}`);
  const batch = Buffer.concat(GOLDEN.map(([op]) => encodeOp(op)));
  assert.deepEqual(decodeOps(batch), GOLDEN.map(([op]) => op));
});

test('rejects ops the facet would revert on', () => {
  assert.throws(() => encodeOp({ kind: 3, dataSetId: 1, pieceId: 1, index: 5 }));
  assert.throws(() => encodeOp({ kind: 1, dataSetId: 1, pieceId: 1, count: 5, key: utf8('k') }));
  assert.throws(() => encodeOp({ kind: 2, dataSetId: 2 ** 40, pieceId: 1 }));
  assert.throws(() => encodeOp({ kind: 4, dataSetId: 1, count: 65536 }));
});

// Golden slots from `cast index` and `cast keccak`, which implement Solidity's mapping and array rules.
test('computes the legacy slots Solidity uses', () => {
  const keys = keysSlot(7, 3);
  assert.equal(hex32(keys), '0x27770f7fbbdd1f8f51e1ce20019fb052db9a585c1ab06e0e2316f136ce48d5b9');
  assert.equal(hex32(dataSlot(keys)), '0xf1d9ede062516de4ada2b7e47fe93076443bd4b9daf380879f0c2fc473c095dd');

  const value = valueSlots(7, 3);
  assert.equal(hex32(value(utf8('name'))), '0xbf1ad8ec7a71d6899e2798d7c1921efeb15926878880c9952264258de96b4224');
  assert.equal(hex32(dataSlot(value(utf8('name')))), '0xc66cd03e8da166d92ac1985cf2d30367b2982c366ebce72def6a119f037215fb');
  assert.equal(hex32(value(utf8('zażółć'))), '0xbeb2359c47192e6aed2c629da3e91b6f235d7e833f5ed427a032708d04595aa5');

  assert.equal(hex32(queueSlot(7)), '0x5c9294642c77fdf0ce4b0f45159c977165b1ec2ef3bb94ee3e2a496634c781e8');
  assert.equal(hex32(dataSlot(queueSlot(7))), '0x4fad2066acfdedbd7d0174241cc1d2f71022b4992ae35321a5ba73efbaff8d1a');
});

test('encodes string heads like Solidity storage', () => {
  assert.equal(hex32(stringHead(utf8('index.ts'))), '0x696e6465782e7473000000000000000000000000000000000000000000000010');
  assert.equal(hex32(stringHead(utf8('a'.repeat(31)))), '0x' + '61'.repeat(31) + '3e');
  assert.equal(stringHead(utf8('a'.repeat(32))), 65n);
  assert.equal(stringHead(utf8('ż'.repeat(20))), 81n, '40 UTF-8 bytes, 20 characters');
});
