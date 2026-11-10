import type { DatabaseSync } from 'node:sqlite';
import { piecePage, setPieceStatus, statusCounts, transaction, type PieceRow, type PieceStatus } from './db.ts';
import { parsePiece, type Piece } from './ops.ts';
import { hex32, keysSlot, stringHead, valueSlots } from './slots.ts';
import type { StorageReader } from './storage.ts';

// Slots that prove the tool knows a piece: the key count, and each value head, which holds the length and, for a
// short value, the bytes themselves. A wrong key reads as an empty head.
export function checkSlots(piece: Piece): { slots: bigint[]; expected: bigint[] } {
  const valueSlot = valueSlots(piece.dataSetId, piece.pieceId);
  const slots = [keysSlot(piece.dataSetId, piece.pieceId)];
  const expected = [BigInt(piece.entries.length)];
  for (const { key, value } of piece.entries) {
    slots.push(valueSlot(key));
    expected.push(stringHead(value)); // 0 for an empty value, which has no slot
  }
  return { slots, expected };
}

// `clean`: storage holds nothing of the piece (the old removal queue deleted it). `match`: storage holds exactly what
// the indexer says. Anything else is `mismatch`, and the piece must not be planned from this metadata.
export function classify(piece: Piece, actual: readonly bigint[]): { status: PieceStatus; detail: string | null } {
  const { slots, expected } = checkSlots(piece);
  if (actual.every((v) => v === 0n)) return { status: 'clean', detail: null };

  const diffs: string[] = [];
  if (actual[0] !== expected[0]) diffs.push(`keys length ${actual[0]}, expected ${expected[0]}`);
  piece.entries.forEach(({ key }, i) => {
    if (actual[i + 1] !== expected[i + 1]) {
      diffs.push(
        `value ${JSON.stringify(Buffer.from(key).toString('utf8'))} at ${hex32(slots[i + 1]!)} holds ${hex32(actual[i + 1]!)}, expected ${hex32(expected[i + 1]!)}`,
      );
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
  } else if (opts.all) {
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
  } else {
    throw new Error('check needs --sample N or --all');
  }

  log(`all pieces: ${JSON.stringify(statusCounts(db))}`);
  return totals;
}
