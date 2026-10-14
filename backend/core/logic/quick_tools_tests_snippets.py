"""
quick_tools_tests_snippets.py — plain-assert tests for the QUICK TOOLS toolbox
(#17, §6, built to §21). Pure stdlib. `python quick_tools_tests_snippets.py`
or import and call run_all(). The engine is deterministic, so every assertion
below is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import quick_tools as Q
except ImportError:  # standalone
    import quick_tools as Q  # noqa: E402


# --------------------------------------------------------------- validation

def test_validate_ok():
    assert Q.validate("summarise", text="Hello there.") == []
    assert Q.validate("change_tone", text="hi", tone="warmer") == []
    assert Q.validate("translate", text="hi", direction="en2bn") == []


def test_validate_catches_each_bad_input():
    assert "bad_action" in Q.validate("explode", text="x")
    assert "empty_text" in Q.validate("summarise", text="   ")
    assert "bad_tone" in Q.validate("change_tone", text="x", tone="angry")
    assert "bad_direction" in Q.validate("translate", text="x", direction="xx")


# --------------------------------------------------------------- determinism

def test_run_is_deterministic():
    a = Q.run("summarise", text="First. Second important point. Third.")
    b = Q.run("summarise", text="First. Second important point. Third.")
    assert a == b


def test_every_result_is_honest_mock():
    for action in ("summarise", "fix_grammar", "change_tone", "make_shareable"):
        r = Q.run(action, text="This is a test sentence. Another one here.")
        assert r["mock"] is True
        assert r["marker"] == Q.MARKER_KEY
        assert r["ai_required"] is False
        assert r["problems"] == []


# --------------------------------------------------------------- summarise

def test_summarise_is_extractive_only():
    src = ("The meeting is important. We decided the budget. "
           "Lunch was okay. Please remember the deadline. Bye.")
    r = Q.summarise(src)
    # every kept sentence must come verbatim from the source
    for part in Q._sentences(r["result"]):
        assert part in src
    assert r["kept"] <= Q.MAX_SUMMARY
    assert r["total"] == 5


def test_summarise_single_sentence_passthrough():
    r = Q.summarise("Just one line here")
    assert r["result"] == "Just one line here"
    assert r["kept"] == 1


def test_summarise_keeps_original_order():
    src = "Alpha first. Beta important must. Gamma please note."
    r = Q.summarise(src)
    kept = Q._sentences(r["result"])
    idxs = [src.index(s) for s in kept]
    assert idxs == sorted(idxs)


# --------------------------------------------------------------- fix_grammar

def test_fix_grammar_spacing_and_caps():
    r = Q.fix_grammar("hello  world .this is  bad .i went home")
    assert "  " not in r["result"]
    assert " ." not in r["result"]
    assert r["result"].startswith("Hello")
    assert " I " in r["result"]
    assert r["changed"] is True


def test_fix_grammar_collapses_repeat_punct():
    r = Q.fix_grammar("Wow!!! Really???")
    assert "!!!" not in r["result"]
    assert "???" not in r["result"]
    assert "repeat_punct" in r["changes"]


def test_fix_grammar_clean_input_is_noop():
    r = Q.fix_grammar("This is already clean.")
    assert r["result"] == "This is already clean."
    assert r["changed"] is False
    assert r["changes"] == []


# --------------------------------------------------------------- translate

def test_translate_direction_auto_guess():
    # ASCII → en2bn, Bangla block char → bn2en
    assert Q.translate("hello")["direction"] == "en2bn"
    bn = Q.translate("আপনি")  # Bangla word
    assert bn["direction"] == "bn2en"


def test_translate_known_phrase_renders_offline():
    r = Q.translate("thank you", direction="en2bn")
    assert r["phrase_hit"] is True
    assert r["translated"] != ""
    assert r["ai_required"] is False


def test_translate_unknown_needs_key_never_fabricates():
    r = Q.translate("a long custom sentence that is not a known phrase",
                    direction="en2bn")
    assert r["phrase_hit"] is False
    assert r["translated"] == ""           # honest: nothing invented
    assert r["ai_required"] is True


# --------------------------------------------------------------- change_tone

def test_change_tone_wraps_and_shorter_trims():
    src = "Please send the report by Friday. It is important for the client."
    pol = Q.change_tone(src, "polite")
    assert pol["result"] != src
    short = Q.change_tone(src, "shorter")
    assert len(short["result"]) <= len(src)
    assert short["result"] == "Please send the report by Friday."


def test_change_tone_all_presets_nonempty():
    for tone in Q.TONES:
        r = Q.change_tone("Come to the office tomorrow.", tone)
        assert r["result"].strip() != ""
        assert r["tone"] == tone


# --------------------------------------------------------------- make_shareable

def test_make_shareable_clamps_on_word_boundary():
    src = ("word " * 300).strip()
    r = Q.make_shareable(src)
    assert len(r["result"]) <= Q.SHARE_LIMIT + 1   # +1 for the ellipsis
    assert r["truncated"] is True
    assert "word" in r["result"]                   # never cut mid-word garbage


def test_make_shareable_short_passthrough():
    r = Q.make_shareable("Short and sweet.")
    assert r["truncated"] is False
    assert r["result"] == "Short and sweet."


# --------------------------------------------------------------- dispatch/seam

def test_run_bad_input_returns_problems_not_crash():
    r = Q.run("summarise", text="   ")
    assert "empty_text" in r["problems"]
    assert r["mock"] is True


def test_ai_plan_describes_contract_only():
    p = Q.ai_plan("translate", text="hello", direction="en2bn", lang="en")
    assert p["ai_required"] is True
    assert p["mock"] is False
    assert p["source"] == "hello"
    assert p["task"] == "translate_text"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"quick_tools: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
