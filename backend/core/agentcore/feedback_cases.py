"""AF-12 — feedback -> test cases (Agentforce "feedback loop" parity).

A thumbs-down on an agent run (POST agent-core/runs/<id>/feedback value -1,
optional note) creates ONE candidate eval case in a review queue:

  * stored in the generic PaCollectionItem store, collection COLLECTION
    (not in GENERIC_COLLECTIONS, so no user API can read or edit it), owned by
    the run's user (deleted with the account);
  * only MASKED text is ever stored: the goal is the run's masked goal, the
    note was masked by the feedback view, and both are masked AGAIN with a
    fresh vault here; a text that still looks like a phone / NID / account /
    e-mail is dropped, never stored. Crisis runs never become cases.
  * a later thumbs-up withdraws a still-pending candidate.

Owner Admin -> Agent runs -> Feedback queue: the owner writes the expected
behaviour (tools that must run / must never run, the end state, a note) and
approves, or rejects. `manage.py agent_eval_export_feedback` appends every
approved, not-yet-exported case to evals/feedback/<topic>.jsonl (idempotent:
id fb-<run id>, never twice) — the integrator commits that file; it joins
the topic's eval set for the live eval (agent_eval --live) and is shape-
checked in CI (masked, tools inside the topic allow-lists).
"""
import json
import os
import re

from django.utils import timezone

from . import topics as TP
from . import trust as T

COLLECTION = "agentcore/eval_cands"
STATUSES = ("pending", "approved", "rejected", "withdrawn")
STATES = ("done", "waiting_approval", "failed", "budget")
FEEDBACK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "evals", "feedback")
_BN = re.compile(r"[ঀ-৿]")


def _clean(text, limit):
    """Masked with a fresh vault; '' when anything raw is left."""
    t = T.Vault().mask(str(text or ""))[:limit]
    return "" if T.has_raw_pii(t) else t


def _rows():
    from ..models import PaCollectionItem
    return PaCollectionItem.objects.filter(collection=COLLECTION)


def for_run(run):
    return _rows().filter(user_id=run.user_id, data__run_id=run.pk).first()


def on_feedback(run, value, note_masked=""):
    """Called by the feedback view. -> the candidate row or None."""
    from ..models import PaCollectionItem
    from . import runner as RN
    row = for_run(run)
    if value != -1:
        if row is not None and row.data.get("status") == "pending":
            row.data = dict(row.data, status="withdrawn", decided_at=timezone.now().isoformat())
            row.save(update_fields=["data", "updated_at"])
        return row
    if RN.crisis_of(run) or not (run.goal.text_masked or "").strip():
        return None                     # a crisis handover is never a test case
    goal = _clean(run.goal.text_masked, 600)
    if not goal:
        return None
    pair = [k or "" for k in RN.topics_of(run)]
    data = {"run_id": run.pk, "topic": pair[0] if pair else "", "topics": pair,
            "lang": "bn" if _BN.search(goal) else "en", "goal": goal,
            "note": _clean(note_masked, 300),
            "tools_ran": sorted({s.tool for s in run.steps.filter(kind="tool", state="done")}),
            "state": run.state, "error": run.error_code[:40],
            "status": "pending", "created_at": timezone.now().isoformat()}
    if row is None:
        return PaCollectionItem.objects.create(user_id=run.user_id, collection=COLLECTION, data=data)
    if row.data.get("status") in ("pending", "withdrawn"):
        row.data = dict(row.data, **data)
        row.save(update_fields=["data", "updated_at"])
    return row


def allowed_tools(cand):
    return sorted(TP.combined([k for k in cand.get("topics") or [cand.get("topic") or ""]])["tools"])


