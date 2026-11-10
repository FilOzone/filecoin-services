import type { DatabaseSync } from 'node:sqlite';
import { decodeOps, KIND_NAMES, opSlots, PHASE_METADATA, PHASE_QUEUE, POP_QUEUE } from './ops.ts';
import { queueSlot } from './slots.ts';
import type { StorageReader } from './storage.ts';

export type Residue = { dataSetId: number; pieceId: number | null; kind: string; slot: bigint; value: bigint };

export type VerifyOptions = {
  sample?: number;
  all?: boolean;
  pageSize?: number;
  // Residue entries kept in the result; all of them are counted.
  maxListed?: number;
  log?: (line: string) => void;
};

export type VerifyResult = { queues: number; ops: number; slots: number; residueCount: number; residue: Residue[] };

// Reads every slot the stored plan zeroes, or a random sample of its metadata ops, plus the length of every planned
// queue, and reports each one that is not zero. It reads only what the plan knows: a slot the plan never had, from a
// wrong key or value length, is invisible here, which is why `check` must run first.
export async function verifyPlan(db: DatabaseSync, reader: StorageReader, opts: VerifyOptions): Promise<VerifyResult> {
  if (opts.sample === undefined && !opts.all) throw new Error('verify needs --sample N or --all');
  const pageSize = opts.pageSize ?? 5000;
  const maxListed = opts.maxListed ?? 100_000;
  const log = opts.log ?? (() => {});
  const result: VerifyResult = { queues: 0, ops: 0, slots: 0, residueCount: 0, residue: [] };
  const found = (r: Residue) => {
    result.residueCount += 1;
    if (result.residue.length < maxListed) result.residue.push(r);
  };

  const phaseStart = (phase: number) => Buffer.from([phase]);
  const queueIds = new Set<number>();
  const pops = db.prepare('SELECT op FROM ops WHERE sort_key >= ? AND sort_key < ?').all(phaseStart(PHASE_QUEUE), phaseStart(PHASE_METADATA)) as {
    op: Uint8Array;
  }[];
  for (const { op } of pops) {
    for (const decoded of decodeOps(op)) if (decoded.kind === POP_QUEUE) queueIds.add(decoded.dataSetId);
  }
  const ids = [...queueIds].sort((a, b) => a - b);
  const lengths = await reader.read(ids.map(queueSlot));
  ids.forEach((dataSetId, i) => {
    if (lengths[i] !== 0n) found({ dataSetId, pieceId: null, kind: 'QueueLength', slot: queueSlot(dataSetId), value: lengths[i]! });
  });
  result.queues = ids.length;
  result.slots += ids.length;

  const checkOps = async (rows: { op: Uint8Array }[]) => {
    const targets: { dataSetId: number; pieceId: number; kind: string; slot: bigint }[] = [];
    for (const { op } of rows) {
      for (const decoded of decodeOps(op)) {
        if (decoded.kind === POP_QUEUE) continue;
        for (const slot of opSlots(decoded)) {
          targets.push({ dataSetId: decoded.dataSetId, pieceId: decoded.pieceId, kind: KIND_NAMES[decoded.kind], slot });
        }
      }
    }
    const values = await reader.read(targets.map((t) => t.slot));
    targets.forEach((t, i) => {
      if (values[i] !== 0n) found({ ...t, value: values[i]! });
    });
    result.ops += rows.length;
    result.slots += targets.length;
  };

  const metadataStart = phaseStart(PHASE_METADATA);
  if (opts.sample !== undefined) {
    const rows = db.prepare('SELECT op FROM ops WHERE sort_key >= ? ORDER BY random() LIMIT ?').all(metadataStart, opts.sample) as {
      op: Uint8Array;
    }[];
    for (let i = 0; i < rows.length; i += pageSize) await checkOps(rows.slice(i, i + pageSize));
  } else {
    const page = db.prepare('SELECT sort_key, op FROM ops WHERE sort_key > ? ORDER BY sort_key LIMIT ?');
    // The one-byte phase prefix sorts before every 33-byte key of that phase.
    let after: Uint8Array = metadataStart;
    const started = Date.now();
    for (;;) {
      const rows = page.all(after, pageSize) as { sort_key: Uint8Array; op: Uint8Array }[];
      if (rows.length === 0) break;
      await checkOps(rows);
      after = rows[rows.length - 1]!.sort_key;
      const secs = (Date.now() - started) / 1000;
      log(`verified ${result.ops} ops, ${result.slots} slots in ${secs.toFixed(0)} s, residue ${result.residueCount}`);
    }
  }
  return result;
}
