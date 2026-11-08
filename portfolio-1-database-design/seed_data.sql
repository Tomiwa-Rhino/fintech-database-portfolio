-- =====================================================================
-- TapNaira Wallet – deterministic synthetic data (all people fictional)
-- ~30k customers, 500 agents, ~250k transactions, ~600k ledger legs.
-- The balance trigger is disabled during bulk load and the whole ledger
-- is validated at the end instead (one set-based check, much faster).
-- =====================================================================
SET search_path TO wallet;
SELECT setseed(0.274);
ALTER TABLE ledger_entry DISABLE TRIGGER ledger_must_balance;

INSERT INTO kyc_tier VALUES
 (1,'Phone number only',          20000,   50000,   300000),
 (2,'BVN verified',              100000,  200000,  1000000),
 (3,'BVN + ID + address verified',1000000, 5000000, NULL);

INSERT INTO state VALUES ('LA','Lagos'),('FC','FCT Abuja'),('KN','Kano'),('RI','Rivers'),('OY','Oyo'),
 ('EN','Enugu'),('KD','Kaduna'),('ED','Edo'),('OG','Ogun'),('AN','Anambra');

INSERT INTO biller(name, category) VALUES ('MTN Airtime','AIRTIME'),('Airtel Airtime','AIRTIME'),('Glo Data','DATA'),
 ('Ikeja Electric (prepaid)','ELECTRICITY'),('Abuja Electric (prepaid)','ELECTRICITY'),('DStv','TV'),('GOtv','TV');

INSERT INTO admin_user(email, full_name, role)
SELECT 'admin'||g||'@tapnaira.example', 'Admin User '||g, (ARRAY['SUPPORT','COMPLIANCE','FINANCE','SUPERADMIN'])[1+g%4]
FROM generate_series(1,12) g;

INSERT INTO customer(phone, first_name, last_name, date_of_birth, bvn_hash, kyc_tier, state_code, created_at)
SELECT '+2348' || lpad(g::text, 9, '0'),
       (ARRAY['Chinedu','Aisha','Tunde','Ngozi','Ibrahim','Funke','Emeka','Zainab','Segun','Blessing','Musa','Kemi'])[1+floor(random()*12)::int],
       (ARRAY['Okafor','Bello','Adeyemi','Eze','Mohammed','Ogunleye','Nwachukwu','Yusuf','Balogun','Okon'])[1+floor(random()*10)::int],
       DATE '1960-01-01' + floor(random()*15000)::int,
       CASE WHEN t.tier > 1 THEN encode(sha256(('BVN'||g)::bytea),'hex') END,
       t.tier,
       (ARRAY['LA','LA','LA','FC','KN','RI','OY','EN','KD','ED','OG','AN'])[1+floor(random()*12)::int],
       TIMESTAMPTZ '2024-06-01' + random()*INTERVAL '480 days'
FROM generate_series(1,30000) g
CROSS JOIN LATERAL (SELECT CASE WHEN random()<0.45 THEN 1 WHEN random()<0.8 THEN 2 ELSE 3 END + (g*0) AS tier) t;

INSERT INTO agent(business_name, phone, state_code, lga, commission_pct, onboarded_at)
SELECT 'Agent Store '||g, '+2347'||lpad(g::text,9,'0'),
       (ARRAY['LA','LA','FC','KN','RI','OY','EN','KD','ED','OG','AN'])[1+g%11],
       'LGA '||(1+g%20), 0.50, TIMESTAMPTZ '2024-01-01' + (g%300)*INTERVAL '1 day'
FROM generate_series(1,500) g;

INSERT INTO wallet(owner_type, system_name) VALUES ('SYSTEM','SETTLEMENT'),('SYSTEM','FEES');
INSERT INTO wallet(owner_type, customer_id) SELECT 'CUSTOMER', customer_id FROM customer;
INSERT INTO wallet(owner_type, agent_id)    SELECT 'AGENT', agent_id FROM agent;

-- staging: one row per business transaction, with debit/credit wallets
CREATE TEMP TABLE stg (seq BIGINT, txn_type TEXT, dr_w BIGINT, cr_w BIGINT, amount NUMERIC(14,2),
                       fee NUMERIC(10,2), agent_id INT, ts TIMESTAMPTZ, ok BOOLEAN, narration TEXT, biller SMALLINT);
CREATE TEMP TABLE cw AS SELECT row_number() OVER (ORDER BY wallet_id) rn, wallet_id FROM wallet WHERE owner_type='CUSTOMER';
CREATE TEMP TABLE aw AS SELECT row_number() OVER (ORDER BY wallet_id) rn, wallet_id, agent_id FROM wallet WHERE owner_type='AGENT';
CREATE INDEX ON cw(rn); CREATE INDEX ON aw(rn);

