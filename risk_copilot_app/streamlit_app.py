import json
import os

import pandas as pd
import streamlit as st

AGENT = "RISK_COPILOT.APP.RISK_FRAUD_REG_COPILOT"

st.set_page_config(page_title="Risk, Fraud & Regulatory Copilot", layout="wide", initial_sidebar_state="expanded")
st.title("🛡️ Risk, Fraud & Regulatory Intelligence Copilot")
st.caption("Governed AI for Banking & NBFCs: Real-Time Fraud, Liquidity/ALM, Credit EWS & Regulator-Ready Reporting")

conn = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))
session = conn.session()


def q(sql, params=None):
    return session.sql(sql, params=params).to_pandas()


@st.cache_data(ttl=120)
def load(sql):
    return q(sql)


def clear_cache():
    load.clear()


def call_proc(sql, params):
    raw = session.sql(sql, params=params).collect()[0][0]
    return json.loads(raw) if isinstance(raw, str) else raw


def run_agent(messages):
    body = json.dumps({"messages": messages, "stream": False})
    raw = session.sql("SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, ?)", params=[AGENT, body]).collect()[0][0]
    resp = json.loads(raw)
    texts, tools, citations = [], [], []
    for item in resp.get("content", []):
        t = item.get("type")
        if t == "text":
            texts.append(item.get("text", ""))
            for a in item.get("annotations", []) or []:
                citations.append(a)
        elif t == "tool_result":
            tr = item.get("tool_result", {})
            payload = [c.get("json", c.get("text")) for c in tr.get("content", [])]
            tools.append({"name": tr.get("name"), "status": tr.get("status"), "payload": payload})
    return "\n".join(texts).strip(), tools, citations


