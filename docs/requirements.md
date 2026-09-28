# Business Requirements

## Context
A UK online giftware retailer (UCI *Online Retail II*, Dec 2009 – Dec 2011, ~1M invoice lines) sells mostly to wholesale customers. Sales data arrives as two overlapping spreadsheet extracts with known quality problems: duplicate lines, missing customer IDs, cancellations mixed with sales, accounting adjustments and non-product charges (postage, fees).

**Stakeholders (assumed):** Head of E-commerce (revenue and growth), CRM / Marketing lead (customer retention and targeting), Merchandising (product performance), Finance (numbers must reconcile).

## Business questions
| # | Question | Owner | Answered by |
|---|---|---|---|
| Q1 | How are net revenue, orders and average order value trending month over month and year over year? | E-commerce | `mart_monthly_kpis` |
| Q2 | How many customers are new vs returning each month? | CRM | `mart_monthly_kpis` |
| Q3 | What share of each monthly cohort buys again 1, 3, 6, 12 months later? | CRM | `mart_cohort_retention` |
| Q4 | Which customer segments drive revenue, and which valuable customers are at risk of churning? | CRM / Marketing | `mart_customer_rfm` |
| Q5 | Which products drive revenue, and which have unusually high cancellation rates? | Merchandising | `mart_product_monthly` |
| Q6 | Can we trust these numbers — what was excluded and why, and does everything reconcile? | Finance | `dq_results`, `recon_results`, `silver_quarantine` |

## KPI definitions
All revenue in GBP, **product lines only** (non-product stock codes excluded) unless stated.

| KPI | Definition |
|---|---|
| Gross revenue | Σ `line_amount` on sale lines |
| Cancelled revenue | −Σ `line_amount` on cancellation lines (shown as a positive number) |
| Net revenue | Gross revenue − cancelled revenue = Σ `line_amount` on all lines |
| Orders | Distinct sale invoices |
| Average order value (AOV) | Gross revenue ÷ orders |
| Active customers | Distinct identified customers with ≥1 sale invoice in the month (GUEST excluded) |
| New customers | Active customers whose first-ever sale invoice falls in the month |
| Cancellation rate | Distinct cancellation invoices ÷ sale invoices in the month |
| Cohort retention (month N) | Customers from cohort *c* with a sale in month *c+N* ÷ cohort size |
| RFM | Recency = days since last sale (as of the day after the last transaction); Frequency = distinct sale invoices; Monetary = net revenue. Each scored 1–5 by quintile (5 = best). |

## Data rules and assumptions
- Invoice prefix **C** = cancellation (negative quantity), prefix **A** = accounting adjustment (not a sale → quarantined).
- Exact duplicate lines are removed; the two extracts overlap in early December 2010.
- Lines without a customer ID count toward revenue but not toward customer metrics (mapped to `GUEST`).
- Stock codes not matching the product pattern (5 digits + optional letters) are non-product charges.
- Dec 2011 is a partial month (data ends 9 Dec 2011) and is flagged `is_partial_month`.
- The Dec 2009 cohort includes customers who bought before the data starts, so its retention is overstated.

## Acceptance criteria
1. Row reconciliation passes: bronze rows = silver + quarantine + removed duplicates.
2. Revenue reconciles from silver → fact → monthly mart to the penny.
3. No orphan keys in `fact_sales` (rule R11 = 0).
4. Every excluded row is in `silver_quarantine` with a reason code — nothing is dropped silently.
5. The pipeline stops (fails) if any reconciliation check fails.
