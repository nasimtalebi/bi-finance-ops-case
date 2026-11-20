# BI case: one trusted view of finance and operations (practice project)

A small, case for  BI and consolidation work in PostgreSQL.

**Scenario:** a group with 3 entities (Netherlands, UK, Singapore) in 3 currencies
(EUR, GBP, SGD), 12 months of ledger data, operational KPIs and a budget.
Two audiences: the **group controller** ("can I trust the consolidated numbers?") and
the **business controller** ("where and why are we off plan?").

## What it shows
- Staging tables, account mapping and monthly exchange rates
- Translation to EUR (P&L at average rate, balance sheet at closing rate)
- Intercompany elimination
- Five data-integrity checks and a one-line close-readiness summary
- Budget vs actual with variance (positive = favourable)
- Operational KPIs linked to the ledger (ARR = 12 x subscription revenue)

## How to run
1. Create a database, for example `bi_practice`.
2. Run the files in `sql/` in order:

| File | Purpose |
| --- | --- |
| `01_setup_and_data.sql` | Tables, invented data, views (safe to re-run, resets everything) |
| `02_checks_and_queries.sql` | Five integrity checks and basic reports |
| `03_inject_problems.sql` | Optional: breaks the data on purpose so the checks fail |
| `04_budget_and_variance.sql` | Budget table, variance view, check summary (run on clean data) |
| `05_controller_reports.sql` | The queries used for the two controllers |

## Notes
- Sign convention: debit positive, credit negative. Amounts are monthly movements.
- Simplifications: all entities 100% owned, no cumulative balances, no booked FX difference
  on intercompany P&L lines, budget translated at the average rate.
- Tested on PostgreSQL 16; nothing in it is version specific.
