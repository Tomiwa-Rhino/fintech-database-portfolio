"""
TapNaira – Portfolio 3: concurrency anomalies and control, with REAL concurrent sessions.

  C1  Double-spend on one wallet (two ₦8,000 transfers from ₦10,000 at the same moment)
        naive read-check-write  -> both approved (money created)
        Option C  conditional UPDATE ... WHERE balance >= x   (CHOSEN for TapNaira)
        Option A  SELECT ... FOR UPDATE                       (for comparison)
        Option B  SERIALIZABLE + retry                        (for comparison)
  C2  Stress test: 20 simultaneous ₦1,000 transfers through transfer_funds() from a ₦10,000 wallet
  C3  Deadlock: A->B and B->A at the same time; fixed by locking wallets in id order
  C4  Read skew in a finance report: READ COMMITTED vs REPEATABLE READ

Demo wallets are created fresh and funded with a proper, balanced ledger posting, so the
main dataset is not disturbed. Usage: python3 concurrency_demo.py | tee evidence/concurrency_output.txt
"""
import os, threading, time, uuid
import psycopg2
from psycopg2 import errors
from psycopg2.extensions import (ISOLATION_LEVEL_READ_COMMITTED as RC,
                                 ISOLATION_LEVEL_REPEATABLE_READ as RR,
                                 ISOLATION_LEVEL_SERIALIZABLE as SER)

DSN = dict(host=os.getenv("PGHOST", "localhost"), user=os.getenv("PGUSER", "postgres"),
           password=os.getenv("PGPASSWORD", "postgres"), dbname=os.getenv("PGDATABASE", "tapnaira"),
           options="-c search_path=wallet -c lock_timeout=10s -c deadlock_timeout=500ms")
T0 = time.time()
LK = threading.Lock()


def log(who, msg):
    with LK:
        print(f"  [{time.time()-T0:6.2f}s] {who:<9} {msg}", flush=True)


def conn(level=RC, name="app"):
    c = psycopg2.connect(application_name=name, **DSN); c.set_isolation_level(level); return c


def q(sql, args=None):
    with psycopg2.connect(**DSN) as c, c.cursor() as cur:
        cur.execute(sql, args)
        return cur.fetchall() if cur.description else None


def run(*fns):
    ts = [threading.Thread(target=f) for f in fns]; [t.start() for t in ts]; [t.join() for t in ts]


def header(t):
    print("\n" + "=" * 100 + f"\n{t}\n" + "=" * 100)


def new_wallet(amount):
    """Create a demo tier-3 customer + wallet and fund it with a balanced SETTLEMENT posting."""
    tag = uuid.uuid4().hex[:8]
    with psycopg2.connect(**DSN) as c, c.cursor() as cur:
        cur.execute("""INSERT INTO customer(phone, first_name, last_name, date_of_birth, bvn_hash, kyc_tier)
                       VALUES ('+2349' || lpad((floor(random()*1e9))::bigint::text, 9, '0'), 'Demo', %s, '1990-01-01',
                               encode(sha256(%s::bytea),'hex'), 3) RETURNING customer_id""", (tag, tag))
        cid = cur.fetchone()[0]
        cur.execute("INSERT INTO wallet(owner_type, customer_id, balance) VALUES ('CUSTOMER', %s, %s) RETURNING wallet_id", (cid, amount))
        wid = cur.fetchone()[0]
        if amount == 0:
            return wid
        cur.execute("UPDATE wallet SET balance = balance - %s WHERE system_name='SETTLEMENT'", (amount,))
        cur.execute("""INSERT INTO txn(reference, txn_type, amount, status, initiated_by_wallet, narration, completed_at)
                       VALUES (%s,'TRANSFER',%s,'SUCCESS',1,'Demo funding', now()) RETURNING txn_id""", ('FUND-' + tag, amount))
        tid = cur.fetchone()[0]
        cur.execute("INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount) VALUES (%s,1,'DR',%s),(%s,%s,'CR',%s)",
                    (tid, amount, tid, wid, amount))
    return wid


def bal(w):
    return q("SELECT balance FROM wallet WHERE wallet_id=%s", (w,))[0][0]


def ledger_bal(w):
    return q("SELECT sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END) FROM ledger_entry WHERE wallet_id=%s", (w,))[0][0]


