"""
job_hunter_tests_snippets.py — plain-assert tests for core.logic.job_hunter.

NOT a Django TestCase (pure logic, no DB/AI). Smoke locally:

    cd backend && python3 -c "import core.logic.job_hunter_tests_snippets as t; t.run_all()"
"""
from datetime import date

from core.logic import job_hunter as J


TODAY = date(2026, 10, 14)


def _job(**kw):
    base = {"id": 1, "title": "Backend Engineer", "company": "Acme",
            "jd": "python django postgres api", "status": J.STAGE_MATCHED,
            "category": "it", "location": "Dhaka", "salary": 60000,
            "job_type": "full_time", "experience": "mid", "history": []}
    base.update(kw)
    return base


# --- pipeline FSM -----------------------------------------------------------

def test_legal_transitions():
    assert J.can_transition(J.STAGE_MATCHED, J.STAGE_APPLIED)
    assert J.can_transition(J.STAGE_APPLIED, J.STAGE_INTERVIEW)
    assert J.can_transition(J.STAGE_INTERVIEW, J.STAGE_OFFER)
    assert J.can_transition(J.STAGE_INTERVIEW, J.STAGE_REJECTED)


def test_illegal_transitions_blocked():
    # can't skip straight from matched to interview
    assert not J.can_transition(J.STAGE_MATCHED, J.STAGE_INTERVIEW)
    # terminal stages go nowhere
    assert not J.can_transition(J.STAGE_OFFER, J.STAGE_APPLIED)
    assert not J.can_transition(J.STAGE_REJECTED, J.STAGE_APPLIED)
    # no self-loop
    assert not J.can_transition(J.STAGE_APPLIED, J.STAGE_APPLIED)


def test_advance_records_dated_history_and_applied_at():
    app = _job()
    app = J.advance(app, J.STAGE_APPLIED, when=TODAY, note="submitted via Gmail")
    assert app["status"] == J.STAGE_APPLIED
    assert app["applied_at"] == "2026-10-14"
    assert app["history"][-1]["stage"] == J.STAGE_APPLIED
    assert app["history"][-1]["date"] == "2026-10-14"
    assert app["history"][-1]["note"] == "submitted via Gmail"


def test_advance_is_immutable_and_appends():
    app = _job()
    out = J.advance(app, J.STAGE_SAVED, when=TODAY)
    assert app["history"] == []          # original untouched
    assert len(out["history"]) == 1      # append-only


def test_advance_rejects_illegal():
    try:
        J.advance(_job(), J.STAGE_INTERVIEW, when=TODAY)
    except ValueError:
        return
    raise AssertionError("illegal transition was not rejected")


def test_pipeline_progress():
    assert J.pipeline_progress(J.STAGE_APPLIED) == (2, 5)
    assert J.pipeline_progress(J.STAGE_REJECTED)[0] == -1
    assert J.pipeline_progress(J.STAGE_WITHDRAWN)[0] == -1


# --- reminders (deterministic) ---------------------------------------------

def test_reminder_overdue_for_stale_applied():
    app = J.advance(_job(), J.STAGE_APPLIED, when=date(2026, 10, 1))
    r = J.next_reminder(app, today=TODAY)   # applied + 7 days = Oct 8 < Oct 14
    assert r["kind"] == J.STAGE_APPLIED
    assert r["due"] == "2026-10-08"
    assert r["overdue"] is True


def test_reminder_not_yet_due():
    app = J.advance(_job(), J.STAGE_APPLIED, when=date(2026, 10, 13))
    r = J.next_reminder(app, today=TODAY)   # due Oct 20 > today
    assert r["overdue"] is False


def test_no_reminder_for_terminal():
    app = _job(status=J.STAGE_OFFER)
    assert J.next_reminder(app, today=TODAY) is None
    app = _job(status=J.STAGE_REJECTED)
    assert J.next_reminder(app, today=TODAY) is None


def test_reminder_deterministic():
    app = J.advance(_job(), J.STAGE_SAVED, when=date(2026, 10, 10))
    assert J.next_reminder(app, today=TODAY) == J.next_reminder(app, today=TODAY)


# --- filters / search -------------------------------------------------------

def test_filters_category_location_type_experience():
    jobs = [_job(id=1), _job(id=2, category="ngo", location="Khulna",
                             job_type="remote", experience="senior")]
    assert [j["id"] for j in J.filter_jobs(jobs, category="it")] == [1]
    assert [j["id"] for j in J.filter_jobs(jobs, location="khulna")] == [2]
    assert [j["id"] for j in J.filter_jobs(jobs, job_type="remote")] == [2]
    assert [j["id"] for j in J.filter_jobs(jobs, experience="entry")] == []


def test_salary_filter_keeps_unstated_jobs():
    jobs = [_job(id=1, salary=30000), _job(id=2, salary=None)]
    out = J.filter_jobs(jobs, min_salary=50000)
    # id=1 filtered out (too low); id=2 kept (no stated salary — never invented)
    assert [j["id"] for j in out] == [2]


def test_query_matches_across_fields():
    jobs = [_job(id=1, title="Nurse", jd="hospital care"),
            _job(id=2, title="Driver", jd="delivery")]
    assert [j["id"] for j in J.filter_jobs(jobs, query="hospital")] == [1]


# --- salary insight (source-noted, never invented) --------------------------

def test_salary_insight_reports_source_and_range():
    jobs = [_job(id=1, salary=40000), _job(id=2, salary=60000),
            _job(id=3, salary=50000)]
    ins = J.salary_insight(jobs, lang="en", source="BdSample feed")
    assert ins["available"] and ins["min"] == 40000 and ins["max"] == 60000
    assert ins["median"] == 50000
    assert "BdSample feed" in ins["note"]      # source noted, not invented


def test_salary_insight_honest_when_no_data():
    jobs = [_job(id=1, salary=None), _job(id=2, salary=None)]
    ins = J.salary_insight(jobs, lang="en")
    assert ins["available"] is False
    assert "not estimated" in ins["note"].lower()


# --- sources: curated sample + no-scrape gate -------------------------------

def test_sources_never_scrape():
    off = J.sources_state(feed_connected=False, lang="en")
    on = J.sources_state(feed_connected=True, lang="en")
    assert off["scraping"] is False and on["scraping"] is False
    assert off["connected"] is False and on["connected"] is True
    assert "never scrape" in off["note"].lower()


# --- misc -------------------------------------------------------------------

def test_interview_checklist_bilingual_nonempty():
    bn = J.interview_checklist("bn")
    en = J.interview_checklist("en")
    assert len(bn) == len(en) >= 5
    assert bn[0]["text"] != en[0]["text"]       # genuinely localised


def test_stage_label_localised():
    assert J.stage_label("en", J.STAGE_OFFER) == "Offer"
    assert J.stage_label("bn", J.STAGE_OFFER) != "Offer"


def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"job_hunter: {len(fns)} tests passed")


if __name__ == "__main__":
    run_all()
