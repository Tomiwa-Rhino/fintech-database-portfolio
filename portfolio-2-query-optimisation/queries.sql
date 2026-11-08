-- =====================================================================
-- TapNaira – Portfolio 2 workload queries (marker "-- name: Qn" used by benchmark.py)
-- =====================================================================

-- name: Q1 Wallet statement for the last 30 days (customer looks at their app)
SELECT le.posted_at, t.reference, t.txn_type, le.direction, le.amount, t.narration
FROM wallet.customer c
JOIN wallet.wallet w        ON w.customer_id = c.customer_id
JOIN wallet.ledger_entry le ON le.wallet_id = w.wallet_id
JOIN wallet.txn t           ON t.txn_id = le.txn_id
WHERE c.phone = '+2348000018267'
  AND le.posted_at >= TIMESTAMPTZ '2026-09-01' AND le.posted_at < TIMESTAMPTZ '2026-10-01'
ORDER BY le.posted_at DESC;

-- name: Q2 Daily-limit check before a transfer: total sent by this wallet today (runs on EVERY transfer)
SELECT COALESCE(sum(le.amount), 0) AS sent_today
FROM wallet.ledger_entry le
WHERE le.wallet_id = 17034 AND le.direction = 'DR'
  AND le.posted_at >= TIMESTAMPTZ '2025-09-11' AND le.posted_at < TIMESTAMPTZ '2025-09-12';

-- name: Q3 Fraud velocity rule: transfers started by a wallet in the last hour
SELECT count(*) AS transfers_last_hour
FROM wallet.txn
WHERE initiated_by_wallet = 17034 AND txn_type = 'TRANSFER'
  AND created_at >= TIMESTAMPTZ '2026-08-15 18:00' AND created_at < TIMESTAMPTZ '2026-08-15 19:00';

-- name: Q4 Agent end-of-day report: cash-in and cash-out totals for one agent on one day
SELECT txn_type, count(*) AS n, sum(amount) AS total, sum(fee) AS fees
FROM wallet.txn
WHERE agent_id = 264 AND status = 'SUCCESS'
  AND created_at >= TIMESTAMPTZ '2026-06-17' AND created_at < TIMESTAMPTZ '2026-06-18'
GROUP BY txn_type;

-- name: Q5 Compliance queue: fraud flags still waiting for review, oldest first
SELECT f.flag_id, f.rule_code, f.score, t.reference, t.amount, f.created_at
FROM wallet.fraud_flag f JOIN wallet.txn t USING (txn_id)
WHERE f.reviewed_by IS NULL
ORDER BY f.created_at
LIMIT 50;

-- name: Q6 Operations: failed transactions in the last 7 days by type
SELECT txn_type, count(*) AS failed, sum(amount) AS value
FROM wallet.txn
WHERE status = 'FAILED' AND created_at >= TIMESTAMPTZ '2026-10-01' AND created_at < TIMESTAMPTZ '2026-10-08'
GROUP BY txn_type ORDER BY failed DESC;

-- name: Q7 Finance: monthly fee revenue (credits to the FEES system wallet) in 2026
SELECT date_trunc('month', le.posted_at) AS month, sum(le.amount) AS fee_revenue, count(*) AS fee_postings
FROM wallet.ledger_entry le
WHERE le.wallet_id = 2 AND le.direction = 'CR'
  AND le.posted_at >= TIMESTAMPTZ '2026-01-01' AND le.posted_at < TIMESTAMPTZ '2027-01-01'
GROUP BY 1 ORDER BY 1;

-- name: Q8 Management: top 10 agents by cash-out value in Q3 2026 (CTE + window function)
WITH agent_totals AS (
    SELECT t.agent_id, sum(t.amount) AS cash_out_value, count(*) AS n
    FROM wallet.txn t
    WHERE t.txn_type = 'CASH_OUT' AND t.status = 'SUCCESS'
      AND t.created_at >= TIMESTAMPTZ '2026-07-01' AND t.created_at < TIMESTAMPTZ '2026-10-01'
    GROUP BY t.agent_id
)
SELECT a.business_name, s.name AS state, at.cash_out_value, at.n,
       rank() OVER (ORDER BY at.cash_out_value DESC) AS rnk
FROM agent_totals at JOIN wallet.agent a USING (agent_id) JOIN wallet.state s USING (state_code)
ORDER BY rnk LIMIT 10;
