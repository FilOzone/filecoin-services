import type { DatabaseSync } from 'node:sqlite';
import { BaseError, encodeFunctionData, formatEther, keccak256, parseAbi, type Address, type Hex, type PublicClient } from 'viem';
import type { LocalAccount } from 'viem/accounts';
import { batchCalldataOps, transaction, type BatchRow, type BatchStatus } from './db.ts';

const cleanupAbi = parseAbi(['function cleanupLegacyPieceMetadata(bytes ops)']);

// Filecoin's mempool accepts at most this many messages ahead of the sender's on-chain nonce.
export const MAX_INFLIGHT = 4;

export type SendOptions = {
  to: Address;
  from: Address;
  chainId: number;
  // Signs the messages; a dry run needs only `from`.
  account?: LocalAccount;
  dryRun?: boolean;
  gasMultiplier?: number;
  maxInflight?: number;
  // attoFIL per gas unit; no message leaves while the latest block's base fee is above it.
  maxBaseFee?: bigint;
  maxBatches?: number;
  receiptTimeoutMs?: number;
  pollMs?: number;
  log?: (line: string) => void;
};

export type SendSummary = {
  // Batches that got a successful receipt in this run, including ones sent by an earlier run.
  done: number;
  gasUsed: bigint;
  fee: bigint;
  // Dry run only.
  estimated: number;
  estimatedGas: bigint;
  // Batches not done after this run.
  remaining: number;
  failure?: string;
};

type Receipt = { status: Hex; blockNumber: Hex; gasUsed: Hex; effectiveGasPrice: Hex };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function batchCalldata(db: DatabaseSync, batch: BatchRow): Hex {
  const ops = batchCalldataOps(db, batch);
  return encodeFunctionData({ abi: cleanupAbi, functionName: 'cleanupLegacyPieceMetadata', args: [`0x${Buffer.from(ops).toString('hex')}`] });
}

// The revert data a node attached to an error, if any, else the error message.
export function revertReason(err: unknown): string {
  let data: string | undefined;
  if (err instanceof BaseError) {
    err.walk((e) => {
      const d = (e as { data?: unknown }).data;
      if (typeof d === 'string' && d.startsWith('0x')) data = d;
      else if (d && typeof d === 'object' && typeof (d as { data?: unknown }).data === 'string') data = (d as { data: string }).data;
      return data !== undefined;
    });
  }
  const message = err instanceof BaseError ? err.shortMessage : err instanceof Error ? err.message : String(err);
  return data ? `revert data ${data} (${message})` : message;
}

export function sendTotals(db: DatabaseSync): { batches: Record<string, number>; fee: bigint; gasUsed: bigint } {
  const rows = db.prepare('SELECT status, count(*) AS n FROM batches GROUP BY status').all() as { status: string; n: number }[];
  const txs = db.prepare('SELECT gas_used, fee FROM txs WHERE fee IS NOT NULL').all() as { gas_used: string; fee: string }[];
  return {
    batches: Object.fromEntries(rows.map((r) => [r.status, r.n])),
    fee: txs.reduce((n, t) => n + BigInt(t.fee), 0n),
    gasUsed: txs.reduce((n, t) => n + BigInt(t.gas_used), 0n),
  };
}

function gasLimit(estimate: bigint, multiplier: number): bigint {
  const perMille = BigInt(Math.round(multiplier * 1000));
  return (estimate * perMille + 999n) / 1000n;
}

