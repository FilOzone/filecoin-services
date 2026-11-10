// End-to-end run on a local anvil against FWSSPieceMetadataCleanupHarness, which seeds the legacy mappings through
// Solidity, so the slots come from the compiler. Needs `anvil` on PATH and `forge build` output in service_contracts/out.
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { after, before, test } from 'node:test';
import { gunzipSync } from 'node:zlib';
import {
  createWalletClient,
  encodeAbiParameters,
  http,
  keccak256,
  toFunctionSelector,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { foundry } from 'viem/chains';
import { checkPieces } from '../../src/check.ts';
import { listBatches, openDb, pieceUpserter, setPieceStatus, statusCounts } from '../../src/db.ts';
import { buildPlan } from '../../src/plan.ts';
import { refreshQueues } from '../../src/queues.ts';
import { sendBatches, type SendOptions } from '../../src/send.ts';
import { publicClient, rpcStorageReader } from '../../src/storage.ts';
import { verifyPlan } from '../../src/verify.ts';

const ARTIFACT = new URL('../../../../out/FWSSPieceMetadataCleanupHarness.sol/FWSSPieceMetadataCleanupHarness.json', import.meta.url);
const NETWORK = { name: 'anvil', fwss: '' };
const MAX_ID = 2 ** 40 - 1;
const RAIL_DATA_SET = 1;
const RAIL_ID = 42n;
const NO_RAIL_DATA_SET = 7;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const repeat = (s: string, n: number) => s.repeat(n);
const utf8 = (s: string) => new TextEncoder().encode(s);

// [dataSetId, pieceId, metadata on chain (keys pushed in this order), metadata in the tool's table or null to copy]
type Seed = [number, number, Record<string, string> | null, Record<string, string> | null];
const PIECES: Seed[] = [
  [RAIL_DATA_SET, 0, { name: 'index.ts' }, null],
  [RAIL_DATA_SET, 1, { a: '', b: 'x', c: repeat('y', 31), d: repeat('z', 32), e: repeat('w', 33) }, null],
  [RAIL_DATA_SET, 2, { note: repeat('q', 64), trace: repeat('ż', 64) }, null],
  [RAIL_DATA_SET, 3, { zażółć: 'gęślą jaźń', 鍵: repeat('😀', 8) }, null],
  [RAIL_DATA_SET, 4, { k1: repeat('a', 128), k2: repeat('b', 100), k3: repeat('c', 65), k4: repeat('d', 96) }, null],
  [NO_RAIL_DATA_SET, 5, { name: repeat('x', 31), size: '1' }, null],
  [MAX_ID, MAX_ID, { [repeat('k', 31)]: repeat('v', 128) }, null],
  // Not on chain any more: the old removal queue deleted it.
  [NO_RAIL_DATA_SET, 6, null, { name: 'gone.bin' }],
  // The indexer is wrong: a shorter value (2 data slots for 3) and a wrong key.
  [NO_RAIL_DATA_SET, 8, { name: repeat('n', 70) }, { name: repeat('n', 40) }],
  [NO_RAIL_DATA_SET, 9, { name: 'file.bin' }, { nam: 'file.bin' }],
];
const QUEUES: [number, number][] = [
  [RAIL_DATA_SET, 20],
  [NO_RAIL_DATA_SET, 3],
];
const LIMITS = { maxCalldataBytes: 400, maxOps: 8 };

let anvil: ChildProcess;
let url: string;
let client: PublicClient;
let harness: Address;
let abi: Abi;

async function rpc<T>(method: string, params: unknown[] = []): Promise<T> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const json = (await res.json()) as { result?: T; error?: unknown };
  if (json.error) throw new Error(`${method}: ${JSON.stringify(json.error)}`);
  return json.result as T;
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as { port: number };
      server.close(() => resolve(port));
    });
    server.on('error', reject);
  });
}

// Every non-zero slot of the harness, from anvil's state dump: no slot formula involved.
async function storageDump(): Promise<Map<bigint, bigint>> {
  const dump = await rpc<Hex>('anvil_dumpState');
  const state = JSON.parse(gunzipSync(Buffer.from(dump.slice(2), 'hex')).toString()) as {
    accounts: Record<string, { storage: Record<string, string> }>;
  };
  const entry = Object.entries(state.accounts).find(([a]) => a.toLowerCase() === harness.toLowerCase());
  assert.ok(entry, 'harness account in the dump');
  const slots = new Map<bigint, bigint>();
  for (const [slot, value] of Object.entries(entry[1].storage)) if (BigInt(value) !== 0n) slots.set(BigInt(slot), BigInt(value));
  return slots;
}

