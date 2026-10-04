"""Inject a small account-takeover style demo sequence into RAW.TRANSACTIONS."""
import os, uuid
import snowflake.connector

ACCOUNT=os.getenv("DEMO_ACCOUNT_ID","")
CUSTOMER=os.getenv("DEMO_CUSTOMER_ID","")
if not ACCOUNT:
    raise SystemExit("Set DEMO_ACCOUNT_ID to an existing non-loan account from RAW.ACCOUNTS.")

rows=[
    ("2026-10-04 10:01:00",15000,"DEV-OLD-001","IN"),
    ("2026-10-04 10:04:00",25000,"DEV-OLD-001","IN"),
    ("2026-10-04 10:07:00",485000,"DEV-NEW-987","IN"),
    ("2026-10-04 10:09:00",375000,"DEV-NEW-987","IN"),
]
conn=snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"], user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"], warehouse=os.getenv("SNOWFLAKE_WAREHOUSE","COMPUTE_WH"),
    database="RISK_COPILOT", schema="RAW", role=os.getenv("SNOWFLAKE_ROLE")
)
with conn.cursor() as cur:
    for ts,amt,dev,geo in rows:
        cur.execute("""INSERT INTO RISK_COPILOT.RAW.TRANSACTIONS
          (TXN_ID,ACCOUNT_ID,COUNTERPARTY_ACCOUNT_ID,TXN_TS,CHANNEL,DIRECTION,
           AMOUNT_INR,DEVICE_ID,IP_ADDRESS,GEO_COUNTRY,SYNTH_LABEL)
          VALUES (%s,%s,%s,%s,'IMPS','DEBIT',%s,%s,'203.0.113.25',%s,'DEMO_ACCOUNT_TAKEOVER')""",
          ("DEMO-"+uuid.uuid4().hex[:12].upper(),ACCOUNT,"CP-DEMO-001",ts,amt,dev,geo))
    conn.commit()
print("Injected 4-event suspicious sequence.")
print("Wait for DT_FRAUD_ALERTS refresh (target lag is defined in Step 3), then query CURATED.V_RISK_COPILOT_FINDINGS.")