// Sends the batches that are not done, in id order, at most `maxInflight` unconfirmed at a time with explicit
// nonces. The first failure (estimate revert, rejected send, reverted receipt, receipt timeout) stops new sends; the
// run then waits for the messages already out, records them, and returns the failure.
export async function sendBatches(db: DatabaseSync, client: PublicClient, opts: SendOptions): Promise<SendSummary> {
  const log = opts.log ?? (() => {});
  const maxInflight = opts.maxInflight ?? MAX_INFLIGHT;
  if (!Number.isInteger(maxInflight) || maxInflight < 1 || maxInflight > MAX_INFLIGHT) {
    throw new Error(`max in-flight must be 1..${MAX_INFLIGHT}`);
  }
  const multiplier = opts.gasMultiplier ?? 1;
  if (!(multiplier > 0)) throw new Error('gas multiplier must be positive');
  const pollMs = opts.pollMs ?? 5000;
  const receiptTimeoutMs = opts.receiptTimeoutMs ?? 600_000;
  if (!opts.dryRun && !opts.account) throw new Error('sending needs a signing key');
  if (opts.account && opts.account.address.toLowerCase() !== opts.from.toLowerCase()) {
    throw new Error(`signing key is for ${opts.account.address}, not ${opts.from}`);
  }

  const chainId = await client.getChainId();
  if (chainId !== opts.chainId) throw new Error(`RPC serves chain ${chainId}, expected ${opts.chainId}`);

  const summary: SendSummary = { done: 0, gasUsed: 0n, fee: 0n, estimated: 0, estimatedGas: 0n, remaining: 0 };
  const total = (db.prepare('SELECT count(*) AS n FROM batches').get() as { n: number }).n;
  const record = receiptRecorder(db, summary, total, log);

  // `planned` and `reverted` batches are not done; `sent` ones are resolved first and become one of the others.
  const unsent = (limit: number) =>
    db
      .prepare("SELECT * FROM batches WHERE status IN ('planned', 'reverted') ORDER BY id LIMIT ?")
      .all(limit) as BatchRow[];
  const limit = opts.maxBatches ?? Number.MAX_SAFE_INTEGER;

  if (opts.dryRun) {
    for (const batch of unsent(limit)) {
      const data = batchCalldata(db, batch);
      try {
        const gas = await client.estimateGas({ account: opts.from, to: opts.to, data });
        summary.estimated += 1;
        summary.estimatedGas += gas;
        log(`batch ${batch.id}: ${batch.op_count} ops, ${(data.length - 2) / 2} calldata bytes, gas estimate ${gas}`);
      } catch (err) {
        summary.failure = `batch ${batch.id}: estimate failed: ${revertReason(err)}`;
        break;
      }
    }
    summary.remaining = countNotDone(db);
    return summary;
  }

  const account = opts.account!;
  await resolveSent(db, client, opts.from, record, { pollMs, timeoutMs: receiptTimeoutMs, log });

  // resolveSent left nothing of ours pending, so the confirmed nonce is the next one; nothing else may use this key.
  let nonce = await client.getTransactionCount({ address: opts.from, blockTag: 'latest' });
  const inflight = new Map<Hex, { batchId: number; sentAt: number; gas: bigint }>();
  const markSent = db.prepare("UPDATE batches SET status = 'sent' WHERE id = ?");
  const insertTx = db.prepare(
    'INSERT INTO txs (hash, batch_id, sender, nonce, gas_limit, max_fee_per_gas, sent_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
  );

  // Polls the in-flight messages once; a reverted receipt or a timeout becomes the run's failure.
  const settle = async () => {
    await sleep(pollMs);
    for (const [hash, tx] of inflight) {
      const receipt = (await client.request({ method: 'eth_getTransactionReceipt', params: [hash] })) as Receipt | null;
      if (receipt) {
        inflight.delete(hash);
        if (!record(tx.batchId, hash, receipt)) {
          summary.failure ??= await revertFailure(client, opts, db, tx.batchId, hash, receipt, tx.gas);
        }
      } else if (Date.now() - tx.sentAt > receiptTimeoutMs) {
        inflight.delete(hash);
        summary.failure ??= `batch ${tx.batchId}: no receipt for ${hash} after ${receiptTimeoutMs / 1000} s; it stays recorded as sent and the next run resolves it`;
      }
    }
  };

  for (const batch of unsent(limit)) {
    while (!summary.failure && inflight.size >= maxInflight) await settle();
    if (summary.failure) break;

    let baseFee = await latestBaseFee(client);
    if (opts.maxBaseFee !== undefined && baseFee > opts.maxBaseFee) {
      log(`base fee ${baseFee} above ${opts.maxBaseFee}, waiting`);
      while (!summary.failure && baseFee > opts.maxBaseFee) {
        await settle();
        baseFee = await latestBaseFee(client);
      }
      if (summary.failure) break;
    }

    const data = batchCalldata(db, batch);
    let estimate: bigint;
    try {
      estimate = await client.estimateGas({ account: opts.from, to: opts.to, data });
    } catch (err) {
      summary.failure = `batch ${batch.id}: estimate failed: ${revertReason(err)}`;
      break;
    }

    const gas = gasLimit(estimate, multiplier);
    const priority = BigInt((await client.request({ method: 'eth_maxPriorityFeePerGas' })) as Hex);
    const maxFeePerGas = baseFee * 2n + priority;
    const signed = await account.signTransaction({
      type: 'eip1559',
      chainId: opts.chainId,
      nonce,
      to: opts.to,
      data,
      value: 0n,
      gas,
      maxFeePerGas,
      maxPriorityFeePerGas: priority,
    });
    const hash = keccak256(signed);

    // Recorded before the broadcast, so a crash in between leaves a `sent` record that the next run resolves.
    transaction(db, () => {
      insertTx.run(hash, batch.id, opts.from, nonce, gas.toString(), maxFeePerGas.toString(), Date.now());
      markSent.run(batch.id);
    });
    try {
      const returned = (await client.request({ method: 'eth_sendRawTransaction', params: [signed] })) as Hex;
      if (returned.toLowerCase() !== hash) throw new Error(`node returned tx hash ${returned}, signed ${hash}`);
    } catch (err) {
      summary.failure = `batch ${batch.id}: send of ${hash} failed: ${revertReason(err)}`;
      break;
    }
    inflight.set(hash, { batchId: batch.id, sentAt: Date.now(), gas });
    log(`batch ${batch.id}: sent ${hash} nonce ${nonce}, ${batch.op_count} ops, gas limit ${gas}`);
    nonce += 1;
  }

  while (inflight.size > 0) await settle();
  summary.remaining = countNotDone(db);
  return summary;
}