-- (a) agent float funding from SETTLEMENT: 6 per agent
INSERT INTO stg SELECT 0,'TRANSFER',1,aw.wallet_id, 5000000, 0, NULL, TIMESTAMPTZ '2025-01-01' + k*INTERVAL '60 days', TRUE, 'Agent float top-up', NULL
FROM aw, generate_series(0,5) k;
-- (b) customer cash-in at agents: 3 each
INSERT INTO stg SELECT 0,'CASH_IN', a.wallet_id, c.wallet_id, round((5000+random()*95000)::numeric,-2), 0, a.agent_id,
       TIMESTAMPTZ '2025-01-02' + random()*INTERVAL '660 days', random()>0.01, 'Cash deposit', NULL
FROM (SELECT c.wallet_id cwid, 1+floor(random()*500)::int ar FROM cw c, generate_series(1,3) k) x
JOIN cw c ON c.wallet_id = x.cwid JOIN aw a ON a.rn = x.ar;
-- (c) P2P transfers
INSERT INTO stg SELECT 0,'TRANSFER', s.wallet_id, r.wallet_id, round((500+random()*19500)::numeric,-1),
       CASE WHEN random()<0.6 THEN 10 ELSE 25 END, NULL,
       TIMESTAMPTZ '2025-01-05' + random()*INTERVAL '665 days', random()>0.02, 'Transfer', NULL
FROM (SELECT g, 1+floor(random()*30000)::int sr, 1+floor(random()*30000)::int rr FROM generate_series(1,140000) g) x
JOIN cw s ON s.rn = x.sr JOIN cw r ON r.rn = x.rr
WHERE s.wallet_id <> r.wallet_id;
-- (d) cash-out at agents
INSERT INTO stg SELECT 0,'CASH_OUT', c.wallet_id, a.wallet_id, round((1000+random()*29000)::numeric,-2), 50, a.agent_id,
       TIMESTAMPTZ '2025-01-10' + random()*INTERVAL '660 days', random()>0.02, 'Cash withdrawal', NULL
FROM (SELECT g, 1+floor(random()*30000)::int cr, 1+floor(random()*500)::int ar FROM generate_series(1,30000) g) x
JOIN cw c ON c.rn = x.cr JOIN aw a ON a.rn = x.ar;
-- (e) bill payments (paid out through SETTLEMENT)
INSERT INTO stg SELECT 0,'BILL', c.wallet_id, 1, round((100+random()*14900)::numeric,-2), 0, NULL,
       TIMESTAMPTZ '2025-01-10' + random()*INTERVAL '660 days', random()>0.03, 'Bill payment', 1+floor(random()*7)::smallint
FROM (SELECT g, 1+floor(random()*30000)::int cr FROM generate_series(1,40000) g) x JOIN cw c ON c.rn = x.cr;

-- top up any wallet that would go negative, so the no-overdraft rule holds at every point in time
-- (simplified: enough opening cash-in so the final balance is >= 0 and each wallet starts well funded)
CREATE TEMP TABLE net AS
SELECT w, sum(v) bal FROM (
  SELECT cr_w w, amount v FROM stg WHERE ok
  UNION ALL SELECT dr_w, -(amount+fee) FROM stg WHERE ok) x GROUP BY w;
INSERT INTO stg SELECT 0,'CASH_IN', a.wallet_id, n.w, ceil((-n.bal + 20000)/100)*100, 0, a.agent_id,
       TIMESTAMPTZ '2025-01-03', TRUE, 'Opening deposit', NULL
FROM net n JOIN cw ON cw.wallet_id = n.w
CROSS JOIN LATERAL (SELECT wallet_id, agent_id FROM aw WHERE rn = 1 + (n.w % 500)) a
WHERE n.bal < 0;
DROP TABLE net;
CREATE TEMP TABLE net AS
SELECT w, sum(v) bal FROM (SELECT cr_w w, amount v FROM stg WHERE ok UNION ALL SELECT dr_w, -(amount+fee) FROM stg WHERE ok) x GROUP BY w;
INSERT INTO stg SELECT 0,'TRANSFER', 1, n.w, ceil((-n.bal + 1000000)/100)*100, 0, NULL, TIMESTAMPTZ '2025-01-01 06:00', TRUE, 'Agent float top-up', NULL
FROM net n JOIN aw ON aw.wallet_id = n.w WHERE n.bal < 0;

-- number transactions chronologically and load txn
CREATE TEMP TABLE stg2 AS SELECT row_number() OVER (ORDER BY ts) seq, txn_type, dr_w, cr_w, amount, fee, agent_id, ts, ok, narration, biller FROM stg;
INSERT INTO txn(reference, txn_type, amount, fee, status, initiated_by_wallet, agent_id, narration, created_at, completed_at)
SELECT 'TN' || to_char(ts,'YYMMDD') || lpad(seq::text,8,'0'), txn_type, amount, fee,
       CASE WHEN ok THEN 'SUCCESS' ELSE 'FAILED' END, dr_w, agent_id, narration, ts, ts + INTERVAL '2 seconds'
FROM stg2 ORDER BY seq;