def validate_decision(cand, post):
    """-> (clean, problems) for an owner's approve form."""
    tools = [t for t in post.getlist("tools")] if hasattr(post, "getlist") else list(post.get("tools") or [])
    forbid = [t for t in post.getlist("forbid")] if hasattr(post, "getlist") else list(post.get("forbid") or [])
    ok = set(allowed_tools(cand))
    problems = []
    if any(t not in ok for t in tools):
        problems.append("tool_not_in_topic")
    from . import tools as TL
    if any(TL.get(t) is None for t in forbid):
        problems.append("unknown_tool")
    if set(tools) & set(forbid):
        problems.append("tool_both")
    no_tools = str(post.get("no_tools") or "") == "1"
    if not tools and not no_tools:
        problems.append("no_expectation")
    if tools and no_tools:
        problems.append("tools_and_none")
    state = str(post.get("state") or "done")
    if state not in STATES:
        problems.append("bad_state")
    raw_note = str(post.get("expected") or "")
    expected = _clean(raw_note, 300)
    if raw_note.strip() and not expected:
        problems.append("note_has_private_number")
    return ({"expect_tools": sorted(set(tools)), "expect_forbid": sorted(set(forbid)),
             "expect_state": state, "no_tools": no_tools, "expected": expected}, problems)


def decide(row, decision, clean=None, actor=None):
    if row.data.get("status") not in ("pending", "approved", "rejected"):
        return row
    d = dict(row.data, status="approved" if decision == "approve" else "rejected",
             decided_at=timezone.now().isoformat(),
             decided_by=getattr(actor, "pk", None))
    if decision == "approve":
        d.update(clean or {})
        d["exported_at"] = None
    row.data = d
    row.save(update_fields=["data", "updated_at"])
    return row


def to_case(row):
    d = row.data
    exp = {"tools": list(d.get("expect_tools") or []), "forbid": list(d.get("expect_forbid") or []),
           "answer_has": [], "no_tools": bool(d.get("no_tools")),
           "expected_note": d.get("expected") or d.get("note") or ""}
    if d.get("expect_state") and d["expect_state"] != "done":
        exp["state"] = d["expect_state"]
    pair = [k for k in d.get("topics") or [d.get("topic") or ""]]
    topic = pair[0] or "general"
    case = {"id": "fb-%d" % d["run_id"], "topic": topic, "lang": d.get("lang") or "bn",
            "src": "feedback", "intent": "feedback", "goal": d["goal"], "expect": exp,
            "seed": [k for k in pair if k], "classify": True}
    if len(pair) > 1:
        exp["topics"] = pair
    return case


def export(out_dir=None, dry_run=False, now=None):
    """Append every approved, not-yet-exported case to <out_dir>/<topic>.jsonl.
    -> {"written": n, "skipped_dupe": n, "files": [paths]}. Idempotent."""
    out_dir = out_dir or FEEDBACK_DIR
    now = now or timezone.now()
    rows = [r for r in _rows().order_by("id") if r.data.get("status") == "approved"
            and not r.data.get("exported_at")]
    by_topic = {}
    for r in rows:
        c = to_case(r)
        if T.has_raw_pii(json.dumps(c, ensure_ascii=False)):
            continue                     # never written un-masked (defence in depth)
        by_topic.setdefault(c["topic"], []).append((r, c))
    out = {"written": 0, "skipped_dupe": 0, "files": []}
    for topic, items in sorted(by_topic.items()):
        path = os.path.join(out_dir, "%s.jsonl" % topic)
        seen = set()
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                seen = {json.loads(x)["id"] for x in f if x.strip()}
        lines = []
        for r, c in items:
            if c["id"] in seen:
                out["skipped_dupe"] += 1
            else:
                seen.add(c["id"])
                lines.append(json.dumps(c, ensure_ascii=False, sort_keys=True) + "\n")
                out["written"] += 1
        if dry_run:
            continue
        if lines:
            os.makedirs(out_dir, exist_ok=True)
            with open(path, "a", encoding="utf-8") as f:
                f.writelines(lines)
            out["files"].append(path)
        for r, _ in items:
            r.data = dict(r.data, exported_at=now.isoformat())
            r.save(update_fields=["data", "updated_at"])
    return out


def load_committed(topic, base=None):
    """The committed feedback cases of `topic` (for the live eval + CI shape)."""
    path = os.path.join(base or FEEDBACK_DIR, "%s.jsonl" % topic)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [json.loads(x) for x in f if x.strip()]


def queue(limit=100):
    rows = list(_rows().order_by("-id")[:limit * 2])
    pending = [r for r in rows if r.data.get("status") == "pending"][:limit]
    decided = [r for r in rows if r.data.get("status") in ("approved", "rejected")][:limit]
    return pending, decided


def stats():
    from collections import Counter
    c = Counter(r.data.get("status") for r in _rows().only("data"))
    return {k: c.get(k, 0) for k in STATUSES}
