-- ============================================================================
-- Risk, Fraud, and Regulatory Intelligence Copilot
-- Step 1: Database and Schemas Setup
-- ============================================================================

CREATE DATABASE IF NOT EXISTS RISK_COPILOT;

-- Raw ingestion layer for transactional logs, accounts, loans, and policy text
CREATE SCHEMA IF NOT EXISTS RISK_COPILOT.RAW;

-- Curated layer for dynamic tables, semantic models, and search indexes
CREATE SCHEMA IF NOT EXISTS RISK_COPILOT.CURATED;

-- Application layer for Streamlit state, investigation cases, and audit logs
CREATE SCHEMA IF NOT EXISTS RISK_COPILOT.APP;

-- Stage for Streamlit code artifacts
CREATE STAGE IF NOT EXISTS RISK_COPILOT.APP.STREAMLIT_STAGE DIRECTORY = (ENABLE = TRUE);
