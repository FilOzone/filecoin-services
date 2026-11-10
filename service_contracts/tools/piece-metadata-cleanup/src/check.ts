import type { DatabaseSync } from 'node:sqlite';
import { batchesStarted, piecePage, setPieceStatus, statusCounts, transaction, type PieceRow, type PieceStatus } from './db.ts';
import { parsePiece, type Piece } from './ops.ts';
import { addSlot, dataSlot, hex32, keysSlot, stringDataSlots, stringHead, valueSlots } from './slots.ts';
import type { StorageReader } from './storage.ts';

// Slots that prove the tool knows a piece: the key count, the key array elements, and each value head, which holds
// the length and, for a short value, the bytes themselves. A wrong key reads as an empty head and a foreign element.
export function checkSlots(piece: Piece): { slots: bigint[]; keyHeads: bigint[]; valueHeads: bigint[] } {
  const keys = keysSlot(piece.dataSetId, piece.pieceId);
  const elements = dataSlot(keys);
  const valueSlot = valueSlots(piece.dataSetId, piece.pieceId);
  return {
    slots: [keys, ...piece.entries.map((_, j) => addSlot(elements, j)), ...piece.entries.map(({ key }) => valueSlot(key))],
    keyHeads: piece.entries.map(({ key }) => stringHead(key)),
    valueHeads: piece.entries.map(({ value }) => stringHead(value)), // 0 for an empty value, which has no slot
  };
}

// The slots of a piece that checkSlots leaves out: the data slots of values of 32 bytes or more.
function valueDataSlots(piece: Piece): bigint[] {
  const valueSlot = valueSlots(piece.dataSetId, piece.pieceId);
  return piece.entries.flatMap(({ key, value }) => {
    const first = dataSlot(valueSlot(key));
    return Array.from({ length: stringDataSlots(value.length) }, (_, i) => addSlot(first, i));
  });
}

// `clean`: storage holds nothing of the piece (the old removal queue deleted it). `match`: storage holds exactly the
// keys and value heads the indexer says. Anything else is `mismatch`, and the piece must not be planned from this
// metadata.
export function classify(piece: Piece, actual: readonly bigint[]): { status: PieceStatus; detail: string | null } {
  if (actual.every((v) => v === 0n)) return { status: 'clean', detail: null };

  const { slots, keyHeads, valueHeads } = checkSlots(piece);
  const count = piece.entries.length;
  const name = (key: Uint8Array) => JSON.stringify(Buffer.from(key).toString('utf8'));
  const diffs: string[] = [];
  if (actual[0] !== BigInt(count)) diffs.push(`keys length ${actual[0]}, expected ${count}`);

  // The chain keeps keys in insertion order, which the indexer does not record, so the elements compare as a multiset.
  const unexpected = actual.slice(1, 1 + count);
  const missing: string[] = [];
  piece.entries.forEach(({ key }, i) => {
    const at = unexpected.indexOf(keyHeads[i]!);
    if (at < 0) missing.push(name(key));
    else unexpected.splice(at, 1);
  });
  if (missing.length > 0) diffs.push(`key elements lack ${missing.join(', ')} and hold ${unexpected.map(hex32).join(', ')} instead`);

  piece.entries.forEach(({ key }, i) => {
    const at = 1 + count + i;
    if (actual[at] !== valueHeads[i]) {
      diffs.push(`value ${name(key)} at ${hex32(slots[at]!)} holds ${hex32(actual[at]!)}, expected ${hex32(valueHeads[i]!)}`);
    }
  });
  return diffs.length === 0 ? { status: 'match', detail: null } : { status: 'mismatch', detail: diffs.join('; ') };
}

function toPiece(row: PieceRow): Piece {
  const parsed = parsePiece(row.data_set_id, row.piece_id, JSON.parse(row.metadata));
  if ('invalid' in parsed) throw new Error(`piece ${row.data_set_id}/${row.piece_id} is invalid: ${parsed.invalid}`);
  return parsed.piece;
}

export type CheckOptions = { sample?: number; all?: boolean; recheck?: boolean; pageSize?: number; log?: (line: string) => void };

