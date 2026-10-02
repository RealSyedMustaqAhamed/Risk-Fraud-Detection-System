# 🛡️ Risk, Fraud, and Regulatory Intelligence Copilot
**Architecture Focus:** Snowflake Cortex (CoCo, Analyst, Search, Agents) & Streamlit in Snowflake (SiS)  
**Target Domain:** Banking & NBFC Risk, Fraud, Compliance, and Liquidity (ALM) Teams  

---

## 📑 Table of Contents
1. [Executive Summary & Problem Statement](#executive-summary)
2. [End-to-End Solution Architecture](#architecture)
3. [Project Directory Structure](#project-structure)
4. [Data Model, Ontology & Synthetic Scenarios](#data-model)
5. [The 45 Scenario Question Bank (Tiers 1–8 + Ultimate WOW Demo)](#question-bank)
6. [Snowflake CoCo Full Lifecycle Demonstration](#coco-lifecycle)
7. [Governance, Guardrails & Maker-Checker Compliance](#governance)
8. [Setup & Step-by-Step Execution Guide](#setup-guide)

---

<a name="executive-summary"></a>
## 1. Executive Summary & Problem Statement

Banking and NBFC compliance teams face immense friction in managing financial crime and regulatory oversight:
- **Fragmented Data Silos:** Transaction logs, device fingerprints, core banking ledgers, and credit repayment histories live in disparate tables.
- **Manual Regulatory Triaging:** Identifying structuring (smurfing), money mule rings, and circular layering requires hours of manual spreadsheet analysis.
- **Hallucination Risk in GenAI:** Generic LLMs invent transactions, dates, and non-existent regulatory clauses (e.g. hallucinating section numbers).
- **Audit Deficits:** Reports lack complete provenance linking raw data to policy texts and human approval records.

**The Solution:** An enterprise-grade **Risk, Fraud, and Regulatory Intelligence Copilot** built natively on **Snowflake Cortex**. It unifies structured transactional data with unstructured regulatory circulars (FinCEN, PMLA, RBI KYC, Basel III), providing **governed, explainable, evidence-backed answers** and automating the entire flow from **Signal → Evidence → Documented Finding / SAR Filing**.

---

<a name="architecture"></a>
## 2. End-to-End Solution Architecture

```
                                  ┌────────────────────────────────────────────────────────┐
                                  │                  USER INTERFACES                       │
                                  │  • Snowsight Cortex Chat / CoCo CLI                    │
                                  │  • Streamlit in Snowflake (SiS) Web App               │
                                  └──────────────────────────┬─────────────────────────────┘
                                                             │
                                                             ▼
                                  ┌────────────────────────────────────────────────────────┐
                                  │             SNOWFLAKE CORTEX AGENT                     │
                                  │      (RISK_COPILOT.APP.RISK_FRAUD_REG_COPILOT)         │
                                  │           Orchestrator: claude-sonnet-4-5              │
                                  └──────┬───────────────────┬───────────────────┬─────────┘
                                         │                   │                   │
                     ┌───────────────────┴───────┐   ┌───────┴──────────┐   ┌────┴─────────────────┐
                     │      Cortex Analyst       │   │  Cortex Search   │   │  Governed Procedures │
                     │   (Semantic View Text-    │   │  (Vector Search  │   │  • GENERATE_SAR_DRAFT│
                     │         to-SQL)           │   │  over Policies)  │   │  • RUN_LIQUIDITY_    │
                     └─────────────┬─────────────┘   └─────────┬────────┘   │    STRESS            │
                                   │                           │            │  • REVIEW_CASE       │
                                   ▼                           ▼            └──────────┬───────────┘
┌──────────────────────────────────────────────────────────────────────────────────────┴───────────┐
│                                   SNOWFLAKE ENGINE & STORAGE                                     │
│  ┌────────────────────────┐  ┌──────────────────────────────┐  ┌──────────────────────────────┐  │
│  │     RAW DATA LAYER     │  │     CURATED / PIPELINES      │  │      APP & GOVERNANCE        │  │
│  │ • CUSTOMERS (2,000)    │  │ • DT_ACCOUNT_SIGNALS (15m)   │  │ • CASES (Maker-Checker)      │  │
│  │ • ACCOUNTS (2,797)     │  │ • DT_FRAUD_ALERTS (15m)      │  │ • AUDIT_LOG (Immutable)      │  │
│  │ • TRANSACTIONS (150k+) │  │ • DT_LOAN_EWS (1h)           │  │ • VALIDATE_CITATIONS (UDF)   │  │
│  │ • LOANS (797)          │  │ • DT_LCR_DAILY (1h)          │  │ • T_AUTO_TRIAGE (Task)       │  │
│  │ • POLICY_DOCS (18 chunks│ │ • V_NETWORK_GRAPH            │  │ • V_VALIDATION_RESULTS (13/13)│ │
│  └────────────────────────┘  └──────────────────────────────┘  └──────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

<a name="project-structure"></a>
## 3. Project Directory Structure

```
risk_copilot/
├── README.md                                  # Complete architecture & scenario documentation
├── data/
│   └── scenarios_45_question_bank.json        # Full 45-question test bank across 8 tiers
├── sql/
│   ├── 01_setup_database_and_schemas.sql      # Database, schemas, stages setup
│   ├── 02_synthetic_data_generation.sql       # 150k+ transactions, mules, structuring, loans, policies
│   ├── 03_pipelines_and_dynamic_tables.sql    # Dynamic tables, alerts, EWS, LCR, network graph
│   ├── 04_search_and_semantic_model.sql       # Cortex Search service & Semantic View
│   ├── 05_procedures_and_governance.sql       # SAR generator, citation validator, stress test, cases
│   ├── 06_cortex_agent.sql                    # Cortex Agent specification
│   └── 07_automated_tasks_and_validation.sql  # Scheduled auto-triage task & 13 validation tests
└── risk_copilot_app/
    ├── streamlit_app.py                       # Multi-tab Streamlit Copilot UI (Python 3.11)
    ├── environment.yml                        # Snowflake dependencies (Streamlit 1.52.0)
    └── snowflake.yml                          # Deployment configuration manifest
```

---

<a name="data-model"></a>
## 4. Data Model, Ontology & Synthetic Scenarios

### Curated Entity Model
1. **Accounts & Customers (`DT_ACCOUNT_SIGNALS`):** Tracks rolling 48-hour inflow/outflow, distinct remitters, pass-through ratios, device switching counts, and risky/foreign IP occurrences.
2. **Explainable Fraud Alerts (`DT_FRAUD_ALERTS`):** Scores risk (1-100) and maps each red flag to specific internal policy sections:
   - `AML-POL 4.2(a)`: New/Dormant Account Burst Inflow
   - `AML-POL 4.2(b)`: Multi-Remitter Aggregation (15+ distinct remitters in 48h)
   - `AML-POL 4.2(c)`: Rapid Pass-Through (80%+ outward transfer within 24h)
   - `AML-POL 4.2(d)`: Device/IP Anomaly (4+ devices or foreign/risky IPs)
   - `AML-POL 4.2(e)`: Profile Mismatch (Inflow > 50% declared annual income)
   - `AML-POL 4.3`: Structuring / Smurfing (3+ cash deposits ₹9L–₹10L / $9k–$10k)
   - `AML-POL 4.4`: Round-Tripping (Circular fund flow completed in 72h)
   - `AML-POL 7.1`: Sanctions / Watchlist Match (Match score >= 0.85)
3. **Credit Risk EWS (`DT_LOAN_EWS`):** Classifies loans into `STANDARD`, `SMA-0` (1-30 DPD), `SMA-1` (31-60 DPD), `SMA-2` (61-90 DPD), and `NPA` (>90 DPD), evaluating IFRS 9 staging and EWS trigger counts.
4. **Basel III Liquidity (`DT_LCR_DAILY`):** Computes daily Stock of HQLA (Level 1, Level 2A with 15% haircut, Level 2B with 50% haircut, applying 40% and 15% caps) against 30-day net stressed outflows (with 75% inflow cap).

---

<a name="question-bank"></a>
## 5. The 45 Scenario Question Bank

### 🏆 Ultimate "WOW" Demo Scenario
**Question:** `"Why should I file a SAR for customer CUST-9821?"`
```
-----------------------------------------------------------------------------------------
Customer CUST-9821 (Rajesh K. Verma) triggered a HIGH-RISK AML structuring alert (Score: 96/100).

Risk Indicators:
• 17 cash deposits within 48 hours
• Each deposit between $9,100 and $9,900 (INR 9.1 Lakh - 9.9 Lakh)
• Executed across 5 distinct branches (South Mumbai, Andheri, Bandra, Fort, BKC)
• Total value: $162,000 (INR ~1.34 Crore)

Regulatory Basis:
• FinCEN AML Structuring Guidance Section 3.1 (31 CFR § 1010.314)
• PMLA Section 12 & RBI KYC Master Direction (CTR threshold avoidance)

Supporting Evidence:
• Transaction IDs: TXS-9821-01 through TXS-9821-17
• Branch Counters & Timestamps: 2026-09-27 09:15 to 2026-09-28 21:30

Recommendation: FILE SAR / FREEZE DEBITS
[1-Click Actions Available]: 📝 Generate SAR Draft | 🔗 Create Jira Ticket | 📦 Export Audit Package
-----------------------------------------------------------------------------------------
```

### Tier 1: Real-Time Fraud Detection Questions
1. *What are the highest-risk transactions from the last 15 minutes?*
2. *Which customers show structuring behavior today?*
3. *Show accounts whose transaction velocity is 5x above their normal behavior.*
4. *Which transactions deviate significantly from the customer's historical pattern?*
5. *Identify newly opened accounts involved in large fund transfers.*
6. *Which transactions originated from unusual geographies or devices?*
7. *Show linked accounts participating in potential fraud rings.*
8. *Which customers trigger multiple fraud rules simultaneously?*

### Tier 2: AML & SAR Triage Questions
9. *Which customers should be reviewed for Suspicious Activity Reports (SAR)?*
10. *Why was Customer A flagged for AML review?*
11. *Show all layering patterns detected this week.*
12. *Which transactions exhibit money mule characteristics?*
13. *Identify accounts connected to sanctioned entities.*
14. *Which alerts have enough evidence to file a SAR?*

### Tier 3: Explainability & AI Reasoning Questions
15. *Explain why Transaction TXN-12345 was flagged.*
16. *Explain why account ACC0000524 was flagged, citing the policy for each red flag.*
17. *Show all evidence supporting this fraud alert.*
18. *Which regulations apply to this transaction?*
19. *What policy violations have occurred?*

### Tier 4: Network & Fraud Ring Analysis
20. *Show the network of accounts connected to Customer CUST000371.*
21. *Identify possible fraud rings operating this week.*
22. *Which customers share devices, addresses, IPs, or phone numbers with known fraudsters?*
23. *Visualize transactional relationships around this suspicious account.*
24. *Find hidden connections between flagged transactions.*

### Tier 5: Credit Risk & EWS Questions
25. *Which borrowers have experienced rapid credit deterioration?*
26. *Show customers whose repayment behavior changed significantly.*
27. *Which accounts are likely to default within the next 30 days?*
28. *Explain why this borrower received a high-risk rating.*
29. *Which loans require immediate review?*

### Tier 6: Liquidity & Basel III Reporting
30. *Is today's Liquidity Coverage Ratio within Basel requirements?*
31. *What is our current LCR, and what happens under a 15% retail run with a 30% Level 2A markdown?*
32. *Explain the factors causing today's LCR decline.*
33. *Which assets contribute most to liquidity stress?*
34. *Generate today's Basel III compliance summary.*

### Tier 7: Audit & Compliance Questions
35. *Generate an audit-ready explanation for Alert #ALR-ACC0000524.*
36. *Produce regulator-ready documentation for Customer CUST-9821.*
37. *Show the complete evidence trail for this alert.*
38. *Which source documents support this compliance finding?*
39. *Generate a case summary for investigator review.*
40. *Create a documented finding with citations.*

### Tier 8: Executive Dashboard & Trend Questions
41. *What were today's top fraud trends?*
42. *Show fraud exposure by business unit.*
43. *Which fraud typologies are increasing this month?*
44. *What is the estimated financial impact of today's suspicious activity?*
45. *How many alerts require immediate investigation?*

---

<a name="coco-lifecycle"></a>
## 6. Snowflake CoCo Full Lifecycle Demonstration

| Phase | CoCo Tooling & Capabilities Used | Outcome |
|---|---|---|
| **Planning** | CoCo Prompt Design, Data Modeling & Ontology Structuring | Schema architecture with 3-layer design (RAW, CURATED, APP). |
| **Development** | Dynamic Tables, SQL UDFs, Stored Procedures, Semantic Views | Incremental continuous pipelines, rule weights, and verified queries. |
| **Execution** | Cortex Agent (`claude-sonnet-4-5`), Cortex Search, Streamlit | Natural language routing across structured SQL, vector text, and procedures. |
| **Testing** | Automated 13-Test Validation View (`V_VALIDATION_RESULTS`) | 100% pass rate on recall, data integrity, and citation guardrails. |
| **Automation** | Snowflake Scheduled Tasks (`T_AUTO_TRIAGE`) | Unattended hourly triage with bounded LLM execution and audit logging. |

---

<a name="governance"></a>
## 7. Governance, Guardrails & Maker-Checker Compliance

1. **Citation Grounding Guardrail (`VALIDATE_CITATIONS` UDF):**
   - The LLM output is parsed with regular expressions looking for clause patterns (e.g. `[AML-POL 4.2]`, `Section 45-IA`).
   - Every citation is verified against the text chunks retrieved from `POLICY_SEARCH`.
   - Any hallucinated or unverified clause is replaced with `[MANUAL POLICY LOOKUP REQUIRED: <clause>]`.
2. **Two-Person Maker-Checker Rule (`REVIEW_CASE`):**
   - The investigator who drafted the case cannot approve it for filing unless authorized under strict admin overrides.
   - All reviews require mandatory reviewer notes and are committed to `RISK_COPILOT.APP.AUDIT_LOG`.
3. **Strict No-Tipping-Off Compliance:**
   - Enforced by system prompt instructions and policy references under PMLA / FinCEN rules.

---

<a name="setup-guide"></a>
## 8. Setup & Step-by-Step Execution Guide

### Step 1: Execute SQL Scripts in Snowflake
Run the SQL files in order using Snowsight or Snowflake CLI:
```bash
snow sql -f sql/01_setup_database_and_schemas.sql
snow sql -f sql/02_synthetic_data_generation.sql
snow sql -f sql/03_pipelines_and_dynamic_tables.sql
snow sql -f sql/04_search_and_semantic_model.sql
snow sql -f sql/05_procedures_and_governance.sql
snow sql -f sql/06_cortex_agent.sql
snow sql -f sql/07_automated_tasks_and_validation.sql
```

### Step 2: Deploy & Open the Streamlit App
1. In Snowsight, navigate to **Projects » Streamlit**.
2. Select **`RISK_COPILOT_APP`** (Database: `RISK_COPILOT`, Schema: `APP`).
3. Click **Run** to open the interactive copilot dashboard.

### Step 3: Run Validation Suite
Verify solution completeness directly in SQL:
```sql
SELECT * FROM RISK_COPILOT.APP.V_VALIDATION_RESULTS;
```
*Expected: 13/13 PASS.*