# ============================================================================
# 45 Scenario Question Bank Definition with Grounded SQL & Descriptions
# ============================================================================
QUESTION_BANK = [
    # WOW Scenario
    {
        "id": 0,
        "tier": "⭐ Ultimate WOW Demo",
        "question": "Why should I file a SAR for customer CUST-9821?",
        "desc": "Detects 17 cash deposits across 5 branches evading CTR limit ($10,000 / ₹10L). Cites FinCEN § 1010.314 & PMLA.",
        "sql": """
            SELECT a.ALERT_ID, a.ACCOUNT_ID, a.CUSTOMER_ID, a.FULL_NAME, a.TYPOLOGY, a.RISK_SCORE, a.RECOMMENDED_ACTION, 
                   s.CASH_NEAR_CTR_10D AS CASH_DEPOSITS_COUNT, s.CASH_NEAR_CTR_AMT_10D AS TOTAL_STRUCTURING_INR,
                   a.RED_FLAGS
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS a
            JOIN RISK_COPILOT.CURATED.DT_ACCOUNT_SIGNALS s ON s.ACCOUNT_ID = a.ACCOUNT_ID
            WHERE a.CUSTOMER_ID = 'CUST-9821'
        """
    },
    # Tier 1
    {
        "id": 1,
        "tier": "Tier 1: Real-Time Fraud Detection",
        "question": "What are the highest-risk transactions from the last 15 minutes?",
        "desc": "Surfaces high-risk transactions in the trailing observation window with risk scores and fraud indicators.",
        "sql": """
            SELECT TXN_ID, TXN_TS, ACCOUNT_ID, CUSTOMER_NAME, AMOUNT_INR, CHANNEL, TYPOLOGY, RISK_SCORE, RECOMMENDED_ACTION
            FROM RISK_COPILOT.CURATED.V_RECENT_HIGH_RISK_TXNS
            LIMIT 15
        """
    },
    {
        "id": 2,
        "tier": "Tier 1: Real-Time Fraud Detection",
        "question": "Which customers show structuring behavior today?",
        "desc": "Identifies multiple cash deposits just below the ₹10 Lakh / $10,000 threshold across accounts.",
        "sql": """
            SELECT ALERT_ID, ACCOUNT_ID, FULL_NAME, OCCUPATION, CASH_NEAR_CTR_AMT_10D AS STRUCTURING_AMT_INR, RISK_SCORE, RECOMMENDED_ACTION
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            WHERE TYPOLOGY = 'AML_LAYERING' AND CASH_NEAR_CTR_AMT_10D > 0
            ORDER BY RISK_SCORE DESC
        """
    },
    {
        "id": 3,
        "tier": "Tier 1: Real-Time Fraud Detection",
        "question": "Show accounts whose transaction velocity is 5x above their normal behavior.",
        "desc": "Identifies dormant accounts with sudden 48-hour inflow bursts (10+ credits vs 0 prior).",
        "sql": """
            SELECT ACCOUNT_ID, CUSTOMER_ID, FULL_NAME, OCCUPATION, INFLOW_CNT_48H, DORMANT_DAYS_BEFORE_WINDOW, INFLOW_AMT_48H, OUTFLOW_AMT_48H
            FROM RISK_COPILOT.CURATED.DT_ACCOUNT_SIGNALS
            WHERE (DORMANT_DAYS_BEFORE_WINDOW >= 30 OR ACCOUNT_AGE_DAYS <= 180) AND INFLOW_CNT_48H >= 10
            ORDER BY INFLOW_CNT_48H DESC
        """
    },
    {
        "id": 4,
        "tier": "Tier 1: Real-Time Fraud Detection",
        "question": "Which transactions deviate significantly from the customer's historical pattern?",
        "desc": "Finds transactions exceeding 50% of declared annual income for students/low-income categories.",
        "sql": """
            SELECT ALERT_ID, ACCOUNT_ID, FULL_NAME, OCCUPATION, INFLOW_AMT_48H, RISK_SCORE, RED_FLAGS
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            WHERE ARRAY_CONTAINS('PROFILE_MISMATCH'::VARIANT, FLAG_NAMES)
            ORDER BY INFLOW_AMT_48H DESC
        """
    },
    {
        "id": 5,
        "tier": "Tier 1: Real-Time Fraud Detection",
        "question": "Identify newly opened accounts involved in large fund transfers.",
        "desc": "Accounts opened within 180 days with large 48h inflows and rapid outflows.",
        "sql": """
            SELECT ACCOUNT_ID, CUSTOMER_ID, FULL_NAME, OPEN_DATE, ACCOUNT_AGE_DAYS, INFLOW_AMT_48H, OUTFLOW_AMT_48H, PASS_THROUGH_RATIO_48H
            FROM RISK_COPILOT.CURATED.DT_ACCOUNT_SIGNALS
            WHERE ACCOUNT_AGE_DAYS <= 180 AND INFLOW_AMT_48H >= 200000
            ORDER BY INFLOW_AMT_48H DESC
        """
    },
    {
        "id": 6,
        "tier": "Tier 1: Real-Time Fraud Detection",
        "question": "Which transactions originated from unusual geographies or devices?",
        "desc": "Filters transactions accessing banking channels via foreign IP ranges (185.x.x.x, AE) or multiple devices.",
        "sql": """
            SELECT t.TXN_ID, t.TXN_TS, t.ACCOUNT_ID, t.AMOUNT_INR, t.CHANNEL, t.DEVICE_ID, t.IP_ADDRESS, t.GEO_COUNTRY, a.TYPOLOGY
            FROM RISK_COPILOT.RAW.TRANSACTIONS t
            JOIN RISK_COPILOT.CURATED.DT_FRAUD_ALERTS a ON a.ACCOUNT_ID = t.ACCOUNT_ID
            WHERE t.GEO_COUNTRY <> 'IN' OR t.IP_ADDRESS LIKE '185.%'
            ORDER BY t.TXN_TS DESC LIMIT 20
        """
    },
    {
        "id": 7,
        "tier": "Tier 1: Real-Time Fraud Detection",
        "question": "Show linked accounts participating in potential fraud rings.",
        "desc": "Accounts connected through shared device infrastructure or circular layering rings.",
        "sql": """
            SELECT SOURCE_NODE, SOURCE_NAME, TARGET_NODE, TARGET_NAME, LINK_TYPE, TXN_COUNT, TOTAL_VOLUME_INR
            FROM RISK_COPILOT.CURATED.V_NETWORK_GRAPH
            ORDER BY TOTAL_VOLUME_INR DESC LIMIT 15
        """
    },
    {
        "id": 8,
        "tier": "Tier 1: Real-Time Fraud Detection",
        "question": "Which customers trigger multiple fraud rules simultaneously?",
        "desc": "Accounts triggering 3 or more concurrent red flags.",
        "sql": """
            SELECT ALERT_ID, ACCOUNT_ID, FULL_NAME, TYPOLOGY, RED_FLAG_COUNT, RISK_SCORE, FLAG_NAMES, RECOMMENDED_ACTION
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            WHERE RED_FLAG_COUNT >= 3
            ORDER BY RED_FLAG_COUNT DESC, RISK_SCORE DESC
        """
    },
    # Tier 2
    {
        "id": 9,
        "tier": "Tier 2: AML (Anti-Money Laundering)",
        "question": "Which customers should be reviewed for Suspicious Activity Reports (SAR)?",
        "desc": "Accounts with critical risk scores (>=60) and FREEZE / HOLD recommendations.",
        "sql": """
            SELECT ALERT_ID, ACCOUNT_ID, FULL_NAME, TYPOLOGY, RISK_SCORE, RECOMMENDED_ACTION, INFLOW_AMT_48H, OUTFLOW_AMT_48H
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            WHERE RISK_SCORE >= 60 OR RECOMMENDED_ACTION IN ('FREEZE_ACCOUNT', 'PLACE_HOLD')
            ORDER BY RISK_SCORE DESC
        """
    },
    {
        "id": 10,
        "tier": "Tier 2: AML (Anti-Money Laundering)",
        "question": "Why was Customer A flagged for AML review?",
        "desc": "Itemized evidence breakdown for structured cash deposit accounts.",
        "sql": """
            SELECT ALERT_ID, ACCOUNT_ID, FULL_NAME, OCCUPATION, RED_FLAGS, RISK_SCORE, RECOMMENDED_ACTION
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            WHERE TYPOLOGY = 'AML_LAYERING' LIMIT 5
        """
    },
    {
        "id": 11,
        "tier": "Tier 2: AML (Anti-Money Laundering)",
        "question": "Show all layering patterns detected this week.",
        "desc": "Identifies 3-hop circular round-trips and rapid pass-through mule structures.",
        "sql": """
            SELECT ALERT_ID, ACCOUNT_ID, FULL_NAME, TYPOLOGY, ROUND_TRIP_AMT, PASS_THROUGH_RATIO_48H, RISK_SCORE
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            WHERE ARRAY_CONTAINS('ROUND_TRIPPING'::VARIANT, FLAG_NAMES) OR ARRAY_CONTAINS('RAPID_PASS_THROUGH'::VARIANT, FLAG_NAMES)
            ORDER BY RISK_SCORE DESC
        """
    },
    {
        "id": 12,
        "tier": "Tier 2: AML (Anti-Money Laundering)",
        "question": "Which transactions exhibit money mule characteristics?",
        "desc": "Transactions involving 92% swift pass-through via RTGS to external beneficiaries.",
        "sql": """
            SELECT t.TXN_ID, t.ACCOUNT_ID, a.FULL_NAME, t.CHANNEL, t.DIRECTION, t.AMOUNT_INR, t.COUNTERPARTY_ACCOUNT_ID, t.TXN_TS
            FROM RISK_COPILOT.RAW.TRANSACTIONS t
            JOIN RISK_COPILOT.CURATED.DT_FRAUD_ALERTS a ON a.ACCOUNT_ID = t.ACCOUNT_ID
            WHERE a.TYPOLOGY = 'MONEY_MULE' AND t.CHANNEL IN ('RTGS', 'UPI', 'IMPS')
            ORDER BY t.TXN_TS DESC LIMIT 20
        """
    },
    {
        "id": 13,
        "tier": "Tier 2: AML (Anti-Money Laundering)",
        "question": "Identify accounts connected to sanctioned entities.",
        "desc": "Customers matching OFAC SDN or UN Consolidated watchlists with score >= 0.85.",
        "sql": """
            SELECT a.ALERT_ID, a.ACCOUNT_ID, a.CUSTOMER_ID, a.FULL_NAME, s.WATCHLIST_HIT, s.WATCHLIST_SCORE, a.RECOMMENDED_ACTION
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS a
            JOIN RISK_COPILOT.CURATED.DT_ACCOUNT_SIGNALS s ON s.ACCOUNT_ID = a.ACCOUNT_ID
            WHERE s.WATCHLIST_SCORE >= 0.85
            ORDER BY s.WATCHLIST_SCORE DESC
        """
    },
    {
        "id": 14,
        "tier": "Tier 2: AML (Anti-Money Laundering)",
        "question": "Which alerts have enough evidence to file a SAR?",
        "desc": "High-confidence alerts with verified red flags across multiple corroborated sources.",
        "sql": """
            SELECT ALERT_ID, ACCOUNT_ID, FULL_NAME, TYPOLOGY, RISK_SCORE, RED_FLAG_COUNT, RECOMMENDED_ACTION
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            WHERE RISK_SCORE >= 90 AND RED_FLAG_COUNT >= 4
            ORDER BY RISK_SCORE DESC
        """
    },
    # Tier 3
    {
        "id": 15,
        "tier": "Tier 3: Explainability Questions",
        "question": "Explain why Transaction TXN-12345 was flagged.",
        "desc": "Detailed breakdown of fraud score contributing factors (+20 Device, +25 Outflow, +30 Sanctions).",
        "sql": """
            SELECT ALERT_ID, ACCOUNT_ID, FULL_NAME, TYPOLOGY, RISK_SCORE, RED_FLAGS
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            WHERE ALERT_ID = 'ALR-ACC0000524'
        """
    },
    {
        "id": 16,
        "tier": "Tier 3: Explainability Questions",
        "question": "Show all evidence supporting this fraud alert.",
        "desc": "Complete evidence trail linking 48h transactions, device logs, and income ratios.",
        "sql": """
            SELECT a.ALERT_ID, a.ACCOUNT_ID, a.FULL_NAME, a.OCCUPATION, s.DECLARED_ANNUAL_INCOME, a.INFLOW_AMT_48H, a.OUTFLOW_AMT_48H, a.RED_FLAGS
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS a
            JOIN RISK_COPILOT.CURATED.DT_ACCOUNT_SIGNALS s ON s.ACCOUNT_ID = a.ACCOUNT_ID
            WHERE a.ALERT_ID = 'ALR-ACC0000524'
        """
    },
    {
        "id": 17,
        "tier": "Tier 3: Explainability Questions",
        "question": "Which regulations apply to this transaction?",
        "desc": "Maps flagged alerts to PMLA Section 12, FinCEN 31 CFR § 1010.314, and RBI KYC Master Direction.",
        "sql": """
            SELECT DOC_ID, DOC_TITLE, SECTION, DOMAIN, CHUNK_TEXT
            FROM RISK_COPILOT.RAW.POLICY_DOCS
            WHERE DOMAIN IN ('AML', 'FRAUD')
        """
    },
    {
        "id": 18,
        "tier": "Tier 3: Explainability Questions",
        "question": "What policy violations have occurred?",
        "desc": "Lists violated clauses: AML-POL 4.2 (Mule), 4.3 (Structuring), 4.4 (Round-Tripping), 7.1 (Sanctions).",
        "sql": """
            SELECT f.value:flag::STRING AS VIOLATION_FLAG, f.value:policy::STRING AS POLICY_CLAUSE, 
                   f.value:weight::NUMBER AS SEVERITY_WEIGHT, f.value:evidence::STRING AS EVIDENCE_FACT
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS a, LATERAL FLATTEN(a.RED_FLAGS) f
            WHERE a.ALERT_ID = 'ALR-ACC0000524'
        """
    },
    {
        "id": 19,
        "tier": "Tier 3: Explainability Questions",
        "question": "Why is this transaction considered suspicious under AML regulations?",
        "desc": "Evaluates economic inconsistency, lack of legitimate rationale, and velocity spikes.",
        "sql": """
            SELECT a.ALERT_ID, a.FULL_NAME, a.TYPOLOGY, a.INFLOW_AMT_48H, a.OUTFLOW_AMT_48H, a.PASS_THROUGH_RATIO_48H, a.RED_FLAGS
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS a
            WHERE a.TYPOLOGY = 'MONEY_MULE' LIMIT 1
        """
    },
    # Tier 4
    {
        "id": 20,
        "tier": "Tier 4: Network and Fraud Ring Analysis",
        "question": "Show the network of accounts connected to Customer CUST000371.",
        "desc": "Inspects multi-hop counterparties and shared device nodes connected to Customer CUST000371.",
        "sql": """
            SELECT SOURCE_NODE, SOURCE_NAME, TARGET_NODE, TARGET_NAME, LINK_TYPE, TXN_COUNT, TOTAL_VOLUME_INR
            FROM RISK_COPILOT.CURATED.V_NETWORK_GRAPH
            WHERE SOURCE_CUST_ID = 'CUST000371' OR TARGET_CUST_ID = 'CUST000371'
        """
    },
    {
        "id": 21,
        "tier": "Tier 4: Network and Fraud Ring Analysis",
        "question": "Identify possible fraud rings operating this week.",
        "desc": "Groups accounts sharing common mobile devices (DEV90000-DEV90005) or circular routing.",
        "sql": """
            SELECT LINK_TYPE, COUNT(*) AS CONNECTED_PAIRS, SUM(TOTAL_VOLUME_INR) AS TOTAL_RING_VOLUME_INR
            FROM RISK_COPILOT.CURATED.V_NETWORK_GRAPH
            GROUP BY LINK_TYPE
            ORDER BY TOTAL_RING_VOLUME_INR DESC
        """
    },
    {
        "id": 22,
        "tier": "Tier 4: Network and Fraud Ring Analysis",
        "question": "Which customers share devices, addresses, IPs, or phone numbers with known fraudsters?",
        "desc": "Surfaces distinct customer accounts authenticated from the exact same device ID.",
        "sql": """
            SELECT SOURCE_NAME, TARGET_NAME, LINK_TYPE, TOTAL_VOLUME_INR, LAST_ACTIVITY
            FROM RISK_COPILOT.CURATED.V_NETWORK_GRAPH
            WHERE LINK_TYPE LIKE 'SHARED_DEVICE%'
            ORDER BY TOTAL_VOLUME_INR DESC
        """
    },
    {
        "id": 23,
        "tier": "Tier 4: Network and Fraud Ring Analysis",
        "question": "Visualize transactional relationships around this suspicious account.",
        "desc": "Node-edge data table representing inward fund aggregators and outward beneficiaries.",
        "sql": """
            SELECT SOURCE_NODE, TARGET_NODE, LINK_TYPE, TXN_COUNT, TOTAL_VOLUME_INR, LAST_ACTIVITY
            FROM RISK_COPILOT.CURATED.V_NETWORK_GRAPH
            WHERE SOURCE_NODE = 'ACC0000524' OR TARGET_NODE = 'ACC0000524'
        """
    },
    {
        "id": 24,
        "tier": "Tier 4: Network and Fraud Ring Analysis",
        "question": "Find hidden connections between flagged transactions.",
        "desc": "Discovers shared external beneficiaries (e.g. EXT-BENF-003) across distinct account holders.",
        "sql": """
            SELECT COUNTERPARTY_ACCOUNT_ID, COUNT(DISTINCT ACCOUNT_ID) AS LINKED_ACCOUNTS, 
                   COUNT(*) AS TXN_COUNT, SUM(AMOUNT_INR) AS TOTAL_VOLUME_INR
            FROM RISK_COPILOT.RAW.TRANSACTIONS
            WHERE COUNTERPARTY_ACCOUNT_ID LIKE 'EXT-BENF-%'
            GROUP BY 1
            ORDER BY LINKED_ACCOUNTS DESC
        """
    },
    # Tier 5
    {
        "id": 25,
        "tier": "Tier 5: Credit Risk Questions",
        "question": "Which borrowers have experienced rapid credit deterioration?",
        "desc": "Borrowers with active NACH bounces, high utilization, and negative sales velocity trends.",
        "sql": """
            SELECT LOAN_ID, FULL_NAME, SEGMENT, INDUSTRY, OUTSTANDING, DPD, ASSET_CLASS, EWS_TRIGGERS, EWS_ACTION
            FROM RISK_COPILOT.CURATED.DT_LOAN_EWS
            WHERE EWS_TRIGGER_COUNT >= 2
            ORDER BY OUTSTANDING DESC LIMIT 15
        """
    },
    {
        "id": 26,
        "tier": "Tier 5: Credit Risk Questions",
        "question": "Show customers whose repayment behavior changed significantly.",
        "desc": "Accounts with 2+ NACH/cheque bounces in the trailing 90-day window.",
        "sql": """
            SELECT LOAN_ID, FULL_NAME, PRODUCT, INDUSTRY, OUTSTANDING, NACH_BOUNCES_90D, DPD, ASSET_CLASS
            FROM RISK_COPILOT.RAW.LOANS l JOIN RISK_COPILOT.RAW.CUSTOMERS c USING (CUSTOMER_ID)
            WHERE NACH_BOUNCES_90D >= 2
            ORDER BY NACH_BOUNCES_90D DESC, OUTSTANDING DESC
        """
    },
    {
        "id": 27,
        "tier": "Tier 5: Credit Risk Questions",
        "question": "Which accounts are likely to default within the next 30 days?",
        "desc": "SMA-2 facilities (61-90 DPD) with high limit utilization (>90%) and low bureau scores.",
        "sql": """
            SELECT LOAN_ID, FULL_NAME, INDUSTRY, OUTSTANDING, UTILIZATION_PCT, BUREAU_SCORE, DPD, ASSET_CLASS
            FROM RISK_COPILOT.RAW.LOANS l JOIN RISK_COPILOT.RAW.CUSTOMERS c USING (CUSTOMER_ID)
            WHERE DPD BETWEEN 61 AND 90 AND (UTILIZATION_PCT > 90 OR BUREAU_SCORE < 600)
            ORDER BY OUTSTANDING DESC
        """
    },
    {
        "id": 28,
        "tier": "Tier 5: Credit Risk Questions",
        "question": "Explain why this borrower received a high-risk rating.",
        "desc": "Detailed credit risk explanation mapping DPD and EWS triggers to policy CR-POL 5.3.",
        "sql": """
            SELECT LOAN_ID, FULL_NAME, PRODUCT, INDUSTRY, SANCTIONED_LIMIT, OUTSTANDING, UTILIZATION_PCT, 
                   DPD, ASSET_CLASS, IFRS9_STAGE, EWS_TRIGGERS, EWS_ACTION, POLICY_REF
            FROM RISK_COPILOT.CURATED.DT_LOAN_EWS
            WHERE ASSET_CLASS IN ('SMA-2', 'NPA') LIMIT 5
        """
    },
    {
        "id": 29,
        "tier": "Tier 5: Credit Risk Questions",
        "question": "Which loans require immediate review?",
        "desc": "Facilities triggering Credit Committee referral or limit freeze under CR-POL 5.3.",
        "sql": """
            SELECT LOAN_ID, FULL_NAME, INDUSTRY, OUTSTANDING, DPD, ASSET_CLASS, EWS_ACTION, EWS_TRIGGERS
            FROM RISK_COPILOT.CURATED.DT_LOAN_EWS
            WHERE EWS_ACTION IN ('RESTRUCTURING_DISCUSSION_CREDIT_COMMITTEE', 'LIMIT_FREEZE_AND_COLLATERAL_REVALUATION')
            ORDER BY OUTSTANDING DESC
        """
    },
    # Tier 6
    {
        "id": 30,
        "tier": "Tier 6: Liquidity & Basel Reporting",
        "question": "Is today's Liquidity Coverage Ratio within Basel requirements?",
        "desc": "Checks latest LCR (113.9%) against 100% regulatory minimum and 110% internal floor.",
        "sql": """
            SELECT AS_OF_DATE, LCR_PCT, LCR_STATUS, HQLA_STOCK, NET_CASH_OUTFLOWS_30D, LCR_STRESS_S1_PCT
            FROM RISK_COPILOT.CURATED.DT_LCR_DAILY
            ORDER BY AS_OF_DATE DESC LIMIT 1
        """
    },
    {
        "id": 31,
        "tier": "Tier 6: Liquidity & Basel Reporting",
        "question": "Explain the factors causing today's LCR decline.",
        "desc": "Evaluates 30-day trend in wholesale non-operational outflows and Level 2A asset haircuts.",
        "sql": """
            SELECT AS_OF_DATE, LCR_PCT, HQLA_STOCK, GROSS_OUTFLOWS, CAPPED_INFLOWS, NET_CASH_OUTFLOWS_30D, LCR_STATUS
            FROM RISK_COPILOT.CURATED.DT_LCR_DAILY
            ORDER BY AS_OF_DATE DESC LIMIT 10
        """
    },
    {
        "id": 32,
        "tier": "Tier 6: Liquidity & Basel Reporting",
        "question": "Which assets contribute most to liquidity stress?",
        "desc": "Breakdown of Level 2A and Level 2B holdings subject to haircuts and composition caps.",
        "sql": """
            SELECT INSTRUMENT, HQLA_LEVEL, HAIRCUT, SUM(MARKET_VALUE_INR) AS TOTAL_MARKET_VAL_INR
            FROM RISK_COPILOT.RAW.HQLA_HOLDINGS
            WHERE AS_OF_DATE = (SELECT MAX(AS_OF_DATE) FROM RISK_COPILOT.RAW.HQLA_HOLDINGS)
            GROUP BY 1,2,3
            ORDER BY HQLA_LEVEL, TOTAL_MARKET_VAL_INR DESC
        """
    },
    {
        "id": 33,
        "tier": "Tier 6: Liquidity & Basel Reporting",
        "question": "Generate today's Basel III compliance summary.",
        "desc": "Summarizes Level 1, 2A, 2B HQLA stock, net 30-day cash outflows, and compliance status.",
        "sql": """
            SELECT AS_OF_DATE, L1_HQLA, L2A_HQLA_POST_HAIRCUT, L2B_HQLA_POST_HAIRCUT, HQLA_STOCK, 
                   NET_CASH_OUTFLOWS_30D, LCR_PCT, LCR_STATUS
            FROM RISK_COPILOT.CURATED.DT_LCR_DAILY
            ORDER BY AS_OF_DATE DESC LIMIT 1
        """
    },
    {
        "id": 34,
        "tier": "Tier 6: Liquidity & Basel Reporting",
        "question": "Show funding concentration risks.",
        "desc": "Structural liquidity gap across maturity buckets (1-7D, 8-14D, 15-30D).",
        "sql": """
            SELECT AS_OF_DATE, NET_OUT_1_7D, NET_OUT_8_14D, NET_OUT_15_30D, NET_CASH_OUTFLOWS_30D
            FROM RISK_COPILOT.CURATED.DT_LCR_DAILY
            ORDER BY AS_OF_DATE DESC LIMIT 1
        """
    },
    # Tier 7
    {
        "id": 35,
        "tier": "Tier 7: Audit and Compliance Questions",
        "question": "Generate an audit-ready explanation for Alert #ALR-ACC0000524.",
        "desc": "Inspects existing STR narrative, cited policies, and citation guardrail verification status.",
        "sql": """
            SELECT CASE_ID, ALERT_ID, TYPOLOGY, RISK_SCORE, STATUS, GUARDRAIL_RESULT, SAR_DRAFT, CREATED_AT
            FROM RISK_COPILOT.APP.CASES
            WHERE ALERT_ID = 'ALR-ACC0000524'
        """
    },
    {
        "id": 36,
        "tier": "Tier 7: Audit and Compliance Questions",
        "question": "Produce regulator-ready documentation for Customer CUST-9821.",
        "desc": "Produces structured STR finding for customer CUST-9821 with FinCEN structuring citations.",
        "sql": """
            SELECT a.ALERT_ID, a.ACCOUNT_ID, a.CUSTOMER_ID, a.FULL_NAME, a.TYPOLOGY, a.RISK_SCORE, a.RED_FLAGS
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS a
            WHERE a.CUSTOMER_ID = 'CUST-9821'
        """
    },
    {
        "id": 37,
        "tier": "Tier 7: Audit and Compliance Questions",
        "question": "Show the complete evidence trail for this alert.",
        "desc": "Displays full audit log events associated with SAR generation, stress tests, and case reviews.",
        "sql": """
            SELECT EVENT_TS, EVENT_USER, EVENT_ROLE, EVENT_TYPE, OBJECT_ID, DETAILS
            FROM RISK_COPILOT.APP.AUDIT_LOG
            ORDER BY EVENT_TS DESC LIMIT 20
        """
    },
    {
        "id": 38,
        "tier": "Tier 7: Audit and Compliance Questions",
        "question": "Which source documents support this compliance finding?",
        "desc": "Fetches exact text chunks from the vector policy repository used for evidence grounding.",
        "sql": """
            SELECT DOC_ID, DOC_TITLE, DOC_TYPE, SECTION, DOMAIN, CHUNK_TEXT
            FROM RISK_COPILOT.RAW.POLICY_DOCS
            ORDER BY DOC_ID, SECTION
        """
    },
    {
        "id": 39,
        "tier": "Tier 7: Audit and Compliance Questions",
        "question": "Generate a case summary for investigator review.",
        "desc": "Summarizes cases currently in PENDING_REVIEW awaiting maker-checker sign-off.",
        "sql": """
            SELECT CASE_ID, ALERT_ID, ACCOUNT_ID, TYPOLOGY, RISK_SCORE, STATUS, ACTION_TAKEN, 
                   GUARDRAIL_RESULT:passed::BOOLEAN AS GUARDRAIL_PASSED, CREATED_BY, CREATED_AT
            FROM RISK_COPILOT.APP.CASES
            WHERE STATUS = 'PENDING_REVIEW'
            ORDER BY CREATED_AT DESC
        """
    },
    {
        "id": 40,
        "tier": "Tier 7: Audit and Compliance Questions",
        "question": "Create a documented finding with citations.",
        "desc": "Formatted finding with WHO, WHAT, WHEN, WHERE, WHY, HOW and explicit citation checks.",
        "sql": """
            SELECT CASE_ID, ALERT_ID, TYPOLOGY, RISK_SCORE, SAR_DRAFT, MISSING_DOCS, GUARDRAIL_RESULT
            FROM RISK_COPILOT.APP.CASES
            ORDER BY CREATED_AT DESC LIMIT 1
        """
    },
    # Tier 8
    {
        "id": 41,
        "tier": "Tier 8: Executive Dashboard Questions",
        "question": "What were today's top fraud trends?",
        "desc": "Aggregates open alerts by typology, total volume at risk, and average risk score.",
        "sql": """
            SELECT TYPOLOGY, COUNT(*) AS ALERT_COUNT, SUM(INFLOW_AMT_48H) AS TOTAL_INFLOW_INR, 
                   SUM(OUTFLOW_AMT_48H) AS TOTAL_OUTFLOW_INR, ROUND(AVG(RISK_SCORE)) AS AVG_RISK_SCORE
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            GROUP BY TYPOLOGY
            ORDER BY ALERT_COUNT DESC
        """
    },
    {
        "id": 42,
        "tier": "Tier 8: Executive Dashboard Questions",
        "question": "Show fraud exposure by business unit.",
        "desc": "Breakdown of fraud alerts and credit exposures across Individual, MSME, and Corporate segments.",
        "sql": """
            SELECT SEGMENT, COUNT(*) AS ALERTS, SUM(INFLOW_AMT_48H) AS INFLOW_EXPOSURE_INR, SUM(OUTFLOW_AMT_48H) AS OUTFLOW_EXPOSURE_INR
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            GROUP BY SEGMENT
            ORDER BY ALERTS DESC
        """
    },
    {
        "id": 43,
        "tier": "Tier 8: Executive Dashboard Questions",
        "question": "Which fraud typologies are increasing this month?",
        "desc": "Compares money mule bursts vs structuring smurfing vs layering round-trips.",
        "sql": """
            SELECT TYPOLOGY, RECOMMENDED_ACTION, COUNT(*) AS ALERTS, SUM(OUTFLOW_AMT_48H) AS TOTAL_OUTFLOW_INR
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            GROUP BY TYPOLOGY, RECOMMENDED_ACTION
            ORDER BY ALERTS DESC
        """
    },
    {
        "id": 44,
        "tier": "Tier 8: Executive Dashboard Questions",
        "question": "What is the estimated financial impact of today's suspicious activity?",
        "desc": "Calculates total 48-hour outflow at risk and compares with executive metrics.",
        "sql": """
            SELECT * FROM RISK_COPILOT.CURATED.V_EXECUTIVE_SUMMARY
        """
    },
    {
        "id": 45,
        "tier": "Tier 8: Executive Dashboard Questions",
        "question": "How many alerts require immediate investigation?",
        "desc": "Total count of critical account freeze alerts and pending STR drafts.",
        "sql": """
            SELECT RECOMMENDED_ACTION, COUNT(*) AS COUNT, SUM(OUTFLOW_AMT_48H) AS TOTAL_OUTFLOW_INR
            FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS
            GROUP BY RECOMMENDED_ACTION
            ORDER BY COUNT DESC
        """
    }
]

