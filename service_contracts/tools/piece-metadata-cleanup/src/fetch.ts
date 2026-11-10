import type { DatabaseSync } from 'node:sqlite';
import pg from 'pg';
import { pieceUpserter, statusCounts, transaction } from './db.ts';
import { parsePiece } from './ops.ts';

export type FetchOptions = {
  legacyBeforeBlock: number;
  // Keep only pieces with (data_set_id + piece_id) % stride = 0: a sample spread over all data sets.
  stride?: number;
  limit?: number;
  pageSize?: number;
  log?: (line: string) => void;
};

function int(value: unknown, what: string): number {
  const n = Number(value);
  if (!Number.isSafeInteger(n)) throw new Error(`${what} is not an integer: ${String(value)}`);
  return n;
}

// Streams legacy pieces that have metadata from the indexer into `pieces` through a server-side cursor, so memory
// stays flat. Rerunning upserts the same rows; a check result survives unless the metadata changed.
// Connection settings come from DATABASE_URL or the standard PG* variables.
export async function fetchPieces(db: DatabaseSync, opts: FetchOptions): Promise<{ rows: number; invalid: number }> {
  const filters = [`added_at_block < ${int(opts.legacyBeforeBlock, 'legacy block')}`, `jsonb_typeof(metadata) = 'object'`, `metadata <> '{}'::jsonb`];
  if (opts.stride !== undefined) filters.push(`(data_set_id + piece_id) % ${int(opts.stride, 'stride')} = 0`);
  const limit = opts.limit !== undefined ? ` LIMIT ${int(opts.limit, 'limit')}` : '';
  const query = `SELECT data_set_id, piece_id, metadata, removed FROM ozone.pieces WHERE ${filters.join(' AND ')} ORDER BY data_set_id, piece_id${limit}`;

  const client = new pg.Client(process.env.DATABASE_URL ? { connectionString: process.env.DATABASE_URL } : {});
  await client.connect();
  const upsert = pieceUpserter(db);
  const log = opts.log ?? (() => {});
  const pageSize = opts.pageSize ?? 20_000;
  let rows = 0;
  let invalid = 0;
  try {
    await client.query('BEGIN READ ONLY');
    await client.query(`DECLARE pieces NO SCROLL CURSOR FOR ${query}`);
    for (;;) {
      const page = await client.query('FETCH FORWARD ' + pageSize + ' FROM pieces');
      if (page.rows.length === 0) break;
      transaction(db, () => {
        for (const r of page.rows) {
          const dataSetId = int(r.data_set_id, 'data_set_id');
          const pieceId = int(r.piece_id, 'piece_id');
          const parsed = parsePiece(dataSetId, pieceId, r.metadata);
          const bad = 'invalid' in parsed ? parsed.invalid : undefined;
          if (bad) invalid += 1;
          upsert({ dataSetId, pieceId, metadata: JSON.stringify(r.metadata), removed: r.removed === true, invalid: bad });
        }
      });
      rows += page.rows.length;
      log(`fetched ${rows} pieces`);
    }
    await client.query('COMMIT');
  } finally {
    await client.end();
  }
  log(`all pieces: ${JSON.stringify(statusCounts(db))}`);
  return { rows, invalid };
}
