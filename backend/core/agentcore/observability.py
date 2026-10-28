"""AF-8 — Agent Core observability + owner alerts (Agentforce "Agent
Observability / Command Center" parity).

stats(since, until) — over the window: runs, failure rate, invalid-plan rate,
planner p50/p95 latency, per tool: calls, error rate, p50/p95 latency; cost per
successful task; approval accept / reject / expire rates. Owner Admin -> Agent
runs shows it (web/owner/views_agent.py).

alert_checks(now) — ops_watch checks [(key, bad, detail, need)] over the last
`window_min` minutes, thresholds from cfg() (owner-editable on the Agent runs
page; stored in AdminFlagState key "agent_obs", no migration). Minimum sample
sizes keep a quiet hour from paging anybody; need=2 = two bad ops_watch runs
in a row (10 minutes) before the first alert; core.ops_health.evaluate then
dedupes (alert once, remind daily, tell on recovery). Owner-only delivery via
push.notify_owner. Numbers only — never a goal, an answer or a user.
"""
import math
from datetime import timedelta

from django.db.models import Count, Q, Sum
from django.utils import timezone

CONFIG_KEY = "agent_obs"
DEFAULTS = {
    "window_min": 15,           # alert window
    "min_runs": 10,             # runs needed before rate alerts may fire
    "run_failure_pct": 20.0,    # failed + budget + expired of finished runs
    "invalid_plan_pct": 10.0,   # runs with a rejected plan
    "tool_min_calls": 10,       # calls of one tool needed before its alerts may fire
    "tool_error_pct": 25.0,
    "tool_p95_ms": 5000,
    "plan_p95_ms": 15000,       # one planner call (the AI provider)
    "cost_per_task_usd": 0.05,  # real provider cost per successful task
}
LIMITS = {"window_min": (5, 1440), "min_runs": (1, 10000), "run_failure_pct": (1, 100),
          "invalid_plan_pct": (1, 100), "tool_min_calls": (1, 10000), "tool_error_pct": (1, 100),
          "tool_p95_ms": (100, 600000), "plan_p95_ms": (100, 600000),
          "cost_per_task_usd": (0.0001, 100)}
FAILED = ("failed", "budget", "expired")


def cfg():
    out = dict(DEFAULTS)
    try:
        from ..models import AdminFlagState
        row = AdminFlagState.objects.filter(key=CONFIG_KEY).first()
        for k, v in ((row.state or {}).get("thresholds") or {}).items() if row else ():
            if k in DEFAULTS:
                out[k] = type(DEFAULTS[k])(v)
    except Exception:  # noqa: BLE001 — a config problem never stops the watch
        pass
    return out


def validate(data):
    """Owner form -> (clean, problems)."""
    clean, probs = {}, []
    for k, (lo, hi) in LIMITS.items():
        raw = data.get(k)
        if raw in (None, ""):
            continue
        try:
            v = type(DEFAULTS[k])(float(str(raw).strip()))
        except (TypeError, ValueError):
            probs.append(k)
            continue
        if not lo <= v <= hi:
            probs.append(k)
            continue
        clean[k] = v
    return clean, probs


def save(clean, actor=None):
    from ..models import AdminFlagState
    row, _ = AdminFlagState.objects.get_or_create(key=CONFIG_KEY)
    state = dict(row.state or {})
    before = dict(state.get("thresholds") or {})
    after = dict(before, **clean)
    state["thresholds"] = after
    row.state = state
    row.audit = ([{"by": getattr(actor, "pk", None), "at": timezone.now().isoformat(),
                   "thresholds": after}] + list(row.audit or []))[:50]
    row.save(update_fields=["state", "audit", "updated_at"])
    return before, after


def pctl(values, p):
    """Nearest-rank percentile (None for no data)."""
    v = sorted(x for x in values if x is not None)
    if not v:
        return None
    return v[max(0, min(len(v) - 1, int(math.ceil(p / 100.0 * len(v))) - 1))]


def _rate(a, b):
    return round(100.0 * a / b, 1) if b else None