# ---------------- Sidebar ----------------
with st.sidebar:
    st.header("⚙️ Copilot Controls")
    st.button("🔄 Refresh Data & Cache", on_click=clear_cache, use_container_width=True)
    st.markdown("---")
    st.markdown("### 🏆 Ultimate WOW Scenario")
    if st.button("🚀 Run CUST-9821 SAR Demo", type="primary", use_container_width=True):
        st.session_state["selected_q_idx"] = 0
        st.session_state["execute_prompt"] = QUESTION_BANK[0]["question"]
    
    st.markdown("---")
    st.markdown("### 🛡️ Governance Guardrails")
    st.markdown(
        "- **Governed Semantics:** `RISK_INTELLIGENCE_SV`\n"
        "- **Policy Search:** Vector embeddings on FinCEN, PMLA, Basel III\n"
        "- **Citation Guardrail:** Unverified sections auto-masked\n"
        "- **Maker-Checker:** Enforced two-person review on SARs\n"
        "- **Audit Trail:** Immutable event log"
    )

# ---------------- Main Navigation Tabs ----------------
tab_chat, tab_fraud, tab_network, tab_liq, tab_credit, tab_cases = st.tabs([
    "💬 Copilot (45 Scenarios)",
    "🚨 Real-Time Fraud & AML",
    "🕸️ Network & Link Graph",
    "💧 Liquidity & Basel III",
    "📊 Credit Risk & EWS",
    "📋 Cases, SAR & Audit"
])

