"""
doctor_serial_tests_snippets.py — plain-assert tests for the Doctor appointment
tracker logic (#187, §20, advanced). Pure stdlib. Deterministic — `now` is
always passed in, so every assertion is hand-verified. No DB, no AI, no network.

    python3 doctor_serial_tests_snippets.py   (or import and call run_all())
"""

try:  # Django harness
    from core.logic import doctor_serial as D
except ImportError:  # standalone
    import doctor_serial as D  # noqa: E402


NOW = "2026-10-14 10:00"


def _appts():
    return [
        {"id": 1, "doctor": "Dr A", "specialty": "cardiology",
         "place": "City Hospital", "date": "2026-10-20", "time": "18:00",
         "serial": "12", "status": "booked", "created": "2026-10-01"},
        {"id": 2, "doctor": "Dr B", "date": "2026-10-14", "time": "16:00",
         "serial": "3", "status": "booked", "created": "2026-10-02"},  # due today
        {"id": 3, "doctor": "Dr C", "date": "2026-10-05", "time": "10:00",
         "status": "done", "created": "2026-09-20"},  # past, done
        {"id": 4, "doctor": "Dr D", "date": "2026-10-06", "time": "09:00",
         "status": "booked", "created": "2026-09-21"},  # past, not done -> missed
        {"id": 5, "doctor": "Dr E", "date": "2026-10-25",
         "status": "cancelled", "created": "2026-09-22"},  # cancelled -> past
    ]


# --------------------------------------------------------------- validation

def test_validate_requires_doctor_and_date():
    p = D.validate(doctor="", date_str="")
    assert "empty_doctor" in p and "empty_date" in p


def test_validate_bad_date_and_time():
    p = D.validate(doctor="Dr", date_str="not-a-date", time_str="99:99")
    assert "bad_date" in p
    assert "bad_time" in p


def test_validate_bad_status():
    assert "bad_status" in D.validate(doctor="Dr", date_str="2026-10-20",
                                      status="weird")


def test_validate_clean_ok():
    assert D.validate(doctor="Dr A", date_str="2026-10-20", time_str="18:00",
                      status="booked") == []


# --------------------------------------------------------------- classify

def test_upcoming_vs_past_bucketing():
    o = D.organise(_appts(), NOW)
    up_ids = {v["id"] for v in o["upcoming"]}
    past_ids = {v["id"] for v in o["past"]}
    assert up_ids == {1, 2}          # future dated + due-today
    assert past_ids == {3, 4, 5}     # done, missed, cancelled


def test_missed_is_derived_not_stored():
    o = D.organise(_appts(), NOW)
    missed = [v for v in o["past"] if v["derived"] == "missed"]
    assert [v["id"] for v in missed] == [4]
    # the stored status is still 'booked' — we never mutate it
    assert missed[0]["status"] == "booked"


def test_cancelled_goes_past_regardless_of_future_date():
    o = D.organise(_appts(), NOW)
    canc = [v for v in o["past"] if v["id"] == 5][0]
    assert canc["derived"] == "cancelled"


def test_reminder_due_within_window_only():
    o = D.organise(_appts(), NOW)
    due = [v["id"] for v in o["upcoming"] if v["reminder_due"]]
    # id 2 is 6h away (<=24h window) and booked -> due; id 1 is ~6 days -> not due
    assert due == [2]
    assert o["reminders_due"] == 1


def test_reminder_not_due_for_cancelled_or_done():
    rows = [
        {"id": 10, "doctor": "X", "date": "2026-10-14", "time": "16:00",
         "status": "cancelled"},
        {"id": 11, "doctor": "Y", "date": "2026-10-14", "time": "16:00",
         "status": "done"},
    ]
    o = D.organise(rows, NOW)
    assert o["reminders_due"] == 0


# --------------------------------------------------------------- order

def test_upcoming_sorted_soonest_first():
    o = D.organise(_appts(), NOW)
    assert [v["id"] for v in o["upcoming"]] == [2, 1]  # 6h then 6d


def test_past_sorted_most_recent_first():
    o = D.organise(_appts(), NOW)
    ids = [v["id"] for v in o["past"]]
    # 5 is cancelled (undated-for-sort via future date but hours_until positive)
    # among dated past: 4 (Oct 6) is more recent than 3 (Oct 5)
    assert ids.index(4) < ids.index(3)


def test_undated_active_stays_upcoming():
    rows = [{"id": 20, "doctor": "Z", "date": "", "status": "booked"}]
    o = D.organise(rows, NOW)
    assert [v["id"] for v in o["upcoming"]] == [20]
    assert o["upcoming"][0]["when"] == ""


# --------------------------------------------------------------- determinism

def test_organise_is_deterministic():
    assert D.organise(_appts(), NOW) == D.organise(_appts(), NOW)


def test_counts_rollup():
    o = D.organise(_appts(), NOW)
    assert o["counts"]["booked"] == 2   # ids 1,2 (future booked)
    assert o["counts"]["done"] == 1
    assert o["counts"]["missed"] == 1
    assert o["counts"]["cancelled"] == 1
    assert o["total"] == 5


# --------------------------------------------------------------- seams

def test_booking_seam_honest_when_unconfigured():
    s = D.booking_seam(configured=False)
    assert s["required"] is True
    assert s["configured"] is False
    assert s["mock"] is True
    assert s["never_fabricates"] is True
    assert s["partner_slug"] == D.BOOKING_PARTNER_SLUG


def test_booking_seam_configured_flips_mock_off():
    s = D.booking_seam(configured=True)
    assert s["configured"] is True and s["mock"] is False


def test_never_fabricates_serial():
    # a row with NO serial keeps an empty serial — the tracker never invents one
    rows = [{"id": 1, "doctor": "X", "date": "2026-10-20", "status": "booked"}]
    o = D.organise(rows, NOW)
    assert o["upcoming"][0]["serial"] == ""


def test_reminder_seam_computes_but_does_not_send():
    s = D.reminder_seam()
    assert s["computes_due"] is True
    assert s["sends"] is False
    assert s["wired"] is False
    assert s["window_hours"] == D.REMINDER_WINDOW_HOURS


# --------------------------------------------------------------- labels

def test_specialty_label_bilingual_and_echo():
    assert D.specialty_label("en", "cardiology") == "Cardiology"
    assert D.specialty_label("bn", "cardiology") != "Cardiology"
    assert D.specialty_label("en", "Neuro-custom") == "Neuro-custom"


# --------------------------------------------------------------- runner

def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"doctor_serial: {len(fns)} checks passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
