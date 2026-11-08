# Portfolio 2 – Query Processing and Optimisation

**Case study:** TapNaira Wallet (Portfolio 1). **DBMS:** PostgreSQL 16. **Data:** 304k transactions and 764k ledger legs.

| File | Purpose |
|---|---|
| `queries.sql` | 8 workload queries (Q1–Q8) taken from real wallet operations |
| `indexes.sql` | Optimisation indexes, each one tied to a query |
| `benchmark.py` | Drops the indexes, runs `EXPLAIN (ANALYZE, BUFFERS)` 5× per query, adds the indexes, then re-runs |
| `extras.sql` | Experiments E1–E4: sargability, materialised view and statistics, write cost, reconciliation |
| `evidence/before`, `evidence/after`, `summary.md`, `extras_output.txt` | Execution plans and timings |

```bash
PGDATABASE=tapnaira python3 benchmark.py
psql -d tapnaira -f extras.sql > evidence/extras_output.txt
```
Method: warm cache, median of 5 runs, no parallel workers. Absolute times depend on the machine; the change in **plan shape** is the main evidence.

## 1. How a query is processed
1. **Parse:** the SQL text becomes a parse tree.
2. **Rewrite:** views such as `v_statement` are expanded into their base tables.
3. **Plan:** the cost-based optimiser picks the access paths (sequential scan, index scan, index-only scan or bitmap scan), the join methods (nested loop, hash or merge) and the join order. It bases these choices on statistics collected by `ANALYZE`.
4. **Execute:** the chosen plan runs. `EXPLAIN ANALYZE` shows the estimated rows next to the actual rows.

## 2. Results

| Query | Business use | Before (ms) | After (ms) | Plan change |
|---|---|---:|---:|---|
| Q1 | Customer's 30-day statement | 74.39 | 0.05 | Seq Scan of 764k ledger rows → index on `(wallet_id, posted_at)` |
| Q2 | **Daily-limit check (runs on every transfer)** | 83.87 | 0.01 | Seq Scan → **Index Only Scan** (covering index, no table visit) |
| Q3 | Fraud velocity rule (transfers in the last hour) | 25.76 | 0.01 | Seq Scan of `txn` → Index Only Scan on `(initiated_by_wallet, created_at)` |
| Q4 | Agent end-of-day report | 26.18 | 0.02 | Seq Scan → **partial** index on agent transactions only |
| Q5 | Compliance queue of unreviewed fraud flags | 0.98 | 0.12 | **Partial** index `WHERE reviewed_by IS NULL` (16 kB) |
| Q6 | Failed transactions this week | 25.06 | 0.04 | **Partial** index `WHERE status='FAILED'` (136 kB) |
| Q7 | Monthly fee revenue | 100.82 | 46.36 | Index Only Scan, but only 2.2× faster (see below) |
| Q8 | Top 10 agents by cash-out (CTE + `rank()`) | 28.11 | 28.66 | No change: an aggregate over a whole quarter |

**Why the transfer-path queries matter most.** Q2 (daily limit) and Q3 (fraud velocity) run inside **every transfer**, before any money moves. At 84 ms and 26 ms they would add over 100 ms to each transfer and hold locks longer (Portfolio 3). At about 0.01 ms they cost almost nothing.

**Index design:**
- **Composite order** `(wallet_id, posted_at)`: the equality column comes first and the range column second, so one wallet's day is a single contiguous slice of the index.
- **`INCLUDE (direction, amount, txn_id)`** makes the index *covering*: Q2 sums amounts without touching the table.
- **Partial indexes** (agent transactions, failed transactions, unreviewed flags) index only the rows queried, so they stay small. The failed-transaction index is 136 kB against 13 MB for a full index on `txn`.
- **Existing indexes reused.** Q1 finds the wallet through `UNIQUE(phone)` and the partial unique index `one_wallet_per_customer` from Portfolio 1, so no new index was needed there.

**Q7 and Q8 (limits of indexing).**
- **Q7:** the FEES system wallet receives a fee leg on most transfers. Even with the index, the query still reads about 100k rows. This is a "hot" wallet, and it's better served by a pre-aggregated daily summary.
- **Q8:** a ranking over a whole quarter has to read every cash-out in it, so an index can't help. E2 shows the fix.

## 3. Experiments (`evidence/extras_output.txt`)

| # | Experiment | Finding |
|---|---|---|
| E1 | `(posted_at AT TIME ZONE 'Africa/Lagos')::date = …` vs a half-open range | The function version uses the index for `wallet_id` only and filters the rest (0.70 ms). The range version scans just the needed slice (0.04 ms), **17× faster**. Never wrap an indexed column in a function. |
| E2 | Materialised view `mv_agent_daily` for Q8 | **Without statistics**, the planner guessed the row count wrong and chose a nested loop: 215 ms, worse than the original 28 ms. **After `ANALYZE`** it switched to a hash join: **8.4 ms**, 3.4× faster than Q8. Lesson: always ANALYZE a new table or view. The nightly refresh costs about 1.9 s. |
| E3 | Write cost: post 20,000 ledger legs with and without `ix_ledger_wallet_time` | 360 ms vs 298 ms, about **20% slower writes**. That's acceptable, because the same index makes every transfer's limit check about 6,000× faster. |
| E4 | Finance reconciliation: stored `wallet.balance` = sum of the ledger, for all 30,502 wallets | **0 mismatches**, in 0.4 s. This shows the controlled redundancy from Portfolio 1 is consistent. |

## 4. Summary
- TapNaira's critical path is OLTP: statements, limit checks and fraud rules. Composite, covering and partial indexes cut these from 25–100 ms to below 0.1 ms.
- Reporting queries (Q7, Q8) read large slices of data, so they need pre-aggregation (materialised views) or a read replica (Portfolio 5), not more indexes.
- Each index costs writes (about 20% for the ledger index) and disk (39 MB). Every index here is justified by a named query.
