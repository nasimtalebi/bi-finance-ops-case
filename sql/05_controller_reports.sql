-- =====================================================================
-- Queries for the meeting. Run them one at a time (select, then F5).
-- Reporting month in the story: October 2025. YTD = January to October 2025.
-- Amounts in EUR. Variance: positive = favourable, negative = unfavourable.
-- =====================================================================

-- ---------------------------------------------------------------------
-- GROUP CONTROLLER: "Can I trust the consolidated numbers?"
-- ---------------------------------------------------------------------

-- G1. Close readiness: all five checks green?
SELECT check_no, check_name, issues,
       CASE WHEN issues = 0 THEN 'OK' ELSE 'STOP' END AS status
FROM v_check_summary
ORDER BY check_no;

-- G2. Consolidated P&L, October 2025 and year to date (EUR)
SELECT account_name,
       SUM(amount_eur) FILTER (WHERE period = '2025-10-01')                          AS oct_2025,
       SUM(amount_eur) FILTER (WHERE period BETWEEN '2025-01-01' AND '2025-10-01')   AS ytd_2025
FROM v_pl_group
GROUP BY group_account, account_name
ORDER BY group_account;

-- G3. Contribution by entity, October 2025 (EUR): which entity drives the result?
SELECT entity_code,
       SUM(actual_eur) FILTER (WHERE group_account IN ('4000','4100')) AS revenue,
       SUM(actual_eur)                                                  AS operating_result
FROM v_actual_vs_budget
WHERE period = '2025-10-01'
GROUP BY entity_code
ORDER BY entity_code;

-- G4. Intercompany positions by partner (balance sheet, EUR): should net to zero
SELECT period, entity_code, ic_partner, SUM(amount_eur) AS balance_eur
FROM v_gl_eur
WHERE ic_partner IS NOT NULL AND group_account LIKE 'IC%' AND period = '2025-10-01'
GROUP BY period, entity_code, ic_partner
ORDER BY entity_code, ic_partner;

-- ---------------------------------------------------------------------
-- BUSINESS CONTROLLER: "Where and why are we off plan?"
-- ---------------------------------------------------------------------

-- B1. Group actual vs budget, October 2025 and year to date (EUR)
SELECT account_name,
       SUM(actual_eur)   FILTER (WHERE period = '2025-10-01') AS oct_actual,
       SUM(budget_eur)   FILTER (WHERE period = '2025-10-01') AS oct_budget,
       SUM(variance_eur) FILTER (WHERE period = '2025-10-01') AS oct_variance,
       SUM(actual_eur)   AS ytd_actual,
       SUM(budget_eur)   AS ytd_budget,
       SUM(variance_eur) AS ytd_variance
FROM v_actual_vs_budget
WHERE period BETWEEN '2025-01-01' AND '2025-10-01'
GROUP BY group_account, account_name
ORDER BY group_account;

-- B2. Biggest variances year to date, by entity and account (EUR)
SELECT entity_code, account_name,
       SUM(actual_eur) AS ytd_actual, SUM(budget_eur) AS ytd_budget,
       SUM(variance_eur) AS ytd_variance,
       ROUND(100.0 * SUM(variance_eur) / NULLIF(ABS(SUM(budget_eur)), 0), 1) AS variance_pct
FROM v_actual_vs_budget
WHERE period BETWEEN '2025-01-01' AND '2025-10-01'
GROUP BY entity_code, group_account, account_name
ORDER BY ABS(SUM(variance_eur)) DESC
LIMIT 5;

-- B3. Story 1: Singapore other operating cost by month
SELECT period, actual_eur, budget_eur, variance_eur, variance_pct
FROM v_actual_vs_budget
WHERE entity_code = 'SG01' AND group_account = '6100'
ORDER BY period;

-- B4. Story 2: UK services revenue vs budget, with billable hours and utilisation
SELECT v.period, v.actual_eur, v.budget_eur, v.variance_pct,
       bh.value AS billable_hours,
       ROUND(100.0 * bh.value / ah.value, 1) AS utilisation_pct
FROM v_actual_vs_budget v
JOIN stg_kpi_value bh ON bh.entity_code = v.entity_code AND bh.period = v.period
                     AND bh.kpi_code = 'BILLABLE_HOURS'
JOIN stg_kpi_value ah ON ah.entity_code = v.entity_code AND ah.period = v.period
                     AND ah.kpi_code = 'AVAILABLE_HOURS'
WHERE v.entity_code = 'UK01' AND v.group_account = '4100'
ORDER BY v.period;

-- B5. Operating result vs budget by entity, year to date (EUR)
SELECT entity_code,
       SUM(actual_eur) AS ytd_actual, SUM(budget_eur) AS ytd_budget,
       SUM(variance_eur) AS ytd_variance
FROM v_actual_vs_budget
WHERE period BETWEEN '2025-01-01' AND '2025-10-01'
GROUP BY entity_code
ORDER BY entity_code;
