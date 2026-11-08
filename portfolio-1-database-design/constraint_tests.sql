-- =====================================================================
-- TapNaira – constraint tests. Tests 1-9 are EXPECTED TO FAIL; Test 10 succeeds.
-- psql -d tapnaira -f constraint_tests.sql > evidence/constraint_tests_output.txt 2>&1
-- =====================================================================
SET search_path TO wallet;
\set ON_ERROR_STOP off

\echo '--- Test 1: unbalanced transaction (debit 5,000, credit 4,000) is rejected at COMMIT by the deferred trigger'
BEGIN;
INSERT INTO txn(reference, txn_type, amount, initiated_by_wallet, status) VALUES ('TEST-UNBAL', 'TRANSFER', 5000, 3, 'SUCCESS');
INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount) SELECT txn_id, 3, 'DR', 5000 FROM txn WHERE reference='TEST-UNBAL';
INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount) SELECT txn_id, 4, 'CR', 4000 FROM txn WHERE reference='TEST-UNBAL';
COMMIT;

\echo '--- Test 2: editing ledger history is forbidden (append-only trigger)'
UPDATE ledger_entry SET amount = 1 WHERE entry_id = 1;

\echo '--- Test 3: a customer wallet cannot go negative (CHECK no_overdraft)'
UPDATE wallet SET balance = -1 WHERE wallet_id = 3;

\echo '--- Test 4: a wallet with two owners (CHECK one_owner)'
INSERT INTO wallet(owner_type, customer_id, agent_id) VALUES ('CUSTOMER', 1, 1);

\echo '--- Test 5: a retried request with the same reference cannot post twice (UNIQUE idempotency key)'
INSERT INTO txn(reference, txn_type, amount, initiated_by_wallet)
SELECT reference, txn_type, amount, initiated_by_wallet FROM txn WHERE txn_type='TRANSFER' LIMIT 1;

\echo '--- Test 6: the same transaction cannot be reversed twice (UNIQUE reverses_txn)'
INSERT INTO txn(reference, txn_type, amount, initiated_by_wallet, reverses_txn)
SELECT 'RV-AGAIN', 'REVERSAL', amount, initiated_by_wallet, reverses_txn FROM txn WHERE txn_type='REVERSAL' LIMIT 1;

\echo '--- Test 7: tier-2 customer without BVN verification (multi-column CHECK)'
INSERT INTO customer(phone, first_name, last_name, date_of_birth, kyc_tier) VALUES ('+2348999999999','No','Bvn','1990-01-01',2);

\echo '--- Test 8: under-18 customer (CHECK)'
INSERT INTO customer(phone, first_name, last_name, date_of_birth) VALUES ('+2348999999998','Too','Young', CURRENT_DATE - 365*15);

\echo '--- Test 9: invalid Nigerian phone format (CHECK regex)'
INSERT INTO customer(phone, first_name, last_name, date_of_birth) VALUES ('08012345678','Bad','Phone','1990-01-01');

\echo '--- Test 10: a correct transfer of 2,000 + 10 fee (3 balanced legs) COMMITS - expected to SUCCEED'
BEGIN;
INSERT INTO txn(reference, txn_type, amount, fee, initiated_by_wallet, status, completed_at)
VALUES ('TEST-OK-1', 'TRANSFER', 2000, 10, 3, 'SUCCESS', now()) RETURNING txn_id, reference;
INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount)
SELECT txn_id, 3, 'DR', 2010 FROM txn WHERE reference='TEST-OK-1'
UNION ALL SELECT txn_id, 4, 'CR', 2000 FROM txn WHERE reference='TEST-OK-1'
UNION ALL SELECT txn_id, 2, 'CR', 10   FROM txn WHERE reference='TEST-OK-1';
COMMIT;
SELECT direction, wallet_id, amount FROM ledger_entry WHERE txn_id = (SELECT txn_id FROM txn WHERE reference='TEST-OK-1') ORDER BY direction DESC, wallet_id;
-- clean up the test row (ledger is append-only, so remove via a privileged maintenance session)
ALTER TABLE ledger_entry DISABLE TRIGGER ledger_append_only;
DELETE FROM ledger_entry WHERE txn_id = (SELECT txn_id FROM txn WHERE reference='TEST-OK-1');
DELETE FROM txn WHERE reference='TEST-OK-1';
ALTER TABLE ledger_entry ENABLE TRIGGER ledger_append_only;
