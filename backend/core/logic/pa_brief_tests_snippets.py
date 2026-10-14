"""
pa_brief_tests_snippets.py — plain-assert tests for core.logic.pa_brief
(PA meeting reminder + 1-page brief, §14 #104). NOT a Django TestCase. Smoke:
    python3 -c "import core.logic.pa_brief_tests_snippets as t; t.run_all()"
Deterministic assembly — every assert is hand-verified.
"""
from datetime import datetime

try:  # Django harness
    from core.logic import pa_brief as PB
except ImportError:  # standalone
    import pa_brief as PB  # noqa: E402


# --------------------------------------------------------------- leads
def test_clean_leads_filters_and_sorts():
    assert PB.clean_leads([60, 1440, 60, 999]) == [1440, 60]   # dedup, drop 999
    assert PB.clean_leads(None) == list(PB.DEFAULT_LEADS)
    assert PB.clean_leads([]) == list(PB.DEFAULT_LEADS)
    assert PB.clean_leads(["bad"]) == list(PB.DEFAULT_LEADS)
    assert PB.clean_leads([0]) == [0]                          # at-time is valid


def test_reminder_times_drops_past_and_sorts():
    now = datetime(2026, 1, 1, 9, 0)
    start = datetime(2026, 1, 2, 9, 0)   # 24h out
    times = PB.reminder_times(start, leads=[1440, 60, 0], now=now)
    # 1440-before == now exactly -> dropped (<= now); 60 & 0 kept, ascending
    assert times == sorted(times)
    assert start not in [t for t in times if False]  # (no-op guard)
    assert len(times) == 2


def test_reminder_times_empty_for_bad_start():
    assert PB.reminder_times(None, leads=[60]) == []


def test_reminder_summary_all_past_flag():
    now = datetime(2026, 1, 2, 10, 0)
    start = datetime(2026, 1, 2, 9, 0)   # already started
    s = PB.reminder_summary(start, leads=[60, 0], now=now)
    assert s["count"] == 0
    assert s["next"] is None
    assert s["all_past"] is True


def test_reminder_summary_future():
    now = datetime(2026, 1, 1, 9, 0)
    start = datetime(2026, 1, 2, 9, 0)
    s = PB.reminder_summary(start, leads=[60, 30], now=now)
    assert s["count"] == 2 and s["all_past"] is False
    assert s["next"] is not None


# --------------------------------------------------------------- brief assembly
def _meeting(**kw):
    base = {"title": "Vendor review", "start": "2026-01-02T15:00",
            "duration_min": 45}
    base.update(kw)
    return base


def test_assemble_core_and_shape():
    b = PB.assemble_brief(_meeting())
    for k in ("title", "has_core", "when", "where", "who", "what", "agenda",
              "prep", "note", "missing", "ai_enhanced", "mock"):
        assert k in b, k
    assert b["has_core"] is True
    assert b["ai_enhanced"] is False and b["mock"] is True
    assert b["when"]["duration_min"] == 45
    assert b["when"]["start"] == "2026-01-02T15:00:00"
    assert b["when"]["end"] == "2026-01-02T15:45:00"


def test_assemble_missing_sections_are_honest():
    b = PB.assemble_brief(_meeting())  # no place/people/what/agenda/prep
    assert set(b["missing"]) == {"where", "who", "what", "agenda", "prep"}
    assert b["agenda"] == [] and b["prep"] == []   # never fabricated


def test_assemble_bullets_from_string_or_list():
    b = PB.assemble_brief(_meeting(
        agenda="- Q1 numbers\n- Renewal terms\n• Risks",
        prep=["Bring contract", "Bring contract", " "]))
    assert b["agenda"] == ["Q1 numbers", "Renewal terms", "Risks"]
    assert b["prep"] == ["Bring contract"]   # de-duped, blank dropped
    assert "agenda" not in b["missing"] and "prep" not in b["missing"]


def test_assemble_organiser_first_in_who():
    b = PB.assemble_brief(_meeting(organiser="Mr Rahman",
                                   people=["Sadia", "Mr Rahman", "Karim"]))
    assert b["who"] == ["Mr Rahman", "Sadia", "Karim"]   # organiser first, dedup


def test_assemble_is_deterministic():
    m = _meeting(agenda=["A", "B"], prep=["X"], place="Office")
    assert PB.assemble_brief(m) == PB.assemble_brief(m)


def test_has_core_false_without_title_or_start():
    assert PB.assemble_brief({"start": "2026-01-02T15:00"})["has_core"] is False
    assert PB.assemble_brief({"title": "X"})["has_core"] is False


# --------------------------------------------------------------- completeness
def test_completeness_scale():
    assert PB.brief_completeness({"title": "X"}) == 0          # no core
    bare = PB.brief_completeness(_meeting())                    # core only
    assert bare == 20
    full = PB.brief_completeness(_meeting(
        place="Office", people=["A"], purpose="Review",
        agenda=["x"], prep=["y"]))
    assert full == 100
    assert bare < full


# --------------------------------------------------------------- share text
def test_share_text_omits_empty_sections():
    txt = PB.share_text(_meeting(place="Office", agenda=["Q1"], prep=["Slides"]))
    assert "Vendor review" in txt
    assert "Where: Office" in txt
    assert "Agenda:" in txt and "- Q1" in txt
    assert "[ ] Slides" in txt
    assert "Who:" not in txt      # no people entered -> section omitted


def test_share_text_uses_caller_labels():
    txt = PB.share_text(_meeting(place="Office"),
                        labels={"where": "WHERE_LBL", "when": "WHEN_LBL"})
    assert "WHERE_LBL: Office" in txt
    assert "WHEN_LBL:" in txt


# --------------------------------------------------------------- ai seam
def test_ai_plan_is_gated_and_sends_only_owner_data():
    plan = PB.ai_brief_plan(_meeting(what="Review", agenda=["A"]), lang="bn")
    assert plan["ai_required"] is True and plan["mock"] is False
    assert plan["task"] == "enhance_meeting_brief"
    assert plan["lang"] == "bn"
    assert set(plan["source"].keys()) == {"title", "what", "agenda",
                                          "prep", "note"}
    # unknown lang falls back honestly
    assert PB.ai_brief_plan(_meeting(), lang="fr")["lang"] == "bn"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_brief: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