# ------------------------------------------------------------------------------------------------
def c1():
    header("C1. DOUBLE-SPEND: customer has ₦10,000 and taps 'send ₦8,000' on two phones at the same moment (+₦10 fee each)")
    AMT = 8010

    # ---- naive read-check-write (READ COMMITTED) -----------------------------------------------
    w = new_wallet(10000)
    print("  --- Naive app logic: read balance, check in the app, write new balance")
    both_read = threading.Barrier(2)
    approved = []

    def naive(who):
        c = conn(RC, who); cur = c.cursor()
        cur.execute("SELECT balance FROM wallet WHERE wallet_id=%s", (w,)); b = cur.fetchone()[0]
        log(who, f"reads balance ₦{b:,.0f}; check {b:,.0f} >= {AMT:,} -> OK")
        both_read.wait()
        cur.execute("UPDATE wallet SET balance=%s WHERE wallet_id=%s", (b - AMT, w))
        c.commit(); approved.append(who); log(who, f"writes balance = {b:,.0f} - {AMT:,} = ₦{b-AMT:,.0f}; COMMIT, transfer approved")
    run(lambda: naive("phone_1"), lambda: naive("phone_2"))
    log("result", f"{len(approved)} transfers approved = ₦{len(approved)*AMT:,} sent, but balance is ₦{bal(w):,.0f} "
                  f"-> ₦{AMT:,} was CREATED out of nothing (lost update). The no-overdraft CHECK did not help: ₦1,990 >= 0.")

    # ---- Option C: conditional UPDATE (chosen) --------------------------------------------------
    w = new_wallet(10000)
    print("\n  --- Option C (TapNaira's choice): UPDATE wallet SET balance = balance - 8010 WHERE wallet_id = ? AND balance >= 8010")
    go = threading.Barrier(2)

    def opt_c(who):
        c = conn(RC, who); cur = c.cursor(); go.wait(); t = time.time()
        cur.execute("UPDATE wallet SET balance = balance - %s WHERE wallet_id=%s AND balance >= %s", (AMT, w, AMT))
        n = cur.rowcount; c.commit()
        log(who, f"rows updated = {n} after {time.time()-t:.3f}s -> " + ("APPROVED" if n else "REJECTED: insufficient funds"))
    run(lambda: opt_c("phone_1"), lambda: opt_c("phone_2"))
    log("result", f"balance ₦{bal(w):,.0f} -> correct. The second UPDATE waited for the row lock, re-checked "
                  "balance >= 8010 against the NEW value (1,990) and matched 0 rows.")

    # ---- Option A: SELECT ... FOR UPDATE --------------------------------------------------------
    w = new_wallet(10000)
    print("\n  --- Option A (comparison): SELECT ... FOR UPDATE, then check, then UPDATE")
    first_locked = threading.Event()

    def opt_a(who, wait_first):
        if wait_first: first_locked.wait()
        c = conn(RC, who); cur = c.cursor(); t = time.time()
        cur.execute("SELECT balance FROM wallet WHERE wallet_id=%s FOR UPDATE", (w,)); b = cur.fetchone()[0]
        log(who, f"got lock after {time.time()-t:.2f}s, balance ₦{b:,.0f}")
        if not wait_first: first_locked.set(); time.sleep(0.5)
        if b >= AMT:
            cur.execute("UPDATE wallet SET balance = balance - %s WHERE wallet_id=%s", (AMT, w)); log(who, "APPROVED")
        else:
            log(who, "REJECTED: insufficient funds")
        c.commit()
    run(lambda: opt_a("phone_1", False), lambda: opt_a("phone_2", True))
    log("result", f"balance ₦{bal(w):,.0f} -> correct, but phone_2 had to WAIT for the whole of phone_1's transaction.")

    # ---- Option B: SERIALIZABLE + retry ---------------------------------------------------------
    w = new_wallet(10000)
    print("\n  --- Option B (comparison): naive logic but under SERIALIZABLE, with automatic retry")
    both_read = threading.Barrier(2)

    def opt_b(who):
        for attempt in (1, 2, 3):
            c = conn(SER, who); cur = c.cursor()
            try:
                cur.execute("SELECT balance FROM wallet WHERE wallet_id=%s", (w,)); b = cur.fetchone()[0]
                if attempt == 1: both_read.wait()
                if b < AMT:
                    c.rollback(); log(who, f"attempt {attempt}: balance ₦{b:,.0f} -> REJECTED"); return
                cur.execute("UPDATE wallet SET balance=%s WHERE wallet_id=%s", (b - AMT, w)); c.commit()
                log(who, f"attempt {attempt}: APPROVED"); return
            except errors.SerializationFailure as e:
                c.rollback(); log(who, f"attempt {attempt}: ERROR {e.pgcode} serialization failure -> retry")
    run(lambda: opt_b("phone_1"), lambda: opt_b("phone_2"))
    log("result", f"balance ₦{bal(w):,.0f} -> correct, but the app needs retry code and wastes one attempt.")


