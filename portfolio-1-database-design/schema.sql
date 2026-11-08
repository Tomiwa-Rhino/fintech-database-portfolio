-- =====================================================================
-- TapNaira Wallet (fictional mobile-money fintech) – Relational schema
-- MIT 8103 Portfolio 1: Database Design and Modelling · PostgreSQL 16
-- Run: psql -d tapnaira -f schema.sql
-- =====================================================================
DROP SCHEMA IF EXISTS wallet CASCADE;
CREATE SCHEMA wallet;
SET search_path TO wallet;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE TABLE kyc_tier (                         -- limits per KYC level (illustrative values)
    tier              SMALLINT PRIMARY KEY CHECK (tier BETWEEN 1 AND 3),
    description       VARCHAR(60)   NOT NULL,
    single_txn_limit  NUMERIC(14,2) NOT NULL CHECK (single_txn_limit > 0),
    daily_limit       NUMERIC(14,2) NOT NULL CHECK (daily_limit >= single_txn_limit),
    max_balance       NUMERIC(14,2)            CHECK (max_balance IS NULL OR max_balance > 0)
);

CREATE TABLE state (                            -- Nigerian states (for agents and customers)
    state_code  CHAR(2)     PRIMARY KEY,
    name        VARCHAR(40) NOT NULL UNIQUE
);

CREATE TABLE biller (
    biller_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(60) NOT NULL UNIQUE,
    category    VARCHAR(15) NOT NULL CHECK (category IN ('AIRTIME','DATA','ELECTRICITY','TV','WATER'))
);

-- ---------------------------------------------------------------------
-- Parties
-- ---------------------------------------------------------------------
CREATE TABLE customer (
    customer_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone         VARCHAR(14)  NOT NULL UNIQUE CHECK (phone ~ '^\+234[0-9]{10}$'),
    first_name    VARCHAR(50)  NOT NULL,
    last_name     VARCHAR(50)  NOT NULL,
    date_of_birth DATE         NOT NULL CHECK (date_of_birth <= CURRENT_DATE - INTERVAL '18 years'),
    bvn_hash      CHAR(64)     UNIQUE,              -- SHA-256 of BVN: the raw BVN is never stored (NDPA data minimisation)
    kyc_tier      SMALLINT     NOT NULL DEFAULT 1 REFERENCES kyc_tier(tier),
    state_code    CHAR(2)      REFERENCES state(state_code),
    status        VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (kyc_tier = 1 OR bvn_hash IS NOT NULL)    -- tiers 2 and 3 require BVN verification
);

CREATE TABLE agent (                            -- POS / cash-in-cash-out agents
    agent_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    business_name VARCHAR(80)  NOT NULL,
    phone         VARCHAR(14)  NOT NULL UNIQUE CHECK (phone ~ '^\+234[0-9]{10}$'),
    state_code    CHAR(2)      NOT NULL REFERENCES state(state_code),
    lga           VARCHAR(60)  NOT NULL,
    commission_pct NUMERIC(4,2) NOT NULL DEFAULT 0.50 CHECK (commission_pct BETWEEN 0 AND 5),
    status        VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    onboarded_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE admin_user (
    admin_id    SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       VARCHAR(120) NOT NULL UNIQUE,
    full_name   VARCHAR(100) NOT NULL,
    role        VARCHAR(15)  NOT NULL CHECK (role IN ('SUPPORT','COMPLIANCE','FINANCE','SUPERADMIN'))
);

-- ---------------------------------------------------------------------
-- Wallets and the double-entry ledger
-- ---------------------------------------------------------------------
CREATE TABLE wallet (
    wallet_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_type    VARCHAR(8)   NOT NULL CHECK (owner_type IN ('CUSTOMER','AGENT','SYSTEM')),
    customer_id   INT          REFERENCES customer(customer_id),
    agent_id      INT          REFERENCES agent(agent_id),
    system_name   VARCHAR(30)  UNIQUE,              -- e.g. 'FEES', 'SETTLEMENT'
    balance       NUMERIC(14,2) NOT NULL DEFAULT 0,
    currency      CHAR(3)      NOT NULL DEFAULT 'NGN' CHECK (currency = 'NGN'),
    status        VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    -- exactly one owner, matching owner_type
    CONSTRAINT one_owner CHECK (
        (owner_type = 'CUSTOMER' AND customer_id IS NOT NULL AND agent_id IS NULL AND system_name IS NULL) OR
        (owner_type = 'AGENT'    AND agent_id    IS NOT NULL AND customer_id IS NULL AND system_name IS NULL) OR
        (owner_type = 'SYSTEM'   AND system_name IS NOT NULL AND customer_id IS NULL AND agent_id IS NULL)),
    -- customer and agent wallets can never go negative; the SETTLEMENT system wallet can (it mirrors the bank account)
    CONSTRAINT no_overdraft CHECK (owner_type = 'SYSTEM' OR balance >= 0)
);
CREATE UNIQUE INDEX one_wallet_per_customer ON wallet(customer_id) WHERE customer_id IS NOT NULL;
CREATE UNIQUE INDEX one_wallet_per_agent    ON wallet(agent_id)    WHERE agent_id IS NOT NULL;

CREATE TABLE txn (                              -- one business transaction (what the customer sees)
    txn_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference     VARCHAR(40)  NOT NULL UNIQUE,     -- idempotency key: a retried request cannot post twice
    txn_type      VARCHAR(10)  NOT NULL CHECK (txn_type IN ('TRANSFER','CASH_IN','CASH_OUT','BILL','REVERSAL')),
    amount        NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    fee           NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fee >= 0),
    status        VARCHAR(9)   NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SUCCESS','FAILED','REVERSED')),
    initiated_by_wallet BIGINT NOT NULL REFERENCES wallet(wallet_id),
    agent_id      INT          REFERENCES agent(agent_id),       -- set for CASH_IN / CASH_OUT
    reverses_txn  BIGINT       UNIQUE REFERENCES txn(txn_id),    -- a transaction can be reversed at most once
    narration     VARCHAR(100),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    completed_at  TIMESTAMPTZ,
    CHECK ((txn_type = 'REVERSAL') = (reverses_txn IS NOT NULL)),
    CHECK ((txn_type IN ('CASH_IN','CASH_OUT')) = (agent_id IS NOT NULL)),
    CHECK (completed_at IS NULL OR completed_at >= created_at)
);

