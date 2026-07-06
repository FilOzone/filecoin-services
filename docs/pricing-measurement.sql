-- ============================================================================
-- FWSS per-operation gas/cost measurement harness
-- ============================================================================
-- Companion to pricing-rationale.md (this directory): the x10 methodology,
-- results, and open items live there. This file is just the queries.
--
-- Running: paste each block into the foc-observer `query_sql` tool, mainnet.
-- The tool rejects a trailing semicolon, so blocks carry none.
--
-- Schema: gas_used / effective_gas_price are in the `tx_meta` view (one row per
-- tx), joined by tx_hash, NOT on event rows. Dedupe to one row per tx
-- (MAX(m.gas_used) GROUP BY tx_hash). Never average effective_gas_price over a
-- per-event join (a 40-piece addPieces would weight that price 40x); average it
-- over tx_meta directly (block [0]).
--
-- Version boundary: mainnet executed v1.3.0 on 2026-06-12; createDataSet and
-- terminateService changed then (sybil burn removed; consent-method terminate),
-- so those blocks filter to >= '2026-06-12 18:00+00'. Gas-stable ops can use a
-- longer window. Each block inlines the x10 multiplier and FIL=$1 as `* 1.0 *
-- 10.0`, and the lookback as a `- 2592000` (30d) literal; edit them in place.
-- ============================================================================


-- ============================================================================
-- [0] REFERENCE GAS PRICE  (mainnet)  -- tx-weighted, attoFIL per gas unit
-- ============================================================================
SELECT ROUND(AVG(effective_gas_price::numeric)) AS ref_price_attofil,
       COUNT(*)                                 AS n_txs
FROM tx_meta
WHERE timestamp::bigint > (SELECT MAX(timestamp::bigint) FROM tx_meta) - 2592000


-- ============================================================================
-- [1] createDataSet, no-CDN  (mainnet, v1.3.0 era)
-- ============================================================================
-- = (create+add combo, 1 piece, no meta) - (warm 1-piece no-meta add), gas units.
-- v1.3.0 era only (pre-upgrade combos carry the sybil burn). Cross-check vs a lone
-- 0-piece create (np=0) when one exists.
WITH wa AS (
  SELECT AVG(g) AS warm_add_gas FROM (
    SELECT MAX(m.gas_used::numeric) AS g
    FROM fwss_piece_added p
    JOIN tx_meta m USING (tx_hash)
    LEFT JOIN fwss_data_set_created c2 ON c2.tx_hash = p.tx_hash
    WHERE c2.tx_hash IS NULL
      AND to_timestamp(m.timestamp::bigint) >= TIMESTAMP '2026-06-12 18:00+00'
    GROUP BY p.tx_hash HAVING COUNT(*) = 1 AND COUNT(p.metadata) = 0
  ) s
),
px AS (
  SELECT AVG(effective_gas_price::numeric) AS ref_price
  FROM tx_meta
  WHERE timestamp::bigint > (SELECT MAX(timestamp::bigint) FROM tx_meta) - 2592000
),
ca AS (
  SELECT c.with_cdn, MAX(m.gas_used::numeric) AS gas,
         COUNT(pa.piece_id) AS np, COUNT(pa.metadata) AS npm, MIN(m.timestamp::bigint) AS ts
  FROM fwss_data_set_created c
  JOIN tx_meta m USING (tx_hash)
  JOIN fwss_piece_added pa ON pa.tx_hash = c.tx_hash
  GROUP BY c.tx_hash, c.with_cdn
)
SELECT ca.with_cdn,
       COUNT(*)                                                            AS n,
       ROUND(AVG(ca.gas) - wa.warm_add_gas)                                AS cds_gas,
       ROUND(px.ref_price)                                                 AS ref_price_attofil,
       ROUND((AVG(ca.gas) - wa.warm_add_gas) * px.ref_price / 1e18, 7)     AS cds_fil,
       ROUND((AVG(ca.gas) - wa.warm_add_gas) * px.ref_price / 1e18
             * 1.0 * 10.0, 4)                                              AS fee_usdfc_10x
FROM ca CROSS JOIN wa CROSS JOIN px
WHERE ca.np = 1 AND ca.npm = 0
  AND to_timestamp(ca.ts) >= TIMESTAMP '2026-06-12 18:00+00'
GROUP BY ca.with_cdn, wa.warm_add_gas, px.ref_price
ORDER BY ca.with_cdn