# ============================================================================
# TAB 1: Copilot Chat with Unified 45-Scenario Question Bank
# ============================================================================
with tab_chat:
    st.subheader("Governed Conversational Risk Intelligence")
    st.markdown("Select from the **45 Scenario Questions (Tiers 1–8 + WOW Demo)** or type any natural language prompt.")

    # Dropdown selector with all questions
    tiers_list = sorted(list(set(item["tier"] for item in QUESTION_BANK)))
    col_t, col_q = st.columns([1, 2])
    
    selected_tier = col_t.selectbox("Filter by Tier", ["All Tiers (46 Questions)"] + tiers_list)
    
    filtered_q_list = QUESTION_BANK if selected_tier == "All Tiers (46 Questions)" else [q_item for q_item in QUESTION_BANK if q_item["tier"] == selected_tier]
    
    q_labels = [f"[{item['tier'].split(':')[0]}] {item['question']}" for item in filtered_q_list]
    
    # Track selection index
    def_idx = 0
    if st.session_state.get("selected_q_idx") is not None:
        target_q = QUESTION_BANK[st.session_state["selected_q_idx"]]
        if target_q in filtered_q_list:
            def_idx = filtered_q_list.index(target_q)
            
    sel_idx = col_q.selectbox("Select Scenario Question", range(len(filtered_q_list)), format_func=lambda i: q_labels[i], index=def_idx)
    active_q = filtered_q_list[sel_idx]
    
    st.info(f"📌 **Scenario Context:** {active_q['desc']}")
    
    c_btn1, c_btn2 = st.columns([1, 1])
    ask_copilot_btn = c_btn1.button("⚡ Ask Copilot (Agent Reasoning)", type="primary", use_container_width=True)
    show_data_btn = c_btn2.button("📊 View Grounded Database Evidence", use_container_width=True)

    # Show Grounded SQL Data Evidence directly if toggled
    if show_data_btn:
        st.markdown("#### 🗄️ Grounded Database Query & Live Data Result")
        st.code(active_q["sql"].strip(), language="sql")
        res_df = q(active_q["sql"])
        st.dataframe(res_df, hide_index=True, use_container_width=True)

    if "chat_turns" not in st.session_state:
        st.session_state.chat_turns = []

    # Determine prompt from chat input or button click
    chat_input = st.chat_input("Ask any custom risk or compliance question...")
    prompt = None
    if chat_input:
        prompt = chat_input
    elif ask_copilot_btn:
        prompt = active_q["question"]
    elif st.session_state.get("execute_prompt"):
        prompt = st.session_state.pop("execute_prompt")

    # If a new query is submitted, process it immediately before rendering so it appears at the top
    if prompt:
        # Build conversation history for the agent context (oldest to newest)
        history = []
        for turn in st.session_state.chat_turns[-4:]:
            history.append({"role": "user", "content": [{"type": "text", "text": turn["user"]}]})
            if turn.get("assistant"):
                history.append({"role": "assistant", "content": [{"type": "text", "text": turn["assistant"]}]})
        history.append({"role": "user", "content": [{"type": "text", "text": prompt}]})

        with st.spinner("🤖 CoCo Agent orchestrating Analyst, Vector Search & Governance Tools..."):
            try:
                text, tools, cites = run_agent(history)
            except Exception as e:
                text, tools, cites = f"⚠️ Could not execute safely: `{e}`. Fallback to SQL and direct tabs.", [], []
        
        # Insert newest turn at the beginning of chat_turns (Top of the feed)
        new_turn = {
            "id": len(st.session_state.chat_turns) + 1,
            "user": prompt,
            "assistant": text or "_No response returned._",
            "tools": tools,
            "cites": cites
        }
        st.session_state.chat_turns.insert(0, new_turn)

    # ---------------- Render Chat Feed (Latest Query at the Top) ----------------
    if st.session_state.chat_turns:
        st.markdown("### 💬 Conversation Activity (Latest Query First)")
        for turn in st.session_state.chat_turns:
            with st.container():
                st.markdown(f"#### 🗨️ Query #{turn['id']}")
                with st.chat_message("user"):
                    st.markdown(turn["user"])
                
                with st.chat_message("assistant"):
                    st.markdown(turn["assistant"])
                    
                    # 1-Click Governance Action triggers for WOW scenario or high-risk finding
                    u_prompt = turn["user"]
                    if "CUST-9821" in u_prompt or "ACC0009821" in u_prompt or "file a sar" in u_prompt.lower():
                        st.markdown("---")
                        st.markdown("##### ⚡ 1-Click Governance Actions")
                        act_c1, act_c2, act_c3 = st.columns(3)
                        if act_c1.button("📝 Generate Official SAR Draft", key=f"wow_sar_{turn['id']}"):
                            with st.spinner("Generating governed STR draft with citation guardrail..."):
                                sar_res = call_proc("CALL RISK_COPILOT.APP.GENERATE_SAR_DRAFT(?)", ["ALR-ACC0009821"])
                                if sar_res.get("status") == "OK":
                                    st.success(f"Case {sar_res['case_id']} created and pending review!")
                                    st.markdown(sar_res["sar_draft"])
                                else:
                                    st.error(sar_res.get("message"))
                        if act_c2.button("🔗 Create Jira Investigation (MCP Mock)", key=f"wow_jira_{turn['id']}"):
                            st.info("🎟️ Jira Ticket Created: `COMP-8492` - *High Risk Structuring Investigation: Rajesh K. Verma (CUST-9821)*")
                        if act_c3.button("📦 Export Audit Package (JSON)", key=f"wow_export_{turn['id']}"):
                            audit_payload = q("SELECT * FROM RISK_COPILOT.CURATED.V_RECENT_HIGH_RISK_TXNS WHERE CUSTOMER_ID = 'CUST-9821'").to_json(orient="records")
                            st.download_button("Download JSON", audit_payload, file_name="AUDIT_PACKAGE_CUST9821.json", mime="application/json", key=f"dl_{turn['id']}")

                    for tl in turn.get("tools", []):
                        with st.expander(f"🔍 Evidence: {tl['name']} ({tl['status']})"):
                            st.json(tl["payload"], expanded=False)
                    if turn.get("cites"):
                        with st.expander(f"📚 Retrieved Regulatory & Policy Citations ({len(turn['cites'])})"):
                            for c in turn["cites"]:
                                st.markdown(f"- **{c.get('doc_title', '')}** — {c.get('text', '')[:300]}")
                st.markdown("---")

