-- ============================================================================
-- Risk, Fraud, and Regulatory Intelligence Copilot
-- Step 5: Procedures, Guardrails, and Governance
-- Covers: GENERATE_SAR_DRAFT, VALIDATE_CITATIONS, RUN_LIQUIDITY_STRESS,
--         REVIEW_CASE (maker-checker), CASES, and AUDIT_LOG tables
-- ============================================================================

USE DATABASE RISK_COPILOT;
USE SCHEMA APP;

-- 1. Cases Table for Human-in-the-Loop Investigation Workflow
CREATE OR REPLACE TABLE RISK_COPILOT.APP.CASES (
  CASE_ID STRING DEFAULT 'CASE-' || UUID_STRING(),
  ALERT_ID STRING,
  ACCOUNT_ID STRING,
  CUSTOMER_ID STRING,
  TYPOLOGY STRING,
  RISK_SCORE NUMBER,
  STATUS STRING DEFAULT 'OPEN',
  ASSIGNED_TO STRING,
  ACTION_TAKEN STRING,
  EVIDENCE VARIANT,
  POLICY_CITATIONS VARIANT,
  SAR_DRAFT STRING,
  GUARDRAIL_RESULT VARIANT,
  MISSING_DOCS VARIANT,
  CREATED_BY STRING DEFAULT CURRENT_USER(),
  CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  REVIEWED_BY STRING,
  REVIEWED_AT TIMESTAMP_NTZ,
  REVIEW_DECISION STRING,
  REVIEW_NOTES STRING
);

-- 2. Immutable Audit Trail Table
CREATE OR REPLACE TABLE RISK_COPILOT.APP.AUDIT_LOG (
  EVENT_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  EVENT_USER STRING DEFAULT CURRENT_USER(),
  EVENT_ROLE STRING DEFAULT CURRENT_ROLE(),
  EVENT_TYPE STRING,
  OBJECT_ID STRING,
  DETAILS VARIANT
);

-- 3. Citation Validator Function (Guardrail)
CREATE OR REPLACE FUNCTION RISK_COPILOT.APP.VALIDATE_CITATIONS(NARRATIVE STRING, CITED ARRAY, ALLOWED ARRAY, CONTEXT STRING)
RETURNS ARRAY
COMMENT = 'Guardrail: returns citations (bracketed policy refs or Section/Rule N mentions) not grounded in retrieved context'
AS
$$
  SELECT COALESCE(ARRAY_AGG(DISTINCT ref), ARRAY_CONSTRUCT()) FROM (
    SELECT c.value::STRING ref,
           TRIM(REGEXP_REPLACE(c.value::STRING, '\\[|\\]|\\([a-z0-9]+\\)', '')) norm
    FROM TABLE(FLATTEN(INPUT => ARRAY_CAT(COALESCE(CITED, ARRAY_CONSTRUCT()),
                                           REGEXP_SUBSTR_ALL(COALESCE(NARRATIVE,''), '\\[[A-Za-z-]+ [0-9][^\\]]*\\]')))) c
    UNION ALL
    SELECT m.value::STRING, m.value::STRING
    FROM TABLE(FLATTEN(INPUT => REGEXP_SUBSTR_ALL(COALESCE(NARRATIVE,''), '(Section|Rule|Regulation|Clause|Article) [0-9]+[A-Z-]*'))) m
  ) x
  WHERE NOT ARRAYS_OVERLAP(ARRAY_CONSTRUCT(TRUE), TRANSFORM(ALLOWED, a -> STARTSWITH(a::STRING, x.norm)))
    AND NOT CONTAINS(CONTEXT, x.norm)
$$;