async function harnessRead<T>(functionName: string, args: unknown[]): Promise<T> {
  return (await client.readContract({ address: harness, abi, functionName, args })) as T;
}

async function nonceOf(address: Address, blockTag: 'latest' | 'pending' = 'latest'): Promise<number> {
  return client.getTransactionCount({ address, blockTag });
}

before(async () => {
  if (!existsSync(ARTIFACT)) throw new Error(`missing ${ARTIFACT.pathname}; run forge build in service_contracts first`);
  const artifact = JSON.parse(readFileSync(ARTIFACT, 'utf8')) as { abi: Abi; bytecode: { object: Hex } };
  abi = artifact.abi;

  const port = await freePort();
  url = `http://127.0.0.1:${port}`;
  anvil = spawn('anvil', ['--port', String(port), '--silent'], { stdio: 'ignore' });
  for (let i = 0; ; i++) {
    try {
      await rpc('eth_chainId');
      break;
    } catch (err) {
      if (i > 100) throw err;
      await sleep(100);
    }
  }
  client = publicClient(url, foundry);

  const seeder = privateKeyToAccount(generatePrivateKey());
  await rpc('anvil_setBalance', [seeder.address, '0x56bc75e2d63100000']);
  const wallet = createWalletClient({ account: seeder, chain: foundry, transport: http(url) });
  const deployHash = await wallet.deployContract({ abi, bytecode: artifact.bytecode.object });
  harness = (await client.waitForTransactionReceipt({ hash: deployHash })).contractAddress!;
  NETWORK.fwss = harness;

  const write = async (functionName: string, args: unknown[]) => {
    const hash = await wallet.writeContract({ address: harness, abi, functionName, args });
    assert.equal((await client.waitForTransactionReceipt({ hash })).status, 'success', functionName);
  };
  for (const [dataSetId, pieceId, onChain] of PIECES) {
    if (onChain) await write('seedPieceMetadata', [BigInt(dataSetId), BigInt(pieceId), Object.keys(onChain), Object.values(onChain)]);
  }
  for (const [dataSetId, length] of QUEUES) {
    await write('seedRemovalQueue', [BigInt(dataSetId), Array.from({ length }, (_, i) => BigInt(i + 100))]);
  }
  await write('setPdpRailId', [BigInt(RAIL_DATA_SET), RAIL_ID]);
});

after(() => {
  anvil?.kill();
});

