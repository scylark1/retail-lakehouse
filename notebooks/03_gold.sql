-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 03 · Gold — star schema and KPI marts
-- MAGIC **Star schema** (grain of `fact_sales` = one invoice line):
-- MAGIC
-- MAGIC ```
-- MAGIC              dim_date
-- MAGIC                 │
-- MAGIC  dim_customer ─ fact_sales ─ dim_product
-- MAGIC ```
-- MAGIC **Marts** built on top: `mart_monthly_kpis`, `mart_customer_rfm`, `mart_cohort_retention`, `mart_product_monthly`.
-- MAGIC
-- MAGIC KPI definitions: `docs/requirements.md`.

-- COMMAND ----------

USE CATALOG workspace;
USE SCHEMA retail;

-- COMMAND ----------

-- Star tables are rebuilt from scratch each run (fact first, because it holds the foreign keys)
DROP TABLE IF EXISTS fact_sales;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_customer;

-- COMMAND ----------

-- MAGIC %md ## Dimensions

-- COMMAND ----------

CREATE TABLE dim_date AS
SELECT
  CAST(date_format(d, 'yyyyMMdd') AS INT) AS date_key,
  d                                       AS calendar_date,
  year(d)                                 AS year,
  quarter(d)                              AS quarter,
  month(d)                                AS month,
  date_format(d, 'MMM')                   AS month_name,
  trunc(d, 'MM')                          AS month_start,
  weekofyear(d)                           AS iso_week,
  dayofweek(d)                            AS day_of_week,
  date_format(d, 'E')                     AS day_name,
  dayofweek(d) IN (1, 7)                  AS is_weekend
FROM (SELECT explode(sequence(DATE'2009-12-01', DATE'2011-12-31', INTERVAL 1 DAY)) AS d);

ALTER TABLE dim_date ALTER COLUMN date_key SET NOT NULL;
ALTER TABLE dim_date ADD CONSTRAINT pk_dim_date PRIMARY KEY (date_key);
COMMENT ON TABLE dim_date IS 'Calendar dimension, one row per day from 2009-12-01 to 2011-12-31.';

-- COMMAND ----------

CREATE TABLE dim_product AS
WITH desc_rank AS (
  -- R08: a stock code can carry several descriptions; keep the most frequent one
  SELECT
    stock_code,
    description,
    row_number() OVER (PARTITION BY stock_code ORDER BY count(*) DESC, description) AS rn
  FROM silver_transactions
  WHERE description IS NOT NULL
  GROUP BY stock_code, description
),
p AS (
  SELECT
    stock_code,
    bool_or(is_non_product) AS is_non_product,
    min(invoice_date)       AS first_sold_date,
    max(invoice_date)       AS last_sold_date
  FROM silver_transactions
  GROUP BY stock_code
)
SELECT
  p.stock_code,
  coalesce(d.description, '(no description)') AS description,
  p.is_non_product,
  p.first_sold_date,
  p.last_sold_date
FROM p
LEFT JOIN desc_rank d
  ON d.stock_code = p.stock_code AND d.rn = 1;

ALTER TABLE dim_product ALTER COLUMN stock_code SET NOT NULL;
ALTER TABLE dim_product ADD CONSTRAINT pk_dim_product PRIMARY KEY (stock_code);
COMMENT ON TABLE dim_product IS 'Product dimension, one row per stock code. Non-product codes (postage, fees, vouchers) are flagged, not removed.';

-- COMMAND ----------

CREATE TABLE dim_customer AS
WITH country_rank AS (
  SELECT
    customer_id,
    country,
    row_number() OVER (PARTITION BY customer_id ORDER BY count(*) DESC, max(invoice_ts) DESC) AS rn
  FROM silver_transactions
  WHERE NOT is_guest
  GROUP BY customer_id, country
),
c AS (
  SELECT
    customer_id,
    min(CASE WHEN invoice_type = 'sale' THEN invoice_date END) AS first_order_date,
    max(CASE WHEN invoice_type = 'sale' THEN invoice_date END) AS last_order_date
  FROM silver_transactions
  WHERE NOT is_guest
  GROUP BY customer_id
)
SELECT c.customer_id, r.country AS primary_country, c.first_order_date, c.last_order_date, false AS is_guest
FROM c
JOIN country_rank r ON r.customer_id = c.customer_id AND r.rn = 1
UNION ALL
-- R02: one placeholder row for all lines without a customer ID
SELECT 'GUEST', 'Unknown', CAST(NULL AS DATE), CAST(NULL AS DATE), true;

ALTER TABLE dim_customer ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE dim_customer ADD CONSTRAINT pk_dim_customer PRIMARY KEY (customer_id);
ALTER TABLE dim_customer ALTER COLUMN customer_id SET TAGS ('pii' = 'pseudonymous_id');
COMMENT ON TABLE dim_customer IS 'Customer dimension. primary_country = country on most of the customer''s lines. GUEST row covers lines with no customer ID.';

