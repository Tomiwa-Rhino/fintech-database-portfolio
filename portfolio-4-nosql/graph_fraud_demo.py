"""
TapNaira – Portfolio 4: Graph model for fraud-ring detection (Kùzu embedded graph DB, Cypher)

Why a graph: money moving between wallets IS a network. Fraud questions are about paths
("is this wallet within 3 hops of a confirmed fraudster?", "who funnels money from many
accounts into one?"). In SQL these need recursive self-joins; in a graph they are one pattern.

Steps
  1. Inject a realistic fraud scenario into PostgreSQL through the REAL transfer_funds()
     procedure (so the relational ledger stays the system of record):
       stolen wallet -> 5 "mule" wallets -> 1 collector -> agent cash-out  (+ a 3-wallet round-trip cycle)
  2. Export wallets + successful transfers from PostgreSQL to CSV and load them into Kùzu
  3. Run graph queries G1-G5 and compare G1 with the equivalent SQL recursive CTE

Usage: python3 graph_fraud_demo.py | tee evidence/graph_output.txt
Requires: pip install kuzu==0.11.3 psycopg2-binary
"""
import csv, os, shutil, time, uuid, pathlib
import kuzu, psycopg2

HERE = pathlib.Path(__file__).parent
DATA = HERE / "graph_data"; DBDIR = HERE / "graph_db"
DSN = dict(host=os.getenv("PGHOST", "localhost"), user=os.getenv("PGUSER", "postgres"),
           password=os.getenv("PGPASSWORD", "postgres"), dbname=os.getenv("PGDATABASE", "tapnaira"),
           options="-c search_path=wallet")
pg = psycopg2.connect(**DSN); pg.autocommit = True; cur = pg.cursor()


def h(t): print("\n" + "=" * 96 + f"\n{t}\n" + "=" * 96)


def new_wallet(label, amount=0):
    tag = uuid.uuid4().hex[:8]
    cur.execute("""INSERT INTO customer(phone, first_name, last_name, date_of_birth, bvn_hash, kyc_tier)
                   VALUES ('+2349' || lpad((floor(random()*1e9))::bigint::text, 9, '0'), %s, %s, '1992-02-02',
                           encode(sha256(%s::bytea),'hex'), 3) RETURNING customer_id""", (label, 'Scenario', tag))
    cid = cur.fetchone()[0]
    cur.execute("INSERT INTO wallet(owner_type, customer_id) VALUES ('CUSTOMER', %s) RETURNING wallet_id", (cid,))
    wid = cur.fetchone()[0]
    if amount:
        cur.execute("""WITH t AS (INSERT INTO txn(reference, txn_type, amount, status, initiated_by_wallet, narration, completed_at)
                                  VALUES (%s,'TRANSFER',%s,'SUCCESS',1,'Scenario funding', now()) RETURNING txn_id)
                       INSERT INTO ledger_entry(txn_id, wallet_id, direction, amount)
                       SELECT txn_id, 1, 'DR', %s FROM t UNION ALL SELECT txn_id, %s, 'CR', %s FROM t""",
                    ('SCN-FUND-' + tag, amount, amount, wid, amount))
        cur.execute("UPDATE wallet SET balance = balance + %s WHERE wallet_id = %s", (amount, wid))
        cur.execute("UPDATE wallet SET balance = balance - %s WHERE system_name = 'SETTLEMENT'", (amount,))
    return wid


def transfer(frm, to, amt, fee=10):
    cur.execute("CALL transfer_funds(%s,%s,%s,%s,%s)", ("SCN-" + uuid.uuid4().hex[:12], frm, to, amt, fee))


# ------------------------------------------------------------------------------------------------
h("1. Inject a fraud scenario through transfer_funds() (PostgreSQL stays the system of record)")
victim = new_wallet("Victim", 500000)
mules = [new_wallet(f"Mule{i}") for i in range(1, 6)]
collector = new_wallet("Collector")
cur.execute("SELECT wallet_id FROM wallet WHERE owner_type='AGENT' ORDER BY wallet_id LIMIT 1"); agent_w = cur.fetchone()[0]
cur.execute("SELECT now()::timestamp(0)"); since = cur.fetchone()[0]
for m in mules: transfer(victim, m, 90000)                 # fan-out: stolen account drained to 5 mules
for m in mules: transfer(m, collector, 89000)              # fan-in: mules forward almost everything
transfer(collector, agent_w, 440000)                       # cash-out through an agent wallet
ring = [new_wallet(f"Ring{i}", 60000 if i == 1 else 0) for i in range(1, 4)]
transfer(ring[0], ring[1], 50000); transfer(ring[1], ring[2], 49000); transfer(ring[2], ring[0], 48000)  # round-trip cycle
cur.execute("""INSERT INTO fraud_flag(txn_id, rule_code, score, reviewed_by, outcome)
               SELECT max(txn_id), 'FAN_IN', 95, 2, 'CONFIRMED' FROM ledger_entry WHERE wallet_id = %s AND direction='CR'""", (collector,))
