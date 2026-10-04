# Risk, Fraud & Regulatory Intelligence Copilot — Merged Hackathon Edition

This repository combines the original fraud/risk project with a governed **continuous evidence + CoCo/MCP action layer**.

## End-to-end story

**Input → Processing → Output**

1. **Input:** transaction/account event enters `RAW.TRANSACTIONS`.
2. **Processing:** existing dynamic tables detect risk; Step 8 continuously materializes findings and evidence.
3. **Copilot:** CoCo uses governed views/skills and the existing Cortex Agent.
4. **Output:** explainable finding → evidence chain → investigation case → audit package.
5. **Governance:** actions are non-destructive and marked for human review.

## Existing capabilities retained

- Synthetic banking/AML/fraud scenarios
- Fraud/AML dynamic tables
- Policy/regulatory document corpus
- Cortex Search + semantic model
- Cortex Agent
- SAR/STR draft workflow and guardrails
- Liquidity/ALM and credit EWS scenarios
- Streamlit application
- Automated validation

## Added capabilities

- `risk_copilot/sql/08_continuous_evidence_and_coco_layer.sql`
- `risk_copilot/sql/09_coco_governed_actions.sql`
- `risk_copilot/sql/10_coco_validation.sql`
- `.cortex/skills/` — fraud investigator, evidence builder, regulatory analyst, audit report
- `mcp/risk_mcp/server.py` — governed MCP tools
- `scripts/inject_demo_event.py`
- `scripts/setup_new_account.ps1`
- `.env.example`

## New Snowflake account

Run the SQL scripts in order:

`01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10`

The existing project uses `COMPUTE_WH`; create it first if your new account does not have it.

Example:

```sql
CREATE DATABASE IF NOT EXISTS RISK_COPILOT;
CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
  WAREHOUSE_SIZE = 'X-SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;
```

Then execute the numbered SQL files in Snowflake.

## MCP

From PowerShell:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r mcp\risk_mcp\requirements.txt
```

Set Snowflake environment variables, then configure the MCP server using `mcp/cortex-mcp.sample.json`.

For production, prefer SSO/key-pair/OAuth instead of storing a password.

## Streamlit Community Cloud

Deploy `risk_copilot_app/streamlit_app.py` from the `main` branch with Python 3.11. Keep the app private and add the Snowflake connection under the app's Community Cloud secrets as `[connections.snowflake]`. Grant only the app role the minimum database privileges needed.

## Demo input

Use the existing fraud engine plus a small suspicious sequence:

- normal activity
- new device
- rapid high-value transfers
- location/device change

Then ask CoCo:

> Investigate the latest high-risk finding. Explain the risk score, show the supporting evidence, identify the applicable policy/regulatory basis, and create an investigation case with an audit package.

## 3–5 minute demo

**0:00–0:30 — Input:** inject suspicious transaction sequence.

**0:30–1:15 — Processing:** show Snowflake RAW → dynamic table → risk alert → evidence.

**1:15–2:15 — Investigation:** CoCo/Fraud Investigator retrieves the high-risk finding and evidence.

**2:15–3:00 — Regulatory:** Regulatory Analyst retrieves verified policy/regulatory context.

**3:00–4:00 — Output:** validate → create investigation → generate audit package → show audit trail.

### Golden demo sentence

> A suspicious event enters the platform → Snowflake continuously detects and enriches the signal → CoCo explains it using governed evidence and regulatory context → the system produces an audit-ready investigation with human-controlled actions.