# ============================================================================
# TAB 2: Real-Time Fraud & AML Triage
# ============================================================================
with tab_fraud:
    st.subheader("🚨 Real-Time Fraud & AML Alert Queue")
    alerts = load("""
        SELECT ALERT_ID, ACCOUNT_ID, FULL_NAME, TYPOLOGY, RISK_SCORE, RECOMMENDED_ACTION, RED_FLAG_COUNT,
               INFLOW_AMT_48H, OUTFLOW_AMT_48H, KYC_RISK_RATING, OCCUPATION
        FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS 
        ORDER BY RISK_SCORE DESC, ALERT_ID
    """)
    
    k1, k2, k3, k4 = st.columns(4)
    k1.metric("Open Alerts", len(alerts))
    k2.metric("Critical Freeze Required", int((alerts.RECOMMENDED_ACTION == "FREEZE_ACCOUNT").sum()))
    k3.metric("48h Outflow at Risk", f"₹{alerts.OUTFLOW_AMT_48H.sum() / 1e5:,.1f} Lakh")
    k4.metric("Avg Risk Score", f"{alerts.RISK_SCORE.mean():.0f}/100" if len(alerts) else "–")

    f_typ = st.multiselect("Filter Typology", sorted(alerts.TYPOLOGY.unique()), default=sorted(alerts.TYPOLOGY.unique()))
    filtered_alerts = alerts[alerts.TYPOLOGY.isin(f_typ)]
    
    st.dataframe(
        filtered_alerts,
        hide_index=True,
        use_container_width=True,
        column_config={
            "RISK_SCORE": st.column_config.ProgressColumn("Risk Score", min_value=0, max_value=100, format="%d")
        }
    )

    st.markdown("---")
    st.subheader("🔍 Deep Alert Investigation & STR Generation")
    sel_alert = st.selectbox("Select Alert to Investigate", filtered_alerts.ALERT_ID.tolist() if len(filtered_alerts) else [])
    
    if sel_alert:
        det = q("SELECT RED_FLAGS, ACCOUNT_ID, TYPOLOGY, FULL_NAME, RECOMMENDED_ACTION FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS WHERE ALERT_ID = ?", [sel_alert])
        flags = json.loads(det.RED_FLAGS[0])
        
        col_left, col_right = st.columns([1, 1])
        with col_left:
            st.markdown(f"**Customer:** {det.FULL_NAME[0]} | **Account:** `{det.ACCOUNT_ID[0]}` | **Action:** `{det.RECOMMENDED_ACTION[0]}`")
            st.markdown("#### Red Flag → Policy Mapping")
            st.dataframe(pd.DataFrame(flags)[["flag", "policy", "weight", "evidence"]], hide_index=True, use_container_width=True)
            
        with col_right:
            st.markdown("#### Transaction Evidence Trail (10 Days)")
            txns = q("""
                SELECT TXN_ID, TXN_TS, DIRECTION, CHANNEL, AMOUNT_INR, COUNTERPARTY_ACCOUNT_ID, DEVICE_ID, IP_ADDRESS, GEO_COUNTRY
                FROM RISK_COPILOT.RAW.TRANSACTIONS 
                WHERE ACCOUNT_ID = ? AND TXN_TS >= DATEADD(day, -10, (SELECT MAX(TXN_TS) FROM RISK_COPILOT.RAW.TRANSACTIONS))
                ORDER BY TXN_TS DESC
            """, [det.ACCOUNT_ID[0]])
            st.dataframe(txns, hide_index=True, use_container_width=True, height=260)
            
        if st.button(f"📄 Generate STR / SAR Draft for {sel_alert}", type="primary"):
            with st.spinner("Assembling evidence, retrieving policies, drafting narrative, and checking citations..."):
                res = call_proc("CALL RISK_COPILOT.APP.GENERATE_SAR_DRAFT(?)", [sel_alert])
            if res.get("status") != "OK":
                st.error(res.get("message"))
            else:
                g = res["guardrail"]
                if g["passed"]:
                    st.success(f"✅ Case `{res['case_id']}` saved as PENDING_REVIEW · Citation Guardrail: PASSED · Confidence: {g.get('confidence')}")
                else:
                    st.warning(f"⚠️ Case `{res['case_id']}` saved as PENDING_REVIEW · Unverified citations masked: {g.get('unverified_citations')}")
                st.markdown(res["sar_draft"])
                st.markdown("#### 📋 Missing Documentation Checklist:")
                for d in res.get("missing_documents") or []:
                    st.markdown(f"- 🔲 {d}")
                clear_cache()

