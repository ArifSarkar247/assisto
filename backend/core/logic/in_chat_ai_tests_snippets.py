"""
in_chat_ai_tests_snippets.py — plain-assert tests for the IN-CHAT AI helper
(#97, §21). Pure stdlib. `python in_chat_ai_tests_snippets.py` or import and
call run_all(). The engine is deterministic, so every assertion is hand-verified
against fixed inputs. No DB, no AI, no network.
"""

try:  # Django harness: core.logic.in_chat_ai_tests_snippets
    from core.logic import in_chat_ai as A
except ImportError:  # standalone
    import in_chat_ai as A  # noqa: E402


# --------------------------------------------------------------- validation

def test_validate_ok_each_action():
    assert A.validate("summarise", messages=[{"text": "hi"}]) == []
    assert A.validate("translate", text="hello") == []
    assert A.validate("tone", text="hello", tone="polite") == []


def test_validate_catches_each_bad_input():
    assert "bad_action" in A.validate("delete_all", text="x")
    assert "empty_thread" in A.validate("summarise", messages=[])
    assert "empty_text" in A.validate("translate", text="   ")
    assert "empty_text" in A.validate("tone", text="")
    assert "bad_tone" in A.validate("tone", text="x", tone="sarcastic")
    assert "bad_direction" in A.validate("translate", text="x",
                                         direction="fr2de")


# --------------------------------------------------------------- determinism

def test_each_action_is_deterministic():
    msgs = [{"text": "let's meet at 5", "mine": True},
            {"text": "ok see you", "mine": False}]
    assert A.summarise_thread(msgs) == A.summarise_thread(msgs)
    assert A.translate_message("hello", "auto") == A.translate_message("hello", "auto")
    assert A.adjust_tone("send it now", "firmer") == A.adjust_tone("send it now", "firmer")


# --------------------------------------------------------------- honest flags

def test_every_result_carries_honest_marker_and_mock():
    for res in (
        A.summarise_thread([{"text": "a", "mine": True}]),
        A.translate_message("hello"),
        A.adjust_tone("hello", "polite"),
    ):
        assert res["mock"] is True
        assert res["marker"] == A.MARKER_KEY
        assert "ai_required" in res


def test_summarise_and_tone_need_no_key_but_translate_does():
    # summarise + tone are fully served by the mock (no key needed).
    assert A.summarise_thread([{"text": "a"}])["ai_required"] is False
    assert A.adjust_tone("a", "polite")["ai_required"] is False
    # translate honestly needs the key for a REAL render (never fabricated).
    assert A.translate_message("hello")["ai_required"] is True


# --------------------------------------------------------------- summarise

def test_summarise_counts_and_caps_bullets_to_three():
    msgs = [{"text": f"message number {i}", "mine": i % 2 == 0}
            for i in range(6)]
    res = A.summarise_thread(msgs)
    assert res["count"] == 6
    assert len(res["bullets"]) == 3           # newest three
    # bullets stay in chronological order (oldest of the three first)
    assert res["bullets"][0]["text"].endswith("3")
    assert res["bullets"][-1]["text"].endswith("5")


def test_summarise_ignores_empty_messages():
    msgs = [{"text": "  ", "mine": True}, {"text": "real one", "mine": False}]
    res = A.summarise_thread(msgs)
    assert res["count"] == 1
    assert res["bullets"][0]["who"] == "them"


def test_summarise_who_labels():
    res = A.summarise_thread([{"text": "mine here", "mine": True}])
    assert res["bullets"][0]["who"] == "you"


# --------------------------------------------------------------- translate

def test_translate_auto_detects_direction_from_script():
    assert A.translate_message("hello there", "auto")["direction"] == "en2bn"
    assert A.translate_message("আমি ভালো আছি", "auto")["direction"] == "bn2en"


def test_translate_never_fabricates_a_translation():
    res = A.translate_message("hello", "en2bn")
    # honest: no invented translation; the real render is key-gated.
    assert res["translated"] == ""
    assert res["source"] == "hello"
    assert res["ai_required"] is True


def test_translate_respects_explicit_direction():
    assert A.translate_message("hello", "bn2en")["direction"] == "bn2en"


# --------------------------------------------------------------- tone

def test_tone_shorter_keeps_first_sentence():
    res = A.adjust_tone("First point. Second point. Third point.", "shorter")
    assert res["result"] == "First point"


def test_tone_wraps_deterministically_per_preset():
    polite = A.adjust_tone("send the file", "polite")["result"]
    assert polite.startswith("Could you please")
    assert "send the file" in polite
    formal = A.adjust_tone("send the file", "formal")["result"]
    assert formal.startswith("Dear recipient")


def test_tone_unknown_preset_falls_back_to_polite_shape():
    # validate() flags it, but the generator stays total (never crashes).
    res = A.adjust_tone("x", "whatever")
    assert res["result"].startswith("Could you please")


# --------------------------------------------------------------- dispatch

def test_run_dispatches_and_reports_problems():
    ok = A.run("tone", text="hello", tone="warmer")
    assert ok["action"] == "tone"
    assert ok["problems"] == []
    assert "🙂" in ok["result"]
    bad = A.run("summarise", messages=[])
    assert "empty_thread" in bad["problems"]
    assert bad["mock"] is True


def test_run_bad_action_is_honest_not_crash():
    res = A.run("rm -rf", text="x")
    assert "bad_action" in res["problems"]
    assert res["mock"] is True


# --------------------------------------------------------------- runner

def run_all():
    import sys
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"in_chat_ai: {len(fns)} checks passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
