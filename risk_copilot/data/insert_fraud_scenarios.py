"""
Risk, Fraud, and Regulatory Intelligence Copilot
Standalone Python Seed Runner: Injected Scenarios & Synthetic Fraud Ground Truth
File: risk_copilot/data/insert_fraud_scenarios.py
"""

import json
import os
import sys

try:
    from snowflake.snowpark import Session
except ImportError:
    Session = None


def get_session():
    if Session is None:
        raise ImportError("snowflake-snowpark-python is required to run this script directly.")
    token_path = os.environ.get("SNOWFLAKE_TOKEN_FILE_PATH", "/snowflake/session/token")
    if os.path.exists(token_path):
        with open(token_path, "r") as f:
            token = f.read().strip()
        return Session.builder.configs({
            "account": os.environ.get("SNOWFLAKE_ACCOUNT", "lg47310"),
            "user": os.environ.get("SNOWFLAKE_USER", "HACK2SKILL"),
            "authenticator": "oauth",
            "token": token,
            "warehouse": "COMPUTE_WH",
            "database": "RISK_COPILOT",
            "schema": "RAW"
        }).create()
    return Session.builder.getOrCreate()


def run_seed():
    print("Connecting to Snowflake session...")
    session = get_session()
    
    sql_file = os.path.join(os.path.dirname(__file__), "insert_fraud_scenarios.sql")
    with open(sql_file, "r") as f:
        statements = [s.strip() for s in f.read().split(";") if s.strip()]
    
    print(f"Executing {len(statements)} SQL statements from insert_fraud_scenarios.sql...")
    for i, stmt in enumerate(statements, 1):
        if stmt.startswith("--") or not stmt:
            continue
        print(f"[{i}/{len(statements)}] Executing: {stmt[:60]}...")
        session.sql(stmt).collect()
    
    print("Refreshing Dynamic Tables...")
    session.sql("ALTER DYNAMIC TABLE RISK_COPILOT.CURATED.DT_ACCOUNT_SIGNALS REFRESH").collect()
    session.sql("ALTER DYNAMIC TABLE RISK_COPILOT.CURATED.DT_FRAUD_ALERTS REFRESH").collect()
    print("Seed complete! Synthetic fraud and regulatory scenarios are active in RISK_COPILOT.")


if __name__ == "__main__":
    run_seed()