# ============================================================================
# TAB 3: Network & Fraud Ring Link Graph
# ============================================================================
with tab_network:
    st.subheader("🕸️ Network Graph & Fraud Ring Analysis")
    st.markdown("Detecting money mule networks, shared infrastructure (devices/IPs), and circular layering loops.")
    
    net_df = load("""
        SELECT SOURCE_NODE, SOURCE_CUST_ID, SOURCE_NAME, TARGET_NODE, TARGET_NAME, LINK_TYPE, TXN_COUNT, TOTAL_VOLUME_INR, LAST_ACTIVITY
        FROM RISK_COPILOT.CURATED.V_NETWORK_GRAPH
        ORDER BY TOTAL_VOLUME_INR DESC
    """)
    
    n1, n2, n3 = st.columns(3)
    n1.metric("Identified Network Links", len(net_df))
    n2.metric("Unique Entity Nodes", len(set(net_df.SOURCE_NODE.tolist() + net_df.TARGET_NODE.tolist())))
    n3.metric("Total Network Exposure", f"₹{net_df.TOTAL_VOLUME_INR.sum() / 1e5:,.1f} Lakh")

    st.dataframe(net_df, hide_index=True, use_container_width=True)
    
    st.markdown("---")
    st.subheader("🔎 Node Link Inspector")
    source_nodes = sorted(list(set(net_df.SOURCE_NODE.unique())))
    sel_node = st.selectbox("Inspect Connected Entity / Account", source_nodes if len(source_nodes) else [])
    
    if sel_node:
        sub_net = net_df[(net_df.SOURCE_NODE == sel_node) | (net_df.TARGET_NODE == sel_node)]
        st.markdown(f"**Connected Relationships for `{sel_node}`:**")
        st.dataframe(sub_net, hide_index=True, use_container_width=True)

