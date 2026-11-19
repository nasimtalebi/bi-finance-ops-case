-- =====================================================================
-- Practice case: hypothetical group with 3 entities, 3 currencies, 12 months
-- ALL DATA IS INVENTED for practice. Nothing here is real company data.
--
-- How to run in pgAdmin:
--   1. Right-click Databases > Create > Database, name it: bi_practice
--   2. Right-click bi_practice > Query Tool, paste this whole file, press F5
--   3. Safe to re-run: it drops and recreates everything.
--
-- Sign convention: debit = positive, credit = negative (so income is negative).
-- Amounts in stg_gl_entry are MONTHLY MOVEMENTS in local currency.
-- =====================================================================

DROP TABLE IF EXISTS stg_gl_entry, stg_kpi_value, map_account, fx_rate,
                     dim_entity, dim_group_account, demo_local_accounts CASCADE;

-- ---------------------------------------------------------------------
-- 1. Reference tables
-- ---------------------------------------------------------------------
CREATE TABLE dim_entity (
  entity_code   VARCHAR(10) PRIMARY KEY,
  entity_name   VARCHAR(60) NOT NULL,
  region        VARCHAR(20) NOT NULL,
  currency      CHAR(3)     NOT NULL,
  ownership_pct NUMERIC(5,2) NOT NULL DEFAULT 100
);
INSERT INTO dim_entity VALUES
  ('NL01', 'Demo Netherlands BV', 'Europe', 'EUR', 100),
  ('UK01', 'Demo UK Ltd',         'Europe', 'GBP', 100),
  ('SG01', 'Demo Singapore Pte',  'APAC',   'SGD', 100);

CREATE TABLE dim_group_account (
  group_account VARCHAR(20) PRIMARY KEY,
  account_name  VARCHAR(60) NOT NULL,
  statement     VARCHAR(2)  NOT NULL CHECK (statement IN ('PL','BS'))
);
INSERT INTO dim_group_account VALUES
  ('1000',    'Cash',                          'BS'),
  ('IC-REC',  'Intercompany receivable',       'BS'),
  ('IC-PAY',  'Intercompany payable',          'BS'),
  ('4000',    'Subscription revenue',          'PL'),
  ('4100',    'Services revenue',              'PL'),
  ('REV-IC',  'Intercompany revenue',          'PL'),
  ('5000',    'Cost of revenue',               'PL'),
  ('6000',    'Personnel cost',                'PL'),
  ('6100',    'Other operating cost',          'PL'),
  ('COST-IC', 'Intercompany cost',             'PL');

-- Each entity has its own local chart of accounts (this is why mapping matters)
CREATE TABLE demo_local_accounts (
  entity_code   VARCHAR(10) NOT NULL,
  acct_key      VARCHAR(10) NOT NULL,
  local_account VARCHAR(20) NOT NULL,
  group_account VARCHAR(20) NOT NULL,
  PRIMARY KEY (entity_code, acct_key)
);
INSERT INTO demo_local_accounts VALUES
  ('NL01','cash','100100','1000'),   ('NL01','ic_rec','110500','IC-REC'),
  ('NL01','ic_pay','210500','IC-PAY'),('NL01','sub','800100','4000'),
  ('NL01','svc','800200','4100'),    ('NL01','ic_rev','809000','REV-IC'),
  ('NL01','cor','700100','5000'),    ('NL01','pers','710100','6000'),
  ('NL01','opex','720100','6100'),   ('NL01','ic_cost','729000','COST-IC'),

  ('UK01','cash','1200','1000'),     ('UK01','ic_rec','1550','IC-REC'),
  ('UK01','ic_pay','2550','IC-PAY'), ('UK01','sub','4001','4000'),
  ('UK01','svc','4002','4100'),      ('UK01','ic_rev','4900','REV-IC'),
  ('UK01','cor','5001','5000'),      ('UK01','pers','6001','6000'),
  ('UK01','opex','6101','6100'),     ('UK01','ic_cost','6900','COST-IC'),

  ('SG01','cash','SG1000','1000'),   ('SG01','ic_rec','SG1500','IC-REC'),
  ('SG01','ic_pay','SG2500','IC-PAY'),('SG01','sub','SG4000','4000'),
  ('SG01','svc','SG4100','4100'),    ('SG01','ic_rev','SG4900','REV-IC'),
  ('SG01','cor','SG5000','5000'),    ('SG01','pers','SG6000','6000'),
  ('SG01','opex','SG6100','6100'),   ('SG01','ic_cost','SG6900','COST-IC');

CREATE TABLE map_account (
  entity_code   VARCHAR(10) NOT NULL,
  local_account VARCHAR(20) NOT NULL,
  group_account VARCHAR(20) NOT NULL,
  valid_from    DATE        NOT NULL,
  PRIMARY KEY (entity_code, local_account, valid_from)
);
INSERT INTO map_account
SELECT entity_code, local_account, group_account, DATE '2025-01-01'
FROM demo_local_accounts;

