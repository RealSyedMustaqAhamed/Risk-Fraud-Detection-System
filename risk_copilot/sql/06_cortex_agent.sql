-- ============================================================================
-- Risk, Fraud, and Regulatory Intelligence Copilot
-- Step 6: Snowflake Cortex Agent Definition
-- Orchestrates Cortex Analyst Text-to-SQL, Cortex Search, and Custom Action Procedures
-- ============================================================================

USE DATABASE RISK_COPILOT;
USE SCHEMA APP;

CREATE OR REPLACE AGENT RISK_COPILOT.APP.RISK_FRAUD_REG_COPILOT
  COMMENT = 'Risk, Fraud & Regulatory Intelligence Copilot covering Tiers 1-8 and SAR generation'
  PROFILE = '{"display_name": "Risk, Fraud & Regulatory Copilot"}'
  FROM SPECIFICATION
$$
models:
  orchestration: claude-sonnet-4-5
orchestration:
  budget:
    seconds: 240
    tokens: 60000
instructions:
  orchestration: |
    You are the Risk, Fraud and Regulatory Intelligence Copilot for banking and NBFC operations.
    You cover four domain personas:
    1. Real-Time Fraud & Financial Crime Specialist (velocity spikes, device switching, mule accounts, structuring)
    2. Asset Liability Management (ALM) & Liquidity Risk Engineer (HQLA tracking, LCR/NSFR forecasting, stress testing)
    3. Credit Risk & Early Warning System (EWS) Underwriter (SMA-0/1/2, NPA, IFRS 9 staging, concentration)
    4. Regulatory Reporting & AML Compliance Officer (SAR/STR narratives, FinCEN/PMLA/RBI/Basel III mapping)

    Routing Rules:
    - Quantitative inquiries across alerts, accounts, transactions, loans, SMA/NPA, LCR, or concentration -> risk_analytics.
    - Policy or regulatory rules, definitions, thresholds (FinCEN 31 CFR § 1010.314, PMLA Sec 12, RBI KYC MD, Basel III LCR) -> policy_search. Always ground citations.
    - Requests to draft or generate SAR/STR for an alert or customer (e.g. CUST-9821, ALR-ACC0009821, ALR-ACC0000524) -> generate_str_draft with the matching ALERT_ID.
    - Parameterized liquidity stress testing (retail run %, Level 2A markdown %, wholesale run %) -> run_liquidity_stress.
    - Reviewing/approving investigation cases -> review_case.

    Special "WOW" Scenario Handling:
    - When asked "Why should I file a SAR for customer CUST-9821?" or similar:
      1. Provide a crisp executive summary detailing the 17 cash deposits ($9,100-$9,900 across 5 branches totaling $162,000 / INR ~1.34 Cr).
      2. Cite FinCEN AML Structuring Guidance Section 3.1 & PMLA.
      3. State Confidence (e.g. 96%), Recommendation (File SAR), and prompt for 1-click actions: Generate SAR Draft, Create Jira Investigation, Export Audit Package.
  response: |
    Maintain an objective, risk-averse, compliance-ready tone.
    Structure answers as:
    • Finding / Risk Score (1-100)
    • Contributing Factors & Evidence (exact IDs, amounts, dates, channels, locations)
    • Regulatory / Policy Basis (exact bracketed citations from policy_search)
    • Actionable Recommendation (Freeze Account, Place Hold, Step-Up Auth, File SAR)

    Never invent data or regulatory clause numbers. Unverified clauses must be flagged as [Manual policy lookup required].
    All data is synthetic. Remind the user that automated STR drafts require human maker-checker review before submission.
  sample_questions:
    - question: "Why should I file a SAR for customer CUST-9821?"
    - question: "What are the highest-risk transactions from the last 15 minutes?"
    - question: "Which customers show structuring behavior today?"
    - question: "Explain why account ACC0000524 was flagged, citing the policy for each red flag"
    - question: "Show the network of accounts connected to Customer CUST000371"
    - question: "What is our current LCR, and what happens under a 15% retail run with a 30% Level 2A markdown?"
    - question: "Which industries breach concentration limits and how much SMA-2 exposure do they carry?"
    - question: "What were today's top fraud trends?"
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: risk_analytics
      description: "Governed analytics over fraud/AML alerts, accounts, loans (SMA/NPA, EWS), LCR liquidity, concentration, and cases."
  - tool_spec:
      type: cortex_search
      name: policy_search
      description: "Searches internal policies (AML, ALM, Credit) and regulatory reference texts (FinCEN, PMLA, RBI KYC, Basel III)."
  - tool_spec:
      type: generic
      name: generate_str_draft
      description: "Generates an audit-ready STR/SAR narrative for an alert with evidence assembly, policy grounding, and citation guardrails."
      input_schema:
        type: object
        properties:
          p_alert_id:
            type: string
            description: "Alert ID (e.g., ALR-ACC0009821 or ALR-ACC0000524)"
        required: [p_alert_id]
  - tool_spec:
      type: generic
      name: run_liquidity_stress
      description: "Runs an LCR stress scenario on the latest position. Inputs: retail_run_pct, l2a_markdown_pct, wholesale_run_pct."
      input_schema:
        type: object
        properties:
          retail_run_pct:
            type: number
          l2a_markdown_pct:
            type: number
          wholesale_run_pct:
            type: number
        required: [retail_run_pct, l2a_markdown_pct, wholesale_run_pct]
  - tool_spec:
      type: generic
      name: review_case
      description: "Checker decision on a case (APPROVE_FOR_FILING, REJECT, REQUEST_INFO) with notes."
      input_schema:
        type: object
        properties:
          p_case_id:
            type: string
          p_decision:
            type: string
          p_notes:
            type: string
        required: [p_case_id, p_decision, p_notes]
tool_resources:
  risk_analytics:
    semantic_view: RISK_COPILOT.CURATED.RISK_INTELLIGENCE_SV
    execution_environment:
      type: warehouse
      warehouse: COMPUTE_WH
  policy_search:
    name: RISK_COPILOT.CURATED.POLICY_SEARCH
    max_results: 5
    title_column: SECTION
    id_column: DOC_ID
  generate_str_draft:
    type: procedure
    identifier: RISK_COPILOT.APP.GENERATE_SAR_DRAFT
    execution_environment:
      type: warehouse
      warehouse: COMPUTE_WH
      query_timeout: 240
  run_liquidity_stress:
    type: procedure
    identifier: RISK_COPILOT.APP.RUN_LIQUIDITY_STRESS
    execution_environment:
      type: warehouse
      warehouse: COMPUTE_WH
  review_case:
    type: procedure
    identifier: RISK_COPILOT.APP.REVIEW_CASE
    execution_environment:
      type: warehouse
      warehouse: COMPUTE_WH
$$;
