-- =====================================================================
-- Budget, variance and a one-line "close readiness" summary.
-- Run AFTER 01_setup_and_data.sql, on CLEAN data (do not run 03 first).
-- Safe to re-run.
--
-- Presentation sign convention in the variance view (same as v_pl_group):
--   revenue positive, costs negative, so
--   variance = actual - budget  ->  POSITIVE = favourable, NEGATIVE = unfavourable.
-- =====================================================================

DROP TABLE IF EXISTS budget_entry CASCADE;
DROP VIEW  IF EXISTS v_actual_vs_budget, v_check_summary;

-- ---------------------------------------------------------------------
-- 1. Budget in LOCAL currency, same sign convention as the ledger
--    (credit negative). Only P&L accounts, no intercompany.
--    The budget is built from the actuals with a small deterministic
--    difference, plus three planted stories for the meeting:
--      * SG01 other operating cost: 25% over budget in Jul to Sep
--      * UK01 services revenue:     18% below budget in Aug to Oct
--      * NL01 subscription revenue:  2% above budget all year
-- ---------------------------------------------------------------------
CREATE TABLE budget_entry (
  entity_code   VARCHAR(10)   NOT NULL,
  period        DATE          NOT NULL,
  group_account VARCHAR(20)   NOT NULL,
  version       VARCHAR(20)   NOT NULL,
  amount_local  DECIMAL(18,2) NOT NULL,
  PRIMARY KEY (entity_code, period, group_account, version)
);

INSERT INTO budget_entry
SELECT a0.entity_code, a0.period, a0.group_account, 'Budget',
       ROUND(a0.amount_local / (1 + COALESCE(a0.story_var, a0.base_var)::numeric), 2)
FROM (
  SELECT g.entity_code, g.period, m.group_account,
         SUM(g.amount_local) AS amount_local,
         -- default: actual is within about +/-3% of budget
         0.03 * SIN(EXTRACT(MONTH FROM g.period) * 0.9
                    + ASCII(RIGHT(g.entity_code, 1))
                    + ASCII(RIGHT(m.group_account, 1))) AS base_var,
         CASE
           WHEN g.entity_code = 'SG01' AND m.group_account = '6100'
                AND EXTRACT(MONTH FROM g.period) BETWEEN 7 AND 9   THEN 0.25
           WHEN g.entity_code = 'UK01' AND m.group_account = '4100'
                AND EXTRACT(MONTH FROM g.period) BETWEEN 8 AND 10  THEN -0.18
           WHEN g.entity_code = 'NL01' AND m.group_account = '4000' THEN 0.02
           ELSE NULL
         END AS story_var
  FROM stg_gl_entry g
  JOIN map_account m
    ON m.entity_code = g.entity_code
   AND m.local_account = g.local_account
   AND m.valid_from <= g.period
  WHERE m.group_account IN ('4000','4100','5000','6000','6100')
  GROUP BY g.entity_code, g.period, m.group_account
) AS a0;

-- ---------------------------------------------------------------------
-- 2. Actual vs budget in EUR (both translated at the monthly average rate;
--    a real budget would normally use a fixed budget rate)
-- ---------------------------------------------------------------------
CREATE VIEW v_actual_vs_budget AS
WITH act AS (
  SELECT entity_code, period, group_account, -SUM(amount_eur) AS actual_eur
  FROM v_gl_eur
  WHERE statement = 'PL' AND group_account NOT IN ('REV-IC', 'COST-IC')
  GROUP BY entity_code, period, group_account
), bud AS (
  SELECT b.entity_code, b.period, b.group_account,
         -ROUND(SUM(b.amount_local * f.avg_rate), 2) AS budget_eur
  FROM budget_entry b
  JOIN dim_entity e ON e.entity_code = b.entity_code
  JOIN fx_rate f    ON f.currency = e.currency AND f.period = b.period
  WHERE b.version = 'Budget'
  GROUP BY b.entity_code, b.period, b.group_account
)
SELECT a.entity_code, a.period, a.group_account, ga.account_name,
       a.actual_eur, b.budget_eur,
       a.actual_eur - b.budget_eur AS variance_eur,
       ROUND(100.0 * (a.actual_eur - b.budget_eur) / NULLIF(ABS(b.budget_eur), 0), 1) AS variance_pct
FROM act a
JOIN bud b USING (entity_code, period, group_account)
JOIN dim_group_account ga ON ga.group_account = a.group_account;

-- ---------------------------------------------------------------------
-- 3. Close readiness: one row per integrity check, 0 issues = green
--    (these are the same five checks as in file 02)
-- ---------------------------------------------------------------------
CREATE VIEW v_check_summary AS
SELECT 1 AS check_no, 'All ledger accounts are mapped' AS check_name,
       (SELECT COUNT(*) FROM (
          SELECT g.entity_code, g.local_account
          FROM stg_gl_entry g
          LEFT JOIN map_account m
            ON m.entity_code = g.entity_code AND m.local_account = g.local_account
           AND m.valid_from <= g.period
          WHERE m.group_account IS NULL
          GROUP BY g.entity_code, g.local_account) x) AS issues
UNION ALL
SELECT 2, 'Trial balance nets to zero per entity and month',
       (SELECT COUNT(*) FROM (
          SELECT 1 FROM stg_gl_entry
          GROUP BY entity_code, period, currency
          HAVING ABS(SUM(amount_local)) > 0.01) x)
UNION ALL
SELECT 3, 'Each entity and month loaded exactly once',
       (SELECT COUNT(*) FROM (
          SELECT 1 FROM stg_gl_entry
          GROUP BY entity_code, period
          HAVING COUNT(DISTINCT load_id) > 1) x)
UNION ALL
SELECT 4, 'Intercompany balances agree between partners',
       (SELECT COUNT(*) FROM (
          WITH ic AS (
            SELECT period, entity_code, ic_partner, SUM(amount_eur) AS amt
            FROM v_gl_eur
            WHERE ic_partner IS NOT NULL AND group_account LIKE 'IC%'
            GROUP BY period, entity_code, ic_partner)
          SELECT 1 FROM ic a
          LEFT JOIN ic b ON b.period = a.period AND b.entity_code = a.ic_partner
                        AND b.ic_partner = a.entity_code
          WHERE ABS(a.amt + COALESCE(b.amt, 0)) > 1) x)
UNION ALL
SELECT 5, 'Every currency and month has an exchange rate',
       (SELECT COUNT(*) FROM (
          SELECT DISTINCT g.currency, g.period
          FROM stg_gl_entry g
          LEFT JOIN fx_rate f ON f.currency = g.currency AND f.period = g.period
          WHERE f.currency IS NULL) x);

-- Quick look
SELECT * FROM v_check_summary ORDER BY check_no;
