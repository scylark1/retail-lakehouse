-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 02 · Silver — typing, de-duplication, data quality
-- MAGIC 1. Cast bronze strings to proper types and classify each invoice (sale / cancellation / adjustment).
-- MAGIC 2. Remove exact duplicate lines (the two source extracts overlap in December 2010).
-- MAGIC 3. Apply blocking DQ rules → failing rows go to `silver_quarantine` with a reason code; clean rows go to `silver_transactions`.
-- MAGIC 4. Log one row per rule per run into `dq_results`.
-- MAGIC
-- MAGIC Rule catalogue lives in `dq_rules` (see also `docs/data_dictionary.md`).

-- COMMAND ----------

USE CATALOG workspace;
USE SCHEMA retail;

-- COMMAND ----------

-- MAGIC %md ## DQ rule catalogue

-- COMMAND ----------

CREATE OR REPLACE TABLE dq_rules AS
SELECT * FROM VALUES
  ('R01', 'Exact duplicate line',                 'silver', 'warning', 'removed',     'Same invoice, stock code, description, quantity, price, timestamp, customer and country appear more than once'),
  ('R02', 'Missing customer ID',                  'silver', 'warning', 'flagged',     'Line has no customer_id; kept for revenue, mapped to GUEST, excluded from customer metrics'),
  ('R03', 'Cancellation line',                    'silver', 'info',    'flagged',     'Invoice starts with C; kept and netted against sales'),
  ('R04', 'Invalid quantity',                     'silver', 'error',   'quarantined', 'Quantity missing or zero, negative on a sale line, or positive on a cancellation line'),
  ('R05', 'Invalid price',                        'silver', 'error',   'quarantined', 'Price missing or negative, or zero on a sale line'),
  ('R06', 'Non-product stock code',               'silver', 'info',    'flagged',     'Postage, fees, manual entries, gift vouchers etc.; excluded from product metrics'),
  ('R07', 'Invalid or out-of-range timestamp',    'silver', 'error',   'quarantined', 'Timestamp cannot be parsed or falls outside 2009-12-01 to 2011-12-31'),
  ('R08', 'Stock code with several descriptions', 'silver', 'warning', 'resolved',    'Most frequent description is used in dim_product'),
  ('R09', 'Invoice linked to several customers',  'silver', 'error',   'monitored',   'Expected 0; one invoice should belong to one customer'),
  ('R10', 'Accounting adjustment',                'silver', 'info',    'quarantined', 'Invoice starts with A (bad-debt adjustment); not a sales transaction'),
  ('R11', 'Orphan key in fact table',             'gold',   'error',   'monitored',   'fact_sales key has no matching dimension row; expected 0')
AS t(rule_id, rule_name, layer, severity, action, rule_description);

COMMENT ON TABLE dq_rules IS 'Data quality rule catalogue: one row per rule, with severity and the action taken on failing rows.';

-- COMMAND ----------

CREATE TABLE IF NOT EXISTS dq_results (
  run_ts        TIMESTAMP COMMENT 'When the pipeline run logged this result',
  rule_id       STRING    COMMENT 'FK to dq_rules.rule_id',
  failed_rows   BIGINT    COMMENT 'Rows (or keys) failing the rule in this run',
  checked_rows  BIGINT    COMMENT 'Rows (or keys) the rule was evaluated on',
  failed_pct    DOUBLE    COMMENT 'failed_rows / checked_rows * 100'
)
COMMENT 'Run-level data quality log, appended on every pipeline run.';

-- COMMAND ----------

-- MAGIC %md ## Step 1 · Type and classify

-- COMMAND ----------

CREATE OR REPLACE TEMP VIEW v_typed AS
SELECT
  trim(invoice)                                              AS invoice,
  CASE
    WHEN upper(trim(invoice)) LIKE 'C%' THEN 'cancellation'
    WHEN upper(trim(invoice)) LIKE 'A%' THEN 'adjustment'
    ELSE 'sale'
  END                                                        AS invoice_type,
  upper(trim(stock_code))                                    AS stock_code,
  nullif(trim(description), '')                              AS description,
  try_cast(quantity AS INT)                                  AS quantity,
  try_cast(price AS DECIMAL(12, 3))                          AS unit_price,
  try_to_timestamp(invoice_date, 'yyyy-MM-dd HH:mm:ss')      AS invoice_ts,
  nullif(trim(customer_id), '')                              AS customer_id,
  trim(country)                                              AS country,
  source_file
FROM bronze_transactions;

-- COMMAND ----------

-- MAGIC %md ## Step 2 · Remove exact duplicates (R01)

-- COMMAND ----------

CREATE OR REPLACE TEMP VIEW v_dedup AS
SELECT * EXCEPT (rn)
FROM (
  SELECT
    *,
    row_number() OVER (
      PARTITION BY invoice, stock_code, description, quantity, unit_price, invoice_ts, customer_id, country
      ORDER BY source_file
    ) AS rn
  FROM v_typed
)
WHERE rn = 1;

-- COMMAND ----------

-- MAGIC %md ## Step 3 · Blocking rules → silver / quarantine

-- COMMAND ----------

