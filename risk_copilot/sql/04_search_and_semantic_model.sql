-- ============================================================================
-- Risk, Fraud, and Regulatory Intelligence Copilot
-- Step 4: Cortex Search Service and Semantic Model
-- Covers: POLICY_SEARCH Cortex Search Service and RISK_INTELLIGENCE_SV Semantic View
-- ============================================================================

USE DATABASE RISK_COPILOT;
USE SCHEMA CURATED;

-- 1. Cortex Search Service over Regulatory and Internal Policy Documents
CREATE OR REPLACE CORTEX SEARCH SERVICE RISK_COPILOT.CURATED.POLICY_SEARCH
  ON CHUNK_TEXT
  ATTRIBUTES DOMAIN, DOC_TYPE, SECTION, DOC_TITLE
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 day'
  AS SELECT DOC_ID, DOC_TITLE, DOC_TYPE, SECTION, DOMAIN, EFFECTIVE_DATE, CHUNK_TEXT FROM RISK_COPILOT.RAW.POLICY_DOCS;

-- 2. Semantic View for Cortex Analyst Text-to-SQL
CREATE OR REPLACE SEMANTIC VIEW RISK_COPILOT.CURATED.RISK_INTELLIGENCE_SV
  TABLES (
    alerts AS RISK_COPILOT.CURATED.DT_FRAUD_ALERTS PRIMARY KEY (ALERT_ID) WITH SYNONYMS ('fraud alerts','AML alerts','suspicious accounts') COMMENT = 'Explainable fraud/AML alerts with red flags mapped to policy sections',
    signals AS RISK_COPILOT.CURATED.DT_ACCOUNT_SIGNALS PRIMARY KEY (ACCOUNT_ID) COMMENT = 'Per-account behavioural signals for all deposit accounts',
    loans AS RISK_COPILOT.CURATED.DT_LOAN_EWS PRIMARY KEY (LOAN_ID) WITH SYNONYMS ('loan book','credit portfolio','borrowers') COMMENT = 'Loan book with SMA/NPA class, IFRS9 stage and EWS triggers',
    lcr AS RISK_COPILOT.CURATED.DT_LCR_DAILY PRIMARY KEY (AS_OF_DATE) WITH SYNONYMS ('liquidity','liquidity coverage','ALM') COMMENT = 'Daily Basel III LCR, stress LCR and liquidity gap buckets. One row per date.',
    conc AS RISK_COPILOT.CURATED.V_INDUSTRY_CONCENTRATION PRIMARY KEY (INDUSTRY) WITH SYNONYMS ('concentration','sector exposure') COMMENT = 'Industry exposure concentration vs policy limits',
    cases AS RISK_COPILOT.APP.CASES PRIMARY KEY (CASE_ID) WITH SYNONYMS ('investigations','STR drafts','SAR') COMMENT = 'Investigation cases and STR drafts'
  )
  RELATIONSHIPS (
    alerts_to_signals AS alerts (ACCOUNT_ID) REFERENCES signals,
    cases_to_alerts AS cases (ALERT_ID) REFERENCES alerts
  )
  FACTS (
    alerts.risk_score_f AS RISK_SCORE, alerts.inflow_48h AS INFLOW_AMT_48H, alerts.outflow_48h AS OUTFLOW_AMT_48H,
    signals.inflow_amt_48h_f AS INFLOW_AMT_48H,
    loans.outstanding_f AS OUTSTANDING, loans.sanctioned_limit_f AS SANCTIONED_LIMIT, loans.dpd_f AS DPD,
    lcr.lcr_pct_f AS LCR_PCT, lcr.lcr_stress_f AS LCR_STRESS_S1_PCT, lcr.hqla_f AS HQLA_STOCK, lcr.net_outflows_f AS NET_CASH_OUTFLOWS_30D,
    lcr.gap_1_7_f AS NET_OUT_1_7D, lcr.gap_8_14_f AS NET_OUT_8_14D, lcr.gap_15_30_f AS NET_OUT_15_30D,
    conc.share_pct_f AS SHARE_PCT, conc.outstanding_inr_f AS OUTSTANDING_INR
  )
  DIMENSIONS (
    alerts.alert_id AS ALERT_ID, alerts.account_id AS ACCOUNT_ID, alerts.customer_id AS CUSTOMER_ID, alerts.customer_name AS FULL_NAME WITH SYNONYMS = ('customer','name'),
    alerts.typology AS TYPOLOGY WITH SYNONYMS = ('fraud type','alert type','scheme') COMMENT = 'MONEY_MULE, AML_LAYERING (structuring/round-tripping), SANCTIONS, OTHER',
    alerts.recommended_action AS RECOMMENDED_ACTION COMMENT = 'FREEZE_ACCOUNT, PLACE_HOLD, STEP_UP_AUTH, REVIEW_AND_CLEAR',
    alerts.kyc_risk AS KYC_RISK_RATING, alerts.segment AS SEGMENT, alerts.flag_names AS FLAG_NAMES COMMENT = 'Array of red flag codes',
    alerts.alert_risk_score AS RISK_SCORE COMMENT = 'Alert risk score 1-100',
    signals.city AS CITY, signals.occupation AS OCCUPATION, signals.account_type AS ACCOUNT_TYPE, signals.watchlist_hit AS WATCHLIST_HIT,
    loans.loan_id AS LOAN_ID, loans.borrower AS FULL_NAME, loans.product AS PRODUCT, loans.industry AS INDUSTRY WITH SYNONYMS = ('sector'),
    loans.loan_segment AS SEGMENT, loans.asset_class AS ASSET_CLASS WITH SYNONYMS = ('SMA bucket','NPA status') COMMENT = 'STANDARD, SMA-0, SMA-1, SMA-2, NPA',
    loans.ifrs9_stage AS IFRS9_STAGE, loans.ews_action AS EWS_ACTION, loans.collateral_type AS COLLATERAL_TYPE, loans.ews_trigger_count AS EWS_TRIGGER_COUNT,
    lcr.as_of_date AS AS_OF_DATE WITH SYNONYMS = ('date','reporting date'), lcr.lcr_status AS LCR_STATUS COMMENT = 'GREEN, AMBER_ALCO (<115), RED_CFP_TRIGGER (<110), REGULATORY_BREACH (<100)',
    conc.conc_industry AS INDUSTRY, conc.conc_status AS STATUS, conc.limit_pct AS LIMIT_PCT,
    cases.case_id AS CASE_ID, cases.case_status AS STATUS, cases.case_typology AS TYPOLOGY, cases.created_at AS CREATED_AT, cases.reviewed_by AS REVIEWED_BY
  )
  METRICS (
    alerts.alert_count AS COUNT(alerts.alert_id),
    alerts.avg_risk_score AS AVG(alerts.risk_score_f),
    alerts.total_inflow_48h AS SUM(alerts.inflow_48h),
    alerts.total_outflow_48h AS SUM(alerts.outflow_48h) COMMENT = 'Value moved out of flagged accounts in last 48h (INR)',
    loans.loan_count AS COUNT(loans.loan_id),
    loans.total_outstanding AS SUM(loans.outstanding_f) COMMENT = 'Outstanding exposure INR',
    loans.npa_ratio_pct AS ROUND(100 * SUM(IFF(loans.dpd_f > 90, loans.outstanding_f, 0)) / NULLIF(SUM(loans.outstanding_f),0), 2) COMMENT = 'Gross NPA % of outstanding',
    loans.sma_exposure AS SUM(IFF(loans.dpd_f BETWEEN 1 AND 90, loans.outstanding_f, 0)) COMMENT = 'Exposure in SMA-0/1/2 buckets INR',
    lcr.latest_lcr AS MAX_BY(lcr.lcr_pct_f, lcr.as_of_date) COMMENT = 'Most recent LCR %. Do not group by LCR_STATUS when asking for the latest value.',
    lcr.avg_lcr AS AVG(lcr.lcr_pct_f), lcr.min_lcr AS MIN(lcr.lcr_pct_f),
    lcr.avg_stress_lcr AS AVG(lcr.lcr_stress_f),
    conc.max_industry_share AS MAX(conc.share_pct_f),
    cases.case_count AS COUNT(cases.case_id)
  )
  COMMENT = 'Risk, Fraud & Regulatory Intelligence semantic layer (synthetic data)'
  AI_SQL_GENERATION 'Amounts are INR. For "latest", "current" or "today" liquidity questions, filter lcr to the row with the maximum AS_OF_DATE instead of aggregating by status. LCR internal floor is 110% and regulatory minimum is 100%. Always include identifiers (ALERT_ID, ACCOUNT_ID, LOAN_ID) when listing records so answers are evidence-backed. Order alert lists by RISK_SCORE descending.'
  AI_VERIFIED_QUERIES (
    latest_lcr_vq AS (
      QUESTION 'What is the current LCR and status?'
      VERIFIED_BY '(owner = alm_team)'
      SQL 'SELECT as_of_date, lcr_pct_f AS lcr_pct, lcr_stress_f AS stress_lcr_pct, lcr_status, gap_1_7_f, gap_8_14_f, gap_15_30_f FROM __lcr ORDER BY as_of_date DESC LIMIT 1'
    ),
    top_alerts_vq AS (
      QUESTION 'Show the highest risk fraud alerts'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT alert_id, account_id, customer_name, typology, alert_risk_score, recommended_action, outflow_48h FROM __alerts ORDER BY alert_risk_score DESC, alert_id LIMIT 20'
    ),
    structuring_vq AS (
      QUESTION 'Which customers show structuring behavior today?'
      SQL 'SELECT alert_id, account_id, customer_name, typology, alert_risk_score, recommended_action FROM __alerts WHERE typology = ''AML_LAYERING'' OR ARRAY_CONTAINS(''STRUCTURING''::VARIANT, flag_names) ORDER BY alert_risk_score DESC'
    ),
    sma_by_industry_vq AS (
      QUESTION 'What is the SMA and NPA exposure by industry?'
      SQL 'SELECT industry, asset_class, COUNT(loan_id) AS loans, SUM(outstanding_f) AS outstanding_inr FROM __loans WHERE asset_class <> ''STANDARD'' GROUP BY industry, asset_class ORDER BY industry, asset_class'
    )
  );
