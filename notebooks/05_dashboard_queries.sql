-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 05 · Dashboard datasets
-- MAGIC Paste each query below as a **dataset** in a Databricks AI/BI Dashboard (New → Dashboard → Data tab).
-- MAGIC Suggested visual for each is in the comment above it. Page 1 = business KPIs, page 2 = data health.

-- COMMAND ----------

USE CATALOG workspace;
USE SCHEMA retail;

-- COMMAND ----------

-- [KPI tiles] Latest full month vs same month last year
WITH m AS (SELECT * FROM mart_monthly_kpis WHERE NOT is_partial_month),
cur AS (SELECT * FROM m ORDER BY month DESC LIMIT 1)
SELECT
  cur.month,
  cur.net_revenue,
  cur.orders,
  cur.avg_order_value,
  cur.active_customers,
  round(100.0 * (cur.net_revenue / ly.net_revenue - 1), 1) AS net_revenue_yoy_pct
FROM cur
LEFT JOIN m ly ON ly.month = add_months(cur.month, -12);

-- COMMAND ----------

-- [Line chart] Monthly net revenue and orders
SELECT month, net_revenue, gross_revenue, cancelled_revenue, orders, is_partial_month
FROM mart_monthly_kpis
ORDER BY month;

-- COMMAND ----------

-- [Bar chart] New vs returning active customers per month
SELECT month, new_customers, active_customers - new_customers AS returning_customers
FROM mart_monthly_kpis
ORDER BY month;

-- COMMAND ----------

-- [Heatmap / pivot] Cohort retention, first 12 months
SELECT cohort_month, months_since_first, retention_pct
FROM mart_cohort_retention
WHERE months_since_first BETWEEN 0 AND 12
ORDER BY cohort_month, months_since_first;

-- COMMAND ----------

-- [Bar chart] RFM segments: customers and revenue share
SELECT
  segment,
  count(*)                                                AS customers,
  round(sum(monetary), 0)                                 AS revenue,
  round(100.0 * sum(monetary) / sum(sum(monetary)) OVER (), 1) AS revenue_share_pct
FROM mart_customer_rfm
GROUP BY segment
ORDER BY revenue DESC;

-- COMMAND ----------

-- [Table] Top 20 products by net revenue, last 12 months, with cancellation rate
SELECT
  stock_code,
  description,
  sum(units_sold)                                                        AS units_sold,
  round(sum(net_revenue), 0)                                             AS net_revenue,
  round(100.0 * sum(units_cancelled) / nullif(sum(units_sold), 0), 1)    AS cancel_rate_pct
FROM mart_product_monthly
WHERE month >= add_months((SELECT max(month) FROM mart_product_monthly), -12)
GROUP BY stock_code, description
ORDER BY net_revenue DESC
LIMIT 20;

-- COMMAND ----------

-- [Bar chart] Net revenue by country (top 10, excl. UK shown separately)
SELECT
  f.country,
  round(sum(f.line_amount), 0) AS net_revenue,
  count(DISTINCT CASE WHEN f.invoice_type = 'sale' THEN f.invoice END) AS orders
FROM fact_sales f
JOIN dim_product p ON p.stock_code = f.stock_code
WHERE NOT p.is_non_product
GROUP BY f.country
ORDER BY net_revenue DESC
LIMIT 11;

-- COMMAND ----------

-- [Data health page · table] Latest DQ result per rule
SELECT r.rule_id, r.rule_name, r.severity, r.action, d.failed_rows, d.failed_pct
FROM (SELECT *, row_number() OVER (PARTITION BY rule_id ORDER BY run_ts DESC) AS rn FROM dq_results) d
JOIN dq_rules r ON r.rule_id = d.rule_id
WHERE d.rn = 1
ORDER BY r.rule_id;

-- COMMAND ----------

-- [Data health page · counter tiles] Latest reconciliation status
SELECT check_name, status
FROM recon_results
WHERE run_ts = (SELECT max(run_ts) FROM recon_results);
