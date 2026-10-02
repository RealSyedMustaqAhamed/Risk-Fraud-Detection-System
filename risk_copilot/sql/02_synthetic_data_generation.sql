give -- ============================================================================
-- Risk, Fraud, and Regulatory Intelligence Copilot
-- Step 2: Referentially-Consistent Synthetic Data Generation
-- Covers: Customers, Accounts, Transactions (with injected Mule, Structuring,
--         and Round-Tripping typologies), Credit Loans, Watchlists, HQLA, and Policy Docs
-- ============================================================================

USE DATABASE RISK_COPILOT;
USE SCHEMA RAW;

-- 1. Customers Table (2,000 synthetic entities across retail, MSME, corporate)
CREATE OR REPLACE TABLE RISK_COPILOT.RAW.CUSTOMERS AS
SELECT
  'CUST' || LPAD(SEQ4()+1, 6, '0') AS CUSTOMER_ID,
  ARRAY_CONSTRUCT('Aarav','Vihaan','Isha','Ananya','Rohan','Priya','Kabir','Meera','Arjun','Diya','Sanjay','Neha','Rahul','Kavya','Vikram')[UNIFORM(0,14,RANDOM(1))]::STRING || ' ' ||
  ARRAY_CONSTRUCT('Sharma','Patel','Iyer','Reddy','Gupta','Nair','Singh','Mehta','Das','Rao')[UNIFORM(0,9,RANDOM(2))]::STRING AS FULL_NAME,
  IFF(UNIFORM(0,9,RANDOM(3))<7,'INDIVIDUAL', IFF(UNIFORM(0,1,RANDOM(4))=0,'MSME','CORPORATE')) AS SEGMENT,
  ARRAY_CONSTRUCT('LOW','LOW','LOW','MEDIUM','MEDIUM','HIGH')[UNIFORM(0,5,RANDOM(5))]::STRING AS KYC_RISK_RATING,
  ARRAY_CONSTRUCT('Mumbai','Delhi','Bengaluru','Chennai','Kolkata','Hyderabad','Pune','Ahmedabad','Jaipur','Lucknow')[UNIFORM(0,9,RANDOM(6))]::STRING AS CITY,
  IFF(UNIFORM(0,99,RANDOM(7))<2, TRUE, FALSE) AS IS_PEP,
  DATEADD(day, -UNIFORM(30, 3650, RANDOM(8)), '2026-09-28')::DATE AS ONBOARDED_DATE,
  ARRAY_CONSTRUCT('Salaried','Self-Employed','Business','Student','Retired')[UNIFORM(0,4,RANDOM(9))]::STRING AS OCCUPATION,
  UNIFORM(300000, 5000000, RANDOM(10)) AS DECLARED_ANNUAL_INCOME
FROM TABLE(GENERATOR(ROWCOUNT => 2000));

-- 2. Deposit & Loan Accounts Table
CREATE OR REPLACE TABLE RISK_COPILOT.RAW.ACCOUNTS AS
SELECT
  'ACC' || LPAD(ROW_NUMBER() OVER (ORDER BY c.CUSTOMER_ID, g.n), 7, '0') AS ACCOUNT_ID,
  c.CUSTOMER_ID,
  IFF(g.n=0, IFF(c.SEGMENT='INDIVIDUAL','SAVINGS','CURRENT'), 'LOAN') AS ACCOUNT_TYPE,
  GREATEST(c.ONBOARDED_DATE, DATEADD(day, UNIFORM(0,200,RANDOM(11)), c.ONBOARDED_DATE))::DATE AS OPEN_DATE,
  'ACTIVE' AS STATUS,
  ROUND(UNIFORM(5000, 2000000, RANDOM(12)),2) AS CURRENT_BALANCE
FROM RISK_COPILOT.RAW.CUSTOMERS c
JOIN (SELECT 0 n UNION ALL SELECT 1) g
  ON g.n = 0 OR (g.n = 1 AND MOD(ABS(HASH(c.CUSTOMER_ID)),10) < 4);

