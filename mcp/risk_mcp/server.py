"""Governed MCP tools for the Risk/Fraud/Regulatory Copilot.
All actions are non-destructive and require human review downstream.
"""
import json, os, uuid
import snowflake.connector
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("risk-copilot-actions")

def get_connection():
    vals = {
        "account": os.getenv("SNOWFLAKE_ACCOUNT"),
        "user": os.getenv("SNOWFLAKE_USER"),
        "password": os.getenv("SNOWFLAKE_PASSWORD"),
        "warehouse": os.getenv("SNOWFLAKE_WAREHOUSE", "COMPUTE_WH"),
        "database": os.getenv("SNOWFLAKE_DATABASE", "RISK_COPILOT"),
        "schema": os.getenv("SNOWFLAKE_SCHEMA", "EVIDENCE"),
        "role": os.getenv("SNOWFLAKE_ROLE"),
    }
    return snowflake.connector.connect(**{k:v for k,v in vals.items() if v})

def fetch(sql, params=()):
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            cols=[d[0] for d in cur.description]
            return [dict(zip(cols,r)) for r in cur.fetchall()]

@mcp.tool()
def get_high_risk_findings(limit: int=10) -> str:
    """Get latest governed high-risk findings."""
    n=max(1,min(int(limit),50))
    return json.dumps(fetch(f"""SELECT FINDING_ID,ALERT_ID,ACCOUNT_ID,CUSTOMER_ID,
      FINDING_TYPE,SEVERITY,RISK_SCORE,SUMMARY,EVIDENCE_COUNT,CONFIDENCE,CREATED_AT
      FROM RISK_COPILOT.CURATED.V_RISK_COPILOT_FINDINGS
      WHERE RISK_SCORE>=60 ORDER BY RISK_SCORE DESC,CREATED_AT DESC LIMIT {n}"""),default=str)

@mcp.tool()
def get_finding_evidence(finding_id: str) -> str:
    """Retrieve the evidence chain for one finding."""
    return json.dumps(fetch("""SELECT * FROM RISK_COPILOT.CURATED.V_RISK_COPILOT_EVIDENCE
      WHERE FINDING_ID=%s ORDER BY EVENT_TS,EVIDENCE_ID""",(finding_id,)),default=str)

@mcp.tool()
def validate_finding(finding_id: str) -> str:
    """Validate that a finding has supporting evidence before action."""
    rows=fetch("""SELECT f.FINDING_ID,f.RISK_SCORE,f.SEVERITY,COUNT(e.EVIDENCE_ID) EVIDENCE_COUNT
      FROM RISK_COPILOT.EVIDENCE.RISK_FINDINGS f
      LEFT JOIN RISK_COPILOT.EVIDENCE.RISK_EVIDENCE e ON e.FINDING_ID=f.FINDING_ID
      WHERE f.FINDING_ID=%s GROUP BY 1,2,3""",(finding_id,))
    if not rows: return json.dumps({"status":"ERROR","message":"FINDING_NOT_FOUND"})
    r=rows[0]; count=int(r["EVIDENCE_COUNT"] or 0); score=float(r["RISK_SCORE"] or 0)
    return json.dumps({"status":"VALID" if score<60 or count>0 else "INSUFFICIENT_EVIDENCE",
      "finding_id":finding_id,"risk_score":score,"evidence_count":count,
      "human_review_required":True})

@mcp.tool()
def create_investigation(finding_id: str, priority: str="HIGH", summary: str="") -> str:
    """Create a non-destructive investigation case."""
    p=priority.upper()
    if p not in {"LOW","MEDIUM","HIGH","CRITICAL"}:
        return json.dumps({"status":"ERROR","message":"INVALID_PRIORITY"})
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT RISK_COPILOT.APP.CREATE_INVESTIGATION_CASE(%s,%s,%s)",
                        (finding_id,p,summary))
            result=cur.fetchone()[0]; conn.commit()
    return json.dumps(result,default=str)

@mcp.tool()
def generate_audit_package(finding_id: str) -> str:
    """Generate an evidence-backed audit package; does not file externally."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT RISK_COPILOT.APP.GENERATE_AUDIT_PACKAGE(%s)",(finding_id,))
            result=cur.fetchone()[0]
    return json.dumps(result,default=str)

@mcp.tool()
def request_fraud_team_notification(case_id: str, message: str) -> str:
    """Record a pending notification request. No external message is sent by this demo tool."""
    aid="ACT-"+str(uuid.uuid4())
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("""INSERT INTO RISK_COPILOT.EVIDENCE.AUDIT_ACTIONS
              (ACTION_ID,CASE_ID,ACTION_TYPE,TARGET_SYSTEM,REQUESTED_BY,STATUS,RESULT)
              SELECT %s,%s,'NOTIFY_FRAUD_TEAM','SLACK',CURRENT_USER(),'PENDING',PARSE_JSON(%s)""",
              (aid,case_id,json.dumps({"message":message})))
            conn.commit()
    return json.dumps({"status":"PENDING","action_id":aid,"case_id":case_id,
                       "target":"SLACK","human_review_required":True})

if __name__=="__main__":
    mcp.run(transport="stdio")