-- ============================================================================
-- [2a] addPieces N=1 gas  (mainnet, v1.3.0 era)
-- ============================================================================
-- Split no-meta vs meta: ~99% of real adds carry ~1 metadata key (+~100M gas).
SELECT bucket, COUNT(*) AS n, ROUND(AVG(gas)) AS add_n1_gas
FROM (
  SELECT p.tx_hash, MAX(m.gas_used::numeric) AS gas,
         CASE WHEN COUNT(p.metadata) = 0 THEN 'no-meta' ELSE 'meta' END AS bucket
  FROM fwss_piece_added p
  JOIN tx_meta m USING (tx_hash)
  LEFT JOIN fwss_data_set_created c ON c.tx_hash = p.tx_hash
  WHERE c.tx_hash IS NULL
    AND to_timestamp(m.timestamp::bigint) >= TIMESTAMP '2026-06-12 18:00+00'
  GROUP BY p.tx_hash HAVING COUNT(*) = 1
) t
GROUP BY bucket


-- ============================================================================
-- [2b] addPieces marginal gas/piece  (mainnet, v1.3.0 era)
-- ============================================================================
-- Least-squares slope gas = A + B*N over per-N mean gas (>=5 txs/bucket). Mainnet
-- batches post-GA, so B is measurable here. Needs >=2 distinct N buckets.
SELECT
  ROUND((cnt*sxy - sx*sy) / NULLIF(cnt*sxx - sx*sx, 0))                                  AS marginal_B_gas,
  ROUND((sy - ((cnt*sxy - sx*sy) / NULLIF(cnt*sxx - sx*sx, 0))*sx) / NULLIF(cnt, 0))      AS base_A_gas,
  cnt                                                                                    AS n_buckets
FROM (
  SELECT COUNT(*) AS cnt, SUM(n) AS sx, SUM(g) AS sy, SUM(n*g) AS sxy, SUM(n*n) AS sxx
  FROM (
    SELECT t.n_pieces AS n, AVG(t.gas) AS g
    FROM (
      SELECT p.tx_hash, COUNT(*) AS n_pieces, MAX(m.gas_used::numeric) AS gas
      FROM fwss_piece_added p
      JOIN tx_meta m USING (tx_hash)
      LEFT JOIN fwss_data_set_created c ON c.tx_hash = p.tx_hash
      WHERE c.tx_hash IS NULL
        AND to_timestamp(m.timestamp::bigint) >= TIMESTAMP '2026-06-12 18:00+00'
      GROUP BY p.tx_hash
    ) t
    GROUP BY t.n_pieces HAVING COUNT(*) >= 5
  ) per_n
) agg

-- [2b-table] Eyeball the per-N points behind the fit
-- SELECT t.n_pieces AS N, COUNT(*) AS txs, ROUND(AVG(t.gas)/1e6,1) AS avg_mgas
-- FROM (
--   SELECT p.tx_hash, COUNT(*) AS n_pieces, MAX(m.gas_used::numeric) AS gas
--   FROM fwss_piece_added p JOIN tx_meta m USING (tx_hash)
--   LEFT JOIN fwss_data_set_created c ON c.tx_hash = p.tx_hash
--   WHERE c.tx_hash IS NULL AND to_timestamp(m.timestamp::bigint) >= TIMESTAMP '2026-06-12 18:00+00'
--   GROUP BY p.tx_hash
-- ) t GROUP BY t.n_pieces HAVING COUNT(*) >= 5 ORDER BY t.n_pieces


-- ============================================================================
-- [3] terminateService  (mainnet, v1.3.0 era)
-- ============================================================================
-- v1.3.0 consent method zeroes the PDP rail lockup (cheap). Event covers user-
-- and SP-initiated; gas is similar.
SELECT COUNT(*)                                                       AS n,
       ROUND(AVG(m.gas_used::numeric))                                AS op_gas,
       ROUND(AVG(m.effective_gas_price::numeric))                     AS ref_price_attofil,
       ROUND(AVG(m.gas_used::numeric * m.effective_gas_price::numeric) / 1e18, 7) AS op_fil,
       ROUND(AVG(m.gas_used::numeric * m.effective_gas_price::numeric) / 1e18
             * 1.0 * 10.0, 4)                                         AS fee_usdfc_10x
FROM fwss_service_terminated t
JOIN tx_meta m USING (tx_hash)
WHERE to_timestamp(m.timestamp::bigint) >= TIMESTAMP '2026-06-12 18:00+00'


