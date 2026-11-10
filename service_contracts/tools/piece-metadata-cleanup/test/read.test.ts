import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { after, before, test } from 'node:test';
import { foundry } from 'viem/chains';
import { readQueueLengths } from '../src/queues.ts';
import { queueSlot } from '../src/slots.ts';
import { rpcStorageReader } from '../src/storage.ts';

type Call = { id: number; method: string; params: unknown[] };
type Mode = 'ok' | 'http500' | 'error-item' | 'empty-word' | 'missing-item' | 'first-fails';

// A JSON-RPC node that answers the chain guard, and storage batches as the mode says: slot n holds n + 1.
let server: Server;
let url: string;
let mode: Mode = 'ok';
let batches = 0;

before(async () => {
  server = createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => (body += chunk));
    req.on('end', () => {
      const parsed = JSON.parse(body) as Call | Call[];
      const reply = (status: number, json: unknown, delayMs = 0) =>
        setTimeout(() => {
          res.writeHead(status, { 'content-type': 'application/json' });
          res.end(JSON.stringify(json));
        }, delayMs);

      if (!Array.isArray(parsed)) {
        return reply(200, { jsonrpc: '2.0', id: parsed.id, result: parsed.method === 'eth_chainId' ? '0x7a69' : '0x60' });
      }

      batches += 1;
      if (mode === 'http500' || (mode === 'first-fails' && batches === 1)) return reply(500, { error: 'down' });
      const items = parsed.map((call, i) => {
        if (i === 1 && mode === 'error-item') return { jsonrpc: '2.0', id: call.id, error: { code: -32000, message: 'rate limit' } };
        if (i === 1 && mode === 'empty-word') return { jsonrpc: '2.0', id: call.id, result: '0x' };
        return { jsonrpc: '2.0', id: call.id, result: '0x' + (BigInt(call.params[1] as string) + 1n).toString(16) };
      });
      reply(200, mode === 'missing-item' ? items.slice(1) : items, mode === 'first-fails' ? 20 : 0);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(() => {
  server.close();
});

const reader = (batchSize: number, concurrency: number) =>
  rpcStorageReader({
    rpcUrl: url,
    chain: foundry,
    address: '0x0000000000000000000000000000000000000001',
    batchSize,
    concurrency,
    requestsPerSecond: 0,
    retries: 0,
  });

test('a storage read that fails is an error, never a zero', async () => {
  const slots = Array.from({ length: 7 }, (_, i) => BigInt(i));
  mode = 'ok';
  assert.deepEqual(await reader(3, 2).read(slots), slots.map((s) => s + 1n));

  for (const [failing, message] of [
    ['http500', /HTTP 500/],
    ['error-item', /1 of 3 reads failed, first: .*rate limit/],
    ['empty-word', /1 of 3 reads failed/],
    ['missing-item', /./],
  ] as const) {
    mode = failing;
    await assert.rejects(reader(3, 2).read(slots), message, failing);
  }
});

test('after one failed chunk the other workers take no new chunks', async () => {
  mode = 'first-fails';
  batches = 0;
  await assert.rejects(reader(1, 4).read(Array.from({ length: 40 }, (_, i) => BigInt(i))), /HTTP 500/);
  await new Promise((r) => setTimeout(r, 300));
  assert.ok(batches <= 8, `${batches} requests for 40 chunks`);
});

test('reads the queue of every data set id below the next one, the last included', async () => {
  const stored = new Map([
    [queueSlot(0), 2n],
    [queueSlot(5), 7n],
    [queueSlot(6), 9n], // not assigned yet: PDPVerifier's next id is 6
  ]);
  const read: bigint[] = [];
  const queues = await readQueueLengths(
    {
      async read(slots) {
        read.push(...slots);
        return slots.map((s) => stored.get(s) ?? 0n);
      },
    },
    6,
  );
  assert.deepEqual(queues, [
    { dataSetId: 0, length: 2 },
    { dataSetId: 5, length: 7 },
  ]);
  assert.equal(read.length, 6);
});