CREATE TABLE ledger_entry (                     -- double entry: every txn = equal debits and credits
    entry_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id        BIGINT       NOT NULL REFERENCES txn(txn_id),
    wallet_id     BIGINT       NOT NULL REFERENCES wallet(wallet_id),
    direction     CHAR(2)      NOT NULL CHECK (direction IN ('DR','CR')),
    amount        NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    posted_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Needed by the balance-check trigger below (it sums the legs of one txn). Other FK indexes are
-- deliberately left out here and evaluated in Portfolio 2.
CREATE INDEX ix_ledger_txn ON ledger_entry(txn_id);

CREATE TABLE bill_payment (                     -- 1:1 extension of a BILL transaction
    txn_id        BIGINT       PRIMARY KEY REFERENCES txn(txn_id),
    biller_id     SMALLINT     NOT NULL REFERENCES biller(biller_id),
    customer_ref  VARCHAR(30)  NOT NULL           -- meter / smartcard / phone number at the biller
);

CREATE TABLE fraud_flag (
    flag_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id        BIGINT       NOT NULL REFERENCES txn(txn_id),
    rule_code     VARCHAR(20)  NOT NULL,           -- e.g. VELOCITY, NEW_DEVICE, LARGE_AMOUNT
    score         SMALLINT     NOT NULL CHECK (score BETWEEN 0 AND 100),
    reviewed_by   SMALLINT     REFERENCES admin_user(admin_id),
    outcome       VARCHAR(10)  CHECK (outcome IN ('CLEARED','CONFIRMED')),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK ((reviewed_by IS NULL) = (outcome IS NULL))
);

CREATE TABLE audit_log (
    audit_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name    TEXT NOT NULL,
    row_pk        TEXT NOT NULL,
    action        TEXT NOT NULL,
    old_data      JSONB,
    new_data      JSONB,
    changed_by    TEXT NOT NULL DEFAULT current_user,
    changed_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Integrity rules that a CHECK cannot express
-- ---------------------------------------------------------------------
-- 1) Balanced ledger: for every transaction, total debits = total credits.
--    A DEFERRABLE constraint trigger checks this at COMMIT, after all legs are inserted.
CREATE OR REPLACE FUNCTION check_txn_balanced() RETURNS trigger AS $$
DECLARE dr NUMERIC; cr NUMERIC;
BEGIN
    SELECT COALESCE(sum(amount) FILTER (WHERE direction='DR'),0),
           COALESCE(sum(amount) FILTER (WHERE direction='CR'),0)
      INTO dr, cr FROM ledger_entry WHERE txn_id = NEW.txn_id;
    IF dr <> cr THEN
        RAISE EXCEPTION 'Unbalanced ledger for txn %: debits % <> credits %', NEW.txn_id, dr, cr;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER ledger_must_balance
AFTER INSERT OR UPDATE ON ledger_entry
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION check_txn_balanced();

-- 2) Ledger entries are append-only: corrections are made with a REVERSAL, never by editing history.
CREATE OR REPLACE FUNCTION forbid_ledger_change() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'ledger_entry is append-only; post a REVERSAL instead';
END $$ LANGUAGE plpgsql;
CREATE TRIGGER ledger_append_only BEFORE UPDATE OR DELETE ON ledger_entry
FOR EACH ROW EXECUTE FUNCTION forbid_ledger_change();

-- 3) Audit trail for wallet status changes (freeze / unfreeze) and txn status changes
CREATE OR REPLACE FUNCTION audit_row() RETURNS trigger AS $$
BEGIN
    INSERT INTO audit_log(table_name,row_pk,action,old_data,new_data)
    VALUES (TG_TABLE_NAME, (to_jsonb(NEW)->>TG_ARGV[0]), TG_OP, to_jsonb(OLD), to_jsonb(NEW));
    RETURN NULL;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER audit_wallet_status AFTER UPDATE OF status ON wallet FOR EACH ROW EXECUTE FUNCTION audit_row('wallet_id');
CREATE TRIGGER audit_txn_status    AFTER UPDATE OF status ON txn    FOR EACH ROW EXECUTE FUNCTION audit_row('txn_id');

-- Convenience view: statement line per wallet
CREATE VIEW v_statement AS
SELECT le.wallet_id, t.created_at, t.reference, t.txn_type, le.direction,
       CASE le.direction WHEN 'CR' THEN le.amount ELSE -le.amount END AS signed_amount, t.narration
FROM ledger_entry le JOIN txn t USING (txn_id)
WHERE t.status IN ('SUCCESS','REVERSED');