// Checks pieces against storage and stores each result. `sample` picks random pieces; `all` walks every piece in
// key order and resumes where an earlier run stopped, because it skips pieces already checked unless `recheck`.
export async function checkPieces(db: DatabaseSync, reader: StorageReader, opts: CheckOptions): Promise<Record<PieceStatus, number>> {
  if ((opts.sample !== undefined) === Boolean(opts.all)) throw new Error('check needs exactly one of --sample N and --all');

  // Ops of one piece land in different batches, so a partly sent plan leaves pieces that read as clean or as a
  // mismatch here while the plan still holds the ops that finish them.
  const left = batchesStarted(db);
  if (left > 0) {
    throw new Error(
      `sending has started (${left} batches left the planned state), and check is only valid before that; to recover, run verify --requeue, then send`,
    );
  }

  const statuses: PieceStatus[] = opts.recheck ? ['unchecked', 'match', 'clean', 'mismatch'] : ['unchecked'];
  const pageSize = opts.pageSize ?? 2000;
  const log = opts.log ?? (() => {});
  const totals: Record<PieceStatus, number> = { unchecked: 0, match: 0, clean: 0, mismatch: 0, invalid: 0 };
  const save = setPieceStatus(db);

  const checkRows = async (rows: PieceRow[]) => {
    const pieces = rows.map(toPiece);
    const plans = pieces.map(checkSlots);
    const values = await reader.read(plans.flatMap((p) => p.slots));
    let at = 0;
    const results = pieces.map((piece, i) => {
      const actual = values.slice(at, at + plans[i]!.slots.length);
      at += plans[i]!.slots.length;
      return classify(piece, actual);
    });

    // Zero heads do not prove zero data slots: a plan sent partly from another state file clears them separately.
    // `clean` takes a piece out of the plan for good, so it has to mean that nothing is left.
    const clean = results.flatMap((r, i) => (r.status === 'clean' ? [i] : []));
    const dataSlots = clean.map((i) => valueDataSlots(pieces[i]!));
    const dataValues = await reader.read(dataSlots.flat());
    let from = 0;
    clean.forEach((i, n) => {
      const set = dataValues.slice(from, from + dataSlots[n]!.length).filter((v) => v !== 0n).length;
      from += dataSlots[n]!.length;
      if (set > 0) results[i] = { status: 'mismatch', detail: `keys and value heads are zero, but ${set} value data slots are set` };
    });
    transaction(db, () => {
      results.forEach((r, i) => {
        save(pieces[i]!.dataSetId, pieces[i]!.pieceId, r.status, r.detail);
        totals[r.status] += 1;
      });
    });
  };

  const started = Date.now();
  const progress = (done: number) => {
    const secs = (Date.now() - started) / 1000;
    log(`checked ${done} pieces in ${secs.toFixed(0)} s (${(done / secs).toFixed(1)} pieces/s): ${JSON.stringify(totals)}`);
  };

  if (opts.sample !== undefined) {
    const placeholders = statuses.map(() => '?').join(', ');
    const rows = db
      .prepare(`SELECT data_set_id, piece_id, metadata, status FROM pieces WHERE status IN (${placeholders}) ORDER BY random() LIMIT ?`)
      .all(...statuses, opts.sample) as PieceRow[];
    for (let i = 0; i < rows.length; i += pageSize) {
      await checkRows(rows.slice(i, i + pageSize));
      progress(Math.min(i + pageSize, rows.length));
    }
  } else {
    const page = piecePage(db, statuses);
    let after: [number, number] = [-1, -1];
    let done = 0;
    for (;;) {
      const rows = page(after, pageSize);
      if (rows.length === 0) break;
      await checkRows(rows);
      done += rows.length;
      const last = rows[rows.length - 1]!;
      after = [last.data_set_id, last.piece_id];
      progress(done);
    }
  }

  log(`all pieces: ${JSON.stringify(statusCounts(db))}`);
  return totals;
}

// Pieces whose storage differs from the indexer row; someone must look at each before the cleanup.
export function mismatchedPieces(db: DatabaseSync): { data_set_id: number; piece_id: number; detail: string | null }[] {
  return db
    .prepare("SELECT data_set_id, piece_id, detail FROM pieces WHERE status = 'mismatch' ORDER BY data_set_id, piece_id")
    .all() as { data_set_id: number; piece_id: number; detail: string | null }[];
}
