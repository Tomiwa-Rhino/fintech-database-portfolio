"""
TapNaira – Portfolio 5: what happens to TRANSFERS if wallets are sharded across servers?

  S0  Measure: with wallets split by hash(wallet_id), what share of real P2P transfers cross shards?
  S1  Same-shard transfer: an ordinary local transaction
  S2  Cross-shard transfer WITHOUT coordination: debit commits on shard0, credit fails on shard1 -> money vanishes
  S3  Cross-shard transfer WITH two-phase commit (PREPARE TRANSACTION / COMMIT PREPARED)
  S4  Coordinator crashes between PREPARE and COMMIT: the prepared transaction survives, holds its
      locks, and is resolved from the coordinator's decision log

Prerequisite: sudo -u postgres bash start_shards.sh   (two nodes on :5470 and :5471)
Usage: python3 sharding_2pc_demo.py | tee ../evidence/sharding_output.txt
"""
import os, uuid
import psycopg2

MAIN = dict(host="localhost", port=5432, user="postgres", password=os.getenv("PGPASSWORD", "postgres"), dbname="tapnaira")
SHARD = {0: dict(host="localhost", port=5470, user="postgres", dbname="tapnaira_shard"),
         1: dict(host="localhost", port=5471, user="postgres", dbname="tapnaira_shard")}
N_SHARDS = 2
def shard_of(w): return w % N_SHARDS


def admin(i, sql, args=None):
    """Run a statement outside any transaction block (needed for COMMIT/ROLLBACK PREPARED)."""
    c = psycopg2.connect(**SHARD[i]); c.autocommit = True
    try:
        cur = c.cursor(); cur.execute(sql, args); return cur.fetchall() if cur.description else None
    finally:
        c.close()


def h(t): print("\n" + "=" * 96 + f"\n{t}\n" + "=" * 96)


def sq(i, sql, args=None):
    with psycopg2.connect(**SHARD[i]) as c, c.cursor() as cur:
        cur.execute(sql, args); return cur.fetchall() if cur.description else None


# ------------------------------------------------------------------------------------------------
h("S0. How many real TapNaira transfers would cross shards?")
with psycopg2.connect(**MAIN) as c, c.cursor() as cur:
    for n in (2, 4, 8):
        cur.execute("""SELECT round(100.0 * avg((dr.wallet_id %% %s <> cr.wallet_id %% %s)::int), 1)
                       FROM wallet.txn t
                       JOIN wallet.ledger_entry dr ON dr.txn_id=t.txn_id AND dr.direction='DR'
                       JOIN wallet.ledger_entry cr ON cr.txn_id=t.txn_id AND cr.direction='CR' AND cr.wallet_id > 2
                       WHERE t.txn_type='TRANSFER' AND t.status='SUCCESS' AND dr.wallet_id > 2""", (n, n))
        print(f"  {n} shards by hash(wallet_id): {cur.fetchone()[0]}% of P2P transfers are CROSS-SHARD  (theory: {100*(1-1/n):.1f}%)")
print("  -> Any random customer can pay any other, so no wallet-based key keeps both sides of a transfer together.")

# ------------------------------------------------------------------------------------------------
h("Setup: 1,000 wallets distributed across 2 shards by wallet_id % 2 (N10,000 each)")
for i in (0, 1):
    for (g,) in admin(i, "SELECT gid FROM pg_prepared_xacts"):   # clear leftovers from an earlier run
        admin(i, "ROLLBACK PREPARED %s", (g,))
    sq(i, """DROP TABLE IF EXISTS wallet, ledger, decision_log;
             CREATE TABLE wallet(wallet_id BIGINT PRIMARY KEY, balance NUMERIC(14,2) NOT NULL CHECK (balance >= 0),
                                 status TEXT NOT NULL DEFAULT 'ACTIVE');
             CREATE TABLE ledger(entry_id BIGSERIAL PRIMARY KEY, ref TEXT, wallet_id BIGINT, direction CHAR(2), amount NUMERIC(14,2));""")
    sq(i, "INSERT INTO wallet SELECT g, 10000 FROM generate_series(1,1000) g WHERE g %% 2 = %s", (i,))
    print(f"  shard{i}: {sq(i, 'SELECT count(*), sum(balance) FROM wallet')[0]}")


def total():
    return sum(sq(i, "SELECT sum(balance) FROM wallet")[0][0] for i in (0, 1))


print(f"  total money in the system: N{total():,.2f}")

# ------------------------------------------------------------------------------------------------
h("S1. Same-shard transfer: wallet 2 -> wallet 4 (both on shard0) is one local ACID transaction")
with psycopg2.connect(**SHARD[0]) as c, c.cursor() as cur:
    cur.execute("UPDATE wallet SET balance = balance - 1000 WHERE wallet_id = 2 AND balance >= 1000")
    cur.execute("UPDATE wallet SET balance = balance + 1000 WHERE wallet_id = 4")
print(f"  committed. total = N{total():,.2f} (unchanged)")

# ------------------------------------------------------------------------------------------------
h("S2. Cross-shard transfer WITHOUT coordination: wallet 2 (shard0) -> wallet 7 (shard1), receiver FROZEN")
sq(1, "UPDATE wallet SET status = 'FROZEN' WHERE wallet_id = 7")
c0 = psycopg2.connect(**SHARD[0]); c1 = psycopg2.connect(**SHARD[1])
cur0, cur1 = c0.cursor(), c1.cursor()
cur0.execute("UPDATE wallet SET balance = balance - 2000 WHERE wallet_id = 2 AND balance >= 2000"); c0.commit()
print("  shard0: debit of N2,000 COMMITTED")
cur1.execute("UPDATE wallet SET balance = balance + 2000 WHERE wallet_id = 7 AND status = 'ACTIVE'")
print(f"  shard1: credit matched {cur1.rowcount} rows (receiver frozen) -> ROLLBACK"); c1.rollback()
print(f"  total = N{total():,.2f}  -> N2,000 has VANISHED. Each shard was atomic on its own; the transfer as a whole was not.")
cur0.execute("UPDATE wallet SET balance = balance + 2000 WHERE wallet_id = 2"); c0.commit()   # manual repair for the demo
sq(1, "UPDATE wallet SET status = 'ACTIVE' WHERE wallet_id = 7")
print(f"  (repaired by hand for the demo; total back to N{total():,.2f})")