CREATE OR REPLACE TEMP VIEW v_checked AS
SELECT
  *,
  CASE
    WHEN invoice_type = 'adjustment'                                     THEN 'R10'
    WHEN invoice_ts IS NULL
      OR invoice_ts <  TIMESTAMP'2009-12-01 00:00:00'
      OR invoice_ts >= TIMESTAMP'2012-01-01 00:00:00'                    THEN 'R07'
    WHEN quantity IS NULL OR quantity = 0
      OR (invoice_type = 'sale'         AND quantity < 0)
      OR (invoice_type = 'cancellation' AND quantity > 0)                THEN 'R04'
    WHEN unit_price IS NULL OR unit_price < 0
      OR (invoice_type = 'sale' AND unit_price = 0)                      THEN 'R05'
  END AS dq_reject_rule
FROM v_dedup;

-- COMMAND ----------

CREATE OR REPLACE TABLE silver_quarantine AS
SELECT
  c.*,
  r.rule_name AS dq_reject_reason,
  current_timestamp() AS quarantined_at
FROM v_checked c
JOIN dq_rules r ON r.rule_id = c.dq_reject_rule
WHERE c.dq_reject_rule IS NOT NULL;

COMMENT ON TABLE silver_quarantine IS 'Rows rejected by blocking DQ rules, with the rule that rejected them. Reviewed, never silently dropped.';

-- COMMAND ----------

CREATE OR REPLACE TABLE silver_transactions AS
SELECT
  invoice,
  invoice_type,
  stock_code,
  description,
  quantity,
  unit_price,
  CAST(quantity * unit_price AS DECIMAL(14, 2))               AS line_amount,
  invoice_ts,
  to_date(invoice_ts)                                         AS invoice_date,
  customer_id,
  customer_id IS NULL                                         AS is_guest,
  country,
  NOT (stock_code RLIKE '^[0-9]{5}[A-Z]{0,2}$')               AS is_non_product,
  source_file
FROM v_checked
WHERE dq_reject_rule IS NULL;

COMMENT ON TABLE silver_transactions IS
  'Cleaned, typed, de-duplicated invoice lines (sales and cancellations). Grain: one invoice line.';
ALTER TABLE silver_transactions SET TAGS ('layer' = 'silver');

-- COMMAND ----------

-- Enforce the rules at table level so bad rows can never be written here later
ALTER TABLE silver_transactions DROP CONSTRAINT IF EXISTS chk_quantity_nonzero;
ALTER TABLE silver_transactions ADD  CONSTRAINT chk_quantity_nonzero CHECK (quantity <> 0);
ALTER TABLE silver_transactions DROP CONSTRAINT IF EXISTS chk_price_nonnegative;
ALTER TABLE silver_transactions ADD  CONSTRAINT chk_price_nonnegative CHECK (unit_price >= 0);
ALTER TABLE silver_transactions DROP CONSTRAINT IF EXISTS chk_invoice_type;
ALTER TABLE silver_transactions ADD  CONSTRAINT chk_invoice_type CHECK (invoice_type IN ('sale', 'cancellation'));

-- COMMAND ----------

-- MAGIC %md ## Step 4 · Log DQ results for this run

-- COMMAND ----------

CREATE OR REPLACE TEMP VIEW v_dq_counts AS
          SELECT 'R01' AS rule_id, (SELECT count(*) FROM v_typed) - (SELECT count(*) FROM v_dedup) AS failed_rows, (SELECT count(*) FROM v_typed) AS checked_rows
UNION ALL SELECT 'R02', count_if(is_guest),                    count(*) FROM silver_transactions
UNION ALL SELECT 'R03', count_if(invoice_type = 'cancellation'), count(*) FROM silver_transactions
UNION ALL SELECT 'R04', count_if(dq_reject_rule = 'R04'),      count(*) FROM v_checked
UNION ALL SELECT 'R05', count_if(dq_reject_rule = 'R05'),      count(*) FROM v_checked
UNION ALL SELECT 'R06', count_if(is_non_product),              count(*) FROM silver_transactions
UNION ALL SELECT 'R07', count_if(dq_reject_rule = 'R07'),      count(*) FROM v_checked
UNION ALL SELECT 'R08', count_if(n_desc > 1),                  count(*)
          FROM (SELECT stock_code, count(DISTINCT description) AS n_desc FROM silver_transactions GROUP BY stock_code)
UNION ALL SELECT 'R09', count_if(n_cust > 1),                  count(*)
          FROM (SELECT invoice, count(DISTINCT customer_id) AS n_cust FROM silver_transactions GROUP BY invoice)
UNION ALL SELECT 'R10', count_if(dq_reject_rule = 'R10'),      count(*) FROM v_checked;

-- COMMAND ----------

INSERT INTO dq_results
SELECT
  current_timestamp(),
  rule_id,
  failed_rows,
  checked_rows,
  round(100.0 * failed_rows / nullif(checked_rows, 0), 3)
FROM v_dq_counts;

-- COMMAND ----------

-- This run's results
SELECT r.rule_id, r.rule_name, r.severity, r.action, d.failed_rows, d.checked_rows, d.failed_pct
FROM dq_results d
JOIN dq_rules r ON r.rule_id = d.rule_id
WHERE d.run_ts = (SELECT max(run_ts) FROM dq_results)
ORDER BY r.rule_id;