-- 4. Stored Procedure: Governed SAR Draft Generator with Citation Guardrails
CREATE OR REPLACE PROCEDURE RISK_COPILOT.APP.GENERATE_SAR_DRAFT(P_ALERT_ID STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Signal -> evidence -> policy retrieval -> governed STR draft -> guardrail -> case (maker). Human checker required.'
EXECUTE AS CALLER
AS
$$
DECLARE
  v_evidence VARIANT; v_txns VARIANT; v_query STRING; v_hits VARIANT; v_context STRING; v_allowed ARRAY; v_sql STRING; rs RESULTSET;
  v_prompt STRING; v_raw STRING; v_out VARIANT; v_narr STRING; v_bad ARRAY; v_case STRING; v_guard VARIANT;
BEGIN
  -- Assemble structured evidence deterministically
  SELECT OBJECT_CONSTRUCT('alert_id',a.ALERT_ID,'account_id',a.ACCOUNT_ID,'customer_id',a.CUSTOMER_ID,'customer_name',a.FULL_NAME,
          'segment',a.SEGMENT,'kyc_risk',a.KYC_RISK_RATING,'occupation',a.OCCUPATION,'declared_income_inr',s.DECLARED_ANNUAL_INCOME,
          'account_open_date',s.OPEN_DATE,'city',s.CITY,'is_pep',s.IS_PEP,'watchlist_hit',s.WATCHLIST_HIT,'watchlist_score',s.WATCHLIST_SCORE,
          'typology',a.TYPOLOGY,'risk_score',a.RISK_SCORE,'recommended_action',a.RECOMMENDED_ACTION,'red_flags',a.RED_FLAGS,
          'inflow_48h_inr',a.INFLOW_AMT_48H,'outflow_48h_inr',a.OUTFLOW_AMT_48H,'signal_as_of',a.SIGNAL_AS_OF),
         OBJECT_CONSTRUCT('query', a.TYPOLOGY || ' ' || ARRAY_TO_STRING(a.FLAG_NAMES, ' ') || ' STR filing narrative',
                          'columns', ARRAY_CONSTRUCT('SECTION','DOC_TITLE','CHUNK_TEXT'), 'limit', 6)::STRING
    INTO :v_evidence, :v_query
  FROM RISK_COPILOT.CURATED.DT_FRAUD_ALERTS a JOIN RISK_COPILOT.CURATED.DT_ACCOUNT_SIGNALS s ON s.ACCOUNT_ID=a.ACCOUNT_ID
  WHERE a.ALERT_ID = :P_ALERT_ID;
  
  IF (v_evidence IS NULL) THEN
    INSERT INTO RISK_COPILOT.APP.AUDIT_LOG (EVENT_TYPE, OBJECT_ID, DETAILS) SELECT 'SAR_REJECTED_UNKNOWN_ALERT', :P_ALERT_ID, OBJECT_CONSTRUCT('reason','alert not found');
    RETURN OBJECT_CONSTRUCT('status','ERROR','message','Alert '||:P_ALERT_ID||' not found in DT_FRAUD_ALERTS. No report generated.');
  END IF;

  SELECT ARRAY_AGG(OBJECT_CONSTRUCT('txn_id',TXN_ID,'ts',TXN_TS,'dir',DIRECTION,'channel',CHANNEL,'amount_inr',AMOUNT_INR,'counterparty',COUNTERPARTY_ACCOUNT_ID,'device',DEVICE_ID,'ip',IP_ADDRESS,'geo',GEO_COUNTRY)) WITHIN GROUP (ORDER BY TXN_TS)
    INTO :v_txns
  FROM (SELECT * FROM RISK_COPILOT.RAW.TRANSACTIONS
        WHERE ACCOUNT_ID = :v_evidence:account_id::STRING AND TXN_TS >= DATEADD(day,-10,:v_evidence:signal_as_of::TIMESTAMP_NTZ)
        QUALIFY ROW_NUMBER() OVER (ORDER BY IFF(CHANNEL IN ('RTGS','NEFT','CASH'),0,1), AMOUNT_INR DESC) <= 40);

  -- Retrieve relevant policies from Cortex Search
  v_sql := 'SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(''RISK_COPILOT.CURATED.POLICY_SEARCH'', ''' || REPLACE(:v_query, '''', '''''') || '''))[''results''] AS R';
  rs := (EXECUTE IMMEDIATE :v_sql);
  LET c1 CURSOR FOR rs;
  FOR r IN c1 DO v_hits := r.R; END FOR;
  SELECT LISTAGG('['||v.value:SECTION::STRING||'] ('||v.value:DOC_TITLE::STRING||') '||v.value:CHUNK_TEXT::STRING, '\n\n'),
         ARRAY_AGG(v.value:SECTION::STRING)
    INTO :v_context, :v_allowed FROM TABLE(FLATTEN(INPUT => :v_hits)) v;

  -- Grounded LLM narrative generation
  v_prompt := 'You are an AML Compliance Officer drafting a Suspicious Transaction Report (STR) narrative for FIU-IND / FinCEN. ' ||
    'Use ONLY the EVIDENCE and POLICY CONTEXT below. Never invent transactions, amounts, dates, people or regulatory clauses. ' ||
    'Cite regulations/policies ONLY using the exact bracketed section labels present in POLICY CONTEXT (you may append a sub-item like (a)). ' ||
    'Structure the narrative with markdown headings: WHO, WHAT, WHEN, WHERE, WHY (red flags), HOW (flow of funds), RECOMMENDED ACTION. ' ||
    'Keep the narrative under 700 words. Summarise high-count small credits in aggregate (count, total, range, first/last txn IDs and timestamps); list every RTGS/NEFT/CASH transaction individually with txn ID, timestamp and INR amount. ' ||
    'Tone: legalistic, precise, objective. Do not tip off the customer.\n' ||
    'Return ONLY a raw JSON object (no code fences) with keys: "narrative" (string, markdown), "cited_sections" (array of bracketed section codes used, e.g. "[AML-POL 4.2]"), ' ||
    '"missing_documents" (array of documents/info needed before submission), "confidence" (string: HIGH, MEDIUM or LOW followed by a short reason).\n\n' ||
    'EVIDENCE:\n' || :v_evidence::STRING || '\n\nTRANSACTIONS:\n' || COALESCE(:v_txns::STRING,'[]') || '\n\nPOLICY CONTEXT:\n' || :v_context;
  v_raw := AI_COMPLETE(model => 'claude-sonnet-4-5', prompt => :v_prompt, model_parameters => {'temperature': 0, 'max_tokens': 8000});
  v_out := TRY_PARSE_JSON(REGEXP_SUBSTR(:v_raw, '\\{.*\\}', 1, 1, 's'));
  IF (v_out IS NULL) THEN
    v_out := OBJECT_CONSTRUCT('narrative', :v_raw, 'cited_sections', ARRAY_CONSTRUCT(), 'missing_documents', ARRAY_CONSTRUCT('LLM output not valid JSON - full manual review required'), 'confidence','LOW - unparseable model output');
  END IF;

  -- Citation Guardrail Check
  v_narr := :v_out:narrative::STRING;
  v_bad := RISK_COPILOT.APP.VALIDATE_CITATIONS(:v_narr, :v_out:cited_sections::ARRAY, :v_allowed, :v_context);
  FOR i IN 0 TO ARRAY_SIZE(:v_bad)-1 DO
    v_narr := REPLACE(:v_narr, :v_bad[i]::STRING, '[MANUAL POLICY LOOKUP REQUIRED: ' || REPLACE(REPLACE(:v_bad[i]::STRING,'[',''),']','') || ']');
  END FOR;
  v_guard := OBJECT_CONSTRUCT('passed', ARRAY_SIZE(:v_bad)=0, 'unverified_citations', :v_bad, 'retrieved_sections', :v_allowed,
                              'cited_sections', :v_out:cited_sections, 'confidence', :v_out:confidence, 'model','claude-sonnet-4-5', 'human_review_required', TRUE);

  -- Save Case record for Human-in-the-Loop review
  v_case := 'CASE-' || :v_evidence:account_id::STRING || '-' || TO_CHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISS');
  INSERT INTO RISK_COPILOT.APP.CASES (CASE_ID, ALERT_ID, ACCOUNT_ID, CUSTOMER_ID, TYPOLOGY, RISK_SCORE, STATUS, ACTION_TAKEN, EVIDENCE, POLICY_CITATIONS, SAR_DRAFT, GUARDRAIL_RESULT, MISSING_DOCS)
    SELECT :v_case, :P_ALERT_ID, :v_evidence:account_id::STRING, :v_evidence:customer_id::STRING, :v_evidence:typology::STRING, :v_evidence:risk_score::NUMBER,
      'PENDING_REVIEW', :v_evidence:recommended_action::STRING, OBJECT_INSERT(:v_evidence,'transactions',:v_txns), :v_hits, :v_narr, :v_guard, :v_out:missing_documents;
  
  INSERT INTO RISK_COPILOT.APP.AUDIT_LOG (EVENT_TYPE, OBJECT_ID, DETAILS)
    SELECT 'SAR_DRAFT_GENERATED', :v_case, OBJECT_CONSTRUCT('alert_id',:P_ALERT_ID,'guardrail',:v_guard);
  
  RETURN OBJECT_CONSTRUCT('status','OK','case_id',:v_case,'guardrail',:v_guard,'missing_documents',:v_out:missing_documents,'sar_draft',:v_narr);
