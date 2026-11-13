import type { DatabaseSync } from 'node:sqlite';
import { listBatches, transaction } from './db.ts';
import { decodeOps, KIND_NAMES, opSlots, PHASE_METADATA, PHASE_QUEUE, POP_QUEUE } from './ops.ts';
import { queueSlot } from './slots.ts';
import type { StorageReader } from './storage.ts';

export type Residue = { dataSetId: number; pieceId: number | null; kind: string; slot: bigint; value: bigint };

export type VerifyOptions = {
  sample?: number;
  all?: boolean;
  // Every slot of the batches recorded as done, and the queues all of whose batches are done: checks a pilot.
  done?: boolean;
  // Put every batch that still has residue back to `planned`, so the next `send` sends it again.
  requeue?: boolean;
  pageSize?: number;
  // Residue entries kept in the result; all of them are counted.
  maxListed?: number;
  log?: (line: string) => void;
};

export type VerifyResult = { queues: number; ops: number; slots: number; residueCount: number; residue: Residue[]; requeued: number };

type OpRow = { sort_key: Uint8Array; op: Uint8Array };

// Reads every slot the stored plan zeroes, or a random sample of its metadata ops, plus the length of every planned
// queue, and reports each one that is not zero. `done` reads only what the batches recorded as done zero. It reads
// only what the plan knows: a slot the plan never had, from a wrong key or value length, is invisible here, which is
// why `check` must pass before `plan`.
export async function verifyPlan(db: DatabaseSync, reader: StorageReader, opts: VerifyOptions): Promise<VerifyResult> {
  if ([opts.sample !== undefined, opts.all, opts.done].filter(Boolean).length !== 1) {
    throw new Error('verify needs exactly one of --sample N, --all and --done');
  }
  // Without a plan there is nothing to read, and "0 residue" would look like a pass.
  if ((db.prepare('SELECT count(*) AS n FROM batches').get() as { n: number }).n === 0) {
    throw new Error('this state file has no plan; run plan first');
  }
  const pageSize = opts.pageSize ?? 5000;
  const maxListed = opts.maxListed ?? 100_000;
  const log = opts.log ?? (() => {});
  const result: VerifyResult = { queues: 0, ops: 0, slots: 0, residueCount: 0, residue: [], requeued: 0 };
  const found = (r: Residue) => {
    result.residueCount += 1;
    if (result.residue.length < maxListed) result.residue.push(r);
  };

  const batches = listBatches(db);
  // Like "0 residue" without a plan, "0 residue" before any batch is done would look like a pass.
  if (opts.done && !batches.some((b) => b.status === 'done')) throw new Error('no batch is recorded as done yet');

  // Batches are consecutive sort-key ranges in id order, so the batch of an op is the last one starting at or before it.
  const batchOf = (sortKey: Uint8Array) => {
    let low = 0;
    let high = batches.length - 1;
    while (low < high) {
      const mid = (low + high + 1) >> 1;
      if (Buffer.compare(batches[mid]!.first_key, sortKey) <= 0) low = mid;
      else high = mid - 1;
    }
    const batch = batches[low];
    if (!batch || Buffer.compare(batch.first_key, sortKey) > 0 || Buffer.compare(sortKey, batch.last_key) > 0) {
      throw new Error(`op ${Buffer.from(sortKey).toString('hex')} is in no batch`);
    }
    return batch;
  };
  const requeue = new Set<number>();
  const markBatch = (sortKey: Uint8Array) => {
    if (opts.requeue) requeue.add(batchOf(sortKey).id);
  };

  const phaseStart = (phase: number) => Buffer.from([phase]);
  const popKeys = new Map<number, Uint8Array[]>();
  const pops = db
    .prepare('SELECT sort_key, op FROM ops WHERE sort_key >= ? AND sort_key < ?')
    .all(phaseStart(PHASE_QUEUE), phaseStart(PHASE_METADATA)) as OpRow[];
  for (const { sort_key, op } of pops) {
    for (const decoded of decodeOps(op)) {
      if (decoded.kind !== POP_QUEUE) continue;
      const keys = popKeys.get(decoded.dataSetId) ?? [];
      keys.push(sort_key);
      popKeys.set(decoded.dataSetId, keys);
    }
  }
  const ids = [...popKeys.keys()]
    .filter((id) => !opts.done || popKeys.get(id)!.every((k) => batchOf(k).status === 'done'))
    .sort((a, b) => a - b);
  const lengths = await reader.read(ids.map(queueSlot));
  ids.forEach((dataSetId, i) => {
    if (lengths[i] === 0n) return;
    found({ dataSetId, pieceId: null, kind: 'QueueLength', slot: queueSlot(dataSetId), value: lengths[i]! });

    // Which pop left the entries behind is unknown, and a pop that already ran pops what is left when sent again.
    popKeys.get(dataSetId)!.forEach(markBatch);
  });
  result.queues = ids.length;
  result.slots += ids.length;

  const checkOps = async (rows: OpRow[]) => {
    const targets: { dataSetId: number; pieceId: number; kind: string; slot: bigint; sortKey: Uint8Array }[] = [];
    for (const { sort_key, op } of rows) {
      for (const decoded of decodeOps(op)) {
        if (decoded.kind === POP_QUEUE) continue;
        for (const slot of opSlots(decoded)) {
          targets.push({ dataSetId: decoded.dataSetId, pieceId: decoded.pieceId, kind: KIND_NAMES[decoded.kind], slot, sortKey: sort_key });
        }
      }
    }
    const values = await reader.read(targets.map((t) => t.slot));
    targets.forEach(({ sortKey, ...t }, i) => {
      if (values[i] === 0n) return;
      found({ ...t, value: values[i]! });
      markBatch(sortKey);
    });
    result.ops += rows.length;
    result.slots += targets.length;
  };

  const metadataStart = phaseStart(PHASE_METADATA);
  if (opts.sample !== undefined) {
    const rows = db.prepare('SELECT sort_key, op FROM ops WHERE sort_key >= ? ORDER BY random() LIMIT ?').all(metadataStart, opts.sample) as OpRow[];
    for (let i = 0; i < rows.length; i += pageSize) await checkOps(rows.slice(i, i + pageSize));
  } else if (opts.done) {
    const range = db.prepare('SELECT sort_key, op FROM ops WHERE sort_key BETWEEN ? AND ? ORDER BY sort_key');
    for (const b of batches) {
      if (b.phase === PHASE_QUEUE || b.status !== 'done') continue;
      await checkOps(range.all(b.first_key, b.last_key) as OpRow[]);
      log(`verified ${result.ops} ops, ${result.slots} slots of done batches, residue ${result.residueCount}`);
    }
  } else {
    const page = db.prepare('SELECT sort_key, op FROM ops WHERE sort_key > ? ORDER BY sort_key LIMIT ?');
    // The one-byte phase prefix sorts before every 33-byte key of that phase.
    let after: Uint8Array = metadataStart;
    const started = Date.now();
    for (;;) {
      const rows = page.all(after, pageSize) as OpRow[];
      if (rows.length === 0) break;
      await checkOps(rows);
      after = rows[rows.length - 1]!.sort_key;
      const secs = (Date.now() - started) / 1000;
      log(`verified ${result.ops} ops, ${result.slots} slots in ${secs.toFixed(0)} s, residue ${result.residueCount}`);
    }
  }

  // A message of a put-back batch may still be recorded as sent; the next `send` settles it before it sends anything.
  const reset = db.prepare("UPDATE batches SET status = 'planned' WHERE id = ? AND status <> 'planned'");
  transaction(db, () => {
    for (const id of requeue) result.requeued += Number(reset.run(id).changes);
  });
  return result;
}
