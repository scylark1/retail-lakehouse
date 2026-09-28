-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 00 · Setup
-- MAGIC Creates the schema and the raw landing volume in Unity Catalog.
-- MAGIC
-- MAGIC **After running this notebook:** open *Catalog → workspace → retail → raw* and upload
-- MAGIC `online_retail_2009_2010.csv` and `online_retail_2010_2011.csv` (produced by `scripts/convert_to_csv.py`).

-- COMMAND ----------

CREATE SCHEMA IF NOT EXISTS workspace.retail
COMMENT 'Retail analytics lakehouse: bronze / silver / gold layers for the UCI Online Retail II dataset';

-- COMMAND ----------

CREATE VOLUME IF NOT EXISTS workspace.retail.raw
COMMENT 'Landing zone for raw CSV extracts (one file per source extract)';

-- COMMAND ----------

-- Run this after uploading: both files should be listed.
LIST '/Volumes/workspace/retail/raw/';
