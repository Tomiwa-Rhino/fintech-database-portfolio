-- =====================================================================
-- TapNaira – Portfolio 2 further experiments (run AFTER indexes.sql)
-- psql -d tapnaira -f extras.sql > evidence/extras_output.txt
-- =====================================================================
SET search_path TO wallet;
SET max_parallel_workers_per_gather = 0;
\timing on

\echo '=== E1. Sargability: wrapping posted_at in a function stops the index range scan (Q2 rewritten badly) ==='
\echo '--- E1a. NON-sargable: posted_at::date = ...'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT COALESCE(sum(amount),0) FROM ledger_entry
WHERE wallet_id = 17034 AND direction='DR' AND (posted_at AT TIME ZONE 'Africa/Lagos')::date = DATE '2025-09-11';
\echo '--- E1b. Sargable half-open range (as in Q2)'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT COALESCE(sum(amount),0) FROM ledger_entry
WHERE wallet_id = 17034 AND direction='DR' AND posted_at >= TIMESTAMPTZ '2025-09-11' AND posted_at < TIMESTAMPTZ '2025-09-12';

\echo '=== E2. Q8 (agent league table) aggregates ~10k cash-outs per quarter: pre-aggregate in a materialised view ==='
DROP MATERIALIZED VIEW IF EXISTS mv_agent_daily;
CREATE MATERIALIZED VIEW mv_agent_daily AS
SELECT agent_id, created_at::date AS day, txn_type, count(*) AS n, sum(amount) AS value, sum(fee) AS fees
FROM txn WHERE agent_id IS NOT NULL AND status = 'SUCCESS'
GROUP BY 1, 2, 3;
CREATE UNIQUE INDEX ON mv_agent_daily(agent_id, day, txn_type);
\echo '--- E2a. query the new view BEFORE it has statistics (no ANALYZE yet)'
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT a.business_name, sum(m.value) AS cash_out_value, rank() OVER (ORDER BY sum(m.value) DESC)
FROM mv_agent_daily m JOIN agent a USING (agent_id)
WHERE m.txn_type='CASH_OUT' AND m.day >= DATE '2026-07-01' AND m.day < DATE '2026-10-01'
GROUP BY a.business_name ORDER BY 2 DESC LIMIT 10;
\echo '--- E2b. after ANALYZE mv_agent_daily (the planner now knows the row counts)'
ANALYZE mv_agent_daily;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT a.business_name, sum(m.value) AS cash_out_value, rank() OVER (ORDER BY sum(m.value) DESC)
FROM mv_agent_daily m JOIN agent a USING (agent_id)
WHERE m.txn_type='CASH_OUT' AND m.day >= DATE '2026-07-01' AND m.day < DATE '2026-10-01'
GROUP BY a.business_name ORDER BY 2 DESC LIMIT 10;
\echo '--- nightly refresh cost'
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_agent_daily;

\echo '=== E3. Cost of the ledger index on writes: post 20,000 ledger legs WITH vs WITHOUT ix_ledger_wallet_time ==='
ALTER TABLE ledger_entry DISABLE TRIGGER ledger_must_balance;
\echo '--- E3a. with the index'
BEGIN;
INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount, posted_at)
SELECT 1, 3 + (g % 30000), CASE WHEN g % 2 = 0 THEN 'DR' ELSE 'CR' END, 100, TIMESTAMPTZ '2026-11-01' + g * INTERVAL '1 second'
FROM generate_series(1, 20000) g;
ROLLBACK;
\echo '--- E3b. index dropped inside the transaction (restored by ROLLBACK)'
BEGIN;
DROP INDEX ix_ledger_wallet_time;
INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount, posted_at)
SELECT 1, 3 + (g % 30000), CASE WHEN g % 2 = 0 THEN 'DR' ELSE 'CR' END, 100, TIMESTAMPTZ '2026-11-01' + g * INTERVAL '1 second'
FROM generate_series(1, 20000) g;
ROLLBACK;
ALTER TABLE ledger_entry ENABLE TRIGGER ledger_must_balance;

\echo '=== E4. Reconciliation query (finance): stored balance must equal the ledger for every wallet (expect 0 rows) ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT w.wallet_id FROM wallet w
JOIN (SELECT wallet_id, sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END) s FROM ledger_entry GROUP BY wallet_id) l USING (wallet_id)
WHERE w.balance <> l.s;
