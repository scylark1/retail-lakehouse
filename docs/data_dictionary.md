# Data Dictionary

Catalog `workspace`, schema `retail`. Table and column comments are also stored in Unity Catalog (visible in Catalog Explorer).

## Bronze
### `bronze_transactions` — raw lines, all STRING
| Column | Description |
|---|---|
| invoice | Invoice number; prefix C = cancellation, A = adjustment |
| stock_code | Product or charge code |
| description | Product description as entered |
| quantity | Units (negative on cancellations) |
| invoice_date | Invoice timestamp, `yyyy-MM-dd HH:mm:ss` |
| price | Unit price, GBP |
| customer_id | Customer number; often empty |
| country | Customer country |
| source_file | CSV file the row came from (lineage) |
| ingested_at | Load timestamp |

## Silver
### `silver_transactions` — typed, de-duplicated, validated. Grain: invoice line
| Column | Type | Description |
|---|---|---|
| invoice | STRING | Invoice number |
| invoice_type | STRING | `sale` or `cancellation` (CHECK constraint) |
| stock_code | STRING | Upper-cased, trimmed |
| description | STRING | Trimmed; NULL if blank |
| quantity | INT | Never 0 (CHECK constraint) |
| unit_price | DECIMAL(12,3) | Never negative (CHECK constraint) |
| line_amount | DECIMAL(14,2) | quantity × unit_price |
| invoice_ts | TIMESTAMP | Invoice timestamp |
| invoice_date | DATE | Date part of invoice_ts |
| customer_id | STRING | NULL for guest lines |
| is_guest | BOOLEAN | customer_id is NULL (rule R02) |
| country | STRING | Customer country |
| is_non_product | BOOLEAN | Postage, fees, vouchers etc. (rule R06) |
| source_file | STRING | Lineage |

### `silver_quarantine` — rows rejected by blocking rules
All typed columns above plus `dq_reject_rule` (rule ID), `dq_reject_reason` (rule name), `quarantined_at`.

## Gold — star schema
### `fact_sales` — grain: invoice line
| Column | Description |
|---|---|
| sales_line_id | Hash of the line's business columns |
| invoice, invoice_type | As in silver |
| date_key | FK → `dim_date` (yyyyMMdd) |
| invoice_ts | Timestamp |
| customer_id | FK → `dim_customer`; `GUEST` when unknown |
| stock_code | FK → `dim_product` |
| country | Country on the transaction |
| quantity, unit_price, line_amount | Measures; SUM(line_amount) = net revenue |

### `dim_date` — PK `date_key`
calendar_date, year, quarter, month, month_name, month_start, iso_week, day_of_week, day_name, is_weekend.

### `dim_product` — PK `stock_code`
description (most frequent, rule R08), is_non_product, first_sold_date, last_sold_date.

### `dim_customer` — PK `customer_id`
primary_country (country on most lines), first_order_date, last_order_date, is_guest. `customer_id` tagged `pii = pseudonymous_id`.

## Gold — marts
| Table | Grain | Key columns |
|---|---|---|
| `mart_monthly_kpis` | month | gross/cancelled/net revenue, avg_order_value, orders, active/new customers, cancellation_rate_pct, guest_revenue_share_pct, is_partial_month |
| `mart_customer_rfm` | customer | recency_days, frequency, monetary, r/f/m_score, rfm_code, segment |
| `mart_cohort_retention` | cohort month × months since first | cohort_size, active_customers, retention_pct |
| `mart_product_monthly` | month × product | units_sold, units_cancelled, net_revenue, orders |

## Data quality and governance tables
| Table | Description |
|---|---|
| `dq_rules` | Rule catalogue: rule_id, rule_name, layer, severity, action, rule_description |
| `dq_results` | Appended every run: run_ts, rule_id, failed_rows, checked_rows, failed_pct |
| `recon_results` | Appended every run: run_ts, check_name, expected, actual, status |

## DQ rules
| ID | Rule | Severity | Action |
|---|---|---|---|
| R01 | Exact duplicate line | warning | removed |
| R02 | Missing customer ID | warning | flagged → GUEST |
| R03 | Cancellation line | info | flagged, netted |
| R04 | Invalid quantity | error | quarantined |
| R05 | Invalid price | error | quarantined |
| R06 | Non-product stock code | info | flagged, excluded from product KPIs |
| R07 | Invalid / out-of-range timestamp | error | quarantined |
| R08 | Stock code with several descriptions | warning | resolved in dim_product |
| R09 | Invoice linked to several customers | error | monitored (expect 0) |
| R10 | Accounting adjustment | info | quarantined |
| R11 | Orphan key in fact table | error | monitored (expect 0) |