function countNotDone(db: DatabaseSync): number {
  return (db.prepare("SELECT count(*) AS n FROM batches WHERE status <> 'done'").get() as { n: number }).n;
}

async function latestBaseFee(client: PublicClient): Promise<bigint> {
  const block = await client.getBlock({ blockTag: 'latest' });
  if (block.baseFeePerGas === null) throw new Error('latest block has no base fee');
  return block.baseFeePerGas;
}

// Stores a receipt on its tx and batch; returns whether the batch succeeded.
function receiptRecorder(db: DatabaseSync, summary: SendSummary, total: number, log: (line: string) => void) {
  const updateTx = db.prepare('UPDATE txs SET status = ?, block_number = ?, gas_used = ?, fee = ? WHERE hash = ?');
  const updateBatch = db.prepare('UPDATE batches SET status = ? WHERE id = ?');
  return (batchId: number, hash: Hex, receipt: Receipt): boolean => {
    const ok = BigInt(receipt.status) === 1n;
    const gasUsed = BigInt(receipt.gasUsed);
    const fee = gasUsed * BigInt(receipt.effectiveGasPrice);
    const status: BatchStatus = ok ? 'done' : 'reverted';
    transaction(db, () => {
      updateTx.run(ok ? 'success' : 'reverted', Number(BigInt(receipt.blockNumber)), gasUsed.toString(), fee.toString(), hash);
      updateBatch.run(status, batchId);
    });
    summary.gasUsed += gasUsed;
    summary.fee += fee;
    if (ok) summary.done += 1;
    log(`batch ${batchId}/${total}: ${status} in block ${BigInt(receipt.blockNumber)}, gas used ${gasUsed}, fee ${formatEther(fee)} FIL`);
    return ok;
  };
}

// Replays a reverted batch at the block before it to get the revert data. Its ops only zero slots, so it reverts for
// the same reason, except out of gas, which the replay reproduces only because it uses the same gas limit.
async function revertFailure(
  client: PublicClient,
  opts: SendOptions,
  db: DatabaseSync,
  batchId: number,
  hash: Hex,
  receipt: Receipt,
  gas: bigint,
): Promise<string> {
  const head = `batch ${batchId}: reverted in ${hash} (gas used ${BigInt(receipt.gasUsed)} of ${gas})`;
  const batch = db.prepare('SELECT * FROM batches WHERE id = ?').get(batchId) as BatchRow;
  try {
    await client.call({
      account: opts.from,
      to: opts.to,
      data: batchCalldata(db, batch),
      gas,
      blockNumber: BigInt(receipt.blockNumber) - 1n,
    });
    return `${head}; the replay at the block before succeeded`;
  } catch (err) {
    return `${head}; replay: ${revertReason(err)}`;
  }
}

// Settles batches an earlier run left `sent`. A successful receipt makes a batch done. Without a receipt, the run
// waits until no message from the sender is pending; a message still missing then was dropped or replaced, and its
// batch goes back to `planned` to be sent again.
// Sending a batch again is always safe: every op zeroes a fixed slot or pops what is left of a queue, so a second
// execution changes nothing. The only cost is the gas of the second message.
async function resolveSent(
  db: DatabaseSync,
  client: PublicClient,
  from: Address,
  record: (batchId: number, hash: Hex, receipt: Receipt) => boolean,
  opts: { pollMs: number; timeoutMs: number; log: (line: string) => void },
): Promise<void> {
  const started = Date.now();
  const sentTxs = db.prepare(
    "SELECT txs.hash, txs.batch_id FROM txs JOIN batches ON batches.id = txs.batch_id WHERE batches.status = 'sent' AND txs.status = 'sent' ORDER BY txs.nonce",
  );
  for (;;) {
    // Nonces first: if nothing was pending before the receipt lookups, a missing receipt cannot still arrive.
    const latest = await client.getTransactionCount({ address: from, blockTag: 'latest' });
    const pending = await client.getTransactionCount({ address: from, blockTag: 'pending' });
    for (const tx of sentTxs.all() as { hash: Hex; batch_id: number }[]) {
      const receipt = (await client.request({ method: 'eth_getTransactionReceipt', params: [tx.hash] })) as Receipt | null;
      if (receipt) record(tx.batch_id, tx.hash, receipt);
    }
    if (pending === latest) break;
    if (Date.now() - started > opts.timeoutMs) {
      throw new Error(`${pending - latest} messages from ${from} still pending after ${opts.timeoutMs / 1000} s; rerun once they land`);
    }
    opts.log(`waiting for ${pending - latest} pending messages from ${from}`);
    await sleep(opts.pollMs);
  }

  const dropped = sentTxs.all() as { hash: Hex; batch_id: number }[];
  if (dropped.length === 0) return;
  transaction(db, () => {
    const markTx = db.prepare("UPDATE txs SET status = 'dropped' WHERE hash = ?");
    const markBatch = db.prepare("UPDATE batches SET status = 'planned' WHERE id = ?");
    for (const tx of dropped) {
      markTx.run(tx.hash);
      markBatch.run(tx.batch_id);
    }
  });
  opts.log(`${dropped.length} messages recorded as sent never landed; their batches will be sent again`);
}
