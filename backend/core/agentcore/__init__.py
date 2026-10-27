"""Assisto Agent Core (flag `agent_core`, default OFF).

Design: owner_actions/AGENT_CORE_DESIGN_BN.md. Layers (dependencies point
down only):

  views.py      channels -> API (/api/v1/agent-core/...)
  runner.py     orchestrator: goal -> plan -> act -> observe -> re-plan,
                budgets, leases, approvals pause/resume, audit
  planner.py    ONE strict-JSON tool-call plan per LLM call, through the AI
                router (core.ai.generate; credits charged there)
  topics.py     topics, instructions, allow-listed tools, keyword classifier
  tools.py      versioned typed tools over existing modules (contract.py)
  trust.py      masking vault, sealing, approvals, audit events
  evals/        testing center: goal sets, scripted planner, graders
"""
FLAG = "agent_core"
