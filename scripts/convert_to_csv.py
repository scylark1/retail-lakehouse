"""Convert the UCI Online Retail II workbook into one CSV per sheet for upload to Databricks.

Usage:
    python3 scripts/convert_to_csv.py data/online_retail_II.xlsx

Writes data/online_retail_2009_2010.csv and data/online_retail_2010_2011.csv.
Only renames columns to snake_case and fixes formats (IDs as text, ISO timestamps);
no rows are removed or cleaned here - cleaning happens in the silver layer so it is auditable.
Reading the workbook takes a few minutes (about 1M rows).
"""
import sys
from pathlib import Path

import pandas as pd

RENAME = {
    "Invoice": "invoice",
    "StockCode": "stock_code",
    "Description": "description",
    "Quantity": "quantity",
    "InvoiceDate": "invoice_date",
    "Price": "price",
    "Customer ID": "customer_id",
    "Country": "country",
}
SHEETS = {
    "Year 2009-2010": "online_retail_2009_2010.csv",
    "Year 2010-2011": "online_retail_2010_2011.csv",
}


def main(xlsx: Path) -> None:
    out_dir = xlsx.parent
    frames = {}
    for sheet, out_name in SHEETS.items():
        df = pd.read_excel(xlsx, sheet_name=sheet, dtype={"Invoice": str, "StockCode": str})
        df = df.rename(columns=RENAME)[list(RENAME.values())]
        df["customer_id"] = df["customer_id"].astype("Int64").astype("string")
        df["invoice_date"] = pd.to_datetime(df["invoice_date"]).dt.strftime("%Y-%m-%d %H:%M:%S")
        df.to_csv(out_dir / out_name, index=False)
        frames[sheet] = df
        print(f"{out_name}: {len(df):,} rows, {df['invoice_date'].min()} -> {df['invoice_date'].max()}")

    a, b = frames.values()
    overlap_start = b["invoice_date"].min()
    overlap = a[a["invoice_date"] >= overlap_start]
    print(f"Rows in sheet 1 on/after {overlap_start} (overlap with sheet 2): {len(overlap):,}")
    both = pd.concat([a, b])
    print(f"Combined rows: {len(both):,}; exact duplicate rows: {both.duplicated().sum():,}")
    print(f"Missing customer_id: {both['customer_id'].isna().mean():.1%}")
    print(f"Cancellation lines (invoice starts with C): {both['invoice'].str.startswith('C').sum():,}")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "data/online_retail_II.xlsx"))