-- ---------------------------------------------------------------------
-- 2. Exchange rates: EUR per 1 unit of currency, monthly average + closing
-- ---------------------------------------------------------------------
CREATE TABLE fx_rate (
  currency     CHAR(3)       NOT NULL,
  period       DATE          NOT NULL,
  avg_rate     DECIMAL(18,8) NOT NULL,
  closing_rate DECIMAL(18,8) NOT NULL,
  PRIMARY KEY (currency, period)
);
INSERT INTO fx_rate
SELECT c.currency,
       (DATE '2025-01-01' + make_interval(months => i))::date,
       CASE WHEN c.currency = 'EUR' THEN 1
            ELSE ROUND((c.base + 0.010 * SIN(i + 1))::numeric, 6) END,
       CASE WHEN c.currency = 'EUR' THEN 1
            ELSE ROUND((c.base + 0.012 * SIN(i + 2))::numeric, 6) END
FROM (VALUES ('EUR', 1.00), ('GBP', 1.15), ('SGD', 0.69)) AS c(currency, base)
CROSS JOIN generate_series(0, 11) AS i;

-- ---------------------------------------------------------------------
-- 3. General ledger staging data
-- ---------------------------------------------------------------------
CREATE TABLE stg_gl_entry (
  source_system VARCHAR(20)   NOT NULL,
  entity_code   VARCHAR(10)   NOT NULL,
  period        DATE          NOT NULL,   -- first day of the month
  local_account VARCHAR(20)   NOT NULL,
  cost_centre   VARCHAR(20),
  ic_partner    VARCHAR(10),
  currency      CHAR(3)       NOT NULL,
  amount_local  DECIMAL(18,2) NOT NULL,
  load_id       INT           NOT NULL
);

CREATE TEMP TABLE tmp_base AS
SELECT p.entity_code, p.currency, p.src, p.seed, p.fte_cost, i,
       (DATE '2025-01-01' + make_interval(months => i))::date AS period,
       ROUND((p.sub_base  * (1 + 0.015 * i))::numeric, 2)                  AS sub_amt,
       ROUND((p.svc_base  * (1 + 0.25  * SIN(i * 1.1 + p.seed)))::numeric, 2) AS svc_amt,
       ROUND((p.pers_base * (1 + 0.004 * i))::numeric, 2)                  AS pers_amt,
       ROUND((p.opex_base * (1 + 0.10  * SIN(i + p.seed)))::numeric, 2)    AS opex_amt
FROM (VALUES
  ('NL01','EUR','LEDGER_A',1, 400000, 70000, 210000, 70000, 7000),
  ('UK01','GBP','LEDGER_B',2, 220000, 50000, 120000, 40000, 5500),
  ('SG01','SGD','LEDGER_B',3, 300000, 50000, 150000, 50000, 6500)
) AS p(entity_code, currency, src, seed, sub_base, svc_base, pers_base, opex_base, fte_cost)
CROSS JOIN generate_series(0, 11) AS i;

-- 3a. Operating lines: revenue (credit), cost of revenue, personnel, other opex (debit)
INSERT INTO stg_gl_entry
SELECT b.src, b.entity_code, b.period, a.local_account, l.cost_centre,
       NULL, b.currency, l.amount, 1
FROM tmp_base b
CROSS JOIN LATERAL (VALUES
  ('sub',  NULL::varchar, -b.sub_amt),
  ('svc',  NULL::varchar, -b.svc_amt),
  ('cor',  'SUPPORT',     ROUND(0.22 * (b.sub_amt + b.svc_amt), 2)),
  ('pers', 'ENG',         b.pers_amt),
  ('opex', 'G&A',         b.opex_amt)
) AS l(acct_key, cost_centre, amount)
JOIN demo_local_accounts a
  ON a.entity_code = b.entity_code AND a.acct_key = l.acct_key;

-- 3b. Intercompany: NL01 charges UK01 and SG01 a management fee of EUR 10,000 a month
INSERT INTO stg_gl_entry
SELECT 'LEDGER_A', 'NL01', b.period, a.local_account, NULL, c.partner, 'EUR', l.amt, 1
FROM tmp_base b
CROSS JOIN (VALUES ('UK01'), ('SG01')) AS c(partner)
CROSS JOIN LATERAL (VALUES ('ic_rec', 10000.00), ('ic_rev', -10000.00)) AS l(acct_key, amt)
JOIN demo_local_accounts a ON a.entity_code = 'NL01' AND a.acct_key = l.acct_key
WHERE b.entity_code = 'NL01';

-- The partners book the same fee in local currency (so it matches at the closing rate)
INSERT INTO stg_gl_entry
SELECT 'LEDGER_B', b.entity_code, b.period, a.local_account, NULL, 'NL01', b.currency,
       l.sign * ROUND(10000 / f.closing_rate, 2), 1