-- 3. Synthetic Scenarios Mapping (Ground Truth for Precision/Recall Evaluation)
CREATE OR REPLACE TABLE RISK_COPILOT.RAW.SYNTH_SCENARIOS AS
SELECT ACCOUNT_ID, CUSTOMER_ID, 'MULE' AS SCENARIO FROM RISK_COPILOT.RAW.ACCOUNTS WHERE ACCOUNT_TYPE='SAVINGS' QUALIFY ROW_NUMBER() OVER (ORDER BY HASH(ACCOUNT_ID,'mule')) <= 12
UNION ALL
SELECT ACCOUNT_ID, CUSTOMER_ID, 'STRUCTURING' FROM RISK_COPILOT.RAW.ACCOUNTS WHERE ACCOUNT_TYPE='CURRENT' QUALIFY ROW_NUMBER() OVER (ORDER BY HASH(ACCOUNT_ID,'struct')) <= 6
UNION ALL
SELECT ACCOUNT_ID, CUSTOMER_ID, 'ROUND_TRIP' FROM RISK_COPILOT.RAW.ACCOUNTS WHERE ACCOUNT_TYPE='CURRENT' QUALIFY ROW_NUMBER() OVER (ORDER BY HASH(ACCOUNT_ID,'rt')) <= 6;

-- Adjust Mule customer demographics to represent low-income / student profiles with recent dormancy
UPDATE RISK_COPILOT.RAW.CUSTOMERS c SET ONBOARDED_DATE='2026-06-15', OCCUPATION='Student', DECLARED_ANNUAL_INCOME=180000
FROM RISK_COPILOT.RAW.SYNTH_SCENARIOS s WHERE s.CUSTOMER_ID=c.CUSTOMER_ID AND s.SCENARIO='MULE';
UPDATE RISK_COPILOT.RAW.ACCOUNTS a SET OPEN_DATE='2026-06-20'
FROM RISK_COPILOT.RAW.SYNTH_SCENARIOS s WHERE s.ACCOUNT_ID=a.ACCOUNT_ID AND s.SCENARIO='MULE';

-- 4. Normal Baseline Transactions (~150,000 records)
CREATE OR REPLACE TABLE RISK_COPILOT.RAW.TRANSACTIONS AS
WITH dep AS (
  SELECT ACCOUNT_ID, ROW_NUMBER() OVER (ORDER BY ACCOUNT_ID)-1 AS rn FROM RISK_COPILOT.RAW.ACCOUNTS WHERE ACCOUNT_TYPE <> 'LOAN'
), cnt AS (SELECT COUNT(*) n FROM dep),
g AS (
  SELECT SEQ4() s, UNIFORM(0, 1999, RANDOM(21)) a1, UNIFORM(0,1999,RANDOM(22)) a2,
         UNIFORM(0,99,RANDOM(23)) ch, UNIFORM(0, 60*24*60-1, RANDOM(24)) mins, UNIFORM(0,1,RANDOM(25)) dir,
         ROUND(EXP(UNIFORM(5.0::FLOAT, 11.5::FLOAT, RANDOM(26))),2) amt
  FROM TABLE(GENERATOR(ROWCOUNT => 150000))
)
SELECT 'TXN' || LPAD(g.s+1, 9, '0') AS TXN_ID,
  d1.ACCOUNT_ID,
  d2.ACCOUNT_ID AS COUNTERPARTY_ACCOUNT_ID,
  DATEADD(minute, -g.mins, '2026-09-28 23:59:00'::TIMESTAMP_NTZ) AS TXN_TS,
  CASE WHEN g.ch<45 THEN 'UPI' WHEN g.ch<60 THEN 'IMPS' WHEN g.ch<80 THEN 'NEFT' WHEN g.ch<85 THEN 'RTGS' ELSE 'CARD' END AS CHANNEL,
  IFF(g.dir=0,'CREDIT','DEBIT') AS DIRECTION,
  IFF(g.ch BETWEEN 80 AND 84, g.amt*20, g.amt) AS AMOUNT_INR,
  'DEV' || LPAD(MOD(ABS(HASH(d1.ACCOUNT_ID)), 99999), 5, '0') AS DEVICE_ID,
  '10.' || MOD(ABS(HASH(d1.ACCOUNT_ID)),255) || '.' || MOD(ABS(HASH(d1.ACCOUNT_ID,1)),255) || '.1' AS IP_ADDRESS,
  'IN' AS GEO_COUNTRY,
  'NORMAL'::VARCHAR(30) AS SYNTH_LABEL
FROM g JOIN dep d1 ON d1.rn = MOD(g.a1, (SELECT n FROM cnt)) JOIN dep d2 ON d2.rn = MOD(g.a2,(SELECT n FROM cnt))
WHERE d1.ACCOUNT_ID <> d2.ACCOUNT_ID;

