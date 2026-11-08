-- =====================================================================
-- TapNaira – optimisation indexes (Portfolio 2). Rationale in README.
-- =====================================================================
SET search_path TO wallet;

-- Q1, Q2, Q7: a wallet's ledger by time. Equality column first, range column second;
-- INCLUDE makes it covering for Q2 (no table visit needed to sum the amounts).
CREATE INDEX IF NOT EXISTS ix_ledger_wallet_time ON ledger_entry (wallet_id, posted_at) INCLUDE (direction, amount, txn_id);

-- Q1: find the customer's wallet (FK customer_id is already covered by the partial UNIQUE index one_wallet_per_customer)

-- Q3: velocity rule – transfers by initiating wallet and time
CREATE INDEX IF NOT EXISTS ix_txn_wallet_time ON txn (initiated_by_wallet, created_at) INCLUDE (txn_type);

-- Q4, Q8: agent activity. PARTIAL – only CASH_IN/CASH_OUT rows have an agent (~30% of txns)
CREATE INDEX IF NOT EXISTS ix_txn_agent_time ON txn (agent_id, created_at) WHERE agent_id IS NOT NULL;

-- Q5: PARTIAL – only flags still awaiting review
CREATE INDEX IF NOT EXISTS ix_fraud_unreviewed ON fraud_flag (created_at) WHERE reviewed_by IS NULL;

-- Q6: PARTIAL – only failed transactions (~2%)
CREATE INDEX IF NOT EXISTS ix_txn_failed_time ON txn (created_at) WHERE status = 'FAILED';

ANALYZE;
