import type { DatabaseSync } from 'node:sqlite';
import pg from 'pg';
import { pieceUpserter, replaceLegacyRanges, statusCounts, transaction } from './db.ts';
import { parsePiece } from './ops.ts';

export type FetchOptions = {
  legacyBeforeBlock: number;
  pageSize?: number;
  log?: (line: string) => void;
};

function int(value: unknown, what: string): number {
  const n = Number(value);
  if (!Number.isSafeInteger(n)) throw new Error(`${what} is not an integer: ${String(value)}`);
  return n;
}

// Streams legacy pieces that have metadata from the indexer into `pieces` through a server-side cursor, so memory
// stays flat. Rerunning upserts the same rows; a check result survives unless the metadata changed, and rows the
// indexer does not return, such as the ones `discover` added, stay. Then it replaces the legacy id ranges.
// Connection settings come from DATABASE_URL or the standard PG* variables.
export async function fetchPieces(db: DatabaseSync, opts: FetchOptions): Promise<{ rows: number; invalid: number; ranges: number }> {
  const legacy = `added_at_block < ${int(opts.legacyBeforeBlock, 'legacy block')}`;
  const query = `SELECT data_set_id, piece_id, metadata FROM ozone.pieces WHERE ${legacy} AND jsonb_typeof(metadata) = 'object' AND metadata <> '{}'::jsonb ORDER BY data_set_id, piece_id`;

  const client = new pg.Client(process.env.DATABASE_URL ? { connectionString: process.env.DATABASE_URL } : {});
  await client.connect();
  const upsert = pieceUpserter(db);
  const log = opts.log ?? (() => {});
  const pageSize = opts.pageSize ?? 20_000;
  let rows = 0;
  let invalid = 0;
  let ranges = 0;
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
          upsert({ dataSetId, pieceId, metadata: JSON.stringify(r.metadata), invalid: bad });
        }
      });
      rows += page.rows.length;
      log(`fetched ${rows} pieces`);
    }

    // `discover` reads the pieces in these id ranges that have no row, for metadata the indexer did not record.
    const maxIds = await client.query(`SELECT data_set_id, max(piece_id) AS max_piece_id FROM ozone.pieces WHERE ${legacy} GROUP BY data_set_id`);
    replaceLegacyRanges(
      db,
      maxIds.rows.map((r) => ({ dataSetId: int(r.data_set_id, 'data_set_id'), maxPieceId: int(r.max_piece_id, 'piece_id') })),
    );
    ranges = maxIds.rows.length;
    await client.query('COMMIT');
  } finally {
    await client.end();
  }
  log(`all pieces: ${JSON.stringify(statusCounts(db))}`);
  return { rows, invalid, ranges };
}