test('check, queues, plan, send with resume, verify leave only the non-legacy state', async () => {
  const db = openDb(':memory:', NETWORK);
  const reader = rpcStorageReader({ rpcUrl: url, chain: foundry, address: harness, batchSize: 7, concurrency: 3, requestsPerSecond: 0 });
  const before = await storageDump();
  assert.ok(before.size > 80, `seeded storage visible in the dump (${before.size} slots)`);

  // The tool's table: the indexer view, keys in another order than on chain, which must not matter.
  const upsert = pieceUpserter(db);
  for (const [dataSetId, pieceId, onChain, table] of PIECES) {
    const metadata = Object.fromEntries(Object.entries((table ?? onChain)!).reverse());
    upsert({ dataSetId, pieceId, metadata: JSON.stringify(metadata), removed: false });
  }

  await checkPieces(db, reader, { all: true, pageSize: 4 });
  const status = (dataSetId: number, pieceId: number) =>
    (db.prepare('SELECT status FROM pieces WHERE data_set_id = ? AND piece_id = ?').get(dataSetId, pieceId) as { status: string }).status;
  assert.deepEqual(statusCounts(db), { match: 7, clean: 1, mismatch: 2 });
  assert.equal(status(NO_RAIL_DATA_SET, 6), 'clean');
  assert.equal(status(NO_RAIL_DATA_SET, 8), 'mismatch', 'wrong value length');
  assert.equal(status(NO_RAIL_DATA_SET, 9), 'mismatch', 'wrong key');

  const queues = await refreshQueues(db, reader, 10, 'anvil');
  assert.deepEqual(queues, QUEUES.map(([dataSetId, length]) => ({ dataSetId, length })));

  // Plan the mismatched pieces anyway, to show what that leaves behind.
  setPieceStatus(db)(NO_RAIL_DATA_SET, 8, 'match', null);
  setPieceStatus(db)(NO_RAIL_DATA_SET, 9, 'match', null);
  const plan = buildPlan(db, LIMITS);
  assert.equal(plan.opsByKind.PopQueue, 4, 'the queue of 20 needs three pops of at most 8');
  const batches = listBatches(db);
  assert.ok(batches.length >= 10, `${batches.length} batches`);

  // Before sending, verify reads every planned slot and queue and finds each one set, except the head of the wrong
  // key, which never existed.
  const unsent = await verifyPlan(db, reader, { all: true, pageSize: 5 });
  assert.equal(unsent.queues, QUEUES.length);
  assert.equal(unsent.slots, plan.metadataSlots + QUEUES.length);
  assert.equal(unsent.residueCount, unsent.slots - 1);
  const sampled = await verifyPlan(db, reader, { sample: 1_000_000 });
  assert.deepEqual([sampled.slots, sampled.residueCount], [unsent.slots, unsent.residueCount], 'a sample covering every op reads the same');

  const sender = privateKeyToAccount(generatePrivateKey());
  await rpc('anvil_setBalance', [sender.address, '0x56bc75e2d63100000']);
  const opts: SendOptions = { to: harness, from: sender.address, chainId: foundry.id, account: sender, pollMs: 50, receiptTimeoutMs: 20_000 };

  const dry = await sendBatches(db, client, { ...opts, account: undefined, dryRun: true });
  assert.equal(dry.estimated, batches.length);
  assert.equal(dry.failure, undefined);
  assert.equal(await nonceOf(sender.address), 0, 'a dry run sends nothing');

  // A pilot of 3 batches that first waits out a base fee above its limit.
  await rpc('anvil_setNextBlockBaseFeePerGas', ['0x174876e800']); // 100 gwei
  await rpc('evm_mine');
  const pilot = sendBatches(db, client, { ...opts, maxBatches: 3, maxBaseFee: 50_000_000_000n });
  await sleep(500);
  assert.equal(await nonceOf(sender.address, 'pending'), 0, 'nothing sent while the base fee is above the limit');
  await rpc('anvil_setNextBlockBaseFeePerGas', ['0x3b9aca00']); // 1 gwei
  await rpc('evm_mine');
  const first = await pilot;
  assert.equal(first.failure, undefined);
  assert.equal(first.done, 3);
  assert.deepEqual(listBatches(db).slice(0, 4).map((b) => b.status), ['done', 'done', 'done', 'planned']);
  assert.equal(await nonceOf(sender.address), 3);

  // Interrupted run: blocks stop, so two messages go out and their receipts never come.
  await rpc('evm_setAutomine', [false]);
  const stalled = await sendBatches(db, client, { ...opts, maxInflight: 2, receiptTimeoutMs: 1000 });
  assert.match(stalled.failure ?? '', /no receipt/);
  assert.deepEqual(listBatches(db).slice(3, 6).map((b) => b.status), ['sent', 'sent', 'planned'], 'at most 2 in flight, recorded as sent');
  assert.equal(await nonceOf(sender.address, 'pending'), 5);

  // A crash between recording a message and broadcasting it: recorded as sent, never seen by the node.
  const lost = listBatches(db)[5]!;
  db.prepare("UPDATE batches SET status = 'sent' WHERE id = ?").run(lost.id);
  db.prepare("INSERT INTO txs (hash, batch_id, sender, nonce, gas_limit, max_fee_per_gas, sent_at) VALUES (?, ?, ?, 5, '0', '0', 0)").run(
    keccak256(utf8('never broadcast')),
    lost.id,
    sender.address,
  );

  // Mine whatever is pending, after giving the sender time to fill its in-flight window, and record the largest pool.
  let mining = true;
  let maxPending = 0;
  const miner = (async () => {
    while (mining) {
      const pending = Number(BigInt((await rpc<{ pending: Hex }>('txpool_status')).pending));
      if (pending > 0) {
        await sleep(300);
        maxPending = Math.max(maxPending, Number(BigInt((await rpc<{ pending: Hex }>('txpool_status')).pending)));
        await rpc('evm_mine');
      }
      await sleep(20);
    }
  })();
  const resumed = await sendBatches(db, client, { ...opts, maxInflight: 2 });
  mining = false;
  await miner;
  await rpc('evm_setAutomine', [true]);

  assert.equal(resumed.failure, undefined);
  assert.equal(resumed.remaining, 0);
  assert.equal(maxPending, 2, 'the in-flight window is used and never exceeded');
  assert.ok(listBatches(db).every((b) => b.status === 'done'));
  const txs = db.prepare('SELECT batch_id, status FROM txs ORDER BY nonce').all() as { batch_id: number; status: string }[];
  assert.deepEqual(
    txs.filter((t) => t.status === 'success').map((t) => t.batch_id).sort((a, b) => a - b),
    batches.map((b) => b.id),
    'one successful message per batch',
  );
  assert.deepEqual(txs.filter((t) => t.status === 'dropped').map((t) => t.batch_id), [lost.id]);
  assert.equal(await nonceOf(sender.address), batches.length, 'no batch was sent twice');

  const verified = await verifyPlan(db, reader, { all: true, pageSize: 5 });
  assert.equal(verified.residueCount, 0, JSON.stringify(verified.residue, (_, v) => (typeof v === 'bigint' ? v.toString(16) : v)));
  assert.equal(verified.queues, 2);

  // The dump holds the data set info of the railed data set, its flag, and what the wrong indexer rows left: verify
  // cannot see those, because the plan never knew their slots.
  const info = await harnessRead<bigint>('dataSetInfoSlot', [BigInt(RAIL_DATA_SET)]);
  const wrongKeyHead = await harnessRead<bigint>('valueSlot', [BigInt(NO_RAIL_DATA_SET), 9n, 'name']);
  const longHead = await harnessRead<bigint>('valueSlot', [BigInt(NO_RAIL_DATA_SET), 8n, 'name']);
  const longData = BigInt(keccak256(encodeAbiParameters([{ type: 'uint256' }], [longHead])));
  const shortString = (s: string) => BigInt('0x' + Buffer.from(s).toString('hex').padEnd(62, '0') + (s.length * 2).toString(16).padStart(2, '0'));
  const expected = new Map<bigint, bigint>([
    [info, RAIL_ID],
    [info + 10n, 1n << 192n], // pieceRemovalsPending, packed above two uint96 fields
    [wrongKeyHead, shortString('file.bin')],
    [longData + 2n, BigInt('0x' + Buffer.from(repeat('n', 6)).toString('hex').padEnd(64, '0'))],
  ]);
  const hex = (m: Map<bigint, bigint>) => [...m].map(([k, v]) => [k.toString(16), v.toString(16)]).sort();
  assert.deepEqual(hex(await storageDump()), hex(expected));
  assert.equal(await harnessRead<boolean>('pieceRemovalsPending', [BigInt(RAIL_DATA_SET)]), true);
  assert.equal(await harnessRead<boolean>('pieceRemovalsPending', [BigInt(NO_RAIL_DATA_SET)]), false, 'no rail, no flag');
});

