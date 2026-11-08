-- =====================================================================
-- TapNaira – Portfolio 3: the transfer procedure + single-session demos
-- psql -d tapnaira -f transactions.sql > evidence/transactions_sql_output.txt 2>&1
-- =====================================================================
SET search_path TO wallet;
\set ON_ERROR_STOP off

-- ---------------------------------------------------------------------
-- transfer_funds: ONE atomic unit of work
--   1. idempotency: the reference is unique, so a retried request fails cleanly
--   2. KYC daily limit (uses the Portfolio 2 covering index)
--   3. CHOSEN CONCURRENCY CONTROL (option C): a single conditional UPDATE
--        UPDATE wallet SET balance = balance - x WHERE wallet_id = ? AND balance >= x
--      The check and the debit happen in one statement under one row lock,
--      so two concurrent transfers can never both pass the check.
--   4. credit receiver + fee wallet, write 3 balanced ledger legs
-- Wallets are always locked first, in wallet_id order, to avoid deadlocks (see C2, C3).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE transfer_funds(p_ref TEXT, p_from BIGINT, p_to BIGINT, p_amount NUMERIC, p_fee NUMERIC DEFAULT 10)
LANGUAGE plpgsql AS $$
DECLARE
    v_txn BIGINT; v_limit NUMERIC; v_sent NUMERIC; v_rows INT;
BEGIN
    IF p_from = p_to THEN RAISE EXCEPTION 'Cannot transfer to the same wallet'; END IF;

    -- (0) lock both wallets FIRST, in a fixed order (lowest id first).
    --     Found in testing (C2): locking AFTER inserting the txn row deadlocked, because the
    --     txn FK takes a KEY SHARE lock on the sender's wallet, and concurrent transfers then
    --     each waited to upgrade it to FOR UPDATE. Locking first also makes the daily-limit
    --     check below race-free: no other transfer from this wallet can run in between.
    PERFORM 1 FROM wallet WHERE wallet_id IN (p_from, p_to) ORDER BY wallet_id FOR UPDATE;

    -- (2) daily limit for the sender's KYC tier
    SELECT k.daily_limit INTO v_limit
    FROM wallet w JOIN customer c USING (customer_id) JOIN kyc_tier k ON k.tier = c.kyc_tier
    WHERE w.wallet_id = p_from;
    SELECT COALESCE(sum(amount),0) INTO v_sent FROM ledger_entry
    WHERE wallet_id = p_from AND direction = 'DR' AND posted_at >= date_trunc('day', now());
    IF v_sent + p_amount + p_fee > v_limit THEN
        RAISE EXCEPTION 'Daily limit exceeded: sent % today, limit %', v_sent, v_limit;
    END IF;

    -- (1) record the transaction; a duplicate reference raises unique_violation
    INSERT INTO txn(reference, txn_type, amount, fee, status, initiated_by_wallet, narration)
    VALUES (p_ref, 'TRANSFER', p_amount, p_fee, 'PENDING', p_from, 'Transfer') RETURNING txn_id INTO v_txn;

    -- (3) debit conditionally (option C): the check and the debit are one statement
    UPDATE wallet SET balance = balance - (p_amount + p_fee)
    WHERE wallet_id = p_from AND status = 'ACTIVE' AND balance >= p_amount + p_fee;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
        RAISE EXCEPTION 'Insufficient funds or wallet not active (wallet %)', p_from;
    END IF;

    -- (4) credit receiver and fee wallet, post balanced legs
    UPDATE wallet SET balance = balance + p_amount WHERE wallet_id = p_to AND status = 'ACTIVE';
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN RAISE EXCEPTION 'Receiver wallet % not active', p_to; END IF;
    INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount) VALUES
        (v_txn, p_from, 'DR', p_amount + p_fee), (v_txn, p_to, 'CR', p_amount);
    IF p_fee > 0 THEN
        UPDATE wallet SET balance = balance + p_fee WHERE system_name = 'FEES';
        INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount)
        VALUES (v_txn, (SELECT wallet_id FROM wallet WHERE system_name='FEES'), 'CR', p_fee);
    END IF;
    UPDATE txn SET status = 'SUCCESS', completed_at = now() WHERE txn_id = v_txn;
