"""Agent Core testing center.

  fixtures.py        deterministic per-topic seed data (+ the expected numbers)
  money_goals.py     >= 200 Bangla / English / Banglish goals for topic "money"
  scripted_brain.py  rule-based stand-in for the LLM, plugged in at the AI
                     router's provider seam (core.ai._call_anthropic) so the
                     REAL router, billing charge, masking, validator, tools,
                     approvals and audit all run in CI with no key and no cost
  harness.py         run_case() + grade(): deterministic graders

CI mode proves the engine, tools, trust layer and graders (a model can only
be judged in live mode: manage.py agent_eval --live, owner-approved spend).
"""