-- ledger legs (only for successful txns): debit payer, credit payee, credit FEES
CREATE TEMP TABLE m AS SELECT t.txn_id, s.* FROM (SELECT *, 'TN' || to_char(ts,'YYMMDD') || lpad(seq::text,8,'0') AS ref FROM stg2 WHERE ok) s JOIN txn t ON t.reference = s.ref;
INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount, posted_at)
SELECT txn_id, dr_w, 'DR', amount+fee, ts FROM m
UNION ALL SELECT txn_id, cr_w, 'CR', amount, ts FROM m
UNION ALL SELECT txn_id, 2, 'CR', fee, ts FROM m WHERE fee > 0;

INSERT INTO bill_payment SELECT txn_id, biller, lpad((txn_id*7919 % 100000000000)::text, 11, '0') FROM m WHERE txn_type='BILL';

-- reversals: 300 successful transfers reported as "sent to wrong number" and reversed
-- only pick transfers whose recipient still holds enough to give the money back (one reversal per recipient)
CREATE TEMP TABLE bal AS SELECT wallet_id, sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END) b FROM ledger_entry GROUP BY wallet_id;
CREATE TEMP TABLE rv AS
SELECT * FROM (SELECT DISTINCT ON (m.cr_w) m.txn_id, m.dr_w, m.cr_w, m.amount, m.fee, m.ts
               FROM m JOIN bal ON bal.wallet_id = m.cr_w
               WHERE m.txn_type='TRANSFER' AND m.dr_w <> 1 AND bal.b >= m.amount
               ORDER BY m.cr_w, random()) x
ORDER BY random() LIMIT 300;
INSERT INTO txn(reference, txn_type, amount, fee, status, initiated_by_wallet, reverses_txn, narration, created_at, completed_at)
SELECT 'RV' || lpad(txn_id::text,10,'0'), 'REVERSAL', amount, 0, 'SUCCESS', cr_w, txn_id, 'Reversal: wrong recipient', ts + INTERVAL '1 hour', ts + INTERVAL '1 hour 2 seconds' FROM rv;
INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount, posted_at)
SELECT t.txn_id, rv.cr_w, 'DR', rv.amount, t.created_at FROM rv JOIN txn t ON t.reverses_txn = rv.txn_id
UNION ALL SELECT t.txn_id, rv.dr_w, 'CR', rv.amount, t.created_at FROM rv JOIN txn t ON t.reverses_txn = rv.txn_id;
UPDATE txn SET status='REVERSED' WHERE txn_id IN (SELECT txn_id FROM rv);

-- fraud flags on ~1% of large transfers
INSERT INTO fraud_flag(txn_id, rule_code, score, reviewed_by, outcome, created_at)
SELECT txn_id, (ARRAY['VELOCITY','NEW_DEVICE','LARGE_AMOUNT'])[1+floor(random()*3)::int], 60+floor(random()*40)::int,
       CASE WHEN r < 0.8 THEN 2 END, CASE WHEN r < 0.72 THEN 'CLEARED' WHEN r < 0.8 THEN 'CONFIRMED' END, ts
FROM (SELECT txn_id, ts, random() r FROM m WHERE txn_type='TRANSFER' AND dr_w <> 1 AND amount > 15000 AND random() < 0.05) f;

-- derive balances from the ledger (the ledger is the source of truth)
UPDATE wallet w SET balance = x.bal
FROM (SELECT wallet_id, sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END) bal FROM ledger_entry GROUP BY wallet_id) x
WHERE x.wallet_id = w.wallet_id;
DELETE FROM audit_log;

ALTER TABLE ledger_entry ENABLE TRIGGER ledger_must_balance;
ANALYZE;

\echo '--- Validation 1: every transaction balances (expect 0 rows)'
SELECT txn_id, sum(CASE direction WHEN 'DR' THEN amount ELSE -amount END) diff
FROM ledger_entry GROUP BY txn_id HAVING sum(CASE direction WHEN 'DR' THEN amount ELSE -amount END) <> 0 LIMIT 5;
\echo '--- Validation 2: the whole ledger sums to zero, and so do all balances'
SELECT sum(CASE direction WHEN 'DR' THEN amount ELSE -amount END) AS ledger_net, (SELECT sum(balance) FROM wallet) AS sum_of_balances FROM ledger_entry;
\echo '--- Validation 3: no customer/agent wallet is negative (expect 0)'
SELECT count(*) FROM wallet WHERE owner_type <> 'SYSTEM' AND balance < 0;
\echo '--- Row counts'
SELECT 'customer' t, count(*) FROM customer UNION ALL SELECT 'agent', count(*) FROM agent
UNION ALL SELECT 'wallet', count(*) FROM wallet UNION ALL SELECT 'txn', count(*) FROM txn
UNION ALL SELECT 'ledger_entry', count(*) FROM ledger_entry UNION ALL SELECT 'bill_payment', count(*) FROM bill_payment
UNION ALL SELECT 'fraud_flag', count(*) FROM fraud_flag;
