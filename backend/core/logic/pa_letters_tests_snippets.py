"""
pa_letters_tests_snippets.py — plain-assert tests for the PA Letters / notices /
memos generator (#107, §14). Pure stdlib. `python pa_letters_tests_snippets.py`
or import and call run_all(). The engine is deterministic (date passed in), so
every assertion is hand-verified against fixed inputs. No DB, no AI, no network.
"""

try:  # Django harness
    from core.logic import pa_letters as A
except ImportError:  # standalone
    import pa_letters as A  # noqa: E402


def _roles(doc):
    return [ln["role"] for ln in doc["lines"]]


def _phrases(doc):
    return [ln["phrase"] for ln in doc["lines"] if ln["phrase"]]


# --------------------------------------------------------------- validation

def test_validate_requires_subject_everywhere():
    assert "empty_subject" in A.validate("letter", to="X", subject="")
    assert "empty_subject" in A.validate("notice", subject="")


def test_validate_recipient_rules():
    # letter/memo/application need a recipient; notice does not
    assert "empty_recipient" in A.validate("letter", to="", subject="S")
    assert "empty_recipient" in A.validate("application", to="", subject="S")
    assert "empty_recipient" not in A.validate("notice", to="", subject="S")


def test_validate_bad_type():
    assert "bad_type" in A.validate("poem", to="X", subject="S")


# --------------------------------------------------------------- determinism

def test_build_is_deterministic():
    a = A.build("letter", to="Boss", sender="PA", subject="Leave",
                body_points=["p1", "p2"], date="2026-10-14")
    b = A.build("letter", to="Boss", sender="PA", subject="Leave",
                body_points=["p1", "p2"], date="2026-10-14")
    assert a == b


# --------------------------------------------------------------- honest flags

def test_every_doc_carries_marker_and_mock():
    for t in A.TYPES:
        doc = A.build(t, to="X", sender="Y", subject="S",
                      body_points=["b"], date="D")
        assert doc["mock"] is True
        assert doc["marker"] == A.MARKER_KEY
        assert "ai_required" in doc


# --------------------------------------------------------------- structure

def test_letter_structure_order():
    doc = A.build("letter", to="Dr Karim", sender="PA Office",
                  subject="Appointment", body_points=["Line one."],
                  date="14 Oct 2026")
    roles = _roles(doc)
    assert roles[0] == A.ROLE_DATE
    assert A.ROLE_RECIPIENT in roles
    assert A.ROLE_SUBJECT in roles
    assert A.ROLE_SALUTATION in roles
    assert A.ROLE_BODY in roles
    assert roles[-2] == A.ROLE_CLOSING   # closing then sender
    assert roles[-1] == A.ROLE_SENDER
    # letter uses the "dear" salutation + "yours sincerely" closing phrases
    assert A.PHRASE_DEAR in _phrases(doc)
    assert A.PHRASE_YOURS_SINCERELY in _phrases(doc)


def test_application_uses_respected_and_faithfully():
    doc = A.build("application", to="The Principal", sender="Student",
                  subject="Fee waiver", body_points=["Please consider."],
                  date="D")
    ph = _phrases(doc)
    assert A.PHRASE_RESPECTED in ph
    assert A.PHRASE_YOURS_FAITHFULLY in ph


def test_memo_has_labelled_header_block():
    doc = A.build("memo", to="All staff", sender="Director",
                  subject="Holiday", body_points=["Office closed."], date="D")
    roles = _roles(doc)
    assert roles[0] == A.ROLE_HEADING
    labels = [ln["phrase"] for ln in doc["lines"] if ln["role"] == A.ROLE_LABEL]
    assert labels == [A.PHRASE_TO, A.PHRASE_FROM, A.PHRASE_DATE, A.PHRASE_SUBJECT]


def test_notice_is_general_and_centred():
    doc = A.build("notice", to="", sender="", subject="Water supply",
                  body_points=["Supply cut 2–4pm."], date="14 Oct")
    roles = _roles(doc)
    assert roles[0] == A.ROLE_HEADING
    assert A.PHRASE_NOTICE in _phrases(doc)
    # no recipient line when `to` is empty
    assert A.ROLE_RECIPIENT not in roles


# --------------------------------------------------------------- body points

def test_body_points_passthrough_and_split():
    doc = A.build("letter", to="X", subject="S",
                  body_points="First.\n\nSecond.\n  \nThird.", date="D")
    bodies = [ln["text"] for ln in doc["lines"] if ln["role"] == A.ROLE_BODY]
    assert bodies == ["First.", "Second.", "Third."]  # empties dropped


def test_owner_words_are_verbatim_not_translated():
    doc = A.build("letter", to="X", subject="S",
                  body_points=["EXACT OWNER TEXT 123"], date="D")
    assert any(ln["text"] == "EXACT OWNER TEXT 123"
               for ln in doc["lines"])


# --------------------------------------------------------------- key-gated AI

def test_ai_body_seam_never_fabricates():
    doc = A.build("letter", to="X", subject="S", body_points=None,
                  date="D", want_ai_body=True)
    assert doc["ai_required"] is True
    assert not any(ln["role"] == A.ROLE_BODY for ln in doc["lines"])  # empty body


def test_ai_body_not_required_when_owner_supplies_points():
    doc = A.build("letter", to="X", subject="S", body_points=["mine"],
                  date="D", want_ai_body=True)
    assert doc["ai_required"] is False
    assert any(ln["role"] == A.ROLE_BODY for ln in doc["lines"])


# --------------------------------------------------------------- runner

def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"pa_letters: {len(fns)} checks passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
