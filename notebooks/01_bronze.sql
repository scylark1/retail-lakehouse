-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 01 · Bronze — raw ingest
-- MAGIC Loads every CSV in the landing volume **as-is** (all columns kept as STRING) and adds lineage columns.
-- MAGIC Bronze is never cleaned: it is the auditable copy of what the source sent.

-- COMMAND ----------

USE CATALOG workspace;
USE SCHEMA retail;

-- COMMAND ----------

CREATE OR REPLACE TABLE bronze_transactions AS
SELECT
  invoice,
  stock_code,
  description,
  quantity,
  invoice_date,
  price,
  customer_id,
  country,
  _metadata.file_name  AS source_file,
  current_timestamp()  AS ingested_at
FROM read_files(
  '/Volumes/workspace/retail/raw/',
  format            => 'csv',
  header            => true,
  inferColumnTypes  => false
);

-- COMMAND ----------

COMMENT ON TABLE bronze_transactions IS
  'Raw invoice lines from Online Retail II extracts. All columns STRING, no cleaning. Grain: one row per source line.';
ALTER TABLE bronze_transactions SET TAGS ('layer' = 'bronze', 'source' = 'uci_online_retail_ii');

-- COMMAND ----------

-- Ingest summary per source file
SELECT source_file, count(*) AS rows_loaded, min(invoice_date) AS first_ts, max(invoice_date) AS last_ts
FROM bronze_transactions
GROUP BY source_file
ORDER BY source_file;
