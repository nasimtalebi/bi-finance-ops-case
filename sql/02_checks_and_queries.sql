-- =====================================================================
-- Run these one at a time (select the query, press F5 in pgAdmin).
-- On the clean data, every CHECK should return ZERO rows.
-- =====================================================================

-- CHECK 1. Unmapped local accounts
SELECT g.entity_code, g.local_account, SUM(g.amount_local) AS amount_local
FROM stg_gl_entry g
LEFT JOIN map_account m
  ON m.entity_code = g.entity_code
 AND m.local_account = g.local_account
 AND m.valid_from <= g.period
WHERE m.group_account IS NULL
GROUP BY g.entity_code, g.local_account;

-- CHECK 2. Trial balance must net to zero per entity, period and currency
SELECT entity_code, period, currency, SUM(amount_local) AS imbalance
FROM stg_gl_entry
GROUP BY entity_code, period, currency
HAVING ABS(SUM(amount_local)) > 0.01;

-- CHECK 3. Entity and period loaded more than once
SELECT entity_code, period, COUNT(DISTINCT load_id) AS loads
FROM stg_gl_entry
GROUP BY entity_code, period
HAVING COUNT(DISTINCT load_id) > 1;

-- CHECK 4. Intercompany differences (balance sheet IC accounts only)
WITH ic AS (
  SELECT period, entity_code, ic_partner, SUM(amount_eur) AS amt
  FROM v_gl_eur
  WHERE ic_partner IS NOT NULL AND group_account LIKE 'IC%'
  GROUP BY period, entity_code, ic_partner
)
SELECT a.period, a.entity_code, a.ic_partner,
       a.amt + COALESCE(b.amt, 0) AS difference
FROM ic a
LEFT JOIN ic b
  ON b.period = a.period
 AND b.entity_code = a.ic_partner
 AND b.ic_partner = a.entity_code
WHERE ABS(a.amt + COALESCE(b.amt, 0)) > 1;

-- CHECK 5. Every currency used has a rate for every month used
SELECT DISTINCT g.currency, g.period
FROM stg_gl_entry g
LEFT JOIN fx_rate f ON f.currency = g.currency AND f.period = g.period
WHERE f.currency IS NULL;

-- =====================================================================
-- REPORTS
-- =====================================================================

-- Consolidated P&L by month (EUR). Revenue positive, costs negative.
SELECT period,
       SUM(amount_eur) FILTER (WHERE group_account IN ('4000','4100'))        AS revenue,
       SUM(amount_eur) FILTER (WHERE group_account = '5000')                  AS cost_of_revenue,
       SUM(amount_eur) FILTER (WHERE group_account IN ('4000','4100','5000')) AS gross_profit,
       SUM(amount_eur) FILTER (WHERE group_account IN ('6000','6100'))        AS opex,
       SUM(amount_eur)                                                        AS operating_result
FROM v_pl_group
GROUP BY period
ORDER BY period;

-- Gross margin % by month
SELECT period,
       ROUND(100.0 * SUM(amount_eur) FILTER (WHERE group_account IN ('4000','4100','5000'))
                   / SUM(amount_eur) FILTER (WHERE group_account IN ('4000','4100')), 1) AS gross_margin_pct
FROM v_pl_group
GROUP BY period
ORDER BY period;

-- Services utilisation % by entity (operational KPI linked to services revenue)
SELECT b.entity_code, b.period,
       ROUND(100.0 * b.value / a.value, 1) AS utilisation_pct
FROM stg_kpi_value b
JOIN stg_kpi_value a
  ON a.entity_code = b.entity_code AND a.period = b.period AND a.kpi_code = 'AVAILABLE_HOURS'
WHERE b.kpi_code = 'BILLABLE_HOURS'
ORDER BY b.entity_code, b.period;

-- Does ARR tie to the ledger? (ARR / 12 should equal subscription revenue, local currency)
SELECT k.entity_code, k.period,
       SUM(k.value) / 12 AS arr_divided_by_12,
       -MAX(g.amount_local) AS ledger_subscription_revenue
FROM stg_kpi_value k
JOIN stg_gl_entry g
  ON g.entity_code = k.entity_code AND g.period = k.period
JOIN map_account m
  ON m.entity_code = g.entity_code AND m.local_account = g.local_account
WHERE k.kpi_code = 'ARR' AND m.group_account = '4000'
GROUP BY k.entity_code, k.period
ORDER BY k.entity_code, k.period;