print(f"victim={victim}  mules={mules}  collector={collector}  agent_wallet={agent_w}  ring={ring}")
print("collector confirmed as fraud by compliance (fraud_flag CONFIRMED)")

# ------------------------------------------------------------------------------------------------
h("2. Export from PostgreSQL and load into the graph")
shutil.rmtree(DATA, ignore_errors=True); DATA.mkdir()
cur.execute("""SELECT w.wallet_id, w.owner_type,
                      EXISTS (SELECT 1 FROM fraud_flag f JOIN ledger_entry le ON le.txn_id = f.txn_id AND le.direction='CR'
                              WHERE f.outcome='CONFIRMED' AND le.wallet_id = w.wallet_id) AS confirmed_fraud
               FROM wallet w WHERE w.owner_type <> 'SYSTEM'""")
with open(DATA / "wallets.csv", "w", newline="") as f: csv.writer(f).writerows(cur.fetchall())
cur.execute("""SELECT dr.wallet_id, cr.wallet_id, t.txn_id, t.amount, to_char(t.created_at,'YYYY-MM-DD HH24:MI:SS')
               FROM txn t
               JOIN ledger_entry dr ON dr.txn_id = t.txn_id AND dr.direction = 'DR'
               JOIN ledger_entry cr ON cr.txn_id = t.txn_id AND cr.direction = 'CR'
               JOIN wallet wd ON wd.wallet_id = dr.wallet_id AND wd.owner_type <> 'SYSTEM'
               JOIN wallet wc ON wc.wallet_id = cr.wallet_id AND wc.owner_type <> 'SYSTEM'
               WHERE t.txn_type = 'TRANSFER' AND t.status IN ('SUCCESS','REVERSED')""")
rows = cur.fetchall()
with open(DATA / "sent.csv", "w", newline="") as f: csv.writer(f).writerows(rows)
for old in HERE.glob("graph_db*"):          # Kuzu 0.11 stores the DB as a file (+ .wal)
    shutil.rmtree(old) if old.is_dir() else old.unlink()
db = kuzu.Database(str(DBDIR)); g = kuzu.Connection(db)
g.execute("CREATE NODE TABLE Wallet(id INT64, owner_type STRING, confirmed_fraud BOOLEAN, PRIMARY KEY(id))")
g.execute("CREATE REL TABLE SENT(FROM Wallet TO Wallet, txn_id INT64, amount DOUBLE, at TIMESTAMP)")
t = time.time()
g.execute(f"COPY Wallet FROM '{DATA/'wallets.csv'}' (header=false)")
g.execute(f"COPY SENT FROM '{DATA/'sent.csv'}' (header=false)")
n = g.execute("MATCH (w:Wallet) RETURN count(*)").get_next()[0]
e = g.execute("MATCH ()-[s:SENT]->() RETURN count(*)").get_next()[0]
print(f"loaded {n:,} Wallet nodes and {e:,} SENT edges in {time.time()-t:.2f}s")


def run(title, cypher, params=None):
    print(f"\n--- {title}\n{cypher.strip()}")
    t = time.perf_counter(); r = g.execute(cypher, params or {}); ms = (time.perf_counter() - t) * 1000
    cols = r.get_column_names(); out = []
    while r.has_next(): out.append(r.get_next())
    print("  " + " | ".join(cols))
    for row in out[:12]: print("  " + " | ".join(str(x) for x in row))
    if len(out) > 12: print(f"  ... ({len(out)} rows)")
    print(f"  -> {len(out)} rows in {ms:.1f} ms")
    return out, ms


# ------------------------------------------------------------------------------------------------
h("3. Graph queries")
cur.execute("""SELECT le.wallet_id FROM fraud_flag f JOIN ledger_entry le ON le.txn_id=f.txn_id AND le.direction='CR'
               WHERE f.outcome='CONFIRMED' AND le.wallet_id <> %s ORDER BY f.flag_id LIMIT 1""", (collector,))
old_fraud = cur.fetchone()[0]
_, g0_ms = run(f"G0. Naive 'guilt by association': every wallet within 3 hops of an older confirmed fraud wallet ({old_fraud}), any direction, any time",
    """MATCH (f:Wallet {id: $f})-[:SENT*1..3]-(w:Wallet)
       WHERE w.id <> f.id
       RETURN count(DISTINCT w) AS wallets_reached""", {"f": old_fraud})

g1, g1_ms = run("G1. Follow the money: where did the victim's funds go? (forward only, >= N10,000, after the theft, <= 3 hops)",
    """MATCH (v:Wallet {id: $victim})-[e:SENT*1..3 (r, n | WHERE r.amount >= 10000 AND r.at >= $since)]->(w:Wallet)
       RETURN DISTINCT w.id AS wallet, w.owner_type AS type, min(length(e)) AS hops ORDER BY hops, wallet""",
    {"victim": victim, "since": since})

