"""
AF-9 — AI sales agent RESOLUTION metrics (HubSpot / Agentforce style), pure.

  resolution rate  AI-handled chats with NO customer-initiated handoff
                   (complaint, refund, abuse) within 72 h of the first AI
                   reply. Only chats whose 72 h window has CLOSED are counted
                   (open ones are reported as `pending`) — never a guess.
  deflection       AI-handled chats (window closed) where no person from the
                   shop had to write at all within the 72 h.
  handoff rate     handoffs (approval-queue rows) per chat, by reason.
  AI-assisted      orders placed from a chat the AI answered + their revenue.
  first response   seconds from a customer's message (first of a burst) to the
                   shop's first reply of any kind (AI, rule, holding line,
                   person) — p50 / p95.
  knowledge gaps   what customers asked when the AI had to say "someone will
                   reply" (unknown product / not sure): the top questions,
                   contacts partly hidden — the seller adds these to the
                   catalog / FAQ.

Input per chat: {"messages": [{"direction", "source", "status", "risk", "ts",
"text"}], "orders": [{"total", "status", "ts"}]} with epoch seconds.
"""
from collections import Counter
from decimal import Decimal, InvalidOperation

from . import bizagent as BZ

WINDOW_S = 72 * 3600
CUSTOMER_HANDOFF = (BZ.RISK_COMPLAINT, BZ.RISK_REFUND, BZ.RISK_ABUSE)
GAP_RISKS = (BZ.RISK_UNKNOWN_PRODUCT, BZ.RISK_LOW_CONF)
SENT = ("sent", "delivered", "read")
AI_SOURCES = ("ai", "rule", "fallback")
APPROVAL = ("pending_approval", "approved", "rejected")


def _dec(v):
    try:
        return Decimal(str(v or 0))
    except (InvalidOperation, ValueError):
        return Decimal(0)


def _pct(a, b):
    return round(100.0 * a / b, 1) if b else None


def _q(xs, q):
    if not xs:
        return None
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round(q * (len(xs) - 1)))))
    return int(xs[k])


def thread_outcome(msgs, now_ts):
    """-> {"ai_handled", "resolved" (True/False/None=window open), "deflected",
    "handoffs": [reason], "frt": [s], "gaps": [text], "first_ai_ts"}."""
    msgs = sorted(msgs or [], key=lambda m: m["ts"])
    ai = [m for m in msgs if m["direction"] == "out" and m.get("source") in AI_SOURCES
          and m.get("status") in SENT]
    out = {"ai_handled": bool(ai), "resolved": None, "deflected": None, "handoffs": [],
           "frt": [], "gaps": [], "first_ai_ts": ai[0]["ts"] if ai else None}
    approvals = [m for m in msgs if m["direction"] == "out" and m.get("status") in APPROVAL]
    out["handoffs"] = [m.get("risk") or BZ.RISK_LOW_CONF for m in approvals]
    # knowledge gaps: the customer message right before an unknown/unsure handoff
    for m in approvals:
        if m.get("risk") in GAP_RISKS:
            prev = [x for x in msgs if x["direction"] == "in" and x["ts"] <= m["ts"]]
            if prev and (prev[-1].get("text") or "").strip() and not prev[-1]["text"].startswith("["):
                out["gaps"].append(prev[-1]["text"])
    # first response time per burst
    waiting = None
    for m in msgs:
        if m["direction"] == "in":
            if waiting is None:
                waiting = m["ts"]
        elif m.get("status") in SENT and waiting is not None:
            out["frt"].append(max(0, m["ts"] - waiting))
            waiting = None
    if ai:
        t0 = ai[0]["ts"]
        end = t0 + WINDOW_S
        in_win = [m for m in msgs if t0 <= m["ts"] <= end]
        cust = any(m.get("status") in APPROVAL and m.get("risk") in CUSTOMER_HANDOFF
                   for m in in_win)
        human = any(m["direction"] == "out" and m.get("source") == "human" for m in in_win)
        if now_ts >= end:                 # only CLOSED windows count (no early bias)
            out["resolved"] = not cust
            out["deflected"] = not (human or cust)
    return out


def summarize(threads, now_ts):
    """threads: [{"messages": [...], "orders": [...]}] -> the metrics dict."""
    from .bizagent_handoff import hide_contact
    n = len(threads)
    res = {"chats": n, "ai_handled": 0, "resolved": 0, "unresolved": 0, "pending": 0,
           "deflected": 0, "deflection_base": 0, "handoffs": 0, "handoff_by_reason": {},
           "ai_orders": 0, "ai_revenue": "0", "frt_p50_s": None, "frt_p95_s": None,
           "knowledge_gaps": []}
    reasons, frt, gaps, revenue = Counter(), [], Counter(), Decimal(0)
    for t in threads:
        o = thread_outcome(t.get("messages"), now_ts)
        reasons.update(o["handoffs"])
        frt += o["frt"]
        for g in o["gaps"]:
            key = " ".join(hide_contact(g).lower().split())[:120]
            gaps[key] += 1
        if not o["ai_handled"]:
            continue
        res["ai_handled"] += 1
        if o["resolved"] is True:
            res["resolved"] += 1
        elif o["resolved"] is False:
            res["unresolved"] += 1
        else:
            res["pending"] += 1
        if o["deflected"] is not None:
            res["deflection_base"] += 1
            res["deflected"] += int(o["deflected"])
        for od in t.get("orders") or []:
            if od.get("status") != "cancelled":
                res["ai_orders"] += 1
                revenue += _dec(od.get("total"))
    res["handoffs"] = sum(reasons.values())
    res["handoff_by_reason"] = dict(sorted(reasons.items()))
    res["handoff_rate"] = _pct(res["handoffs"], n)
    res["resolution_rate"] = _pct(res["resolved"], res["resolved"] + res["unresolved"])
    res["deflection_rate"] = _pct(res["deflected"], res["deflection_base"])
    res["ai_revenue"] = BZ._fmt_money(revenue)
    res["frt_p50_s"], res["frt_p95_s"] = _q(frt, 0.5), _q(frt, 0.95)
    res["knowledge_gaps"] = [{"q": q, "n": c} for q, c in gaps.most_common(10)]
    return res
