"""
transcription_tests_snippets.py — plain-assert tests for the CALL & VOICE-NOTE
TRANSCRIPTION organiser (#92, §21). Pure stdlib, deterministic (no clock, no
network, no model). `python transcription_tests_snippets.py` or import +
run_all().
"""
try:  # Django harness
    from core.logic import transcription as T
except ImportError:  # standalone
    import transcription as T  # noqa: E402


# --------------------------------------------------------------- duration

def test_clamp_duration():
    assert T.clamp_duration(0) == 0
    assert T.clamp_duration("90") == 90
    assert T.clamp_duration(90.9) == 90
    assert T.clamp_duration(-5) == 0
    assert T.clamp_duration("junk") == 0
    assert T.clamp_duration(None) == 0
    assert T.clamp_duration(10 ** 9) == T.MAX_DURATION


def test_fmt_duration():
    assert T.fmt_duration(0) == "0:00"
    assert T.fmt_duration(5) == "0:05"
    assert T.fmt_duration(65) == "1:05"
    assert T.fmt_duration(600) == "10:00"
    assert T.fmt_duration(3661) == "1:01:01"


# --------------------------------------------------------------- transcript helpers

def test_word_count_and_reading_time():
    assert T.word_count("") == 0
    assert T.word_count(None) == 0
    assert T.word_count("hello  world") == 2
    assert T.reading_time("") == 0
    # 161 words -> just over WPM(160) -> 2 minutes
    assert T.reading_time(" ".join(["w"] * 161)) == 2
    assert T.reading_time("one two three") == 1  # any words => at least 1


# --------------------------------------------------------------- validate

def test_validate():
    assert T.validate({"title": "Call with Rahim"}) == []
    assert "empty_title" in T.validate({"title": "   "})
    assert "bad_source" in T.validate({"title": "x", "source": "nope"})
    # claiming an auto transcript with no text is dishonest -> rejected
    assert "auto_without_text" in T.validate(
        {"title": "x", "source": "auto", "transcript": ""})
    assert T.validate({"title": "x", "source": "auto",
                       "transcript": "hi there"}) == []


# --------------------------------------------------------------- normalize

def test_normalize_total_shape():
    n = T.normalize_note({"title": "  Meeting  ", "duration": "120",
                          "date": "2026-10-14"})
    assert n["title"] == "Meeting"
    assert n["duration"] == 120
    assert n["transcript"] == ""
    assert n["source"] == ""          # no text => no provenance claimed
    assert n["consent_ack"] is False  # never defaults to True
    assert n["words"] == 0 and n["read_min"] == 0
    for k in ("audio_ref", "notes", "problems"):
        assert k in n


def test_normalize_forces_manual_source():
    # text present, source blank -> only a human could have typed it => manual
    n = T.normalize_note({"title": "x", "transcript": "line one\nline two"})
    assert n["source"] == "manual"
    assert n["words"] == 4
    # never auto-promotes to "auto"
    assert n["source"] != "auto"


def test_normalize_never_claims_auto_from_empty():
    n = T.normalize_note({"title": "x", "source": "auto", "transcript": ""})
    assert n["source"] == ""  # empty text can't be an auto transcript


# --------------------------------------------------------------- search / stats

def test_search_notes():
    rows = [
        {"id": 1, "title": "Call with doctor", "transcript": "blood pressure"},
        {"id": 2, "title": "Grocery note", "notes": "rice and oil"},
        {"id": 3, "title": "Meeting", "transcript": "budget review"},
    ]
    allr = T.search_notes(rows, "")
    assert len(allr) == 3 and allr[0]["id"] == 1  # order preserved, id kept
    assert [r["id"] for r in T.search_notes(rows, "blood")] == [1]
    assert [r["id"] for r in T.search_notes(rows, "oil")] == [2]
    assert T.search_notes(rows, "zzz") == []


def test_note_stats():
    rows = [
        {"title": "a", "duration": 60, "transcript": "hi"},
        {"title": "b", "duration": 120},
        {"title": "c", "duration": 30, "transcript": ""},
    ]
    s = T.note_stats(rows)
    assert s["count"] == 3
    assert s["total_duration"] == 210
    assert s["total_duration_human"] == "3:30"
    assert s["transcribed"] == 1
    assert s["untranscribed"] == 2


# --------------------------------------------------------------- STT seam

def test_transcribe_request_no_key_is_honest():
    r = T.transcribe_request(
        {"title": "x", "audio_ref": "note1.m4a", "duration": 60}, has_key=False)
    assert r["ready"] is False
    assert r["ai_required"] is True
    assert r["marker"] == T.STT_MARKER
    assert r["provider_integration"] == "transcription"
    assert r["transcript"] == ""  # NEVER fabricates


def test_transcribe_request_ready_with_key_but_still_no_text():
    r = T.transcribe_request(
        {"title": "x", "audio_ref": "note1.m4a", "duration": 60}, has_key=True)
    assert r["ready"] is True
    assert r["marker"] == ""
    assert r["payload"]["audio_ref"] == "note1.m4a"
    assert r["payload"]["duration"] == 60
    assert r["transcript"] == ""  # module itself never produces text


def test_transcribe_request_missing_inputs():
    r = T.transcribe_request({"title": "x"}, has_key=True)
    assert r["ready"] is False
    assert "no_audio_ref" in r["missing"]
    assert "no_duration" in r["missing"]


def run_all():
    import sys
    g = globals()
    fns = [g[n] for n in sorted(g) if n.startswith("test_") and callable(g[n])]
    for fn in fns:
        fn()
    print(f"transcription: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