-- ============================================================================
-- [4] Proving (recurring)  (mainnet)
-- ============================================================================
-- Two txs per period (nextProvingPeriod + provePossession, never the same tx),
-- summed x30 (mainnet: 1 period/day). Excludes nextPP txs that also process
-- removals (inflated; see [5]).
WITH npp AS (
  SELECT AVG(g) AS gas, AVG(price) AS price FROM (
    SELECT MAX(m.gas_used::numeric) AS g, MAX(m.effective_gas_price::numeric) AS price
    FROM pdp_next_proving_period n
    JOIN tx_meta m USING (tx_hash)
    WHERE n.set_id IN (SELECT data_set_id FROM fwss_data_set_created)
      AND m.timestamp::bigint > (SELECT MAX(timestamp::bigint) FROM tx_meta) - 2592000
      AND NOT EXISTS (SELECT 1 FROM pdp_pieces_removed r WHERE r.tx_hash = n.tx_hash)
    GROUP BY n.tx_hash
  ) s
),
pp AS (
  SELECT AVG(g) AS gas FROM (
    SELECT MAX(m.gas_used::numeric) AS g
    FROM pdp_possession_proven p
    JOIN tx_meta m USING (tx_hash)
    WHERE p.set_id IN (SELECT data_set_id FROM fwss_data_set_created)
      AND m.timestamp::bigint > (SELECT MAX(timestamp::bigint) FROM tx_meta) - 2592000
    GROUP BY p.tx_hash
  ) s
)
SELECT ROUND(npp.gas)                                                          AS next_pp_gas,
       ROUND(pp.gas)                                                           AS prove_gas,
       ROUND((npp.gas + pp.gas) * 30)                                          AS monthly_gas,
       ROUND(npp.price)                                                        AS ref_price_attofil,
       ROUND((npp.gas + pp.gas) * 30 * npp.price / 1e18, 7)                    AS monthly_fil,
       ROUND((npp.gas + pp.gas) * 30 * npp.price / 1e18 * 1.0 * 10.0, 4)       AS proving_fee_usdfc_per_month_10x
FROM npp CROSS JOIN pp


-- ============================================================================
-- [5] schedulePieceRemovals  (mainnet)  -- BEST-EFFORT, entangled
-- ============================================================================
-- The enqueue emits no event (FilOzone/pdp#281); the delete runs inside
-- nextProvingPeriod, fused with proving. Estimates the per-piece processing
-- premium = (removal-processing nextPP gas - baseline nextPP gas) / pieces.
-- Upper-bound sketch only; pricing-rationale.md section 5. Both CTEs use a 30d
-- window (removals are sparse; widen the literal if the sample is too small).
WITH base AS (
  SELECT AVG(g) AS gas FROM (
    SELECT MAX(m.gas_used::numeric) AS g
    FROM pdp_next_proving_period n
    JOIN tx_meta m USING (tx_hash)
    WHERE n.set_id IN (SELECT data_set_id FROM fwss_data_set_created)
      AND m.timestamp::bigint > (SELECT MAX(timestamp::bigint) FROM tx_meta) - 2592000
      AND NOT EXISTS (SELECT 1 FROM pdp_pieces_removed r WHERE r.tx_hash = n.tx_hash)
    GROUP BY n.tx_hash
  ) s
),
rm AS (
  SELECT AVG(g) AS gas, AVG(pieces) AS pieces, AVG(price) AS price, COUNT(*) AS n FROM (
    SELECT MAX(m.gas_used::numeric) AS g, MAX(r.piece_count::numeric) AS pieces,
           MAX(m.effective_gas_price::numeric) AS price
    FROM pdp_pieces_removed r
    JOIN tx_meta m USING (tx_hash)
    WHERE r.set_id IN (SELECT data_set_id FROM fwss_data_set_created)
      AND m.timestamp::bigint > (SELECT MAX(timestamp::bigint) FROM tx_meta) - 2592000
    GROUP BY r.tx_hash
  ) s
)
SELECT rm.n                                                       AS n_removal_txs,
       ROUND(base.gas)                                            AS baseline_nextpp_gas,
       ROUND(rm.gas)                                              AS removal_nextpp_gas,
       ROUND(rm.pieces, 1)                                        AS avg_pieces_removed,
       ROUND((rm.gas - base.gas) / NULLIF(rm.pieces, 0))          AS processing_gas_per_piece,
       ROUND((rm.gas - base.gas) / NULLIF(rm.pieces, 0) * rm.price / 1e18, 8) AS fil_per_piece
FROM base CROSS JOIN rm
