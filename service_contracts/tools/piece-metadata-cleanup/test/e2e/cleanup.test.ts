// End-to-end runs on a local anvil against FWSSPieceMetadataCleanupHarness, which seeds the legacy mappings through
// Solidity, so the slots come from the compiler. Needs `anvil` on PATH and `forge build` output in service_contracts/out.
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { createServer } from 'node:net';
import type { DatabaseSync } from 'node:sqlite';
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
  type WalletClient,
} from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { filecoin, foundry } from 'viem/chains';
import { checkPieces } from '../../src/check.ts';
import { batchCalldataOps, listBatches, openDb, pieceUpserter, replaceQueues, setPieceStatus, statusCounts, type BatchRow } from '../../src/db.ts';
import { decodeOps, POP_QUEUE } from '../../src/ops.ts';
import { buildPlan } from '../../src/plan.ts';
import { refreshQueues } from '../../src/queues.ts';
import { sendBatches, type SendOptions } from '../../src/send.ts';
import { publicClient, rpcStorageReader } from '../../src/storage.ts';
import { verifyPlan } from '../../src/verify.ts';

const ARTIFACT = new URL('../../../../out/FWSSPieceMetadataCleanupHarness.sol/FWSSPieceMetadataCleanupHarness.json', import.meta.url);
const MAX_ID = 2 ** 40 - 1;
const RAIL_DATA_SET = 1;
const RAIL_ID = 42n;
const NO_RAIL_DATA_SET = 7;
const GWEI = 1_000_000_000n;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const repeat = (s: string, n: number) => s.repeat(n);