-- COMMAND ----------

-- MAGIC %md ## Fact

-- COMMAND ----------

CREATE TABLE fact_sales AS
SELECT
  xxhash64(invoice, stock_code, description, quantity, unit_price, invoice_ts, customer_id, country) AS sales_line_id,
  invoice,
  invoice_type,
  CAST(date_format(invoice_date, 'yyyyMMdd') AS INT) AS date_key,
  invoice_ts,
  coalesce(customer_id, 'GUEST')                     AS customer_id,
  stock_code,
  country,
  quantity,
  unit_price,
  line_amount
FROM silver_transactions;

ALTER TABLE fact_sales ALTER COLUMN date_key    SET NOT NULL;
ALTER TABLE fact_sales ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE fact_sales ALTER COLUMN stock_code  SET NOT NULL;
ALTER TABLE fact_sales ADD CONSTRAINT fk_sales_date     FOREIGN KEY (date_key)    REFERENCES dim_date;
ALTER TABLE fact_sales ADD CONSTRAINT fk_sales_customer FOREIGN KEY (customer_id) REFERENCES dim_customer;
ALTER TABLE fact_sales ADD CONSTRAINT fk_sales_product  FOREIGN KEY (stock_code)  REFERENCES dim_product;

COMMENT ON TABLE fact_sales IS 'Sales fact. Grain: one invoice line. Cancellations are negative lines so SUM(line_amount) = net revenue.';
ALTER TABLE fact_sales ALTER COLUMN line_amount  COMMENT 'quantity * unit_price in GBP; negative for cancellations';
ALTER TABLE fact_sales ALTER COLUMN invoice_type COMMENT 'sale or cancellation (adjustments are quarantined in silver)';
ALTER TABLE fact_sales ALTER COLUMN customer_id  COMMENT 'FK to dim_customer; GUEST when the source had no customer ID';

ALTER TABLE dim_date     SET TAGS ('layer' = 'gold');
ALTER TABLE dim_product  SET TAGS ('layer' = 'gold');
ALTER TABLE dim_customer SET TAGS ('layer' = 'gold');
ALTER TABLE fact_sales   SET TAGS ('layer' = 'gold');

-- COMMAND ----------

-- MAGIC %md ## Marts

-- COMMAND ----------

CREATE OR REPLACE TABLE mart_monthly_kpis AS
WITH f AS (
  SELECT f.*, d.month_start
  FROM fact_sales f
  JOIN dim_date d    ON d.date_key   = f.date_key
  JOIN dim_product p ON p.stock_code = f.stock_code
  WHERE NOT p.is_non_product
),
first_order AS (
  SELECT customer_id, min(month_start) AS first_month
  FROM f
  WHERE invoice_type = 'sale' AND customer_id <> 'GUEST'
  GROUP BY customer_id
),
monthly AS (
  SELECT
    month_start                                                                     AS month,
    sum(CASE WHEN invoice_type = 'sale'         THEN line_amount ELSE 0 END)        AS gross_revenue,
    -sum(CASE WHEN invoice_type = 'cancellation' THEN line_amount ELSE 0 END)       AS cancelled_revenue,
    sum(line_amount)                                                                AS net_revenue,
    sum(CASE WHEN customer_id = 'GUEST' THEN line_amount ELSE 0 END)                AS guest_net_revenue,
    count(DISTINCT CASE WHEN invoice_type = 'sale' THEN invoice END)                AS orders,
    count(DISTINCT CASE WHEN invoice_type = 'cancellation' THEN invoice END)        AS cancelled_invoices,
    count(DISTINCT CASE WHEN invoice_type = 'sale' AND customer_id <> 'GUEST'
                        THEN customer_id END)                                       AS active_customers
  FROM f
  GROUP BY month_start
)
SELECT
  m.month,
  m.gross_revenue,
  m.cancelled_revenue,
  m.net_revenue,
  round(m.gross_revenue / nullif(m.orders, 0), 2)                   AS avg_order_value,
  m.orders,
  m.active_customers,
  coalesce(n.new_customers, 0)                                      AS new_customers,
  round(100.0 * m.cancelled_invoices / nullif(m.orders, 0), 2)      AS cancellation_rate_pct,
  round(100.0 * m.guest_net_revenue  / nullif(m.net_revenue, 0), 2) AS guest_revenue_share_pct,
  m.month = DATE'2011-12-01'                                        AS is_partial_month
FROM monthly m
LEFT JOIN (SELECT first_month, count(*) AS new_customers FROM first_order GROUP BY first_month) n
  ON n.first_month = m.month;

