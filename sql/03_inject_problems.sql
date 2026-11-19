-- =====================================================================
-- OPTIONAL: break the data on purpose, then re-run the checks in file 02.
-- To get clean data again, re-run file 01 (it recreates everything).
-- =====================================================================

-- Problem A: a new UK account that nobody mapped (booked against cash, so it still balances)
-- Expected: CHECK 1 finds account 9999
INSERT INTO stg_gl_entry VALUES
  ('LEDGER_B','UK01','2025-06-01','9999','G&A',NULL,'GBP', 500.00, 1),
  ('LEDGER_B','UK01','2025-06-01','1200', NULL, NULL,'GBP',-500.00, 1);

-- Problem B: one-sided posting in the Netherlands (no offsetting line)
-- Expected: CHECK 2 finds NL01 March 2025 out of balance by 250
INSERT INTO stg_gl_entry VALUES
  ('LEDGER_A','NL01','2025-03-01','720100','G&A',NULL,'EUR', 250.00, 1);

-- Problem C: Singapore September loaded twice (a copy with load_id 2)
-- Expected: CHECK 3 finds SG01 September 2025 with 2 loads.
-- Side effects to notice: September revenue in the P&L report jumps (Singapore counted
-- twice), and CHECK 4 also shows a September difference of 10,000 EUR, because the
-- doubled Singapore payable no longer matches the Netherlands receivable.
INSERT INTO stg_gl_entry
SELECT source_system, entity_code, period, local_account, cost_centre,
       ic_partner, currency, amount_local, 2
FROM stg_gl_entry
WHERE entity_code = 'SG01' AND period = '2025-09-01' AND load_id = 1;

-- Problem D: Singapore books a smaller intercompany invoice than the Netherlands in August
-- (payable and cost both reduced, so Singapore still balances)
-- Expected: CHECK 4 shows a difference of 800 EUR for NL01 and SG01 in August 2025
-- (shown on both sides: once for each entity)
UPDATE stg_gl_entry g
SET amount_local = ROUND(g.amount_local * 0.92, 2)
FROM map_account m
WHERE m.entity_code = g.entity_code
  AND m.local_account = g.local_account
  AND m.group_account IN ('IC-PAY', 'COST-IC')
  AND g.entity_code = 'SG01'
  AND g.period = '2025-08-01';