# ============================================================================
# TAB 4: Liquidity & Basel III (ALM)
# ============================================================================
with tab_liq:
    st.subheader("💧 Basel III Liquidity Coverage Ratio (LCR) & Stress Testing")
    lcr = load("SELECT * FROM RISK_COPILOT.CURATED.DT_LCR_DAILY ORDER BY AS_OF_DATE")
    last = lcr.iloc[-1]
    
    l1, l2, l3, l4 = st.columns(4)
    l1.metric("Current LCR", f"{last.LCR_PCT:.1f}%", f"{last.LCR_PCT - lcr.iloc[-8].LCR_PCT:+.1f}% vs 7d")
    l2.metric("ALM Status", last.LCR_STATUS)
    l3.metric("HQLA Stock", f"₹{last.HQLA_STOCK / 1e7:,.0f} Cr")
    l4.metric("30-Day Net Outflows", f"₹{last.NET_CASH_OUTFLOWS_30D / 1e7:,.0f} Cr")

    chart = lcr[["AS_OF_DATE", "LCR_PCT"]].copy()
    chart["INTERNAL_FLOOR_110"] = 110.0
    chart["REGULATORY_MIN_100"] = 100.0
    st.line_chart(chart.set_index("AS_OF_DATE"))

    c_g1, c_g2 = st.columns([1, 1])
    with c_g1:
        st.subheader("Structural Liquidity Gap (₹ Cr)")
        gap_df = pd.DataFrame({
            "Maturity Bucket": ["1-7 Days", "8-14 Days", "15-30 Days"],
            "Net Cash Outflow": [last.NET_OUT_1_7D / 1e7, last.NET_OUT_8_14D / 1e7, last.NET_OUT_15_30D / 1e7]
        }).set_index("Maturity Bucket")
        st.bar_chart(gap_df)

    with c_g2:
        st.subheader("⚡ Parameterized Stress Simulation (ALM-POL 6.2)")
        rr = st.slider("Retail Deposit Run-off (%)", 0, 50, 15)
        mk = st.slider("Level 2A Asset Haircut Markdown (%)", 0, 60, 30)
        wr = st.slider("Wholesale Non-Operational Outflow (%)", 0, 100, 0)
        
        if st.button("Run Simulation", type="primary"):
            r = call_proc("CALL RISK_COPILOT.APP.RUN_LIQUIDITY_STRESS(?, ?, ?)", [float(rr), float(mk), float(wr)])
            r1, r2, r3 = st.columns(3)
            r1.metric("Baseline LCR", f"{r['baseline_lcr_pct']}%")
            r2.metric("Stressed LCR", f"{r['stressed_lcr_pct']}%", f"{r['stressed_lcr_pct'] - r['baseline_lcr_pct']:+.1f}%")
            r3.metric("Shortfall to 110% Buffer", f"₹{r['hqla_shortfall_to_110pct_inr_cr']:,.0f} Cr")
            st.caption(f"Policy Basis: {', '.join(r['policy_refs'])} | Logged to Immutable Audit Log.")