def stats(since, until=None):
    from ..models import AgentApproval, AgentRun, AgentStep
    until = until or timezone.now()
    runs = AgentRun.objects.filter(created_at__gte=since, created_at__lt=until)
    agg = runs.aggregate(n=Count("id"), done=Count("id", filter=Q(state="done")),
                         failed=Count("id", filter=Q(state__in=FAILED)), cost=Sum("cost_usd"))
    n, done, failed = agg["n"] or 0, agg["done"] or 0, agg["failed"] or 0
    invalid = runs.filter(steps__kind="plan", steps__state="failed").distinct().count()
    steps = AgentStep.objects.filter(run__in=runs)
    plan_ms = list(steps.filter(kind="plan").exclude(latency_ms=0).values_list("latency_ms", flat=True))
    tools = {}
    for tool, state, ms in steps.filter(kind="tool", state__in=("done", "failed")) \
            .values_list("tool", "state", "latency_ms"):
        t = tools.setdefault(tool, {"tool": tool, "calls": 0, "errors": 0, "ms": []})
        t["calls"] += 1
        if state == "failed":
            t["errors"] += 1
        elif ms:
            t["ms"].append(ms)
    rows = []
    for t in sorted(tools.values(), key=lambda x: (-x["calls"], x["tool"])):
        rows.append({"tool": t["tool"], "calls": t["calls"], "errors": t["errors"],
                     "error_pct": _rate(t["errors"], t["calls"]),
                     "p50_ms": pctl(t["ms"], 50), "p95_ms": pctl(t["ms"], 95)})
    aps = AgentApproval.objects.filter(created_at__gte=since, created_at__lt=until)
    ap = {s: aps.filter(status=s).count() for s in ("approved", "rejected", "expired", "pending")}
    decided = ap["approved"] + ap["rejected"] + ap["expired"]
    cost = float(agg["cost"] or 0.0)
    return {
        "runs": n, "done": done, "failed": failed, "finished": done + failed,
        "failure_pct": _rate(failed, done + failed), "invalid_plan_runs": invalid,
        "invalid_plan_pct": _rate(invalid, n),
        "plan_p50_ms": pctl(plan_ms, 50), "plan_p95_ms": pctl(plan_ms, 95),
        "tools": rows, "cost_usd": round(cost, 6),
        "cost_per_success_usd": round(cost / done, 6) if done else None,
        "approvals": dict(ap, decided=decided, accept_pct=_rate(ap["approved"], decided),
                          reject_pct=_rate(ap["rejected"], decided),
                          expire_pct=_rate(ap["expired"], decided)),
    }


def alert_checks(now=None):
    """[(key, bad, detail, need)] for manage.py ops_watch."""
    c = cfg()
    now = now or timezone.now()
    s = stats(now - timedelta(minutes=c["window_min"]), now)
    win = "last %d min" % c["window_min"]
    out = []
    enough = s["finished"] >= c["min_runs"]
    fp = s["failure_pct"] or 0.0
    out.append(("agent:run_failure", enough and fp > c["run_failure_pct"],
                "agent runs failing: %.1f%% of %d finished (%s; bar %.0f%%)"
                % (fp, s["finished"], win, c["run_failure_pct"]), 2))
    ip = s["invalid_plan_pct"] or 0.0
    out.append(("agent:invalid_plan", s["runs"] >= c["min_runs"] and ip > c["invalid_plan_pct"],
                "agent invalid plans: %.1f%% of %d runs (%s; bar %.0f%%)"
                % (ip, s["runs"], win, c["invalid_plan_pct"]), 2))
    p95 = s["plan_p95_ms"] or 0
    out.append(("agent:plan_p95", s["runs"] >= c["min_runs"] and p95 > c["plan_p95_ms"],
                "agent planner p95 %d ms (%s; bar %d ms)" % (p95, win, c["plan_p95_ms"]), 2))
    cps = s["cost_per_success_usd"] or 0.0
    out.append(("agent:cost_per_task", s["done"] >= c["min_runs"] and cps > c["cost_per_task_usd"],
                "agent cost per successful task $%.4f (%s; bar $%.4f)"
                % (cps, win, c["cost_per_task_usd"]), 2))
    from . import tools as TL
    seen = {t["tool"]: t for t in s["tools"]}
    names = sorted(set(TL.REGISTRY) | set(seen))
    for name in names:            # every tool, so a quiet tool's old alert recovers
        t = seen.get(name) or {"tool": name, "calls": 0, "errors": 0, "error_pct": None, "p95_ms": None}
        big = t["calls"] >= c["tool_min_calls"]
        out.append((("agent:tool_err:" + t["tool"])[:64], big and (t["error_pct"] or 0) > c["tool_error_pct"],
                    "agent tool %s errors %.1f%% of %d calls (%s; bar %.0f%%)"
                    % (t["tool"], t["error_pct"] or 0, t["calls"], win, c["tool_error_pct"]), 2))
        out.append((("agent:tool_p95:" + t["tool"])[:64], big and (t["p95_ms"] or 0) > c["tool_p95_ms"],
                    "agent tool %s p95 %d ms (%s; bar %d ms)"
                    % (t["tool"], t["p95_ms"] or 0, win, c["tool_p95_ms"]), 2))
    return out