FROM tmp_base b
JOIN fx_rate f ON f.currency = b.currency AND f.period = b.period
CROSS JOIN LATERAL (VALUES ('ic_pay', -1), ('ic_cost', 1)) AS l(acct_key, sign)
JOIN demo_local_accounts a ON a.entity_code = b.entity_code AND a.acct_key = l.acct_key
WHERE b.entity_code IN ('UK01', 'SG01');

-- 3c. Cash is the balancing line, so every entity/month nets to zero
INSERT INTO stg_gl_entry
SELECT MIN(g.source_system), g.entity_code, g.period, a.local_account, NULL, NULL,
       MIN(g.currency), -SUM(g.amount_local), 1
FROM stg_gl_entry g
JOIN demo_local_accounts a ON a.entity_code = g.entity_code AND a.acct_key = 'cash'
GROUP BY g.entity_code, g.period, a.local_account;

-- ---------------------------------------------------------------------
-- 4. Operational KPIs (in local currency where money is involved)
--    ARR is tied to the ledger: 12 x monthly subscription revenue
-- ---------------------------------------------------------------------
CREATE TABLE stg_kpi_value (
  kpi_code    VARCHAR(30)   NOT NULL,
  entity_code VARCHAR(10)   NOT NULL,
  period      DATE          NOT NULL,
  segment     VARCHAR(30),
  value       DECIMAL(18,4) NOT NULL,
  load_id     INT           NOT NULL
);

INSERT INTO stg_kpi_value
SELECT l.kpi_code, d.entity_code, d.period, l.segment, l.val, 1
FROM (
  SELECT b.*,
         ROUND(b.pers_amt / b.fte_cost, 1) AS headcount,
         ROUND(b.sub_amt / 4000.0)         AS customers
  FROM tmp_base b
) d
CROSS JOIN LATERAL (VALUES
  ('ARR',              'Oil & Gas', ROUND(d.sub_amt * 12 * 0.5, 2)),
  ('ARR',              'Chemicals', ROUND(d.sub_amt * 12 * 0.3, 2)),
  ('ARR',              'Energy',    ROUND(d.sub_amt * 12 * 0.2, 2)),
  ('HEADCOUNT_FTE',    'ALL',       d.headcount),
  ('ACTIVE_CUSTOMERS', 'ALL',       d.customers),
  ('SUPPORT_TICKETS',  'ALL',       ROUND((d.customers * (1.8 + 0.3 * SIN(d.i + d.seed)))::numeric)),
  ('BILLABLE_HOURS',   'ALL',       ROUND(d.svc_amt / 140.0)),
  ('AVAILABLE_HOURS',  'ALL',       ROUND(d.headcount * 0.17 * 140))
) AS l(kpi_code, segment, val);

-- ---------------------------------------------------------------------
-- 5. Views: ledger translated to EUR, and the consolidated P&L
--    P&L lines use the average rate, balance sheet lines the closing rate.
--    NOTE: an unmapped account silently disappears here (inner join).
--    That is exactly why check 1 exists.
-- ---------------------------------------------------------------------
CREATE VIEW v_gl_eur AS
SELECT g.entity_code, g.period, m.group_account, ga.statement,
       g.cost_centre, g.ic_partner, g.currency, g.amount_local,
       ROUND(g.amount_local *
             CASE ga.statement WHEN 'PL' THEN f.avg_rate ELSE f.closing_rate END, 2) AS amount_eur
FROM stg_gl_entry g
JOIN map_account m
  ON m.entity_code = g.entity_code
 AND m.local_account = g.local_account
 AND m.valid_from <= g.period
JOIN dim_group_account ga ON ga.group_account = m.group_account
JOIN fx_rate f ON f.currency = g.currency AND f.period = g.period;

-- Consolidated P&L in EUR; intercompany revenue and cost are eliminated (left out).
-- Revenue is shown positive, costs negative.
CREATE VIEW v_pl_group AS
SELECT v.period, v.group_account, ga.account_name,
       -SUM(v.amount_eur) AS amount_eur
FROM v_gl_eur v
JOIN dim_group_account ga ON ga.group_account = v.group_account
WHERE v.statement = 'PL'
  AND v.group_account NOT IN ('REV-IC', 'COST-IC')
GROUP BY v.period, v.group_account, ga.account_name;

-- ---------------------------------------------------------------------
-- 6. Quick look: row counts
-- ---------------------------------------------------------------------
SELECT 'stg_gl_entry' AS tbl, COUNT(*) AS rows FROM stg_gl_entry
UNION ALL SELECT 'stg_kpi_value', COUNT(*) FROM stg_kpi_value
UNION ALL SELECT 'fx_rate',       COUNT(*) FROM fx_rate
UNION ALL SELECT 'map_account',   COUNT(*) FROM map_account;