-- 5. Injected Typologies
-- (a) Mule Inflows (Burst of 30 distinct UPI/IMPS payments after dormancy)
INSERT INTO RISK_COPILOT.RAW.TRANSACTIONS
WITH m AS (SELECT ACCOUNT_ID, ROW_NUMBER() OVER (ORDER BY ACCOUNT_ID) mi FROM RISK_COPILOT.RAW.SYNTH_SCENARIOS WHERE SCENARIO='MULE'),
sv AS (SELECT ACCOUNT_ID, ROW_NUMBER() OVER (ORDER BY ACCOUNT_ID)-1 rn, COUNT(*) OVER () n FROM RISK_COPILOT.RAW.ACCOUNTS WHERE ACCOUNT_TYPE='SAVINGS'
       AND ACCOUNT_ID NOT IN (SELECT ACCOUNT_ID FROM RISK_COPILOT.RAW.SYNTH_SCENARIOS)),
g AS (SELECT SEQ4() k FROM TABLE(GENERATOR(ROWCOUNT=>30)))
SELECT 'TXM'||LPAD(m.mi,3,'0')||LPAD(g.k,3,'0'), m.ACCOUNT_ID, sv.ACCOUNT_ID,
   DATEADD(minute, -(2640 - g.k*60 - MOD(ABS(HASH(g.k,m.mi)),50)), '2026-09-28 20:00:00'::TIMESTAMP_NTZ),
   IFF(MOD(g.k,2)=0,'UPI','IMPS'), 'CREDIT',
   ROUND(9000 + MOD(ABS(HASH(m.mi,g.k,'a')), 40000),2),
   'DEV' || (90000 + MOD(ABS(HASH(m.mi,g.k)),6)),
   '185.' || MOD(ABS(HASH(m.mi,g.k,'ip')),200) || '.44.' || MOD(g.k,9), 'IN', 'MULE_INFLOW'
FROM m CROSS JOIN g JOIN sv ON sv.rn = MOD(ABS(HASH(m.mi,g.k,'cp')), sv.n);

-- (b) Mule Outflows (92% rapid pass-through via RTGS to offshore-linked beneficiaries)
INSERT INTO RISK_COPILOT.RAW.TRANSACTIONS
SELECT 'TXO'||LPAD(ROW_NUMBER() OVER (ORDER BY i.ACCOUNT_ID, t.k),6,'0'), i.ACCOUNT_ID, 'EXT-BENF-' || LPAD(MOD(ABS(HASH(i.ACCOUNT_ID)),7),3,'0'),
  DATEADD(minute, 30 + t.k*45, i.last_ts), 'RTGS','DEBIT', ROUND(i.tot*0.46,2), 'DEV90003', '185.12.44.7', IFF(t.k=0,'IN','AE'), 'MULE_OUTFLOW'
FROM (SELECT ACCOUNT_ID, SUM(AMOUNT_INR) tot, MAX(TXN_TS) last_ts FROM RISK_COPILOT.RAW.TRANSACTIONS WHERE SYNTH_LABEL='MULE_INFLOW' GROUP BY 1) i,
     (SELECT 0 k UNION ALL SELECT 1) t;

-- (c) Structuring (Smurfing deposits below INR 10 Lakh / $10,000 CTR limit)
INSERT INTO RISK_COPILOT.RAW.TRANSACTIONS
SELECT 'TXS'||LPAD(ROW_NUMBER() OVER (ORDER BY s.ACCOUNT_ID, g.k),6,'0'), s.ACCOUNT_ID, 'CASH-BRANCH-'||MOD(g.k,4),
  DATEADD(day, -g.k, '2026-09-27 11:00:00'::TIMESTAMP_NTZ), 'CASH','CREDIT', 940000 + MOD(ABS(HASH(s.ACCOUNT_ID,g.k)),55000), 'BRANCH', '0.0.0.0','IN','STRUCTURING'
FROM RISK_COPILOT.RAW.SYNTH_SCENARIOS s, (SELECT SEQ4() k FROM TABLE(GENERATOR(ROWCOUNT=>8))) g WHERE s.SCENARIO='STRUCTURING';

-- (d) Round-Tripping Rings (A -> B -> C -> A within 72h)
INSERT INTO RISK_COPILOT.RAW.TRANSACTIONS
SELECT 'TXR'||LPAD(ROW_NUMBER() OVER (ORDER BY a.ACCOUNT_ID),6,'0'), a.ACCOUNT_ID, b.ACCOUNT_ID,
  DATEADD(hour, a.pos*3, DATEADD(day,-3,'2026-09-28 10:00:00'::TIMESTAMP_NTZ)), 'NEFT','DEBIT', 2500000, 'DEV7'||a.ring, '10.9.9.'||a.ring,'IN','ROUND_TRIP'
