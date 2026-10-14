"""
pa_projects_tests_snippets.py — plain-assert tests for PA CORPORATE project
tracking (#120, §14). Pure stdlib. `python pa_projects_tests_snippets.py` or
import and call run_all(). Deterministic (overdue from a passed-in `now`).
"""
from datetime import datetime

try:  # Django harness
    from core.logic import pa_projects as T
except ImportError:  # standalone
    import pa_projects as T  # noqa: E402


NOW = datetime(2026, 10, 14, 12, 0, 0)


# --------------------------------------------------------------- normalize
def test_normalize_project_defaults_and_clamp():
    p = T.normalize_project({"name": "  Site   Launch ", "percent": 140,
                             "status": "??"})
    assert p["name"] == "Site Launch"
    assert p["percent"] == 100               # clamped
    assert p["status"] == T.ST_PLANNED       # bad status falls back


def test_normalize_project_percent_junk():
    assert T.normalize_project({"name": "x", "percent": "abc"})["percent"] == 0
    assert T.normalize_project({"name": "x", "percent": -5})["percent"] == 0


def test_normalize_milestone_and_risk_fallbacks():
    assert T.normalize_milestone({"title": "a", "status": "??"})["status"] == T.MS_PENDING
    r = T.normalize_risk({"label": "x", "severity": "???", "status": "???"})
    assert r["severity"] == T.RISK_MED and r["status"] == T.RISK_OPEN


# --------------------------------------------------------------- validate
def test_validate_project():
    assert T.validate_project({"name": "P", "due": "2026-12-01"}) == []
    assert "name_required" in T.validate_project({"name": "  "})
    assert "bad_due" in T.validate_project({"name": "x", "due": "nope"})


def test_validate_milestone():
    assert T.validate_milestone({"title": "M"}) == []
    assert "title_required" in T.validate_milestone({"title": ""})
    assert "bad_date" in T.validate_milestone({"title": "x", "date": "nope"})


# --------------------------------------------------------------- derived
def test_is_overdue_from_passed_in_now():
    assert T.is_overdue({"name": "x", "status": "active", "due": "2026-10-10"},
                        NOW) is True
    assert T.is_overdue({"name": "x", "status": "active", "due": "2026-10-20"},
                        NOW) is False
    # closed projects are never overdue
    assert T.is_overdue({"name": "x", "status": "done", "due": "2026-10-10"},
                        NOW) is False
    # no due date → never overdue
    assert T.is_overdue({"name": "x", "status": "active", "due": ""},
                        NOW) is False


def test_days_to_due():
    assert T.days_to_due({"name": "x", "due": "2026-10-20"}, NOW) == 6
    assert T.days_to_due({"name": "x", "due": "2026-10-10"}, NOW) == -4
    assert T.days_to_due({"name": "x", "due": ""}, NOW) is None


def test_milestone_progress():
    ms = [{"title": "a", "status": "done"}, {"title": "b", "status": "pending"},
          {"title": "c", "status": "missed"}, {"title": "d", "status": "done"}]
    p = T.milestone_progress(ms)
    assert p == {"total": 4, "done": 2, "missed": 1, "pending": 1, "percent": 50}


# --------------------------------------------------------------- classify
def test_classify_done():
    assert T.classify_project({"name": "x", "status": "done"}, NOW) == T.HEALTH_DONE


def test_classify_overdue_beats_at_risk():
    # overdue + an open high risk → still classified overdue (overdue wins)
    b = T.classify_project(
        {"name": "x", "status": "active", "due": "2026-10-01"}, NOW,
        risks=[{"label": "r", "severity": "high", "status": "open"}])
    assert b == T.HEALTH_OVERDUE


def test_classify_at_risk_open_high_risk():
    b = T.classify_project(
        {"name": "x", "status": "active", "due": "2026-12-01"}, NOW,
        risks=[{"label": "r", "severity": "high", "status": "open"}])
    assert b == T.HEALTH_AT_RISK


def test_classify_at_risk_missed_milestone():
    b = T.classify_project(
        {"name": "x", "status": "active", "due": "2026-12-01"}, NOW,
        milestones=[{"title": "m", "status": "missed"}])
    assert b == T.HEALTH_AT_RISK


def test_classify_on_track():
    b = T.classify_project(
        {"name": "x", "status": "active", "due": "2026-12-01"}, NOW,
        risks=[{"label": "r", "severity": "low", "status": "open"}],
        milestones=[{"title": "m", "status": "pending"}])
    assert b == T.HEALTH_ON_TRACK


def test_classify_cancelled():
    assert T.classify_project({"name": "x", "status": "cancelled"}, NOW) == T.ST_CANCELLED


# --------------------------------------------------------------- portfolio
def test_portfolio_summary_counts_and_avg():
    projects = [
        {"id": 1, "name": "A", "status": "active", "due": "2026-10-01",
         "percent": 40},   # overdue
        {"id": 2, "name": "B", "status": "active", "due": "2026-12-01",
         "percent": 60},   # at_risk (high risk below)
        {"id": 3, "name": "C", "status": "active", "due": "2026-12-01",
         "percent": 80},   # on_track
        {"id": 4, "name": "D", "status": "done", "percent": 100},   # done
        {"id": 5, "name": "E", "status": "cancelled", "percent": 10},  # cancelled
    ]
    milestones = []
    risks = [{"project_id": 2, "label": "r", "severity": "high", "status": "open"}]
    s = T.portfolio_summary(projects, NOW, milestones, risks)
    assert s["total"] == 5
    assert s["overdue"] == 1 and s["at_risk"] == 1 and s["on_track"] == 1
    assert s["done"] == 1 and s["cancelled"] == 1
    assert s["open"] == 3 and s["closed"] == 2
    # weighted/averaged over OPEN only: (40+60+80)//3 = 60
    assert s["avg_percent"] == 60
    # worst-health-first ordering: overdue (id 1) comes before at_risk (id 2)
    assert s["projects"][0]["id"] == 1 and s["projects"][0]["health"] == "overdue"
    assert s["projects"][1]["id"] == 2 and s["projects"][1]["health"] == "at_risk"


def test_portfolio_summary_empty():
    s = T.portfolio_summary([], NOW)
    assert s["total"] == 0 and s["avg_percent"] == 0 and s["projects"] == []


# --------------------------------------------------------------- seam
def test_status_synthesis_seam_is_honest_and_empty():
    r = T.status_synthesis_seam(
        {"name": "Launch", "status": "active"},
        milestones=[{"title": "m", "status": "done"}],
        risks=[{"label": "r", "severity": "high", "status": "open"}])
    assert r["required"] is True and r["ai_required"] is True and r["mock"] is True
    assert r["text"] == ""               # never fabricates a narrative
    assert r["marker"] == T.AI_MARKER_KEY
    assert r["facts"]["project"]["name"] == "Launch"
    assert len(r["facts"]["milestones"]) == 1 and len(r["facts"]["risks"]) == 1


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_projects: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
