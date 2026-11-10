import type { DatabaseSync } from 'node:sqlite';
import { calldataBytes, cutBatches, type Batch, type BatchLimits } from './batches.ts';
import { getMeta, insertBatches, iterateOps, opInserter, piecePage, readQueues, sendStarted, transaction } from './db.ts';
import { KIND_NAMES, decodeOps, parsePiece, plannedPieceOps, plannedQueueOps, POP_QUEUE, VALUE_DATA } from './ops.ts';

export type PlanTotals = {
  pieces: number;
  // Of `pieces`, the ones planned without a check (--allow-unchecked).
  unchecked: number;
  queues: number;
  opsByKind: Record<string, number>;
  ops: number;
  metadataSlots: number;
  queueEntries: number;
  batches: number;
  queueBatches: number;
  opsBytes: number;
  calldataBytes: number;
  skipped: Record<string, number>;
};

// Rebuilds ops and batches from the pieces and queues tables. Pieces checked `match` or `clean` are planned, and with
// `allowUnchecked` also the ones never checked. `mismatch` and `invalid` pieces are left out, because ops built from
// wrong metadata leave residue the facet cannot notice.
export function buildPlan(db: DatabaseSync, limits: BatchLimits, opts: { allowUnchecked?: boolean } = {}): PlanTotals {
  if (sendStarted(db)) {
    throw new Error('a message was already sent from this state file; to finish the cleanup run verify --requeue, then send');
  }
  if (getMeta(db, 'queues') === undefined) throw new Error('no queue lengths stored; run `queues` first');

  const unchecked = (db.prepare("SELECT count(*) AS n FROM pieces WHERE status = 'unchecked'").get() as { n: number }).n;
  if (unchecked > 0 && !opts.allowUnchecked) {
    throw new Error(`${unchecked} pieces are unchecked; run check --all first, or plan them unchecked with --allow-unchecked`);
  }

  const totals: PlanTotals = {
    pieces: 0,
    unchecked,
    queues: 0,
    opsByKind: Object.fromEntries(KIND_NAMES.map((k) => [k, 0])),
    ops: 0,
    metadataSlots: 0,
    queueEntries: 0,
    batches: 0,
    queueBatches: 0,
    opsBytes: 0,
    calldataBytes: 0,
    skipped: {},
  };
  const insert = opInserter(db);
  const count = (op: Uint8Array) => {
    const [decoded] = decodeOps(op);
    totals.opsByKind[KIND_NAMES[decoded!.kind]]! += 1;
    totals.ops += 1;
    if (decoded!.kind === POP_QUEUE) totals.queueEntries += decoded!.count;
    else totals.metadataSlots += decoded!.kind === VALUE_DATA ? decoded!.count : 1;
  };

  // One transaction: a crash keeps the old plan instead of leaving a state file without batches.
  transaction(db, () => {
    db.exec('DELETE FROM batches; DELETE FROM ops;');

    for (const q of readQueues(db)) {
      for (const op of plannedQueueOps(q.dataSetId, q.length, limits.maxOps)) {
        insert(op);
        count(op.op);
      }
      totals.queues += 1;
    }

    const page = piecePage(db, ['unchecked', 'match', 'clean']);
    let after: [number, number] = [-1, -1];
    for (;;) {
      const rows = page(after, 20_000);
      if (rows.length === 0) break;
      for (const row of rows) {
        const parsed = parsePiece(row.data_set_id, row.piece_id, JSON.parse(row.metadata));
        if ('invalid' in parsed) throw new Error(`piece ${row.data_set_id}/${row.piece_id} became invalid: ${parsed.invalid}`);
        for (const op of plannedPieceOps(parsed.piece)) {
          insert(op);
          count(op.op);
        }
        totals.pieces += 1;
      }
      const last = rows[rows.length - 1]!;
      after = [last.data_set_id, last.piece_id];
    }

    const batches: Batch[] = [...cutBatches(iterateOps(db), limits)];
    insertBatches(db, batches);
    for (const b of batches) {
      totals.batches += 1;
      if (b.phase === 0) totals.queueBatches += 1;
      totals.opsBytes += b.opsBytes;
      totals.calldataBytes += calldataBytes(b.opsBytes);
    }
  });

  const skipped = db
    .prepare("SELECT status, count(*) AS n FROM pieces WHERE status NOT IN ('unchecked', 'match', 'clean') GROUP BY status")
    .all() as { status: string; n: number }[];
  totals.skipped = Object.fromEntries(skipped.map((r) => [r.status, r.n]));
  return totals;
}

// Pieces the plan leaves out for a reason someone must look at.
export function excludedPieces(db: DatabaseSync): { data_set_id: number; piece_id: number; status: string; detail: string | null }[] {
  return db
    .prepare("SELECT data_set_id, piece_id, status, detail FROM pieces WHERE status IN ('invalid', 'mismatch') ORDER BY data_set_id, piece_id")
    .all() as { data_set_id: number; piece_id: number; status: string; detail: string | null }[];
}