FROM (SELECT ACCOUNT_ID, FLOOR((ROW_NUMBER() OVER (ORDER BY ACCOUNT_ID)-1)/3) ring, MOD(ROW_NUMBER() OVER (ORDER BY ACCOUNT_ID)-1,3) pos FROM RISK_COPILOT.RAW.SYNTH_SCENARIOS WHERE SCENARIO='ROUND_TRIP') a
JOIN (SELECT ACCOUNT_ID, FLOOR((ROW_NUMBER() OVER (ORDER BY ACCOUNT_ID)-1)/3) ring, MOD(ROW_NUMBER() OVER (ORDER BY ACCOUNT_ID)-1,3) pos FROM RISK_COPILOT.RAW.SYNTH_SCENARIOS WHERE SCENARIO='ROUND_TRIP') b
 ON a.ring=b.ring AND b.pos = MOD(a.pos+1,3);

-- (e) WOW Scenario: CUST-9821 with 17 cash deposits across 5 branches
INSERT INTO RISK_COPILOT.RAW.CUSTOMERS (CUSTOMER_ID, FULL_NAME, SEGMENT, KYC_RISK_RATING, CITY, IS_PEP, ONBOARDED_DATE, OCCUPATION, DECLARED_ANNUAL_INCOME)
VALUES ('CUST-9821', 'Rajesh K. Verma', 'INDIVIDUAL', 'HIGH', 'Mumbai', FALSE, '2026-01-10', 'Retail Trader', 600000);

INSERT INTO RISK_COPILOT.RAW.ACCOUNTS (ACCOUNT_ID, CUSTOMER_ID, ACCOUNT_TYPE, OPEN_DATE, STATUS, CURRENT_BALANCE)
VALUES ('ACC0009821', 'CUST-9821', 'SAVINGS', '2026-01-15', 'ACTIVE', 1450000.00);

INSERT INTO RISK_COPILOT.RAW.SYNTH_SCENARIOS (ACCOUNT_ID, CUSTOMER_ID, SCENARIO)
VALUES ('ACC0009821', 'CUST-9821', 'STRUCTURING');

INSERT INTO RISK_COPILOT.RAW.TRANSACTIONS (TXN_ID, ACCOUNT_ID, COUNTERPARTY_ACCOUNT_ID, TXN_TS, CHANNEL, DIRECTION, AMOUNT_INR, DEVICE_ID, IP_ADDRESS, GEO_COUNTRY, SYNTH_LABEL)
WITH b AS (
  SELECT * FROM (VALUES 
    (1, 'BRANCH-SOUTH-MUMBAI', 950000, '2026-09-27 09:15:00'),
    (2, 'BRANCH-ANDHERI-WEST', 960000, '2026-09-27 10:45:00'),
    (3, 'BRANCH-BANDRA-EAST', 940000, '2026-09-27 12:30:00'),
    (4, 'BRANCH-FORT-MAIN', 980000, '2026-09-27 14:10:00'),
    (5, 'BRANCH-BKC-PLAZA', 920000, '2026-09-27 16:00:00'),
    (6, 'BRANCH-SOUTH-MUMBAI', 955000, '2026-09-27 17:30:00'),
    (7, 'BRANCH-ANDHERI-WEST', 970000, '2026-09-28 09:30:00'),
    (8, 'BRANCH-BANDRA-EAST', 935000, '2026-09-28 10:50:00'),
    (9, 'BRANCH-FORT-MAIN', 990000, '2026-09-28 11:45:00'),
    (10, 'BRANCH-BKC-PLAZA', 945000, '2026-09-28 13:15:00'),
    (11, 'BRANCH-SOUTH-MUMBAI', 965000, '2026-09-28 14:30:00'),
    (12, 'BRANCH-ANDHERI-WEST', 930000, '2026-09-28 15:40:00'),
    (13, 'BRANCH-BANDRA-EAST', 975000, '2026-09-28 16:50:00'),
    (14, 'BRANCH-FORT-MAIN', 985000, '2026-09-28 18:00:00'),
    (15, 'BRANCH-BKC-PLAZA', 915000, '2026-09-28 19:10:00'),
    (16, 'BRANCH-SOUTH-MUMBAI', 960000, '2026-09-28 20:20:00'),
    (17, 'BRANCH-ANDHERI-WEST', 940000, '2026-09-28 21:30:00')
  ) AS v(k, branch, amt, ts)
)
SELECT 'TXS-9821-' || LPAD(k, 2, '0'), 'ACC0009821', branch, ts::TIMESTAMP_NTZ, 'CASH', 'CREDIT', amt, 'BRANCH-COUNTER', '10.200.5.' || k, 'IN', 'STRUCTURING'
FROM b;

