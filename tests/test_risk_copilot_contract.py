from pathlib import Path
ROOT=Path(__file__).parents[1]
def test_required_files():
    required=[
      "risk_copilot/sql/08_continuous_evidence_and_coco_layer.sql",
      "risk_copilot/sql/09_coco_governed_actions.sql",
      "mcp/risk_mcp/server.py",
      ".cortex/skills/fraud-investigator/SKILL.md",
      "scripts/inject_demo_event.py"]
    assert all((ROOT/p).exists() for p in required)
def test_guarded_action_language():
    s=(ROOT/"mcp/risk_mcp/server.py").read_text()
    assert "human_review_required" in s
    assert "does not file externally" in s