END;
$$;

-- 5. Stored Procedure: Parameterized Liquidity Stress Testing
CREATE OR REPLACE PROCEDURE RISK_COPILOT.APP.RUN_LIQUIDITY_STRESS(RETAIL_RUN_PCT FLOAT, L2A_MARKDOWN_PCT FLOAT, WHOLESALE_RUN_PCT FLOAT)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Parameterised LCR stress on latest date: extra retail run %, Level 2A markdown %, extra wholesale non-operational run %'
EXECUTE AS CALLER
AS
$$
DECLARE res VARIANT;
BEGIN
  IF (RETAIL_RUN_PCT < 0 OR RETAIL_RUN_PCT > 100 OR L2A_MARKDOWN_PCT < 0 OR L2A_MARKDOWN_PCT > 100 OR WHOLESALE_RUN_PCT < 0 OR WHOLESALE_RUN_PCT > 100) THEN
    RETURN OBJECT_CONSTRUCT('status','ERROR','message','Percentages must be between 0 and 100');
  END IF;
  WITH d AS (SELECT MAX(AS_OF_DATE) dt FROM RISK_COPILOT.RAW.HQLA_HOLDINGS),
  h AS (SELECT SUM(IFF(HQLA_LEVEL='LEVEL_1', MARKET_VALUE_INR,0)) L1,
               SUM(IFF(HQLA_LEVEL='LEVEL_2A', MARKET_VALUE_INR*(1-HAIRCUT),0)) L2A,
               SUM(IFF(HQLA_LEVEL='LEVEL_2B', MARKET_VALUE_INR*(1-HAIRCUT),0)) L2B
        FROM RISK_COPILOT.RAW.HQLA_HOLDINGS WHERE AS_OF_DATE=(SELECT dt FROM d)),
  c AS (SELECT SUM(IFF(FLOW_TYPE='OUTFLOW', BALANCE_INR*RATE,0)) OUTF, SUM(IFF(FLOW_TYPE='INFLOW', BALANCE_INR*RATE,0)) INF,
               SUM(IFF(CATEGORY LIKE 'Retail%', BALANCE_INR,0)) RETAIL, SUM(IFF(CATEGORY LIKE '%non-operational%', BALANCE_INR*(1-RATE),0)) WHS_RESID
        FROM RISK_COPILOT.RAW.CASHFLOW_POSITIONS WHERE AS_OF_DATE=(SELECT dt FROM d)),
  s AS (SELECT (SELECT dt FROM d) dt,
      h.L1 + LEAST(h.L2A + LEAST(h.L2B, 15/85*(h.L1+h.L2A)), 2/3*h.L1) base_hqla,
      c.OUTF - LEAST(c.INF, 0.75*c.OUTF) base_nco,
      h.L1 + LEAST(h.L2A*(1-:L2A_MARKDOWN_PCT/100) + LEAST(h.L2B, 15/85*(h.L1+h.L2A)), 2/3*h.L1) st_hqla,
      c.OUTF + :RETAIL_RUN_PCT/100*c.RETAIL + :WHOLESALE_RUN_PCT/100*c.WHS_RESID AS st_out, c.INF
    FROM h, c)
  SELECT OBJECT_CONSTRUCT('status','OK','as_of_date',dt,
     'scenario', OBJECT_CONSTRUCT('retail_run_pct',:RETAIL_RUN_PCT,'l2a_markdown_pct',:L2A_MARKDOWN_PCT,'wholesale_run_pct',:WHOLESALE_RUN_PCT),
     'baseline_lcr_pct', ROUND(100*base_hqla/base_nco,1),
     'stressed_lcr_pct', ROUND(100*st_hqla/(st_out - LEAST(INF,0.75*st_out)),1),
     'stressed_hqla_inr_cr', ROUND(st_hqla/1e7), 'stressed_net_outflows_inr_cr', ROUND((st_out - LEAST(INF,0.75*st_out))/1e7),
     'hqla_shortfall_to_110pct_inr_cr', GREATEST(0, ROUND((1.10*(st_out - LEAST(INF,0.75*st_out)) - st_hqla)/1e7)),
     'hqla_shortfall_to_100pct_inr_cr', GREATEST(0, ROUND((1.00*(st_out - LEAST(INF,0.75*st_out)) - st_hqla)/1e7)),
     'policy_refs', ARRAY_CONSTRUCT('ALM-POL 5.1','ALM-POL 6.2','LCR Minimum and HQLA Composition'))
  INTO :res FROM s;
  INSERT INTO RISK_COPILOT.APP.AUDIT_LOG (EVENT_TYPE, OBJECT_ID, DETAILS) SELECT 'LIQUIDITY_STRESS_RUN', 'LCR', :res;
  RETURN res;