-- 6. Credit Risk Loan Book
CREATE OR REPLACE TABLE RISK_COPILOT.RAW.LOANS AS
SELECT a.ACCOUNT_ID AS LOAN_ID, a.CUSTOMER_ID, c.SEGMENT,
  CASE c.SEGMENT WHEN 'INDIVIDUAL' THEN ARRAY_CONSTRUCT('HOME','PERSONAL','AUTO','GOLD')[UNIFORM(0,3,RANDOM(31))]::STRING
                 WHEN 'MSME' THEN 'WORKING_CAPITAL' ELSE 'TERM_LOAN' END AS PRODUCT,
  ARRAY_CONSTRUCT('Textiles','Real Estate','IT Services','Pharma','Auto Components','Retail Trade','Agriculture','Construction','NBFC Lending','Hospitality')[UNIFORM(0,9,RANDOM(32))]::STRING AS INDUSTRY,
  ROUND(CASE c.SEGMENT WHEN 'INDIVIDUAL' THEN UNIFORM(100000,8000000,RANDOM(33)) WHEN 'MSME' THEN UNIFORM(1000000,50000000,RANDOM(33)) ELSE UNIFORM(50000000,1000000000,RANDOM(33)) END,0) AS SANCTIONED_LIMIT,
  a.OPEN_DATE AS DISBURSAL_DATE,
  ROUND(UNIFORM(8.0::FLOAT, 18.0::FLOAT, RANDOM(34)),2) AS INTEREST_RATE,
  ARRAY_CONSTRUCT('PROPERTY','VEHICLE','GOLD','RECEIVABLES','UNSECURED')[UNIFORM(0,4,RANDOM(35))]::STRING AS COLLATERAL_TYPE,
  UNIFORM(300, 850, RANDOM(36)) AS BUREAU_SCORE,
  0::NUMBER(18,0) AS OUTSTANDING,
  ROUND(UNIFORM(20::FLOAT, 100::FLOAT, RANDOM(37)),1) AS UTILIZATION_PCT,
  CASE WHEN UNIFORM(0,99,RANDOM(38))<78 THEN 0 WHEN UNIFORM(0,99,RANDOM(39))<50 THEN UNIFORM(1,30,RANDOM(40)) WHEN UNIFORM(0,99,RANDOM(41))<60 THEN UNIFORM(31,60,RANDOM(42)) WHEN UNIFORM(0,99,RANDOM(43))<60 THEN UNIFORM(61,90,RANDOM(44)) ELSE UNIFORM(91,200,RANDOM(45)) END AS DPD,
  IFF(UNIFORM(0,99,RANDOM(46))<80, 0, UNIFORM(1,5,RANDOM(47))) AS NACH_BOUNCES_90D,
  ROUND(UNIFORM(-60::FLOAT, 40::FLOAT, RANDOM(48)),1) AS SALES_VELOCITY_CHG_PCT
FROM RISK_COPILOT.RAW.ACCOUNTS a JOIN RISK_COPILOT.RAW.CUSTOMERS c USING (CUSTOMER_ID) WHERE a.ACCOUNT_TYPE='LOAN';

UPDATE RISK_COPILOT.RAW.LOANS SET OUTSTANDING = ROUND(SANCTIONED_LIMIT * UTILIZATION_PCT/100, 0);

-- 7. Sanctions and Watchlist Data
CREATE OR REPLACE TABLE RISK_COPILOT.RAW.WATCHLIST (LIST_NAME STRING, ENTITY_NAME STRING, MATCHED_CUSTOMER_ID STRING, MATCH_SCORE FLOAT, LISTED_DATE DATE, REMARKS STRING);
INSERT INTO RISK_COPILOT.RAW.WATCHLIST
SELECT IFF(ROW_NUMBER() OVER (ORDER BY c.CUSTOMER_ID) % 3 = 0,'OFAC_SDN_SYNTH','UN_CONSOLIDATED_SYNTH'), c.FULL_NAME, c.CUSTOMER_ID, ROUND(UNIFORM(0.82::FLOAT,0.99::FLOAT,RANDOM(51)),2), '2025-11-01', 'Synthetic name-match hit; requires L2 disposition'
FROM RISK_COPILOT.RAW.CUSTOMERS c JOIN RISK_COPILOT.RAW.SYNTH_SCENARIOS s USING(CUSTOMER_ID) WHERE s.SCENARIO IN ('MULE','ROUND_TRIP') QUALIFY ROW_NUMBER() OVER (ORDER BY HASH(c.CUSTOMER_ID)) <= 5
UNION ALL
SELECT 'PEP_DOMESTIC_SYNTH', FULL_NAME, CUSTOMER_ID, 1.0, '2024-01-01', 'Politically exposed person' FROM RISK_COPILOT.RAW.CUSTOMERS WHERE IS_PEP;

