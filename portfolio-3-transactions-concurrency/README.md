# Portfolio 3 – Transactions and Concurrency

**Case study:** TapNaira Wallet. **DBMS:** PostgreSQL 16 (MVCC). **Client:** Python 3 + psycopg2, running real concurrent sessions.

| File | Purpose |
|---|---|
| `transactions.sql` | The `transfer_funds()` stored procedure plus demos T1–T5 (COMMIT, ROLLBACK, idempotency, SAVEPOINT, durability and reconciliation) |
| `concurrency_demo.py` | C1–C4: double-spend (naive approach and three fixes), a 20-way stress test, a deadlock, and read skew |
| `evidence/` | The output of both files |

```bash
psql -d tapnaira -f transactions.sql > evidence/transactions_sql_output.txt 2>&1
python3 concurrency_demo.py | tee evidence/concurrency_output.txt
```

## 1. The transfer as one atomic transaction

`transfer_funds(reference, from, to, amount, fee)` runs as one unit of work:

1. **Lock both wallets** in wallet-id order (prevents deadlocks).
2. **Check the KYC daily limit** for the sender.
3. **Insert the `txn` row.** A duplicate reference fails here, which gives idempotency.
4. **Debit the sender** with the chosen conditional UPDATE (option C below).
5. **Credit the receiver and the FEES wallet.**
6. **Post three balanced ledger legs.** The Portfolio 1 trigger checks them at COMMIT.
7. **Mark the transaction SUCCESS.**

If any step fails, **everything** is rolled back.

| Demo | Result (`evidence/transactions_sql_output.txt`) | ACID property |
|---|---|---|
| T1 COMMIT | A ₦2,000 transfer from wallet 101 to 102 produces DR ₦2,010, CR ₦2,000 and CR ₦10 (fee). Both balances update. | Atomicity, consistency |
| T2 ROLLBACK | A ₦500,000 transfer from a wallet holding far less fails with "Insufficient funds". **0 new transaction rows**, and both balances are unchanged. The `txn` row inserted in step 3 was rolled back too. | Atomicity |
| T3 Idempotency | The app "retries" T1 with the same reference after a timeout. It is rejected by `UNIQUE(reference)`, so the customer is **not charged twice**. | Consistency |
| T4 SAVEPOINT | Compliance freezes wallet 102. A transfer to it fails, and `ROLLBACK TO SAVEPOINT` undoes only the failed transfer, so the freeze stays in place. | Partial rollback |
| T5 Durability | In a new session, both wallets' stored balance **equals their ledger balance**. | Durability, consistency |

## 2. Concurrency control: the double-spend problem (`evidence/concurrency_output.txt`)

**C1.** A customer has ₦10,000 and taps "send ₦8,000" (+₦10 fee) on two phones at the same moment.

| Approach | What happened | Verdict |
|---|---|---|
| **Naive**: read the balance, check it in the app, write the new balance | Both phones read ₦10,000 and both transfers were approved. The final balance was ₦1,990, but ₦16,020 was sent: **₦8,010 created out of nothing** (a lost update). The no-overdraft CHECK didn't help, because ₦1,990 is still ≥ 0. | ✗ Wrong |
| **C: conditional UPDATE** (`… SET balance = balance − 8010 WHERE balance >= 8010`), **chosen for TapNaira** | Phone 1 updated 1 row (APPROVED). Phone 2 updated **0 rows** (REJECTED). The second UPDATE waited for the row lock, then re-checked the condition against the new balance of ₦1,990. | ✓ Correct, fastest (the wait was only about 0.004 s) |
| A: `SELECT … FOR UPDATE` | Correct, but phone 2 **waited 0.50 s**, the whole length of phone 1's transaction. | ✓ Correct, slower under load |
| B: SERIALIZABLE + retry | Phone 1 got **error 40001**, retried, then saw ₦1,990 and was rejected. | ✓ Correct, but needs retry code and wastes an attempt |

**Why option C was chosen:** the balance check and the debit happen in **one SQL statement** under a single row lock, so there is no gap in which another transfer can slip in. It holds the lock for the shortest time and needs no retry logic in the app. Its limit is that it only works for checks that fit in one `WHERE` clause. That is why `transfer_funds()` also locks both wallets first, to cover the daily-limit check.

## 3. Further scenarios

| # | Scenario | Result |
|---|---|---|
| **C2** Stress test | 20 simultaneous ₦1,000 transfers (+₦10 fee) from a ₦10,000 wallet, through `transfer_funds()` | **9 approved, 11 rejected**, exactly as expected (9 × ₦1,010 = ₦9,090). Sender ₦910, receiver ₦9,000, and **balance = ledger**. |
| **C3** Deadlock | Wallet A sends to B while B sends to A, each locking its own wallet first | **40P01 deadlock detected**: PostgreSQL cancelled one transfer. When `transfer_funds()` locks the lowest wallet id first, both transfers COMMIT. |
| **C4** Read skew | Finance totals wallets A + B while A sends ₦5,000 to B | Under **READ COMMITTED** the report showed ₦45,000 against a true ₦40,000: **₦5,000 counted twice**. Under **REPEATABLE READ** it showed ₦40,000, from one consistent snapshot. Finance reports must use REPEATABLE READ (or run on a replica, Portfolio 5). |

**A bug found during testing.** The first version of `transfer_funds()` locked the wallets *after* inserting the `txn` row, and the C2 stress test produced deadlocks. The `txn` foreign key takes a KEY SHARE lock on the sender's wallet row, and each concurrent transfer then waited for the others to upgrade that lock to FOR UPDATE. Moving the lock to the very start of the procedure fixed it. It also made the daily-limit check race-free.

## 4. Isolation levels (PostgreSQL behaviour, verified above)

| Level | Lost update | Read skew / non-repeatable read | Write skew |
|---|---|---|---|
| READ COMMITTED (default) | Possible with read-then-write (C1 naive) | **Possible (C4)** | Possible |
| REPEATABLE READ | Detected (40001) | **Prevented (C4)** | Possible |
| SERIALIZABLE | Prevented (C1-B) | Prevented | Prevented |

## 5. Recommendations for TapNaira
1. Keep **READ COMMITTED** for the transfer path, with option C and ordered locking inside one stored procedure.
2. Use **REPEATABLE READ** (or a read replica) for finance and reconciliation reports.
3. Make every money-moving call **idempotent** with a client-generated reference.
4. Run a **nightly reconciliation**: stored balance must equal the ledger for every wallet. After all the demos, the result is still 0 mismatches and the sum of all balances is ₦0.00.
