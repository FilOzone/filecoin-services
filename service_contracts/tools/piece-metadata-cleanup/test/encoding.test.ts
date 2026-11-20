import assert from 'node:assert/strict';
import { test } from 'node:test';
import { decodeOps, encodeOp, opSlots, type Op } from '../src/ops.ts';
import { dataSlot, decodeString, hex32, keysSlot, queueSlot, stringDataSlots, stringHead, valueSlots } from '../src/slots.ts';

const utf8 = (s: string) => new TextEncoder().encode(s);
const hex = (b: Uint8Array) => '0x' + Buffer.from(b).toString('hex');

// Golden bytes from `cast abi-encode --packed`, the layout of the Solidity test encoder in
// test/modules/FWSSPieceMetadataCleanupModule.t.sol.
const GOLDEN: [Op, string][] = [
  [{ kind: 0, dataSetId: 7, pieceId: 3, key: utf8('name') }, '0x00000007000003046e616d65'],
  [
    { kind: 1, dataSetId: 2 ** 24 - 1, pieceId: 0x010203, count: 4, key: utf8('x-trace-id-01234567') },
    '0x01ffffff0102030413782d74726163652d69642d3031323334353637',
  ],
  [{ kind: 2, dataSetId: 2 ** 24 - 1, pieceId: 0 }, '0x02ffffff000000'],
  [{ kind: 3, dataSetId: 5, pieceId: 9, index: 4 }, '0x0300000500000904'],
  [{ kind: 4, dataSetId: 300, count: 65535 }, '0x0400012cffff'],
  [{ kind: 5, dataSetId: 0x0a0b0c, pieceId: 2 ** 24 - 1, index: 2 }, '0x050a0b0cffffff02'],
];

test('encodes every op kind byte for byte like abi.encodePacked', () => {
  for (const [op, expected] of GOLDEN) assert.equal(hex(encodeOp(op)), expected, `kind ${op.kind}`);
  const batch = Buffer.concat(GOLDEN.map(([op]) => encodeOp(op)));
  assert.deepEqual(decodeOps(batch), GOLDEN.map(([op]) => op));
});

test('rejects ops the facet would revert on', () => {
  assert.throws(() => encodeOp({ kind: 3, dataSetId: 1, pieceId: 1, index: 5 }));
  assert.throws(() => encodeOp({ kind: 5, dataSetId: 1, pieceId: 1, index: 5 }));
  assert.throws(() => encodeOp({ kind: 1, dataSetId: 1, pieceId: 1, count: 5, key: utf8('k') }));
  assert.throws(() => encodeOp({ kind: 2, dataSetId: 2 ** 24, pieceId: 1 }));
  assert.throws(() => encodeOp({ kind: 2, dataSetId: 1, pieceId: 2 ** 24 }));
  assert.throws(() => encodeOp({ kind: 4, dataSetId: 2 ** 24, count: 1 }));
  assert.throws(() => encodeOp({ kind: 4, dataSetId: 1, count: 65536 }));
});

// Golden slots from `cast index` and `cast keccak`, which implement Solidity's mapping and array rules.
test('computes the legacy slots Solidity uses', () => {
  const keys = keysSlot(7, 3);
  assert.equal(hex32(keys), '0x27770f7fbbdd1f8f51e1ce20019fb052db9a585c1ab06e0e2316f136ce48d5b9');
  assert.equal(hex32(dataSlot(keys)), '0xf1d9ede062516de4ada2b7e47fe93076443bd4b9daf380879f0c2fc473c095dd');
  const keyData = opSlots({ kind: 5, dataSetId: 7, pieceId: 3, index: 1 });
  assert.deepEqual(keyData.map(hex32), ['0x83d3a24611f9424a3bb2800f29cd3a3605dd784188438a49ba1bc7991cf58737'], 'data slot of element 1');

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

test('decodes stored strings back to the bytes stringHead encoded', () => {
  // A long string's data slots: its bytes left-aligned in consecutive words, the last one zero-padded.
  const words = (b: Uint8Array) =>
    Array.from({ length: stringDataSlots(b.length) }, (_, i) => BigInt('0x' + Buffer.from(b.subarray(32 * i, 32 * i + 32)).toString('hex').padEnd(64, '0')));
  const values = ['', 'v', 'v'.repeat(31), 'v'.repeat(32), 'v'.repeat(33), 'v'.repeat(128), 'ż'.repeat(15) + 'x', '😀'.repeat(8), 'zażółć gęślą jaźń 鍵'];
  for (const value of values.map(utf8)) {
    assert.deepEqual(hex(decodeString(stringHead(value), words(value))), hex(value), `${value.length} bytes`);
  }

  assert.throws(() => decodeString(stringHead(utf8('a'.repeat(40))), []), /needs 2 data slots/);
  assert.throws(() => decodeString(31n, [0n]), /holds only 15 bytes/);
  assert.throws(() => decodeString(0x40n, []), /malformed short string head/, 'a short head of 32 bytes');
  assert.throws(() => decodeString(stringHead(utf8('ab')) | (1n << 8n), []), /malformed short string head/, 'a byte past the length');
});