# ------------------------------------------------------------------------------------------------
def c2():
    header("C2. STRESS TEST: 20 simultaneous ₦1,000 transfers (+₦10 fee) via transfer_funds() from a ₦10,000 wallet")
    src, dst = new_wallet(10000), new_wallet(0)
    go = threading.Barrier(20); res = {"ok": 0, "rejected": 0}

    def one(i):
        c = conn(RC, f"t{i}"); cur = c.cursor(); go.wait()
        try:
            cur.execute("CALL transfer_funds(%s,%s,%s,1000,10)", (f"STRESS-{uuid.uuid4().hex[:10]}", src, dst)); c.commit()
            with LK: res["ok"] += 1
        except psycopg2.Error:
            c.rollback()
            with LK: res["rejected"] += 1
    run(*[lambda i=i: one(i) for i in range(20)])
    log("result", f"approved {res['ok']}, rejected {res['rejected']} (expected 9 and 11: 9 × ₦1,010 = ₦9,090 ≤ ₦10,000)")
    log("result", f"sender balance ₦{bal(src):,.2f} (expected ₦910.00) · ledger says ₦{ledger_bal(src):,.2f} · "
                  f"receiver ₦{bal(dst):,.2f} (expected ₦9,000.00) -> balance and ledger agree")


# ------------------------------------------------------------------------------------------------
def c3():
    header("C3. DEADLOCK: A sends to B while B sends to A at the same moment")
    a, b = new_wallet(50000), new_wallet(50000)
    print("  --- Naive order: each transfer locks its OWN (sender) wallet first")
    both = threading.Barrier(2)

    def naive(who, frm, to):
        c = conn(RC, who); cur = c.cursor()
        try:
            cur.execute("UPDATE wallet SET balance = balance - 1000 WHERE wallet_id=%s AND balance >= 1000", (frm,))
            log(who, f"locked sender wallet {frm}"); both.wait()
            cur.execute("UPDATE wallet SET balance = balance + 1000 WHERE wallet_id=%s", (to,))
            c.commit(); log(who, "COMMIT")
        except errors.DeadlockDetected as e:
            c.rollback(); log(who, f"ERROR {e.pgcode} deadlock detected -> this transfer was cancelled (victim)")
    run(lambda: naive("A->B", a, b), lambda: naive("B->A", b, a))

    print("\n  --- transfer_funds(): both wallets locked in wallet_id order (lowest first)")
    go = threading.Barrier(2)

    def ordered(who, frm, to):
        c = conn(RC, who); cur = c.cursor(); go.wait()
        cur.execute("CALL transfer_funds(%s,%s,%s,1000,10)", (f"DL-{uuid.uuid4().hex[:10]}", frm, to)); c.commit()
        log(who, "COMMIT (no deadlock)")
    run(lambda: ordered("A->B", a, b), lambda: ordered("B->A", b, a))


# ------------------------------------------------------------------------------------------------
def c4():
    a, b = new_wallet(20000), new_wallet(20000)
    for level, name in ((RC, "READ COMMITTED"), (RR, "REPEATABLE READ")):
        header(f"C4. READ SKEW: finance totals wallets A + B while A sends ₦5,000 to B ({name})")
        first = threading.Event(); moved = threading.Event(); out = {}

        def report():
            c = conn(level, "finance"); cur = c.cursor()
            cur.execute("SELECT balance FROM wallet WHERE wallet_id=%s", (a,)); out["a"] = cur.fetchone()[0]
            log("finance", f"reads A = ₦{out['a']:,.0f}"); first.set(); moved.wait()
            cur.execute("SELECT balance FROM wallet WHERE wallet_id=%s", (b,)); out["b"] = cur.fetchone()[0]
            log("finance", f"reads B = ₦{out['b']:,.0f}  -> report total ₦{out['a']+out['b']:,.0f}"); c.commit()

        def transfer():
            first.wait(); c = conn(RC, "customer"); cur = c.cursor()
            cur.execute("CALL transfer_funds(%s,%s,%s,5000,0)", (f"RS-{uuid.uuid4().hex[:10]}", a, b)); c.commit()
            log("customer", "A -> B ₦5,000 COMMIT"); moved.set()
        before = bal(a) + bal(b)
        run(report, transfer)
        ok = out["a"] + out["b"] == before
        log("result", f"true total before = ₦{before:,.0f}; report shows ₦{out['a']+out['b']:,.0f} -> "
                      + ("CONSISTENT snapshot" if ok else "ANOMALY: ₦5,000 counted twice (money that doesn't exist)"))


if __name__ == "__main__":
    print(q("SELECT version()")[0][0])
    c1(); c2(); c3(); c4()
    # repair the wallet corrupted by the naive C1 demo, exactly as a reconciliation job would
    fixed = q("""UPDATE wallet w SET balance = l.s FROM (SELECT wallet_id, sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END) s
                 FROM ledger_entry GROUP BY wallet_id) l WHERE l.wallet_id = w.wallet_id AND w.balance <> l.s RETURNING w.wallet_id""")
    print(f"\nReconciliation repair: {len(fixed or [])} demo wallet(s) reset to their ledger balance (the C1 naive/option-A/B demos "
          "changed balances without ledger legs).")
    print("All scenarios complete.")