-- 8. Liquidity Positions (HQLA & Cash Flows)
CREATE OR REPLACE TABLE RISK_COPILOT.RAW.HQLA_HOLDINGS AS
WITH d AS (SELECT DATEADD(day, -SEQ4(), '2026-09-28'::DATE) AS AS_OF_DATE, SEQ4() k FROM TABLE(GENERATOR(ROWCOUNT=>30))),
s AS (SELECT * FROM (VALUES
 ('G-SEC 7.26% 2033','LEVEL_1',0.00, 42000),('T-BILL 364D','LEVEL_1',0.00, 18000),('CASH & CRR EXCESS','LEVEL_1',0.00, 9000),
 ('AA+ CORPORATE BONDS','LEVEL_2A',0.15, 14000),('PSU BONDS AAA','LEVEL_2A',0.15, 9000),
 ('NIFTY50 EQUITIES','LEVEL_2B',0.50, 4000),('AA- CORPORATE BONDS','LEVEL_2B',0.50, 3000)) AS s(INSTRUMENT, HQLA_LEVEL, HAIRCUT, BASE_CR))
SELECT d.AS_OF_DATE, s.INSTRUMENT, s.HQLA_LEVEL, s.HAIRCUT::FLOAT HAIRCUT,
  ROUND(s.BASE_CR * (1 + 0.004*d.k) * 1e7 * (1 + UNIFORM(-0.02::FLOAT,0.02::FLOAT,RANDOM(61))),0) AS MARKET_VALUE_INR
FROM d CROSS JOIN s;

CREATE OR REPLACE TABLE RISK_COPILOT.RAW.CASHFLOW_POSITIONS AS
WITH d AS (SELECT DATEADD(day, -SEQ4(), '2026-09-28'::DATE) AS AS_OF_DATE, SEQ4() k FROM TABLE(GENERATOR(ROWCOUNT=>30))),
s AS (SELECT * FROM (VALUES
 ('Retail deposits - stable','OUTFLOW',0.05, 380000),('Retail deposits - less stable','OUTFLOW',0.10, 210000),
 ('Unsecured wholesale - operational','OUTFLOW',0.25, 60000),('Unsecured wholesale - non-operational','OUTFLOW',0.40, 55000),
 ('Undrawn committed credit facilities','OUTFLOW',0.10, 70000),('Derivative net outflows','OUTFLOW',1.00, 4000),
 ('Performing loan inflows (50%)','INFLOW',0.50, 30000),('Interbank placements maturing','INFLOW',1.00, 8000)) AS s(CATEGORY, FLOW_TYPE, RATE, BASE_CR))
SELECT d.AS_OF_DATE, s.CATEGORY, s.FLOW_TYPE, s.RATE::FLOAT RATE, b.BUCKET,
  ROUND(s.BASE_CR * b.w * (1 + IFF(s.CATEGORY LIKE '%non-operational%' OR s.CATEGORY LIKE '%less stable%', 0.012*(29-d.k), 0)) * 1e7 * (1+UNIFORM(-0.02::FLOAT,0.02::FLOAT,RANDOM(62))),0) AS BALANCE_INR
FROM d CROSS JOIN s CROSS JOIN (SELECT * FROM (VALUES ('1-7D',0.45),('8-14D',0.25),('15-30D',0.30)) AS b(BUCKET,w)) b;

