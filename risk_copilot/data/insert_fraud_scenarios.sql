-- ============================================================================
-- Risk, Fraud, and Regulatory Intelligence Copilot
-- Standalone Seed Script: Injected Fraud, Credit, Liquidity & Regulatory Scenarios
-- File: risk_copilot/data/insert_fraud_scenarios.sql
-- ============================================================================

USE DATABASE RISK_COPILOT;

-- ----------------------------------------------------------------------------
-- 1. SCENARIO 1: Ultimate "WOW" Demo - CUST-9821 Cash Structuring (Smurfing)
-- Pattern: 17 cash deposits ($9,100 - $9,900 / INR 9.1L - 9.9L) across 5 branches
-- Total Value: $162,000 / INR ~1.34 Cr to evade CTR threshold ($10,000 / INR 10 Lakh)
-- Governing Rules: FinCEN 31 CFR § 1010.314 & PMLA Section 12
-- ----------------------------------------------------------------------------
INSERT INTO RISK_COPILOT.RAW.CUSTOMERS (CUSTOMER_ID, FULL_NAME, SEGMENT, KYC_RISK_RATING, CITY, IS_PEP, ONBOARDED_DATE, OCCUPATION, DECLARED_ANNUAL_INCOME)
VALUES ('CUST-9821', 'Rajesh K. Verma', 'INDIVIDUAL', 'HIGH', 'Mumbai', FALSE, '2026-01-10', 'Retail Trader', 600000)
ON CONFLICT (CUSTOMER_ID) DO NOTHING;

INSERT INTO RISK_COPILOT.RAW.ACCOUNTS (ACCOUNT_ID, CUSTOMER_ID, ACCOUNT_TYPE, OPEN_DATE, STATUS, CURRENT_BALANCE)
VALUES ('ACC0009821', 'CUST-9821', 'SAVINGS', '2026-01-15', 'ACTIVE', 1450000.00)
ON CONFLICT (ACCOUNT_ID) DO NOTHING;

INSERT INTO RISK_COPILOT.RAW.SYNTH_SCENARIOS (ACCOUNT_ID, CUSTOMER_ID, SCENARIO)
SELECT 'ACC0009821', 'CUST-9821', 'STRUCTURING'
WHERE NOT EXISTS (SELECT 1 FROM RISK_COPILOT.RAW.SYNTH_SCENARIOS WHERE ACCOUNT_ID='ACC0009821');

DELETE FROM RISK_COPILOT.RAW.TRANSACTIONS WHERE ACCOUNT_ID='ACC0009821';

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

-- ----------------------------------------------------------------------------
-- 2. SCENARIO 2: Money Mule Ring & Dormancy Bursts (12 Accounts)
-- Pattern: Dormant student accounts receiving bursts of 30 UPI/IMPS deposits from
--          30 distinct remitters, with 92% outflowed in 24h via RTGS to EXT-BENF-003 (AE geo)
-- Governing Rules: AML-POL 4.2(a-e) & AML-POL 7.1
-- ----------------------------------------------------------------------------
-- Re-apply mule demographic profiles
UPDATE RISK_COPILOT.RAW.CUSTOMERS c
SET ONBOARDED_DATE='2026-06-15', OCCUPATION='Student', DECLARED_ANNUAL_INCOME=180000, KYC_RISK_RATING='HIGH'
FROM RISK_COPILOT.RAW.SYNTH_SCENARIOS s
WHERE s.CUSTOMER_ID=c.CUSTOMER_ID AND s.SCENARIO='MULE';

-- ----------------------------------------------------------------------------
-- 3. SCENARIO 3: Circular Layering / Round-Tripping (6 Accounts, 2 Rings)
-- Pattern: Circular funds (₹25,00,000) routed A -> B -> C -> A within 72h via NEFT
-- Governing Rules: AML-POL 4.4 Round-Tripping and Layering
-- ----------------------------------------------------------------------------
-- (Ensures 3-hop rings exist across current accounts with shared infrastructure)

-- ----------------------------------------------------------------------------
-- 4. SCENARIO 4: Credit Risk EWS Stressed Portfolios
-- Pattern: Borrowers sliding into SMA-1 / SMA-2 with 2+ NACH bounces,
--          >90% working capital limit utilization, and 30%+ drop in sales velocity
-- Governing Rules: CR-POL 4.1 (SMA Classification) & CR-POL 5.3 (EWS Triggers)
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 5. SCENARIO 5: Basel III Liquidity Coverage Ratio (LCR) Deterioration
-- Pattern: LCR dropping from 157.8% to 113.9% (Amber zone <115%) driven by
--          non-operational wholesale deposit run-offs and Level 2A cap constraints
-- Governing Rules: ALM-POL 5.1 (110% Floor) & ALM-POL 6.2 (Stress Scenarios)
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 6. Trigger Dynamic Pipeline Refresh
-- ----------------------------------------------------------------------------
ALTER DYNAMIC TABLE RISK_COPILOT.CURATED.DT_ACCOUNT_SIGNALS REFRESH;
ALTER DYNAMIC TABLE RISK_COPILOT.CURATED.DT_FRAUD_ALERTS REFRESH;
ALTER DYNAMIC TABLE RISK_COPILOT.CURATED.DT_LOAN_EWS REFRESH;
ALTER DYNAMIC TABLE RISK_COPILOT.CURATED.DT_LCR_DAILY REFRESH;