// [dataSetId, pieceId, metadata on chain (keys pushed in this order), metadata in the tool's table or null to copy]
type Seed = [number, number, Record<string, string> | null, Record<string, string> | null];
const MATCHING: Seed[] = [
  [RAIL_DATA_SET, 0, { name: 'index.ts' }, null],
  [RAIL_DATA_SET, 1, { a: '', b: 'x', c: repeat('y', 31), d: repeat('z', 32), e: repeat('w', 33) }, null],
  [RAIL_DATA_SET, 2, { note: repeat('q', 64), trace: repeat('ż', 64) }, null],
  [RAIL_DATA_SET, 3, { zażółć: 'gęślą jaźń', 鍵: repeat('😀', 8) }, null],
  [RAIL_DATA_SET, 4, { k1: repeat('a', 128), k2: repeat('b', 100), k3: repeat('c', 65), k4: repeat('d', 96) }, null],
  [NO_RAIL_DATA_SET, 5, { name: repeat('x', 31), size: '1' }, null],
  [MAX_ID, MAX_ID, { [repeat('k', 31)]: repeat('v', 128) }, null],
];
const PIECES: Seed[] = [
  ...MATCHING,
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
let wallet: WalletClient;
let abi: Abi;
let bytecode: Hex;

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

// Every non-zero slot of a harness, from anvil's state dump: no slot formula involved.
async function storageDump(harness: Address): Promise<Map<bigint, bigint>> {
  const dump = await rpc<Hex>('anvil_dumpState');
  const state = JSON.parse(gunzipSync(Buffer.from(dump.slice(2), 'hex')).toString()) as {
    accounts: Record<string, { storage?: Record<string, string> }>;
  };
  const entry = Object.entries(state.accounts).find(([a]) => a.toLowerCase() === harness.toLowerCase());
  assert.ok(entry, 'harness account in the dump');
  const slots = new Map<bigint, bigint>();
  for (const [slot, value] of Object.entries(entry[1].storage ?? {})) if (BigInt(value) !== 0n) slots.set(BigInt(slot), BigInt(value));
  return slots;
}

const hex = (m: Map<bigint, bigint>) => [...m].map(([k, v]) => [k.toString(16), v.toString(16)]).sort();

async function nonceOf(address: Address, blockTag: 'latest' | 'pending' = 'latest'): Promise<number> {
  return client.getTransactionCount({ address, blockTag });
}

// A fresh harness with the seeds written through Solidity, the tool's table filled with the indexer view of them
// (keys in another order than on chain, which must not matter), and a funded sender.
async function setup(pieces: Seed[], queues: [number, number][]) {
  // A test that failed while blocks were stopped must not stall the ones after it.
  await rpc('evm_setAutomine', [true]);

  const deployHash = await wallet.deployContract({ abi, bytecode, account: wallet.account!, chain: foundry });
  const harness = (await client.waitForTransactionReceipt({ hash: deployHash })).contractAddress!;
  const write = async (functionName: string, args: unknown[]) => {
    const hash = await wallet.writeContract({ address: harness, abi, functionName, args, account: wallet.account!, chain: foundry });
    assert.equal((await client.waitForTransactionReceipt({ hash })).status, 'success', functionName);
  };
  for (const [dataSetId, pieceId, onChain] of pieces) {
    if (onChain) await write('seedPieceMetadata', [BigInt(dataSetId), BigInt(pieceId), Object.keys(onChain), Object.values(onChain)]);
  }
  for (const [dataSetId, length] of queues) {
    await write('seedRemovalQueue', [BigInt(dataSetId), Array.from({ length }, (_, i) => BigInt(i + 100))]);
  }
  await write('setPdpRailId', [BigInt(RAIL_DATA_SET), RAIL_ID]);

  const db = openDb(':memory:', { name: 'anvil', fwss: harness });
  const upsert = pieceUpserter(db);
  for (const [dataSetId, pieceId, onChain, table] of pieces) {
    const metadata = Object.fromEntries(Object.entries((table ?? onChain)!).reverse());
    upsert({ dataSetId, pieceId, metadata: JSON.stringify(metadata), removed: false });
  }

  const reader = rpcStorageReader({ rpcUrl: url, chain: foundry, address: harness, batchSize: 7, concurrency: 3, requestsPerSecond: 0 });
  const sender = privateKeyToAccount(generatePrivateKey());
  await rpc('anvil_setBalance', [sender.address, '0x56bc75e2d63100000']);
  const opts: SendOptions = {
    to: harness,
    from: sender.address,
    chainId: foundry.id,
    account: sender,
    maxGasPrice: 1000n * GWEI,
    pollMs: 50,
    receiptTimeoutMs: 20_000,
  };
  const read = async <T>(functionName: string, args: unknown[]) => (await client.readContract({ address: harness, abi, functionName, args })) as T;
  return { harness, db, reader, sender, opts, read };
}

const statuses = (db: DatabaseSync) => listBatches(db).map((b) => b.status);
const txsOf = (db: DatabaseSync, batchId: number) =>
  db.prepare('SELECT hash, status, fee FROM txs WHERE batch_id = ? ORDER BY sent_at').all(batchId) as { hash: string; status: string; fee: string | null }[];

// The same client, except that the next broadcast is lost before it reaches the node. `raw()` is the signed message.
function losingNextBroadcast(): { client: PublicClient; raw: () => Hex } {
  let raw: Hex | undefined;
  const flaky = new Proxy(client, {
    get(target, prop, receiver) {
      if (prop !== 'request') return Reflect.get(target, prop, receiver);
      return async (args: { method: string; params?: unknown[] }) => {
        if (args.method === 'eth_sendRawTransaction' && raw === undefined) {
          raw = args.params![0] as Hex;
          throw new Error('socket hang up');
        }
        return (target.request as (a: unknown) => Promise<unknown>)(args);
      };
    },
  }) as PublicClient;
  return { client: flaky, raw: () => raw! };
}

before(async () => {
  if (!existsSync(ARTIFACT)) throw new Error(`missing ${ARTIFACT.pathname}; run forge build in service_contracts first`);
  const artifact = JSON.parse(readFileSync(ARTIFACT, 'utf8')) as { abi: Abi; bytecode: { object: Hex } };
  abi = artifact.abi;
  bytecode = artifact.bytecode.object;

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
  wallet = createWalletClient({ account: seeder, chain: foundry, transport: http(url) });
});

after(() => {
  anvil?.kill();
});

test('check, queues, plan, send with resume, verify leave only the non-legacy state', async () => {
  const { harness, db, reader, sender, opts, read } = await setup(PIECES, QUEUES);
  const before = await storageDump(harness);
  assert.ok(before.size > 80, `seeded storage visible in the dump (${before.size} slots)`);

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

  const dry = await sendBatches(db, client, { ...opts, account: undefined, maxGasPrice: undefined, dryRun: true });
  assert.equal(dry.estimated, batches.length);
  assert.equal(dry.failure, undefined);
  assert.equal(await nonceOf(sender.address), 0, 'a dry run sends nothing');

  // A pilot of 3 batches under a price ceiling that is above the base fee but below base fee plus priority fee.
  const setBaseFee = async (fee: bigint) => {
    await rpc('anvil_setNextBlockBaseFeePerGas', [`0x${fee.toString(16)}`]);
    await rpc('evm_mine');
  };
  const priority = BigInt(await rpc<Hex>('eth_maxPriorityFeePerGas'));
  assert.ok(priority > 0n, 'the node suggests a priority fee');
  const ceiling = 100n * GWEI + priority - 1n;
  await setBaseFee(100n * GWEI);
  const pilot = sendBatches(db, client, { ...opts, maxBatches: 3, maxGasPrice: ceiling });
  await sleep(500);
  assert.equal(await nonceOf(sender.address, 'pending'), 0, 'nothing sent while base fee plus priority fee is above the ceiling');

  // At 60 gwei the price is under the ceiling, and twice the base fee plus the priority fee is still above it.
  await setBaseFee(60n * GWEI);
  const first = await pilot;
  assert.equal(first.failure, undefined);
  assert.equal(first.done, 3);
  assert.deepEqual(statuses(db).slice(0, 4), ['done', 'done', 'done', 'planned']);
  assert.equal(await nonceOf(sender.address), 3);
  const pilotTxs = db.prepare('SELECT hash FROM txs ORDER BY nonce').all() as { hash: Hex }[];
  const feeCaps: bigint[] = [];
  for (const { hash } of pilotTxs) {
    const tx = await rpc<{ maxFeePerGas: Hex; maxPriorityFeePerGas: Hex }>('eth_getTransactionByHash', [hash]);
    feeCaps.push(BigInt(tx.maxFeePerGas));
    assert.ok(BigInt(tx.maxPriorityFeePerGas) <= BigInt(tx.maxFeePerGas));
  }
  assert.equal(feeCaps[0], ceiling, 'the ceiling is the fee cap when the usual cap would be above it');
  assert.ok(feeCaps.every((cap) => cap <= ceiling), `fee caps ${feeCaps} within ${ceiling}`);

  // Interrupted run: blocks stop, so two messages go out and their receipts never come.
  await rpc('evm_setAutomine', [false]);
  const stalled = await sendBatches(db, client, { ...opts, maxInflight: 2, receiptTimeoutMs: 1000 });
  assert.match(stalled.failure ?? '', /no receipt/);
  assert.deepEqual(statuses(db).slice(3, 6), ['sent', 'sent', 'planned'], 'at most 2 in flight, recorded as sent');
  assert.equal(await nonceOf(sender.address, 'pending'), 5);

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
  assert.ok(statuses(db).every((s) => s === 'done'));
  const txs = db.prepare('SELECT batch_id, status FROM txs ORDER BY nonce').all() as { batch_id: number; status: string }[];
  assert.deepEqual(
    txs.map((t) => [t.batch_id, t.status]),
    batches.map((b) => [b.id, 'success']),
    'one successful message per batch, the stalled ones included',
  );
  assert.equal(await nonceOf(sender.address), batches.length, 'no batch was sent twice');

  const verified = await verifyPlan(db, reader, { all: true, requeue: true, pageSize: 5 });
  assert.equal(verified.residueCount, 0, JSON.stringify(verified.residue, (_, v) => (typeof v === 'bigint' ? v.toString(16) : v)));
  assert.deepEqual([verified.queues, verified.requeued], [2, 0]);

  // The dump holds the data set info of the railed data set, its flag, and what the wrong indexer rows left: verify
  // cannot see those, because the plan never knew their slots.
  const info = await read<bigint>('dataSetInfoSlot', [BigInt(RAIL_DATA_SET)]);
  const wrongKeyHead = await read<bigint>('valueSlot', [BigInt(NO_RAIL_DATA_SET), 9n, 'name']);
  const longHead = await read<bigint>('valueSlot', [BigInt(NO_RAIL_DATA_SET), 8n, 'name']);
  const longData = BigInt(keccak256(encodeAbiParameters([{ type: 'uint256' }], [longHead])));
  const shortString = (s: string) => BigInt('0x' + Buffer.from(s).toString('hex').padEnd(62, '0') + (s.length * 2).toString(16).padStart(2, '0'));
  const expected = new Map<bigint, bigint>([
    [info, RAIL_ID],
    [info + 10n, 1n << 192n], // pieceRemovalsPending, packed above two uint96 fields
    [wrongKeyHead, shortString('file.bin')],
    [longData + 2n, BigInt('0x' + Buffer.from(repeat('n', 6)).toString('hex').padEnd(64, '0'))],
  ]);
  assert.deepEqual(hex(await storageDump(harness)), hex(expected));
  assert.equal(await read<boolean>('pieceRemovalsPending', [BigInt(RAIL_DATA_SET)]), true);
  assert.equal(await read<boolean>('pieceRemovalsPending', [BigInt(NO_RAIL_DATA_SET)]), false, 'no rail, no flag');
});

test('after a partial send, check refuses and verify --requeue then send finishes the cleanup', async () => {
  const { harness, db, reader, opts, read } = await setup(MATCHING, QUEUES);
  await checkPieces(db, reader, { all: true });
  assert.deepEqual(statusCounts(db), { match: MATCHING.length });
  await refreshQueues(db, reader, 10, 'anvil');
  buildPlan(db, LIMITS);

  const batches = listBatches(db);
  const ops = (b: BatchRow) => decodeOps(batchCalldataOps(db, b));
  const queueBatches = batches.filter((b) => b.phase === 0);
  const railQueueBatches = queueBatches.filter((b) => ops(b).some((o) => o.kind === POP_QUEUE && o.dataSetId === RAIL_DATA_SET));
  assert.ok(railQueueBatches.length >= 2, 'the queue of 20 is popped by several batches');

  // Two batches recorded done that never executed, as when a receipt was seen and its block was then reorged out.
  const lostQueue = railQueueBatches[0]!;
  const lostMetadata = batches[batches.length - 1]!;
  const markDone = db.prepare("UPDATE batches SET status = 'done' WHERE id = ?");
  markDone.run(lostQueue.id);
  markDone.run(lostMetadata.id);

  // A partial send: the other queue batches and two metadata batches.
  const partial = await sendBatches(db, client, { ...opts, maxBatches: queueBatches.length - 1 + 2 });
  assert.equal(partial.done, queueBatches.length + 1);
  const pieceIds = (list: BatchRow[]) => new Set(list.flatMap(ops).map((o) => ('pieceId' in o ? `${o.dataSetId}/${o.pieceId}` : '')));
  const executed = pieceIds(batches.filter((b) => b.phase === 1).slice(0, 2));
  const waiting = pieceIds(batches.filter((b) => b.phase === 1).slice(2));
  assert.ok([...executed].some((id) => waiting.has(id)), 'a piece has ops in an executed batch and in a waiting one');

  await assert.rejects(checkPieces(db, reader, { all: true, recheck: true }), /sending has started.*verify --requeue, then send/);
  await assert.rejects(checkPieces(db, reader, { sample: 5 }), /sending has started/);
  assert.deepEqual(statusCounts(db), { match: MATCHING.length }, 'no check result changed');

  // One more batch whose message is out and unmined when verify runs.
  await rpc('evm_setAutomine', [false]);
  const stalled = await sendBatches(db, client, { ...opts, maxBatches: 1, receiptTimeoutMs: 500 });
  assert.match(stalled.failure ?? '', /no receipt/);
  const pendingBatch = listBatches(db).find((b) => b.status === 'sent')!;

  const before = statuses(db);
  const looked = await verifyPlan(db, reader, { all: true });
  assert.ok(looked.residueCount > 0);
  assert.deepEqual([looked.requeued, statuses(db)], [0, before], 'verify without --requeue changes nothing');

  const requeued = await verifyPlan(db, reader, { all: true, requeue: true });
  const putBack = listBatches(db).filter((b, i) => before[i] !== 'planned' && b.status === 'planned').map((b) => b.id);
  const expectedBack = [...railQueueBatches.map((b) => b.id), pendingBatch.id, lostMetadata.id];
  assert.deepEqual(putBack, expectedBack, 'every pop of the queue that is not empty, and each metadata batch with residue');
  assert.equal(requeued.requeued, expectedBack.length);
  assert.equal(statuses(db).filter((s) => s === 'done').length, queueBatches.length - railQueueBatches.length + 2, 'executed batches stay done');

  // The pending message lands; the next send settles it instead of sending its batch again.
  await rpc('evm_mine');
  await rpc('evm_setAutomine', [true]);
  const finished = await sendBatches(db, client, opts);
  assert.equal(finished.failure, undefined);
  assert.equal(finished.remaining, 0);
  assert.deepEqual(txsOf(db, pendingBatch.id).map((t) => t.status), ['success'], 'the put-back batch with a message out was not sent twice');
  assert.equal(txsOf(db, lostMetadata.id).length, 1);

  const verified = await verifyPlan(db, reader, { all: true, requeue: true });
  assert.deepEqual([verified.residueCount, verified.requeued], [0, 0]);
  const info = await read<bigint>('dataSetInfoSlot', [BigInt(RAIL_DATA_SET)]);
  assert.deepEqual(hex(await storageDump(harness)), hex(new Map([[info, RAIL_ID], [info + 10n, 1n << 192n]])));

  // A new plan puts every batch back to `planned`. check must still refuse: it would call partly cleaned pieces
  // clean or mismatched, and the next plan would leave them out.
  buildPlan(db, LIMITS, { force: true });
  assert.ok(listBatches(db).every((b) => b.status === 'planned'));
  await assert.rejects(checkPieces(db, reader, { all: true, recheck: true }), /sending has started/);
});

test('a message lost before broadcast is sent again under the same hash, and one that lands late is found', async () => {
  const { harness, db, reader, sender, opts, read } = await setup(MATCHING.slice(0, 3), []);
  await checkPieces(db, reader, { all: true });
  await refreshQueues(db, reader, 10, 'anvil');
  buildPlan(db, { maxCalldataBytes: 400, maxOps: 4 });
  const batches = listBatches(db);
  assert.ok(batches.length >= 4, `${batches.length} batches`);
  assert.equal((await sendBatches(db, client, { ...opts, maxBatches: 1 })).done, 1);

  // Batch 2 is signed and recorded, and its broadcast is lost. The next run finds no trace of it, calls it dropped
  // and sends the batch again; the base fee moved, so this second message has another hash and the same nonce.
  const setBaseFee = async (fee: bigint) => {
    await rpc('anvil_setNextBlockBaseFeePerGas', [`0x${fee.toString(16)}`]);
    await rpc('evm_mine');
  };
  await setBaseFee(10n * GWEI);
  const late = losingNextBroadcast();
  const lostLate = await sendBatches(db, late.client, opts);
  assert.match(lostLate.failure ?? '', /^batch 2: send of 0x[0-9a-f]{64} failed/);
  assert.deepEqual(statuses(db).slice(0, 3), ['done', 'sent', 'planned']);
  await setBaseFee(5n * GWEI);
  await rpc('evm_setAutomine', [false]);
  const resent = await sendBatches(db, client, { ...opts, maxBatches: 1, receiptTimeoutMs: 500 });
  assert.match(resent.failure ?? '', /^batch 2: no receipt/);
  const first = keccak256(late.raw());
  assert.deepEqual(txsOf(db, 2).map((t) => [t.hash === first, t.status]), [[true, 'dropped'], [false, 'sent']]);

  // The lost message reaches the chain after all, in place of the second one. The next run finds its receipt, and
  // does not send batch 2 a third time when the second message turns out dropped.
  await rpc('anvil_dropTransaction', [txsOf(db, 2)[1]!.hash]);
  await rpc('eth_sendRawTransaction', [late.raw()]);
  await rpc('evm_mine');
  await rpc('evm_setAutomine', [true]);
  assert.equal(await nonceOf(sender.address), 2);
  const found = await sendBatches(db, client, { ...opts, maxBatches: 0 });
  assert.equal(found.done, 1);
  assert.equal(statuses(db)[1], 'done');
  const [landed, replaced] = txsOf(db, 2);
  assert.deepEqual([landed!.status, replaced!.status], ['success', 'dropped']);
  assert.ok(BigInt(landed!.fee!) > 0n, 'its fee is in the spend records');

  // Batch 3 is lost the same way. Nothing changed on chain since, so the resend signs the same bytes: same hash.
  const again = losingNextBroadcast();
  const lostAgain = await sendBatches(db, again.client, opts);
  assert.match(lostAgain.failure ?? '', /^batch 3: send of/);
  const rest = await sendBatches(db, client, opts);
  assert.equal(rest.failure, undefined);
  assert.equal(rest.remaining, 0);
  assert.deepEqual(
    txsOf(db, 3).map((t) => [t.hash, t.status]),
    [[keccak256(again.raw()), 'success']],
    'the resend reused the row of the lost message',
  );
  assert.equal(await nonceOf(sender.address), batches.length, 'one message per batch landed');

  assert.equal((await verifyPlan(db, reader, { all: true })).residueCount, 0);
  const info = await read<bigint>('dataSetInfoSlot', [BigInt(RAIL_DATA_SET)]);
  assert.deepEqual(hex(await storageDump(harness)), hex(new Map([[info, RAIL_ID]])));
});

test('a key the chain does not have is a mismatch, even with an empty value and the right key count', async () => {
  const { db, reader } = await setup([[NO_RAIL_DATA_SET, 0, { kept: 'x', hidden: 'legacy' }, { kept: 'x', phantom: '' }]], []);
  await checkPieces(db, reader, { all: true });
  const row = db.prepare('SELECT status, detail FROM pieces').get() as { status: string; detail: string };
  assert.equal(row.status, 'mismatch');
  assert.match(row.detail, /^key elements lack "phantom" and hold 0x68696464656e0{50}0c instead$/);
});

test('reads and sends refuse a node of another chain and an address without code', async () => {
  const { db, reader, opts } = await setup(MATCHING.slice(0, 1), []);
  const empty = '0x00000000000000000000000000000000000000aa';
  const readerOf = (chain: typeof foundry | typeof filecoin, address: Address) =>
    rpcStorageReader({ rpcUrl: url, chain, address, batchSize: 7, concurrency: 3, requestsPerSecond: 0 });

  // Without the guard every slot of the empty address reads zero, so the piece would come out clean.
  await assert.rejects(checkPieces(db, readerOf(foundry, empty), { all: true }), /no contract code at 0x0{38}aa/i);
  await assert.rejects(refreshQueues(db, readerOf(foundry, empty), 10, 'anvil'), /no contract code/);
  await assert.rejects(checkPieces(db, readerOf(filecoin, opts.to), { all: true }), /RPC serves chain 31337, expected 314/);
  assert.deepEqual(statusCounts(db), { unchecked: 1 });

  await checkPieces(db, reader, { all: true });
  replaceQueues(db, [], 'anvil');
  buildPlan(db, LIMITS);
  await assert.rejects(verifyPlan(db, readerOf(foundry, empty), { all: true }), /no contract code/);
  await assert.rejects(sendBatches(db, client, { ...opts, to: empty }), /no contract code/);
  await assert.rejects(sendBatches(db, client, { ...opts, chainId: filecoin.id }), /RPC serves chain 31337, expected 314/);
  await assert.rejects(sendBatches(db, client, { ...opts, maxGasPrice: undefined }), /price ceiling/);
  assert.ok(statuses(db).every((s) => s === 'planned'));
});

test('a batch that reverts stops the run with its id and revert data', async () => {
  const { db, sender, opts } = await setup([], []);
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
  assert.deepEqual(statuses(db), ['reverted', 'planned']);
});
