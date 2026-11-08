# Portfolio 4 – NoSQL and Advanced Data Models: a Graph Model for Fraud Detection

**Case study:** TapNaira Wallet. **NoSQL model chosen:** **graph** (property graph, queried with Cypher).
**Engine:** Kùzu 0.11.3, an embedded graph database. **System of record:** PostgreSQL (Portfolios 1–3).

| File | Purpose |
|---|---|
| `graph_fraud_demo.py` | Injects a fraud scenario through the real `transfer_funds()`, exports to the graph, and runs graph queries G0–G5 with SQL comparisons |
| `evidence/graph_output.txt` | Full output: every query, its result and its timing |

```bash
pip install kuzu==0.11.3 psycopg2-binary
python3 graph_fraud_demo.py | tee evidence/graph_output.txt
```

## 1. Why a graph for TapNaira?
Money moving between wallets **is a network**. The questions compliance staff ask are about **paths and shapes**, not rows:
- Where did the stolen money go next, and after that?
- Is this account a "collector" that many accounts feed into?
- Does money go round in a circle back to where it started?

In SQL, each extra hop means another self-join or a recursive CTE. In a graph database, the relationship **is** the data, and a multi-hop path is written as a single pattern: `(a)-[:SENT*1..3]->(b)`.

## 2. Graph model

```
(:Wallet {id, owner_type, confirmed_fraud}) -[:SENT {txn_id, amount, at}]-> (:Wallet)
```
- **Nodes:** 30,537 wallets (customers and agents). The SETTLEMENT and FEES system wallets are left out, because they touch every transaction and would connect everyone.
- **Edges:** 137,325 successful transfers, built from the double-entry ledger (debit wallet → credit wallet).
- **`confirmed_fraud`** comes from `fraud_flag.outcome = 'CONFIRMED'` in PostgreSQL.
- **Load:** exported from PostgreSQL and bulk-loaded with `COPY` in 0.28 s. In production this would be a nightly batch, or a stream of new ledger rows (change data capture).

## 3. Injected fraud scenario (through the real `transfer_funds()`)
1. A **victim** wallet (₦500,000) is drained in **₦90,000** transfers to **5 mule wallets**.
2. Each mule forwards **₦89,000** to **one collector**.
3. The collector sends **₦440,000** to an **agent** wallet for cash-out.
4. Separately, three wallets pass money in a **circle**: ₦50,000 → ₦49,000 → ₦48,000.
5. Compliance marks the collector as **CONFIRMED** fraud.

Because the scenario went through `transfer_funds()`, the relational ledger stays balanced. The graph is a **read model** built from it.

## 4. Results (`evidence/graph_output.txt`)

| # | Question | Result |
|---|---|---|
| G0 | Naive "guilt by association": everyone within 3 hops of an older confirmed fraud wallet, in any direction and at any time | **667 wallets**, almost all innocent. Unfiltered hop counts are useless in a busy payment network. |
| **G1** | **Follow the money:** forward from the victim, transfers ≥ ₦10,000 made after the theft, up to 3 hops | **Exactly 7 wallets:** the 5 mules (1 hop), the collector (2 hops) and the agent (3 hops). Filtering on **direction, amount and time** turns noise into evidence. |
| G2 | **Fan-in pattern:** wallets receiving from ≥ 4 different senders within one hour | **1 hit, the collector**, with all 5 mules listed. There were no false positives among about 30,000 normal wallets. |
| G3 | All paths from the victim to the cash-out agent | **5 paths**, victim → mule → collector → agent: the full money trail for the police report |
| G4a | All 3-wallet cycles, ignoring timing | **35 cycles.** Everyday transfers form cycles by chance. |
| G4b | Cycles completed **in time order within 24 hours** | **Only the injected ring** (shown 3 times, once for each starting wallet) |
| G5 | Busiest hubs by number of distinct counterparties | The top wallets each have 23–24 counterparties. A sudden jump in this number is a cheap mule indicator. |

**G1 in a graph vs in SQL (same answer, `True`):**

| | Cypher (graph) | SQL (recursive CTE on PostgreSQL) |
|---|---|---|
| Size of the query | **3 lines**, one path pattern | 12 lines: a recursive CTE with 3 joins per hop |
| G1: filtered, 7 wallets | 15.2 ms | **1.4 ms** (the Portfolio 2 indexes make each hop cheap) |
| G0: unfiltered 3-hop neighbourhood | **18 ms** | 585 ms (**32× slower**) |

**Honest conclusion:** for a short, tightly filtered trail, PostgreSQL with good indexes is just as fast or faster. The graph wins on wide or deep traversals, where SQL's recursive joins grow quickly. It also wins on **expressiveness**: fan-in, paths and time-ordered cycles are one readable pattern each, which compliance analysts can write and change themselves.

## 5. Suitability, trade-offs and design decisions
- **The graph is a secondary read model, not the system of record.** Money still moves only through PostgreSQL's ACID `transfer_funds()` (Portfolio 3). The graph has no balance-safety rules and should never be written to directly.
- **Freshness:** a nightly load means fraud found today shows up tomorrow. For real-time blocking, stream the ledger into the graph with change data capture, or keep fast rules such as the Portfolio 2 velocity query in PostgreSQL.
- **Privacy (NDPA 2023):** the graph holds only wallet IDs, amounts and times, with no names, phone numbers or BVN data. This is data minimisation: analysts see patterns, and identities stay in PostgreSQL behind access control.
- **Engine choice:** Kùzu was used because it is embedded (no server to install) and supports Cypher. Its repository was **archived in October 2025, and 0.11.3 is the final release**, so the version is pinned here (Dhandala, 2026). For production, TapNaira would run the same Cypher on a maintained engine such as Neo4j, Memgraph or FalkorDB.
- **Why not the other NoSQL types?** A key-value store such as Redis suits OTPs and live counters, and a document store suits flexible KYC profiles. Neither can answer **path** questions, and that's where fintech fraud hides.

**Reference:** Dhandala, N. (2026) *Kuzu was archived: should you pin 0.11.3, fork it, or migrate?* OneUptime. [Online] Available from: https://oneuptime.com/blog/post/2026-08-12-kuzu-archived-pin-0-11-3-fork-or-migrate/markdown. [Accessed 8 November 2026].
