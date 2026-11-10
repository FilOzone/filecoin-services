import { writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { formatEther, getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { calldataBytes, DEFAULT_LIMITS } from './batches.ts';
import { checkPieces } from './check.ts';
import { openDb } from './db.ts';
import { fetchPieces } from './fetch.ts';
import { DEFAULT_DEPLOYMENTS, loadNetwork } from './network.ts';
import { hex32 } from './slots.ts';
import { buildPlan, excludedPieces } from './plan.ts';
import { nextDataSetId, refreshQueues } from './queues.ts';
import { MAX_INFLIGHT, sendBatches, sendTotals } from './send.ts';
import { publicClient, rpcStorageReader } from './storage.ts';
import { verifyPlan } from './verify.ts';

// The only place the signing key is read; it is never logged or stored.
const KEY_ENV = 'CLEANUP_PRIVATE_KEY';

const USAGE = `usage: node src/cli.ts <command> --network mainnet|calibnet [options]

commands:
  fetch    copy legacy pieces with metadata from the indexer (DATABASE_URL or PG* variables)
  queues   read every legacy removal queue length from chain
  check    compare pieces with chain storage: --sample N | --all [--recheck]
  plan     build sorted ops and batches from checked or unchecked pieces
  send     send the batches that are not done, resuming an earlier run (key in ${KEY_ENV})
  verify   read the slots and queue lengths the plan zeroes, expect zero: --sample N | --all

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
  --report <file>                plan: write invalid and mismatch pieces as TSV; verify: write residue as TSV
  --force                        plan: replan although batches left the planned state
  --dry-run                      send: estimate gas only, send nothing (needs --from or ${KEY_ENV})
  --from <address>               send: sender for --dry-run without a key
  --gas-multiplier <x>           send: gas limit = estimate * x, at least 1 (default 1)
  --max-inflight <n>             send: unconfirmed messages at a time, 1..${MAX_INFLIGHT} (default ${MAX_INFLIGHT})
  --max-base-fee <attoFIL>       send: wait while the base fee is above this
  --max-batches <n>              send: stop after n batches
  --receipt-timeout <s>          send: give up on a receipt after s seconds (default 600)
  --poll-interval <s>            send: receipt and base fee polling interval (default 5)
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
      'dry-run': { type: 'boolean' },
      from: { type: 'string' },
      'gas-multiplier': { type: 'string' },
      'max-inflight': { type: 'string' },
      'max-base-fee': { type: 'string' },
      'max-batches': { type: 'string' },
      'receipt-timeout': { type: 'string' },
      'poll-interval': { type: 'string' },
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
  const rpcUrl = values['rpc-url'] ?? network.defaultRpcUrl;
  const reader = () =>
    rpcStorageReader({
      rpcUrl,
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
      const queues = await refreshQueues(db, r, next, `data set ids 0..${next - 1} read near block ${block}`);
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
    case 'send': {
      const secret = process.env[KEY_ENV];
      if (secret !== undefined && !/^0x[0-9a-fA-F]{64}$/.test(secret)) throw new Error(`${KEY_ENV} is not a 32-byte hex key`);
      const account = secret ? privateKeyToAccount(secret as `0x${string}`) : undefined;
      const from = values.from ? getAddress(values.from) : account?.address;
      if (!from) throw new Error(`send needs ${KEY_ENV}, or --dry-run with --from`);
      if (!values['dry-run'] && !account) throw new Error(`send needs ${KEY_ENV}`);

      const multiplier = values['gas-multiplier'] === undefined ? 1 : Number(values['gas-multiplier']);
      if (!(multiplier >= 1)) throw new Error('--gas-multiplier must be at least 1');
      const maxInflight = positiveInt(values['max-inflight'], 'max-inflight', MAX_INFLIGHT);
      if (maxInflight < 1 || maxInflight > MAX_INFLIGHT) throw new Error(`--max-inflight must be 1..${MAX_INFLIGHT}`);
      const maxBaseFeeArg = values['max-base-fee'];
      if (maxBaseFeeArg !== undefined && !/^\d+$/.test(maxBaseFeeArg)) throw new Error('--max-base-fee must be an integer in attoFIL');
      const maxBaseFee = maxBaseFeeArg === undefined ? undefined : BigInt(maxBaseFeeArg);
      const maxBatches = values['max-batches'] === undefined ? undefined : positiveInt(values['max-batches'], 'max-batches', 0);

      log(`send: ${values['dry-run'] ? 'dry run' : 'sending'} from ${from} to ${network.fwss} on ${network.name}`);
      const s = await sendBatches(db, publicClient(rpcUrl, network.chain), {
        to: network.fwss,
        from,
        chainId: network.chain.id,
        account,
        dryRun: values['dry-run'],
        gasMultiplier: multiplier,
        maxInflight,
        maxBaseFee,
        maxBatches,
        receiptTimeoutMs: positiveInt(values['receipt-timeout'], 'receipt-timeout', 600) * 1000,
        pollMs: positiveInt(values['poll-interval'], 'poll-interval', 5) * 1000,
        log,
      });
      if (values['dry-run']) {
        log(`dry run: ${s.estimated} batches estimated, ${s.estimatedGas} gas in total`);
      } else {
        log(`this run: ${s.done} batches done, ${s.gasUsed} gas used, ${formatEther(s.fee)} FIL spent`);
        const t = sendTotals(db);
        log(`all runs: batches ${JSON.stringify(t.batches)}, ${t.gasUsed} gas used, ${formatEther(t.fee)} FIL spent`);
      }
      log(`batches not done: ${s.remaining}`);
      if (s.failure) {
        console.error(`send stopped: ${s.failure}`);
        process.exitCode = 1;
      }
      break;
    }
    case 'verify': {
      const sample = values.sample === undefined ? undefined : positiveInt(values.sample, 'sample', 0);
      const r = await verifyPlan(db, reader(), { sample, all: values.all, log });
      log(`verify: ${r.queues} queues, ${r.ops} metadata ops, ${r.slots} slots read, ${r.residueCount} not zero`);
      for (const x of r.residue.slice(0, 20)) {
        log(`residue ${x.dataSetId}/${x.pieceId ?? '-'} ${x.kind} slot ${hex32(x.slot)} holds ${hex32(x.value)}`);
      }
      if (r.residueCount > 20) log(`... ${r.residueCount - 20} more`);
      if (values.report) {
        const lines = r.residue.map((x) => [x.dataSetId, x.pieceId ?? '', x.kind, hex32(x.slot), hex32(x.value)].join('\t'));
        writeFileSync(values.report, ['data_set_id\tpiece_id\tkind\tslot\tvalue', ...lines].join('\n') + '\n');
        log(`wrote ${r.residue.length} residue slots to ${values.report}`);
      }
      if (r.residueCount > 0) process.exitCode = 1;
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