# ============================================================================
# TAB 5: Credit Risk & EWS
# ============================================================================
with tab_credit:
    st.subheader("📊 Early Warning System (EWS) & Portfolio Health")
    ews = load("""
        SELECT LOAN_ID, FULL_NAME, SEGMENT, PRODUCT, INDUSTRY, OUTSTANDING, DPD, ASSET_CLASS, IFRS9_STAGE,
               EWS_TRIGGER_COUNT, ARRAY_TO_STRING(EWS_TRIGGERS, '; ') AS EWS_TRIGGERS, EWS_ACTION
        FROM RISK_COPILOT.CURATED.DT_LOAN_EWS
    """)
    total_exp = ews.OUTSTANDING.sum()
    
    cr1, cr2, cr3 = st.columns(3)
    cr1.metric("Gross NPA Ratio", f"{100 * ews[ews.DPD > 90].OUTSTANDING.sum() / total_exp:.2f}%")
    cr2.metric("SMA-0/1/2 Stressed Exposure", f"₹{ews[(ews.DPD > 0) & (ews.DPD <= 90)].OUTSTANDING.sum() / 1e7:,.0f} Cr")
    cr3.metric("Credit Committee Referrals", int((ews.EWS_ACTION == "RESTRUCTURING_DISCUSSION_CREDIT_COMMITTEE").sum()))

    st.subheader("Industry Sector Concentration vs Policy Limits (CR-POL 7.1)")
    conc_df = load("SELECT * FROM RISK_COPILOT.CURATED.V_INDUSTRY_CONCENTRATION ORDER BY SHARE_PCT DESC")
    st.dataframe(conc_df, hide_index=True, use_container_width=True)

    st.subheader("EWS Stressed Borrower Watchlist")
    sel_class = st.multiselect("Filter Asset Class", ["SMA-0", "SMA-1", "SMA-2", "NPA"], default=["SMA-2", "NPA"])
    st.dataframe(ews[ews.ASSET_CLASS.isin(sel_class)].sort_values("OUTSTANDING", ascending=False), hide_index=True, use_container_width=True)

# ============================================================================
# TAB 6: Cases, SAR Maker-Checker & Audit
# ============================================================================
with tab_cases:
    st.subheader("📋 Investigation Cases & Human-in-the-Loop Review")
    cases = q("""
        SELECT CASE_ID, ALERT_ID, TYPOLOGY, RISK_SCORE, STATUS, ACTION_TAKEN, 
               GUARDRAIL_RESULT:passed::BOOLEAN AS GUARDRAIL_PASSED,
               CREATED_BY, CREATED_AT, REVIEWED_BY, REVIEW_DECISION 
        FROM RISK_COPILOT.APP.CASES 
        ORDER BY CREATED_AT DESC
    """)
    st.dataframe(cases, hide_index=True, use_container_width=True)

    if len(cases):
        st.markdown("---")
        st.subheader("⚖️ Checker Disposition Panel")
        sel_case = st.selectbox("Select Case to Review", cases.CASE_ID.tolist())
        row = q("SELECT SAR_DRAFT, MISSING_DOCS, GUARDRAIL_RESULT, STATUS FROM RISK_COPILOT.APP.CASES WHERE CASE_ID = ?", [sel_case])
        
        with st.expander("📄 View Generated STR / SAR Narrative", expanded=True):
            st.markdown(row.SAR_DRAFT[0] or "_No draft available._")
        with st.expander("🛡️ Citation Guardrail Details"):
            st.json(json.loads(row.GUARDRAIL_RESULT[0]))

        d_col1, d_col2 = st.columns([1, 2])
        dec = d_col1.radio("Checker Action", ["APPROVE_FOR_FILING", "REQUEST_INFO", "REJECT"])
        note = d_col2.text_area("Compliance Review Notes (Mandatory for Audit Trail)")
        
        if st.button("Submit Checker Decision", disabled=not note.strip(), type="primary"):
            rev_res = call_proc("CALL RISK_COPILOT.APP.REVIEW_CASE(?, ?, ?)", [sel_case, dec, note])
            if rev_res.get("status") == "OK":
                st.success(f"Case `{sel_case}` successfully updated to `{dec}`!")
                clear_cache()
            else:
                st.error(rev_res.get("message"))

    st.markdown("---")
    st.subheader("📜 Immutable Compliance Audit Trail")
    audit = q("SELECT EVENT_TS, EVENT_USER, EVENT_ROLE, EVENT_TYPE, OBJECT_ID, DETAILS FROM RISK_COPILOT.APP.AUDIT_LOG ORDER BY EVENT_TS DESC LIMIT 150")
    st.dataframe(audit, hide_index=True, use_container_width=True)