END $$;

-- demo wallets: two tier-3 customers given a known starting balance via a cash-in
\echo '================ Setup: give wallet A (id 101) and B (id 102) a known state ================'
CREATE TEMP TABLE demo AS SELECT 101::bigint a, 102::bigint b;
SELECT wallet_id, balance, status FROM wallet WHERE wallet_id IN (101,102) ORDER BY 1;
UPDATE customer SET kyc_tier = 3, bvn_hash = COALESCE(bvn_hash, encode(sha256('demo'::bytea || customer_id::text::bytea),'hex'))
WHERE customer_id IN (SELECT customer_id FROM wallet WHERE wallet_id IN (101,102));

\echo '================ T1. COMMIT: transfer 2,000 (+10 fee) from A to B ================'
SELECT balance AS a_before FROM wallet WHERE wallet_id = 101 \gset
CALL transfer_funds('DEMO-T1-' || extract(epoch FROM now())::bigint, 101, 102, 2000, 10);
SELECT wallet_id, balance FROM wallet WHERE wallet_id IN (101,102) ORDER BY 1;
SELECT t.reference, t.status, le.wallet_id, le.direction, le.amount
FROM txn t JOIN ledger_entry le USING (txn_id)
WHERE t.txn_id = (SELECT max(txn_id) FROM txn WHERE reference LIKE 'DEMO-T1-%') ORDER BY le.direction DESC, le.wallet_id;

\echo '================ T2. ROLLBACK: transfer 500,000 when A holds far less -> nothing is written ================'
SELECT count(*) AS txn_rows_before FROM txn \gset
CALL transfer_funds('DEMO-T2-' || extract(epoch FROM now())::bigint, 101, 102, 500000, 10);
SELECT count(*) - :txn_rows_before AS new_txn_rows_after_failure FROM txn;
SELECT wallet_id, balance FROM wallet WHERE wallet_id IN (101,102) ORDER BY 1;

\echo '================ T3. Idempotency: the app retries T1 with the SAME reference after a timeout ================'
SELECT reference AS t1_ref FROM txn WHERE reference LIKE 'DEMO-T1-%' ORDER BY txn_id DESC LIMIT 1 \gset
CALL transfer_funds(:'t1_ref', 101, 102, 2000, 10);
SELECT wallet_id, balance FROM wallet WHERE wallet_id IN (101,102) ORDER BY 1;

\echo '================ T4. Frozen wallet: compliance freezes B, a transfer to B is rolled back ================'
BEGIN;
UPDATE wallet SET status = 'FROZEN' WHERE wallet_id = 102;
SAVEPOINT before_transfer;
CALL transfer_funds('DEMO-T4-' || extract(epoch FROM now())::bigint, 101, 102, 500, 10);
ROLLBACK TO SAVEPOINT before_transfer;      -- undo only the failed transfer
SELECT wallet_id, status, balance FROM wallet WHERE wallet_id IN (101,102) ORDER BY 1;
ROLLBACK;                                   -- end of demo: unfreeze (undo the freeze too)

\echo '================ T5. Durability + reconciliation: new session, ledger = balance for A and B ================'
\c tapnaira
SELECT w.wallet_id, w.balance,
       sum(CASE le.direction WHEN 'CR' THEN le.amount ELSE -le.amount END) AS ledger_balance,
       w.balance = sum(CASE le.direction WHEN 'CR' THEN le.amount ELSE -le.amount END) AS matches
FROM wallet.wallet w JOIN wallet.ledger_entry le USING (wallet_id)
WHERE w.wallet_id IN (101,102) GROUP BY w.wallet_id, w.balance ORDER BY 1;
