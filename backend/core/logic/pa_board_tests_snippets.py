"""
pa_board_tests_snippets.py — plain-assert tests for the PA Board-meeting pack
assembler (#116, §14, CORPORATE). Pure stdlib. `python pa_board_tests_snippets.py`
or import and call run_all(). Deterministic (no clock), so every assertion is
hand-verified against fixed inputs. No DB, no AI, no network.
"""

try:  # Django harness
    from core.logic import pa_board as A
except ImportError:  # standalone
    import pa_board as A  # noqa: E402


def _roles(pack):
    return [ln["role"] for ln in pack["lines"]]


def _items(pack):
    return [ln for ln in pack["lines"] if ln["role"] == A.ROLE_ITEM]


def _phrases(pack):
    return [ln["phrase"] for ln in pack["lines"] if ln["phrase"]]


# --------------------------------------------------------------- validation

def test_validate_requires_title_and_agenda():
    p = A.validate(title="", agenda=[])
    assert "empty_title" in p
    assert "empty_agenda" in p


def test_validate_flags_blank_resolution():
    p = A.validate(title="Q3 Board", agenda=[{"title": "Opening"}],
                   resolutions=[{"text": ""}])
    assert "empty_resolution" in p


def test_validate_clean_pack_has_no_problems():
    assert A.validate(title="Q3 Board", agenda=[{"title": "Opening"}]) == []


# --------------------------------------------------------------- determinism

def test_build_is_deterministic():
    kw = dict(title="Q3 Board", meeting_date="2026-10-14",
              agenda=[{"title": "Opening", "minutes": 5},
                      {"title": "Finance", "presenter": "CFO", "minutes": 20}],
              documents=[{"title": "Accounts", "ref": "A1"}],
              attendees=[{"name": "Chair", "status": "present"},
                         {"name": "Dir B", "status": "apology"}],
              resolutions=[{"text": "Approve accounts", "proposer": "CFO"}],
              quorum=2)
    assert A.build(**kw) == A.build(**kw)


# --------------------------------------------------------------- honest flags

def test_pack_carries_marker_and_mock():
    pack = A.build(title="T", agenda=[{"title": "x"}])
    assert pack["mock"] is True
    assert pack["marker"] == A.MARKER_KEY
    assert pack["ai_required"] is False


# --------------------------------------------------------------- structure

def test_sections_present_and_ordered():
    pack = A.build(title="Board", agenda=[{"title": "Open"}],
                   documents=[{"title": "Paper"}],
                   attendees=[{"name": "Chair"}],
                   resolutions=[{"text": "Motion"}])
    sect = [ln["phrase"] for ln in pack["lines"] if ln["role"] == A.ROLE_SECTION]
    assert sect == [A.PHRASE_AGENDA, A.PHRASE_DOCUMENTS,
                    A.PHRASE_ATTENDEES, A.PHRASE_RESOLUTIONS]
    # title line first with the PACK cover phrase
    assert pack["lines"][0]["role"] == A.ROLE_TITLE
    assert pack["lines"][0]["phrase"] == A.PHRASE_PACK


def test_agenda_items_are_numbered_1_based():
    pack = A.build(title="T", agenda=[{"title": "A"}, {"title": "B"},
                                      {"title": "C"}])
    nums = [ln["num"] for ln in _items(pack)
            if ln["text"] in ("A", "B", "C")]
    assert nums == [1, 2, 3]


def test_owner_text_is_verbatim():
    pack = A.build(title="T", agenda=[{"title": "EXACT ITEM 42"}])
    assert any(ln["text"] == "EXACT ITEM 42" for ln in pack["lines"])


def test_empty_section_gets_note_not_fake_content():
    pack = A.build(title="T", agenda=[{"title": "only agenda"}])
    # documents / attendees / resolutions each get a NOTE(empty), no items
    notes = [ln for ln in pack["lines"] if ln["role"] == A.ROLE_NOTE]
    assert len(notes) == 3
    assert all(n["phrase"] == A.PHRASE_EMPTY for n in notes)


# --------------------------------------------------------------- attendance

def test_attendance_counts():
    c = A.count_attendance([{"name": "A", "status": "present"},
                            {"name": "B", "status": "present"},
                            {"name": "C", "status": "apology"},
                            {"name": "D", "status": "absent"},
                            {"name": "", "status": "present"}])  # unnamed dropped
    assert c == {"present": 2, "apologies": 1, "absent": 1, "named": 4}


def test_quorum_met_and_short():
    met = A.build(title="T", agenda=[{"title": "x"}],
                  attendees=[{"name": "A"}, {"name": "B"}, {"name": "C"}],
                  quorum=3)
    assert A.PHRASE_QUORUM_MET in _phrases(met)
    short = A.build(title="T", agenda=[{"title": "x"}],
                    attendees=[{"name": "A"}], quorum=3)
    assert A.PHRASE_QUORUM_SHORT in _phrases(short)


def test_no_quorum_line_when_not_specified():
    pack = A.build(title="T", agenda=[{"title": "x"}],
                   attendees=[{"name": "A"}])
    assert A.PHRASE_QUORUM_MET not in _phrases(pack)
    assert A.PHRASE_QUORUM_SHORT not in _phrases(pack)


# --------------------------------------------------------------- roll-ups

def test_resolution_to_vote_rollup_counts():
    pack = A.build(title="T", agenda=[{"title": "x"}],
                   resolutions=[{"text": "R1"}, {"text": "R2"}])
    rv = [ln for ln in pack["lines"] if ln["phrase"] == A.PHRASE_TO_VOTE]
    assert rv and rv[0]["num"] == 2


def test_total_minutes_sum_only_when_present():
    pack = A.build(title="T", agenda=[{"title": "a", "minutes": 10},
                                      {"title": "b", "minutes": 15}])
    tm = [ln for ln in pack["lines"] if ln["phrase"] == A.PHRASE_TOTAL_MINUTES]
    assert tm and tm[0]["num"] == 25
    none = A.build(title="T", agenda=[{"title": "a"}])
    assert not any(ln["phrase"] == A.PHRASE_TOTAL_MINUTES
                   for ln in none["lines"])


# --------------------------------------------------------------- key-gated AI

def test_ai_summary_seam_sets_flag_but_always_assembles():
    pack = A.build(title="T", agenda=[{"title": "real item"}],
                   want_ai_summary=True)
    assert pack["ai_required"] is True
    # deterministic content is STILL assembled (never fabricated / withheld)
    assert any(ln["text"] == "real item" for ln in pack["lines"])


# --------------------------------------------------------------- runner

def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"pa_board: {len(fns)} checks passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