COMMENT ON TABLE mart_monthly_kpis IS 'One row per month: revenue, orders, AOV, customers, cancellation rate. Product lines only. Dec 2011 is a partial month.';

-- COMMAND ----------

CREATE OR REPLACE TABLE mart_customer_rfm AS
WITH asof AS (
  SELECT date_add(max(invoice_date), 1) AS asof_date FROM silver_transactions
),
base AS (
  SELECT
    customer_id,
    max(CASE WHEN invoice_type = 'sale' THEN to_date(invoice_ts) END) AS last_purchase_date,
    count(DISTINCT CASE WHEN invoice_type = 'sale' THEN invoice END)  AS frequency,
    sum(line_amount)                                                  AS monetary
  FROM fact_sales
  WHERE customer_id <> 'GUEST'
  GROUP BY customer_id
  HAVING count(DISTINCT CASE WHEN invoice_type = 'sale' THEN invoice END) > 0
),
scored AS (
  SELECT
    b.*,
    datediff(a.asof_date, b.last_purchase_date)                       AS recency_days,
    6 - ntile(5) OVER (ORDER BY datediff(a.asof_date, b.last_purchase_date))  AS r_score,
    ntile(5) OVER (ORDER BY b.frequency)                              AS f_score,
    ntile(5) OVER (ORDER BY b.monetary)                               AS m_score
  FROM base b
  CROSS JOIN asof a
)
SELECT
  *,
  concat(r_score, f_score, m_score) AS rfm_code,
  CASE
    WHEN r_score >= 4 AND f_score >= 4 THEN 'Champions'
    WHEN r_score >= 3 AND f_score >= 3 THEN 'Loyal'
    WHEN r_score >= 4 AND f_score <= 2 THEN 'New / promising'
    WHEN r_score <= 2 AND f_score >= 3 THEN 'At risk'
    WHEN r_score <= 2 AND f_score <= 2 THEN 'Hibernating'
    ELSE 'Needs attention'
  END AS segment
FROM scored;

COMMENT ON TABLE mart_customer_rfm IS 'RFM scores (1-5 quintiles) and segment per identified customer, as of the day after the last transaction.';

-- COMMAND ----------

CREATE OR REPLACE TABLE mart_cohort_retention AS
WITH orders AS (
  SELECT DISTINCT f.customer_id, d.month_start
  FROM fact_sales f
  JOIN dim_date d ON d.date_key = f.date_key
  WHERE f.invoice_type = 'sale' AND f.customer_id <> 'GUEST'
),
cohorts AS (
  SELECT customer_id, min(month_start) AS cohort_month FROM orders GROUP BY customer_id
),
activity AS (
  SELECT
    c.cohort_month,
    CAST(months_between(o.month_start, c.cohort_month) AS INT) AS months_since_first,
    count(DISTINCT o.customer_id)                              AS active_customers
  FROM orders o
  JOIN cohorts c ON c.customer_id = o.customer_id
  GROUP BY c.cohort_month, CAST(months_between(o.month_start, c.cohort_month) AS INT)
),
sizes AS (
  SELECT cohort_month, count(*) AS cohort_size FROM cohorts GROUP BY cohort_month
)
SELECT
  a.cohort_month,
  a.months_since_first,
  s.cohort_size,
  a.active_customers,
  round(100.0 * a.active_customers / s.cohort_size, 1) AS retention_pct
FROM activity a
JOIN sizes s ON s.cohort_month = a.cohort_month;

COMMENT ON TABLE mart_cohort_retention IS 'Monthly acquisition cohorts: share of each cohort buying again N months later. The Dec 2009 cohort includes pre-existing customers (data starts then).';

-- COMMAND ----------

CREATE OR REPLACE TABLE mart_product_monthly AS
SELECT
  d.month_start                                                          AS month,
  f.stock_code,
  p.description,
  sum(CASE WHEN f.invoice_type = 'sale'         THEN f.quantity ELSE 0 END)  AS units_sold,
  -sum(CASE WHEN f.invoice_type = 'cancellation' THEN f.quantity ELSE 0 END) AS units_cancelled,
  sum(f.line_amount)                                                     AS net_revenue,
  count(DISTINCT CASE WHEN f.invoice_type = 'sale' THEN f.invoice END)   AS orders
FROM fact_sales f
JOIN dim_date d    ON d.date_key   = f.date_key
JOIN dim_product p ON p.stock_code = f.stock_code
WHERE NOT p.is_non_product
GROUP BY d.month_start, f.stock_code, p.description;

COMMENT ON TABLE mart_product_monthly IS 'Product x month performance: units sold, units cancelled, net revenue, orders.';

-- COMMAND ----------

SELECT * FROM mart_monthly_kpis ORDER BY month;
