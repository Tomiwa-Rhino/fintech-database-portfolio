| Query | Description | Before (ms) | After (ms) | Speed-up |
|---|---|---:|---:|---:|
| Q1 | Wallet statement for the last 30 days (customer looks at their app) | 74.39 | 0.05 | 1617.3× |
| Q2 | Daily-limit check before a transfer: total sent by this wallet today (runs on EVERY transfer) | 83.87 | 0.01 | 5990.9× |
| Q3 | Fraud velocity rule: transfers started by a wallet in the last hour | 25.76 | 0.01 | 1981.8× |
| Q4 | Agent end-of-day report: cash-in and cash-out totals for one agent on one day | 26.18 | 0.02 | 1309.0× |
| Q5 | Compliance queue: fraud flags still waiting for review, oldest first | 0.98 | 0.12 | 8.4× |
| Q6 | Operations: failed transactions in the last 7 days by type | 25.06 | 0.04 | 582.8× |
| Q7 | Finance: monthly fee revenue (credits to the FEES system wallet) in 2026 | 100.82 | 46.36 | 2.2× |
| Q8 | Management: top 10 agents by cash-out value in Q3 2026 (CTE + window function) | 28.11 | 28.66 | 1.0× |

| Index | Size |
|---|---:|
| ix_fraud_unreviewed | 16 kB |
| ix_ledger_txn | 18 MB |
| ix_ledger_wallet_time | 39 MB |
| ix_txn_agent_time | 3736 kB |
| ix_txn_failed_time | 136 kB |
| ix_txn_wallet_time | 13 MB |