END;
$$;

-- 6. Stored Procedure: Maker-Checker Case Review
CREATE OR REPLACE PROCEDURE RISK_COPILOT.APP.REVIEW_CASE(P_CASE_ID STRING, P_DECISION STRING, P_NOTES STRING)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Checker step: APPROVE_FOR_FILING, REJECT, or REQUEST_INFO. Maker cannot approve own case.'
EXECUTE AS CALLER
AS
$$
DECLARE v_maker STRING; v_status STRING;
BEGIN
  IF (P_DECISION NOT IN ('APPROVE_FOR_FILING','REJECT','REQUEST_INFO')) THEN
    RETURN OBJECT_CONSTRUCT('status','ERROR','message','Decision must be APPROVE_FOR_FILING, REJECT or REQUEST_INFO');
  END IF;
  SELECT MAX(CREATED_BY), MAX(STATUS) INTO :v_maker, :v_status FROM RISK_COPILOT.APP.CASES WHERE CASE_ID = :P_CASE_ID;
  IF (v_status IS NULL) THEN RETURN OBJECT_CONSTRUCT('status','ERROR','message','Case not found'); END IF;
  IF (v_status <> 'PENDING_REVIEW' AND v_status <> 'INFO_REQUESTED') THEN RETURN OBJECT_CONSTRUCT('status','ERROR','message','Case already '||v_status); END IF;
  IF (P_DECISION = 'APPROVE_FOR_FILING' AND v_maker = CURRENT_USER() AND CURRENT_ROLE() <> 'ACCOUNTADMIN') THEN
    RETURN OBJECT_CONSTRUCT('status','ERROR','message','Maker-checker violation: the case creator cannot approve it');
  END IF;
  UPDATE RISK_COPILOT.APP.CASES SET STATUS = DECODE(:P_DECISION,'APPROVE_FOR_FILING','APPROVED_FOR_FILING','REJECT','CLOSED_NO_STR','INFO_REQUESTED'),
     REVIEW_DECISION = :P_DECISION, REVIEW_NOTES = :P_NOTES, REVIEWED_BY = CURRENT_USER(), REVIEWED_AT = CURRENT_TIMESTAMP()
  WHERE CASE_ID = :P_CASE_ID;
  INSERT INTO RISK_COPILOT.APP.AUDIT_LOG (EVENT_TYPE, OBJECT_ID, DETAILS) SELECT 'CASE_REVIEWED', :P_CASE_ID, OBJECT_CONSTRUCT('decision',:P_DECISION,'notes',:P_NOTES,'maker',:v_maker);
  RETURN OBJECT_CONSTRUCT('status','OK','case_id',:P_CASE_ID,'decision',:P_DECISION);
END;
$$;
