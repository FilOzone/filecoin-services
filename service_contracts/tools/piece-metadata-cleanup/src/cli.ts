import { writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { calldataBytes, DEFAULT_LIMITS } from './batches.ts';
import { checkPieces } from './check.ts';
import { openDb, replaceQueues } from './db.ts';
import { fetchPieces } from './fetch.ts';
import { DEFAULT_DEPLOYMENTS, loadNetwork } from './network.ts';
import { buildPlan, excludedPieces } from './plan.ts';
import { nextDataSetId, readQueueLengths } from './queues.ts';
import { rpcStorageReader } from './storage.ts';

const USAGE = `usage: node src/cli.ts <command> --network mainnet|calibnet [options]

commands:
  fetch    copy legacy pieces with metadata from the indexer (DATABASE_URL or PG* variables)
  queues   read every legacy removal queue length from chain
  check    compare pieces with chain storage: --sample N | --all [--recheck]
  plan     build sorted ops and batches from checked or unchecked pieces

options:
  --db <file>                    state file (default cleanup-<network>.sqlite)
  --rpc-url <url>                JSON-RPC endpoint (default: Glif for the network)
  --deployments <file>           deployments.json with the FWSS proxy (default: the repo's)
  --read-batch-size <n>          storage reads per JSON-RPC batch request (default 50)
  --read-concurrency <n>         batch requests in flight (default 16)
  --requests-per-second <n>      cap on batch requests per second, 0 for none (default 0)
  --stride <n>                   fetch: keep pieces with (data_set_id + piece_id) % n = 0
  --limit <n>                    fetch: stop after n pieces
  --max-calldata-bytes <n>       plan: calldata limit per batch (default ${DEFAULT_LIMITS.maxCalldataBytes})
  --max-ops <n>                  plan: ops per batch, each queue pop counts as one (default ${DEFAULT_LIMITS.maxOps})
  --report <file>                plan: write invalid and mismatch pieces as TSV
  --force                        plan: replan although batches left the planned state
`;

function positiveInt(value: string | undefined, name: string, fallback: number): number {
  if (value === undefined) return fallback;
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < 0) throw new Error(`--${name} must be a non-negative integer`);
  return n;
}

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      network: { type: 'string' },
      db: { type: 'string' },
      'rpc-url': { type: 'string' },
      deployments: { type: 'string' },
      'read-batch-size': { type: 'string' },
      'read-concurrency': { type: 'string' },
      'requests-per-second': { type: 'string' },
      sample: { type: 'string' },
      all: { type: 'boolean' },
      recheck: { type: 'boolean' },
      stride: { type: 'string' },
      limit: { type: 'string' },
      'max-calldata-bytes': { type: 'string' },
      'max-ops': { type: 'string' },
      report: { type: 'string' },
      force: { type: 'boolean' },
      help: { type: 'boolean' },
    },
  });
  const command = positionals[0];
  if (values.help || !command || !values.network) {
    process.stdout.write(USAGE);
    process.exitCode = values.help ? 0 : 2;
    return;
  }

  const network = loadNetwork(values.network, values.deployments ?? DEFAULT_DEPLOYMENTS);
  const db = openDb(values.db ?? `cleanup-${network.name}.sqlite`, network);
  const log = (line: string) => console.log(line);
  const reader = () =>
    rpcStorageReader({
      rpcUrl: values['rpc-url'] ?? network.defaultRpcUrl,
      chain: network.chain,
      address: network.fwss,
      batchSize: positiveInt(values['read-batch-size'], 'read-batch-size', 50) || 1,
      concurrency: positiveInt(values['read-concurrency'], 'read-concurrency', 16) || 1,
      requestsPerSecond: positiveInt(values['requests-per-second'], 'requests-per-second', 0),
      log,
    });

  switch (command) {
    case 'fetch': {
      const stride = values.stride === undefined ? undefined : positiveInt(values.stride, 'stride', 1) || 1;
      const limit = values.limit === undefined ? undefined : positiveInt(values.limit, 'limit', 0);
      const { rows, invalid } = await fetchPieces(db, { legacyBeforeBlock: network.legacyBeforeBlock, stride, limit, log });
      log(`fetch done: ${rows} pieces, ${invalid} outside the facet's bounds`);
      break;
    }
    case 'queues': {
      const r = reader();
      const block = await r.client.getBlockNumber();
      const next = await nextDataSetId(r.client, network.pdpVerifier);
      const queues = await readQueueLengths(r, next);
      replaceQueues(db, queues, `data set ids 0..${next - 1} read near block ${block}`);
      const entries = queues.reduce((n, q) => n + q.length, 0);
      log(`queues: read ${next} data set ids (PDPVerifier.getNextDataSetId) near block ${block}`);
      log(`queues: ${queues.length} non-empty, ${entries} entries, longest ${Math.max(0, ...queues.map((q) => q.length))}`);
      break;
    }
    case 'check': {
      const sample = values.sample === undefined ? undefined : positiveInt(values.sample, 'sample', 0);
      const totals = await checkPieces(db, reader(), { sample, all: values.all, recheck: values.recheck, log });
      log(`check done: ${JSON.stringify(totals)}`);
      break;
    }
    case 'plan': {
      const limits = {
        maxCalldataBytes: positiveInt(values['max-calldata-bytes'], 'max-calldata-bytes', DEFAULT_LIMITS.maxCalldataBytes),
        maxOps: positiveInt(values['max-ops'], 'max-ops', DEFAULT_LIMITS.maxOps),
      };
      if (calldataBytes(0) >= limits.maxCalldataBytes || limits.maxOps < 1) throw new Error('batch limits too small');
      const t = buildPlan(db, limits, { force: values.force });
      log(`pieces planned:  ${t.pieces}`);
      log(`pieces skipped:  ${JSON.stringify(t.skipped)}`);
      log(`queues:          ${t.queues} (${t.queueEntries} entries)`);
      log(`ops:             ${t.ops} ${JSON.stringify(t.opsByKind)}`);
      log(`metadata slots:  ${t.metadataSlots}`);
      log(`batches:         ${t.batches} (${t.queueBatches} queue batches first)`);
      log(`ops bytes:       ${t.opsBytes}`);
      log(`calldata bytes:  ${t.calldataBytes}`);

      const excluded = excludedPieces(db);
      for (const p of excluded.slice(0, 20)) log(`excluded ${p.data_set_id}/${p.piece_id} ${p.status}: ${p.detail ?? ''}`);
      if (excluded.length > 20) log(`... ${excluded.length - 20} more excluded pieces`);
      if (values.report) {
        const lines = excluded.map((p) => [p.data_set_id, p.piece_id, p.status, p.detail ?? ''].join('\t'));
        writeFileSync(values.report, ['data_set_id\tpiece_id\tstatus\tdetail', ...lines].join('\n') + '\n');
        log(`wrote ${excluded.length} excluded pieces to ${values.report}`);
      }
      break;
    }
    default:
      throw new Error(`unknown command ${command}\n${USAGE}`);
  }
  db.close();
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : err);
  process.exitCode = 1;
});
