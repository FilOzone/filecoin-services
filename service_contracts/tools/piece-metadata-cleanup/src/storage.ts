import { createPublicClient, http, type Address, type Chain, type PublicClient } from 'viem';
import { hex32 } from './slots.ts';

export interface StorageReader {
  read(slots: readonly bigint[]): Promise<bigint[]>;
}

// A node of another network, or a wrong address, answers every storage read with zero, which reads as "all clean".
export async function assertTarget(client: PublicClient, chainId: number, address: Address): Promise<void> {
  const served = await client.getChainId();
  if (served !== chainId) throw new Error(`RPC serves chain ${served}, expected ${chainId}`);

  const code = await client.getCode({ address });
  if (!code || code === '0x') throw new Error(`no contract code at ${address} on chain ${chainId}; wrong node or address`);
}

export type RpcReaderOptions = {
  rpcUrl: string;
  chain: Chain;
  address: Address;
  batchSize: number;
  concurrency: number;
  // Upper bound on HTTP requests per second across all workers; 0 means no limit.
  requestsPerSecond: number;
  retries?: number;
  log?: (line: string) => void;
};

export function publicClient(rpcUrl: string, chain: Chain): PublicClient {
  return createPublicClient({ chain, transport: http(rpcUrl, { retryCount: 6, retryDelay: 1000, timeout: 120_000 }) });
}

const WORD_HEX = /^0x[0-9a-fA-F]{1,64}$/;

// One JSON-RPC batch of eth_getStorageAt. Every slot must come back as a word; anything else fails the whole batch.
async function postBatch(url: string, address: Address, slots: readonly bigint[]): Promise<bigint[]> {
  const body = slots.map((slot, id) => ({ jsonrpc: '2.0', id, method: 'eth_getStorageAt', params: [address, hex32(slot), 'latest'] }));
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(120_000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
  const json: unknown = await res.json();
  if (!Array.isArray(json)) throw new Error(`not a batch response: ${JSON.stringify(json).slice(0, 200)}`);

  const words: (bigint | undefined)[] = new Array(slots.length);
  let firstError: unknown;
  for (const r of json as { id?: unknown; result?: unknown; error?: unknown }[]) {
    const id = r?.id;
    const known = typeof id === 'number' && Number.isInteger(id) && id >= 0 && id < slots.length && words[id] === undefined;
    if (known && typeof r.result === 'string' && WORD_HEX.test(r.result)) words[id] = BigInt(r.result);
    else firstError ??= r?.error ?? r;
  }
  const missing = slots.length - words.filter((w) => w !== undefined).length;
  if (missing > 0) throw new Error(`${missing} of ${slots.length} reads failed, first: ${JSON.stringify(firstError).slice(0, 200)}`);
  return words as bigint[];
}

// eth_getStorageAt in JSON-RPC batches: one HTTP request per `batchSize` slots, at most `concurrency` in flight, a
// failed batch retried with backoff. Glif answered batches of up to 2000 calls but ran fastest with small batches in
// parallel; Multicall3 with extsload was slower per slot and ran out of gas at 1000 slots.
export function rpcStorageReader(opts: RpcReaderOptions): StorageReader & { client: PublicClient; ready(): Promise<void> } {
  const client = publicClient(opts.rpcUrl, opts.chain);
  const interval = opts.requestsPerSecond > 0 ? 1000 / opts.requestsPerSecond : 0;
  const retries = opts.retries ?? 8;
  const log = opts.log ?? (() => {});
  let nextStart = 0;

  async function throttle(): Promise<void> {
    if (interval === 0) return;
    const now = Date.now();
    const start = Math.max(now, nextStart);
    nextStart = start + interval;
    if (start > now) await new Promise((r) => setTimeout(r, start - now));
  }

  let target: Promise<void> | undefined;
  const ready = () => (target ??= assertTarget(client, opts.chain.id, opts.address));

  async function readChunk(slots: readonly bigint[]): Promise<bigint[]> {
    for (let attempt = 0; ; attempt++) {
      await throttle();
      try {
        return await postBatch(opts.rpcUrl, opts.address, slots);
      } catch (err) {
        if (attempt >= retries) throw err;
        const delay = Math.min(30_000, 1000 * 2 ** attempt);
        log(`storage read failed (${err instanceof Error ? err.message : String(err)}), retry in ${delay} ms`);
        await new Promise((r) => setTimeout(r, delay));
      }
    }
  }

  return {
    client,
    ready,
    async read(slots) {
      await ready();

      const chunks: (readonly bigint[])[] = [];
      for (let i = 0; i < slots.length; i += opts.batchSize) chunks.push(slots.slice(i, i + opts.batchSize));
      const results: bigint[][] = new Array(chunks.length);
      let next = 0;
      let failed = false;
      const worker = async () => {
        while (!failed && next < chunks.length) {
          const i = next++;
          try {
            results[i] = await readChunk(chunks[i]!);
          } catch (err) {
            failed = true;
            throw err;
          }
        }
      };
      await Promise.all(Array.from({ length: Math.min(opts.concurrency, chunks.length) }, worker));
      return results.flat();
    },
  };
}