-- 9. Regulatory and Policy Documents (Internal AML/ALM/Credit + PMLA + FinCEN + Basel III)
CREATE OR REPLACE TABLE RISK_COPILOT.RAW.POLICY_DOCS (DOC_ID STRING, DOC_TITLE STRING, DOC_TYPE STRING, SECTION STRING, DOMAIN STRING, EFFECTIVE_DATE DATE, CHUNK_TEXT STRING);
INSERT INTO RISK_COPILOT.RAW.POLICY_DOCS VALUES
('AML-POL-01','Internal AML & CFT Policy v4.1','INTERNAL_POLICY','AML-POL 3.1 Customer Risk Categorisation','AML','2026-04-01','Customers are categorised LOW, MEDIUM or HIGH risk at onboarding and reviewed periodically. HIGH risk customers (PEPs, sanctions near-matches, complex ownership, high cash intensity) require Enhanced Due Diligence and senior management approval. Periodic KYC updation: HIGH every 2 years, MEDIUM every 8 years, LOW every 10 years, aligned to the RBI KYC Master Direction.'),
('AML-POL-01','Internal AML & CFT Policy v4.1','INTERNAL_POLICY','AML-POL 4.2 Money Mule Red Flags','FRAUD','2026-04-01','Money mule red flags: (a) account opened within 180 days or dormant for 30+ days followed by a sudden burst of inward credits; (b) 15 or more inward credits from distinct remitters within 48 hours; (c) 80% or more of inward value moved out within 24 hours, particularly via RTGS/NEFT to new beneficiaries; (d) access from multiple devices or foreign/unusual IP ranges; (e) transaction volume inconsistent with declared occupation or income (e.g. Student). Two or more red flags require an immediate debit freeze pending investigation and L2 review within 4 business hours.'),
('AML-POL-01','Internal AML & CFT Policy v4.1','INTERNAL_POLICY','AML-POL 4.3 Structuring / Threshold Avoidance','AML','2026-04-01','Structuring is the deliberate splitting of cash deposits to remain below the INR 10 lakh Cash Transaction Report (CTR) threshold. Three or more cash deposits between INR 9 lakh and INR 10 lakh within 10 days from the same customer shall be escalated as suspected structuring and assessed for STR filing.'),
('AML-POL-01','Internal AML & CFT Policy v4.1','INTERNAL_POLICY','AML-POL 4.4 Round-Tripping and Layering','AML','2026-04-01','Round-tripping: funds that leave an account and return to the originator through one or more intermediary accounts within a short window (72 hours) with no evident economic purpose. Circular flows among related current accounts of similar value are indicators of layering and must be escalated to the Principal Officer.'),
('AML-POL-01','Internal AML & CFT Policy v4.1','INTERNAL_POLICY','AML-POL 6.1 STR Filing Timeline','AML','2026-04-01','Once the Principal Officer is satisfied that a transaction is suspicious, the STR must be furnished to FIU-IND within 7 working days, consistent with the PML (Maintenance of Records) Rules. No tipping-off: the customer must not be informed that an STR has been or will be filed. All STR drafts require human (maker-checker) approval before submission.'),
('AML-POL-01','Internal AML & CFT Policy v4.1','INTERNAL_POLICY','AML-POL 6.2 STR Narrative Standard','AML','2026-04-01','The STR narrative must describe Who (customer, KYC risk, linked parties), What (transaction types and values), When (exact date range and timestamps), Where (channels, branches, geographies, IPs), Why (red flags triggered and why activity is inconsistent with profile) and How (flow of funds). It must cite transaction IDs and list missing documents required before submission.'),
('AML-POL-01','Internal AML & CFT Policy v4.1','INTERNAL_POLICY','AML-POL 7.1 Sanctions Screening','AML','2026-04-01','All customers and counterparties are screened against sanctions lists (UN consolidated list, OFAC SDN and domestic lists) at onboarding and on list updates. Match score >= 0.85 requires L2 disposition before any outward transaction is released. Confirmed true matches require account freeze and reporting as mandated.'),
('REG-PMLA','Prevention of Money Laundering Act, 2002 - Reference Summary','REGULATION_SUMMARY','PMLA Section 12','AML','2023-03-07','Section 12 of the PMLA places obligations on every reporting entity (including banks and NBFCs) to maintain records of transactions and to furnish information on prescribed transactions (including suspicious transactions) to the Director, FIU-IND, and to verify the identity of clients. Records must be preserved for five years. [Reference summary for demo; verify against the official gazette text before reliance.]'),
('REG-KYC-MD','RBI Master Direction - KYC - Reference Summary','REGULATION_SUMMARY','KYC MD - Cash Transaction Reports','AML','2025-06-12','Reporting entities must report all cash transactions of value more than INR 10 lakh, or series of integrally connected cash transactions aggregating above INR 10 lakh within a month, to FIU-IND by the 15th of the succeeding month (CTR). [Reference summary for demo; verify against the official Master Direction.]'),
('REG-FINCEN-STR','FinCEN Guidance on Structuring (31 CFR § 1010.314)','REGULATION_SUMMARY','FinCEN AML Structuring Guidance Section 3.1','AML','2024-01-15','FinCEN Structuring Rule (31 CFR § 1010.314 & 31 U.S.C. 5324): Prohibits structuring transactions to evade Currency Transaction Reporting (CTR) requirements for currency deposits above $10,000. Indicators include multiple cash deposits just below the $10,000 threshold (e.g., $9,000-$9,900) across multiple branches or short timeframes without a clear legitimate business purpose. Reporting entities must file a Suspicious Activity Report (SAR) within 30 days of initial detection.'),
('REG-FINCEN-SAR','FinCEN SAR Filing Requirements (31 CFR § 1020.320)','REGULATION_SUMMARY','FinCEN SAR Filing Standard Section 2.4','AML','2024-01-15','Financial institutions must file a SAR for any suspicious transaction involving $5,000 or more if the institution knows, suspects, or has reason to suspect that the transaction involves funds derived from illegal activity, is designed to evade BSA requirements, or has no business or apparent lawful purpose. Safe harbor protections apply under 31 U.S.C. 5318(g)(3). Strict prohibition on tipping off.'),
('REG-BASEL-LCR','Basel III Liquidity Coverage Ratio - Reference Summary','REGULATION_SUMMARY','LCR Minimum and HQLA Composition','LIQUIDITY','2019-01-01','LCR = Stock of HQLA / Total net cash outflows over the next 30 calendar days, and must be at least 100% on an ongoing basis. Level 1 assets carry 0% haircut. Level 2A assets carry a minimum 15% haircut; Level 2B assets carry a 50% haircut (for eligible corporate debt and equities). Level 2 assets may not exceed 40% of total HQLA and Level 2B may not exceed 15% of total HQLA after haircuts. Total inflows are capped at 75% of total outflows. [Reference summary; verify against BCBS and RBI LCR guidelines.]'),
('REG-BASEL-LCR','Basel III Liquidity Coverage Ratio - Reference Summary','REGULATION_SUMMARY','LCR Run-off Rates','LIQUIDITY','2019-01-01','Indicative run-off factors: stable retail deposits 5%, less stable retail deposits 10%, operational unsecured wholesale deposits 25%, non-operational unsecured wholesale from non-financial corporates 40%, undrawn committed credit facilities to non-financial corporates 10%. [Reference summary; verify against RBI LCR circular for local calibration.]'),
('ALM-POL-02','Internal ALM & Liquidity Risk Policy v3.0','INTERNAL_POLICY','ALM-POL 5.1 Internal LCR Buffer','LIQUIDITY','2026-01-01','The Board-approved internal LCR floor is 110%, above the 100% regulatory minimum. A breach of 115% triggers an amber alert to ALCO; a breach of 110% triggers the Contingency Funding Plan (CFP), including drawing on repo/LAF facilities, reducing wholesale non-operational reliance, and reviewing retail deposit pricing.'),
('ALM-POL-02','Internal ALM & Liquidity Risk Policy v3.0','INTERNAL_POLICY','ALM-POL 6.2 Stress Scenarios','LIQUIDITY','2026-01-01','Mandatory stress scenarios: (S1) 15% retail deposit run with 30% markdown on Level 2A HQLA; (S2) 50% wholesale non-operational withdrawal; (S3) combined idiosyncratic and market-wide stress. Survival horizon under S1 must remain at least 30 days.'),
('CR-POL-03','Internal Credit Risk & EWS Policy v2.4','INTERNAL_POLICY','CR-POL 4.1 SMA Classification','CREDIT','2026-02-01','Special Mention Account classification based on days past due (DPD) of principal or interest: SMA-0 = 1-30 days, SMA-1 = 31-60 days, SMA-2 = 61-90 days. Accounts overdue beyond 90 days are classified as Non-Performing Assets (NPA). For IFRS 9 / Ind AS 109 staging, Stage 2 is presumed at 30+ DPD and Stage 3 at 90+ DPD.'),
('CR-POL-03','Internal Credit Risk & EWS Policy v2.4','INTERNAL_POLICY','CR-POL 5.3 EWS Triggers and Actions','CREDIT','2026-02-01','EWS triggers: limit utilisation >90% for 60 days, 2 or more NACH/cheque bounces in 90 days, 30%+ decline in primary account sales velocity, bureau score below 600. Actions: 1 trigger - watchlist; 2 triggers - limit freeze and collateral revaluation; 3+ triggers or SMA-2 - restructuring discussion and Credit Committee referral.'),
('CR-POL-03','Internal Credit Risk & EWS Policy v2.4','INTERNAL_POLICY','CR-POL 7.1 Concentration Limits','CREDIT','2026-02-01','Single industry exposure must not exceed 15% of total funded exposure; Real Estate and NBFC Lending sectors are capped at 10% each. Breaches require CRO sign-off and a remediation plan within 30 days.');
