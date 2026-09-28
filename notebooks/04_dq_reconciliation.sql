-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 04 · Data quality report and reconciliation
-- MAGIC Proves nothing was lost or double-counted between layers:
-- MAGIC - **Row reconciliation:** bronze = silver + quarantine + removed duplicates
-- MAGIC - **Value reconciliation:** revenue in silver = fact = sum of monthly mart
-- MAGIC - **Referential integrity (R11):** every fact key exists in its dimension
-- MAGIC
-- MAGIC The last cell fails the run if any check fails, so a scheduled Job stops before bad numbers reach the dashboard.

-- COMMAND ----------

USE CATALOG workspace;
USE SCHEMA retail;

-- COMMAND ----------

-- MAGIC %md ## R11 · Orphan keys in fact_sales

-- COMMAND ----------

INSERT INTO dq_results
SELECT current_timestamp(), 'R11', failed, total, round(100.0 * failed / nullif(total, 0), 3)
FROM (
  SELECT
    count(*) AS total,
    count_if(d.date_key IS NULL OR c.customer_id IS NULL OR p.stock_code IS NULL) AS failed
  FROM fact_sales f
  LEFT JOIN dim_date d     ON d.date_key    = f.date_key
  LEFT JOIN dim_customer c ON c.customer_id = f.customer_id
  LEFT JOIN dim_product p  ON p.stock_code  = f.stock_code
);

-- COMMAND ----------

-- MAGIC %md ## Reconciliation checks

-- COMMAND ----------

CREATE TABLE IF NOT EXISTS recon_results (
  run_ts      TIMESTAMP,
  check_name  STRING,
  expected    DECIMAL(18, 2),
  actual      DECIMAL(18, 2),
  status      STRING
)
COMMENT 'Run-level reconciliation log between pipeline layers. status = PASS / FAIL.';

-- COMMAND ----------

CREATE OR REPLACE TEMP VIEW v_recon AS
WITH latest_r01 AS (
  SELECT failed_rows FROM dq_results WHERE rule_id = 'R01' ORDER BY run_ts DESC LIMIT 1
),
latest_r11 AS (
  SELECT failed_rows FROM dq_results WHERE rule_id = 'R11' ORDER BY run_ts DESC LIMIT 1
),
checks AS (
  SELECT
    'Rows: bronze = silver + quarantine + duplicates removed' AS check_name,
    (SELECT count(*) FROM bronze_transactions)                AS expected,
    (SELECT count(*) FROM silver_transactions)
      + (SELECT count(*) FROM silver_quarantine)
      + (SELECT failed_rows FROM latest_r01)                  AS actual
  UNION ALL
  SELECT 'Rows: fact_sales = silver_transactions',
    (SELECT count(*) FROM silver_transactions),
    (SELECT count(*) FROM fact_sales)
  UNION ALL
  SELECT 'Revenue: fact_sales = silver_transactions',
    (SELECT sum(line_amount) FROM silver_transactions),
    (SELECT sum(line_amount) FROM fact_sales)
  UNION ALL
  SELECT 'Revenue: mart_monthly_kpis = fact_sales (product lines)',
    (SELECT sum(f.line_amount) FROM fact_sales f JOIN dim_product p ON p.stock_code = f.stock_code WHERE NOT p.is_non_product),
    (SELECT sum(net_revenue) FROM mart_monthly_kpis)
  UNION ALL
  SELECT 'Referential integrity: orphan fact keys = 0',
    0,
    (SELECT failed_rows FROM latest_r11)
)
SELECT
  current_timestamp() AS run_ts,
  check_name,
  CAST(expected AS DECIMAL(18, 2)) AS expected,
  CAST(actual   AS DECIMAL(18, 2)) AS actual,
  CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS status
FROM checks;

-- COMMAND ----------

INSERT INTO recon_results SELECT * FROM v_recon;

SELECT check_name, expected, actual, status
FROM recon_results
WHERE run_ts = (SELECT max(run_ts) FROM recon_results);

-- COMMAND ----------

-- MAGIC %md ## Latest result for every DQ rule

-- COMMAND ----------

SELECT r.rule_id, r.rule_name, r.severity, r.action, d.failed_rows, d.checked_rows, d.failed_pct, d.run_ts
FROM (
  SELECT *, row_number() OVER (PARTITION BY rule_id ORDER BY run_ts DESC) AS rn FROM dq_results
) d
JOIN dq_rules r ON r.rule_id = d.rule_id
WHERE d.rn = 1
ORDER BY r.rule_id;

-- COMMAND ----------

-- Quarantine breakdown
SELECT dq_reject_rule, dq_reject_reason, count(*) AS rows, round(sum(quantity * unit_price), 2) AS value_gbp
FROM silver_quarantine
GROUP BY dq_reject_rule, dq_reject_reason
ORDER BY rows DESC;

-- COMMAND ----------

-- MAGIC %md ## Gate: stop the run if any check failed

-- COMMAND ----------

SELECT assert_true(count_if(status = 'FAIL') = 0, 'Reconciliation failed - see recon_results') AS gate
FROM recon_results
WHERE run_ts = (SELECT max(run_ts) FROM recon_results);
