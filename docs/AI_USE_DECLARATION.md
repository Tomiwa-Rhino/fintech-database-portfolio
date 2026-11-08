# AI Use Declaration

| | |
|---|---|
| **AI tool used** | Claude (Anthropic), via the Claude app |
| **What it was used for** | Generating the database schema, seed data, SQL queries, stored procedures, test scripts (Python and Bash), graph model, README explanations and diagrams for all five portfolio activities, based on the design choices I made (fintech mobile wallet; customers, agents and admin users; transfers as the key operation; conditional-update concurrency control; a graph model for fraud; synchronous + asynchronous replication) |
| **How I reviewed and verified the output** | I answered the design questions and checked my understanding at each step, and I re-ran the scripts on my own PostgreSQL installation. I wrote the individual reflection myself. |

Defects found and fixed during testing (recorded in the READMEs):
1. **Stress test (Portfolio 3):** `transfer_funds()` deadlocked under 20 concurrent transfers because it locked wallets after inserting the transaction row. It now locks both wallets first, in id order.
2. **Seed generator (Portfolio 1):** it produced negative balances when reversing transfers whose recipient had already spent the money. Reversals are now chosen only where the recipient can repay.
3. **Materialised view (Portfolio 2):** a new view was slow until `ANALYZE` was run, because the planner had no statistics.
4. **Replication lab (Portfolio 5):** the procedure failed on another node because of a different `search_path`. The procedure now pins `SET search_path = wallet`.