run("G2. Fan-in 'collector' pattern: wallets receiving from >= 4 different senders within one hour",
    """MATCH (s:Wallet)-[r:SENT]->(c:Wallet)
       WITH c, date_trunc('hour', r.at) AS hr, collect(DISTINCT s.id) AS senders
       WHERE size(senders) >= 4
       RETURN c.id AS collector, hr, size(senders) AS n_senders, senders ORDER BY n_senders DESC""")

run("G3. How did money get from the victim to the agent? (all paths up to 3 hops)",
    """MATCH p = (v:Wallet {id: $victim})-[:SENT*1..3]->(a:Wallet {id: $agent})
       RETURN properties(nodes(p), 'id') AS path LIMIT 10""", {"victim": victim, "agent": agent_w})

run("G4a. Round-trip cycles A -> B -> C -> A, any timing (random everyday transfers also form cycles)",
    """MATCH (a:Wallet)-[:SENT]->(b:Wallet)-[:SENT]->(c:Wallet)-[:SENT]->(a)
       WHERE a.id < b.id AND a.id < c.id
       RETURN count(*) AS cycles""")
run("G4b. Suspicious cycles: money returns to the start in time order within 24 hours (layering)",
    """MATCH (a:Wallet)-[r1:SENT]->(b:Wallet)-[r2:SENT]->(c:Wallet)-[r3:SENT]->(a)
       WHERE r1.at <= r2.at AND r2.at <= r3.at AND r3.at - r1.at <= interval('24 hours')
       RETURN a.id, b.id, c.id, r1.amount, r2.amount, r3.amount""")

run("G5. Busiest hubs: wallets with the most distinct counterparties",
    """MATCH (w:Wallet)-[:SENT]-(x:Wallet)
       RETURN w.id AS wallet, w.owner_type AS type, count(DISTINCT x) AS counterparties
       ORDER BY counterparties DESC LIMIT 5""")

# ------------------------------------------------------------------------------------------------
h("4. Same question as G1 in SQL (recursive CTE over the relational ledger)")
sql = """
WITH RECURSIVE hop(w, depth) AS (
    SELECT %(victim)s::bigint, 0
    UNION
    SELECT cr.wallet_id, hop.depth + 1
    FROM hop
    JOIN ledger_entry dr ON dr.wallet_id = hop.w AND dr.direction = 'DR'
    JOIN txn t           ON t.txn_id = dr.txn_id AND t.txn_type = 'TRANSFER'
                        AND t.status IN ('SUCCESS','REVERSED') AND t.amount >= 10000 AND t.created_at >= %(since)s
    JOIN ledger_entry cr ON cr.txn_id = t.txn_id AND cr.direction = 'CR' AND cr.wallet_id > 2
    WHERE hop.depth < 3
)
SELECT w, min(depth) FROM hop WHERE w <> %(victim)s GROUP BY w ORDER BY 2, 1"""
print(sql.strip())
t = time.perf_counter(); cur.execute(sql, {"victim": victim, "since": since}); sql_rows = cur.fetchall(); sql_ms = (time.perf_counter() - t) * 1000
print(f"  -> {len(sql_rows)} rows in {sql_ms:.1f} ms")
same = sorted(r[0] for r in sql_rows) == sorted(r[0] for r in g1)
print(f"\nSame answer as G1: {same}.  Graph {g1_ms:.1f} ms vs SQL {sql_ms:.1f} ms")
print(f"Query size: Cypher G1 = 3 lines; SQL = {len(sql.strip().splitlines())} lines (recursive CTE + 3 joins per hop)")

h("5. Same question as G0 in SQL (unfiltered 3-hop neighbourhood, both directions)")
sql0 = """
WITH RECURSIVE pairs AS (
    SELECT DISTINCT dr.wallet_id a, cr.wallet_id b
    FROM txn t JOIN ledger_entry dr ON dr.txn_id=t.txn_id AND dr.direction='DR'
               JOIN ledger_entry cr ON cr.txn_id=t.txn_id AND cr.direction='CR'
    WHERE t.txn_type='TRANSFER' AND t.status IN ('SUCCESS','REVERSED') AND dr.wallet_id>2 AND cr.wallet_id>2
), und AS (SELECT a, b FROM pairs UNION SELECT b, a FROM pairs),
walk(w, depth) AS (
    SELECT %(c)s::bigint, 0
    UNION
    SELECT und.b, walk.depth + 1 FROM walk JOIN und ON und.a = walk.w WHERE walk.depth < 3
)
SELECT count(DISTINCT w) - 1 FROM walk"""
print(sql0.strip())
cur.execute("SET statement_timeout = '120s'")
t = time.perf_counter(); cur.execute(sql0, {"c": old_fraud}); n0 = cur.fetchone()[0]; ms0 = (time.perf_counter()-t)*1000
print(f"  -> {n0:,} wallets reached in {ms0:,.0f} ms   vs graph G0 {g0_ms:,.0f} ms  ({ms0/g0_ms:.0f}x faster in the graph)")