test('a batch that reverts stops the run with its id and revert data', async () => {
  const db = openDb(':memory:', NETWORK);
  const sender = privateKeyToAccount(generatePrivateKey());
  await rpc('anvil_setBalance', [sender.address, '0x56bc75e2d63100000']);
  const opts: SendOptions = { to: harness, from: sender.address, chainId: foundry.id, account: sender, pollMs: 50, receiptTimeoutMs: 20_000 };
  const insertOp = db.prepare('INSERT INTO ops (sort_key, op) VALUES (?, ?)');
  const insertBatch = db.prepare('INSERT INTO batches (id, phase, first_key, last_key, op_count, weight, ops_bytes) VALUES (?, 1, ?, ?, 1, 1, ?)');
  const addBatch = (id: number, op: Uint8Array) => {
    const key = Buffer.alloc(33);
    key[0] = 1;
    key[32] = id;
    insertOp.run(key, op);
    insertBatch.run(id, key, key, op.length);
  };

  // A KeysLength op of an unknown kind 9; then a valid batch that must not go out.
  addBatch(1, Buffer.from('090000000001000000000a', 'hex'));
  addBatch(2, Buffer.from('020000000001000000000a', 'hex'));
  const estimateRevert = await sendBatches(db, client, opts);
  assert.match(estimateRevert.failure ?? '', /^batch 1: estimate failed: revert data 0x/);
  assert.ok(estimateRevert.failure!.includes(toFunctionSelector('UnknownCleanupOp(uint256,uint256)')));
  assert.equal(await nonceOf(sender.address), 0);

  // Out of gas on chain: the receipt reverts and the run names the batch.
  db.exec('DELETE FROM ops; DELETE FROM batches;');
  addBatch(1, Buffer.from('020000000001000000000a', 'hex'));
  addBatch(2, Buffer.from('020000000001000000000b', 'hex'));
  const outOfGas = await sendBatches(db, client, { ...opts, gasMultiplier: 0.9, maxInflight: 1 });
  assert.match(outOfGas.failure ?? '', /^batch 1: reverted in 0x[0-9a-f]{64} \(gas used \d+ of \d+\); replay: /);
  assert.deepEqual(listBatches(db).map((b) => b.status), ['reverted', 'planned']);
});
