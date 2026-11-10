import { DatabaseSync } from 'node:sqlite';
import type { Batch } from './batches.ts';
import type { PlannedOp } from './ops.ts';

export type PieceStatus = 'unchecked' | 'match' | 'clean' | 'mismatch' | 'invalid';

export type PieceRow = { data_set_id: number; piece_id: number; metadata: string; status: PieceStatus };

export type BatchRow = {
  id: number;
  phase: number;
  first_key: Uint8Array;
  last_key: Uint8Array;
  op_count: number;
  weight: number;
  ops_bytes: number;
  status: string;
};

// ops is clustered by sort_key (WITHOUT ROWID), so a batch is the range [first_key, last_key] and reading ops in send
// order is a sequential scan. sort_key is the phase byte plus the op's first slot, 32 bytes big-endian.
const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS pieces (
  data_set_id INTEGER NOT NULL,
  piece_id INTEGER NOT NULL,
  metadata TEXT NOT NULL,
  removed INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'unchecked',
  detail TEXT,
  PRIMARY KEY (data_set_id, piece_id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS queues (data_set_id INTEGER PRIMARY KEY, length INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS ops (sort_key BLOB PRIMARY KEY, op BLOB NOT NULL) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS batches (
  id INTEGER PRIMARY KEY,
  phase INTEGER NOT NULL,
  first_key BLOB NOT NULL,
  last_key BLOB NOT NULL,
  op_count INTEGER NOT NULL,
  weight INTEGER NOT NULL,
  ops_bytes INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'planned'
);
`;

// Opens or creates the state file, and refuses one made for another network or FWSS proxy.
export function openDb(path: string, network: { name: string; fwss: string }): DatabaseSync {
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA cache_size = -262144;');
  db.exec(SCHEMA);

  const identity = `${network.name} ${network.fwss}`;
  const stored = getMeta(db, 'network');
  if (stored === undefined) setMeta(db, 'network', identity);
  else if (stored !== identity) throw new Error(`${path} belongs to ${stored}, not ${identity}`);
  return db;
}

export function getMeta(db: DatabaseSync, key: string): string | undefined {
  const row = db.prepare('SELECT value FROM meta WHERE key = ?').get(key) as { value: string } | undefined;
  return row?.value;
}

export function setMeta(db: DatabaseSync, key: string, value: string): void {
  db.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value').run(
    key,
    value,
  );
}

export function transaction<T>(db: DatabaseSync, fn: () => T): T {
  db.exec('BEGIN');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

// Keeps a stored check result only while the indexer still reports the same metadata.
export function pieceUpserter(db: DatabaseSync) {
  const stmt = db.prepare(`
    INSERT INTO pieces (data_set_id, piece_id, metadata, removed, status, detail) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT (data_set_id, piece_id) DO UPDATE SET
      removed = excluded.removed,
      status = CASE WHEN pieces.metadata = excluded.metadata THEN pieces.status ELSE excluded.status END,
      detail = CASE WHEN pieces.metadata = excluded.metadata THEN pieces.detail ELSE excluded.detail END,
      metadata = excluded.metadata
  `);
  return (row: { dataSetId: number; pieceId: number; metadata: string; removed: boolean; invalid?: string }) =>
    stmt.run(row.dataSetId, row.pieceId, row.metadata, row.removed ? 1 : 0, row.invalid ? 'invalid' : 'unchecked', row.invalid ?? null);
}

export function setPieceStatus(db: DatabaseSync) {
  const stmt = db.prepare('UPDATE pieces SET status = ?, detail = ? WHERE data_set_id = ? AND piece_id = ?');
  return (dataSetId: number, pieceId: number, status: PieceStatus, detail: string | null) =>
    stmt.run(status, detail, dataSetId, pieceId);
}

// Pieces after (dataSetId, pieceId) in key order, one page at a time, so callers can write between pages.
export function piecePage(db: DatabaseSync, statuses: PieceStatus[]) {
  const placeholders = statuses.map(() => '?').join(', ');
  const stmt = db.prepare(`
    SELECT data_set_id, piece_id, metadata, status FROM pieces
    WHERE (data_set_id, piece_id) > (?, ?) AND status IN (${placeholders})
    ORDER BY data_set_id, piece_id LIMIT ?
  `);
  return (after: [number, number], limit: number) => stmt.all(...after, ...statuses, limit) as PieceRow[];
}

export function statusCounts(db: DatabaseSync): Record<string, number> {
  const rows = db.prepare('SELECT status, count(*) AS n FROM pieces GROUP BY status').all() as {
    status: string;
    n: number;
  }[];
  return Object.fromEntries(rows.map((r) => [r.status, r.n]));
}

export function replaceQueues(db: DatabaseSync, queues: { dataSetId: number; length: number }[], note: string): void {
  transaction(db, () => {
    db.exec('DELETE FROM queues');
    const insert = db.prepare('INSERT INTO queues (data_set_id, length) VALUES (?, ?)');
    for (const q of queues) insert.run(q.dataSetId, q.length);
    setMeta(db, 'queues', note);
  });
}

export function readQueues(db: DatabaseSync): { dataSetId: number; length: number }[] {
  const rows = db.prepare('SELECT data_set_id, length FROM queues ORDER BY data_set_id').all() as {
    data_set_id: number;
    length: number;
  }[];
  return rows.map((r) => ({ dataSetId: r.data_set_id, length: r.length }));
}

export function opInserter(db: DatabaseSync) {
  const stmt = db.prepare('INSERT INTO ops (sort_key, op) VALUES (?, ?)');
  return (op: PlannedOp) => stmt.run(op.sortKey, op.op);
}

// Ops in send order, optionally limited to one batch's range.
export function* iterateOps(db: DatabaseSync, range?: { first: Uint8Array; last: Uint8Array }): Generator<PlannedOp> {
  const rows = range
    ? db.prepare('SELECT sort_key, op FROM ops WHERE sort_key BETWEEN ? AND ? ORDER BY sort_key').iterate(range.first, range.last)
    : db.prepare('SELECT sort_key, op FROM ops ORDER BY sort_key').iterate();
  for (const row of rows as Iterable<{ sort_key: Uint8Array; op: Uint8Array }>) {
    yield { sortKey: row.sort_key, op: row.op };
  }
}

export function insertBatches(db: DatabaseSync, batches: Batch[]): void {
  const stmt = db.prepare(
    'INSERT INTO batches (id, phase, first_key, last_key, op_count, weight, ops_bytes) VALUES (?, ?, ?, ?, ?, ?, ?)',
  );
  transaction(db, () => {
    batches.forEach((b, i) => stmt.run(i + 1, b.phase, b.firstKey, b.lastKey, b.opCount, b.weight, b.opsBytes));
  });
}

export function listBatches(db: DatabaseSync): BatchRow[] {
  return db.prepare('SELECT * FROM batches ORDER BY id').all() as BatchRow[];
}

// The `ops` argument of one batch: its ops concatenated in sort-key order.
export function batchCalldataOps(db: DatabaseSync, batch: BatchRow): Uint8Array {
  const parts = [...iterateOps(db, { first: batch.first_key, last: batch.last_key })].map((o) => o.op);
  if (parts.length !== batch.op_count) {
    throw new Error(`batch ${batch.id}: ${parts.length} ops in range, planned ${batch.op_count}`);
  }
  return Buffer.concat(parts);
}