# ------------------------------------------------------------------------------------------------
def transfer_2pc(frm, to, amount, crash_after_prepare=False, freeze_receiver=False):
    gid = "xfer-" + uuid.uuid4().hex[:8]
    s_from, s_to = shard_of(frm), shard_of(to)
    conns = {s_from: psycopg2.connect(**SHARD[s_from]), s_to: psycopg2.connect(**SHARD[s_to])}
    if freeze_receiver: sq(s_to, "UPDATE wallet SET status='FROZEN' WHERE wallet_id=%s", (to,))
    prepared = []
    try:
        # phase 1: do the work on each shard, then PREPARE (vote yes = "I can definitely commit")
        cur = conns[s_from].cursor()
        cur.execute("UPDATE wallet SET balance = balance - %s WHERE wallet_id=%s AND balance >= %s AND status='ACTIVE'", (amount, frm, amount))
        if cur.rowcount == 0: raise RuntimeError("insufficient funds / sender inactive")
        cur.execute("INSERT INTO ledger(ref, wallet_id, direction, amount) VALUES (%s,%s,'DR',%s)", (gid, frm, amount))
        cur.execute("PREPARE TRANSACTION %s", (gid + "-a",)); prepared.append((s_from, gid + "-a"))
        print(f"    phase 1: shard{s_from} debit wallet {frm} -> PREPARED ({gid}-a)")
        cur = conns[s_to].cursor()
        cur.execute("UPDATE wallet SET balance = balance + %s WHERE wallet_id=%s AND status='ACTIVE'", (amount, to))
        if cur.rowcount == 0: raise RuntimeError("receiver inactive")
        cur.execute("INSERT INTO ledger(ref, wallet_id, direction, amount) VALUES (%s,%s,'CR',%s)", (gid, to, amount))
        cur.execute("PREPARE TRANSACTION %s", (gid + "-b",)); prepared.append((s_to, gid + "-b"))
        print(f"    phase 1: shard{s_to} credit wallet {to} -> PREPARED ({gid}-b)")
        if crash_after_prepare:
            print("    !!! coordinator CRASHES after both PREPAREs, before COMMIT"); return gid, prepared
        # phase 2: everyone voted yes -> commit everywhere
        for s, g in prepared:
            admin(s, "COMMIT PREPARED %s", (g,))
        print(f"    phase 2: COMMIT PREPARED on both shards")
        return gid, []
    except Exception as e:
        print(f"    phase 1 FAILED ({e}) -> rolling back everything")
        for cn in conns.values():
            try: cn.rollback()
            except Exception: pass
        for s, g in prepared:
            admin(s, "ROLLBACK PREPARED %s", (g,))
            print(f"    phase 2: ROLLBACK PREPARED {g} on shard{s}")
        return gid, []
    finally:
        if freeze_receiver: sq(s_to, "UPDATE wallet SET status='ACTIVE' WHERE wallet_id=%s", (to,))


h("S3. Cross-shard transfers WITH two-phase commit")
print("  --- S3a. wallet 2 (shard0) -> wallet 7 (shard1), N2,000, both active")
transfer_2pc(2, 7, 2000)
print(f"  balances: w2 = N{sq(0,'SELECT balance FROM wallet WHERE wallet_id=2')[0][0]:,.2f}, w7 = N{sq(1,'SELECT balance FROM wallet WHERE wallet_id=7')[0][0]:,.2f}; total = N{total():,.2f}")
print("  --- S3b. same transfer but the receiver is FROZEN (the S2 situation)")
transfer_2pc(2, 7, 2000, freeze_receiver=True)
print(f"  balances: w2 = N{sq(0,'SELECT balance FROM wallet WHERE wallet_id=2')[0][0]:,.2f}, w7 = N{sq(1,'SELECT balance FROM wallet WHERE wallet_id=7')[0][0]:,.2f}; total = N{total():,.2f} -> nothing vanished")

# ------------------------------------------------------------------------------------------------
h("S4. Coordinator crash between PREPARE and COMMIT")
gid, pending = transfer_2pc(4, 9, 1500, crash_after_prepare=True)
for s in (0, 1):
    print(f"  shard{s} pg_prepared_xacts: {sq(s, 'SELECT gid FROM pg_prepared_xacts')}")
c = psycopg2.connect(**SHARD[0]); c.autocommit = True; cur = c.cursor()
cur.execute("SET lock_timeout = '2s'")
try:
    cur.execute("UPDATE wallet SET balance = balance - 1 WHERE wallet_id = 4")
except psycopg2.errors.LockNotAvailable:
    print("  another transfer from wallet 4 BLOCKS: the prepared (in-doubt) transaction still holds its row lock")
print("  recovery: the coordinator restarts, reads its decision log ('all prepared -> COMMIT') and finishes phase 2")
for s, g in pending:
    admin(s, "COMMIT PREPARED %s", (g,))
for s in (0, 1):
    print(f"  shard{s} pg_prepared_xacts after recovery: {sq(s, 'SELECT gid FROM pg_prepared_xacts')}")
print(f"  total = N{total():,.2f} (unchanged: money conserved across shards)")
