"""
blog_writer_tests_snippets.py — plain-assert tests for the BLOG & SCRIPT writer
(#130, §21). Pure stdlib. `python blog_writer_tests_snippets.py` or import and
call run_all(). The assembler is deterministic, so every assertion below is
hand-verified against fixed inputs.
"""

try:  # Django harness: core.logic.blog_writer_tests_snippets
    from core.logic import blog_writer as B
except ImportError:  # standalone
    import blog_writer as B  # noqa: E402


# --------------------------------------------------------------- validation

def test_validate_ok():
    assert B.validate("blog", "Saving money", "informative", "medium", "bn") == []


def test_validate_catches_each_bad_input():
    assert "bad_format" in B.validate("tweet", "x")
    assert "topic_required" in B.validate("blog", "   ")
    assert "bad_tone" in B.validate("blog", "x", tone="angry")
    assert "bad_length" in B.validate("blog", "x", length="huge")
    assert "bad_lang" in B.validate("blog", "x", lang="fr")


# --------------------------------------------------------------- determinism

def test_assemble_is_deterministic():
    a = B.assemble("blog", "Freelancing in Bangladesh", "casual", "medium", "en")
    b = B.assemble("blog", "Freelancing in Bangladesh", "casual", "medium", "en")
    assert a == b


def test_assemble_shape_and_honest_flags():
    d = B.assemble("script", "New phone review", "persuasive", "long", "banglish")
    for k in ("format", "tone", "length", "lang", "title", "hook", "sections",
              "cta", "text", "marker", "ai_required", "ai_full_requires",
              "mock", "problems"):
        assert k in d, k
    # honest: mock, deterministic, never needs a key; richer draft is key-gated
    assert d["ai_required"] is False
    assert d["mock"] is True
    assert d["marker"] == "ai_review"
    assert d["ai_full_requires"] == "anthropic"
    assert d["problems"] == []


# --------------------------------------------------------------- scaffolding

def test_topic_fills_into_hook_and_title():
    d = B.assemble("blog", "Rooftop gardening", "informative", "short", "en")
    assert "Rooftop gardening" in d["title"]
    assert "Rooftop gardening" in d["hook"]


def test_length_scales_section_count_for_blog():
    short = B.assemble("blog", "Topic", "informative", "short", "en")
    med = B.assemble("blog", "Topic", "informative", "medium", "en")
    long = B.assemble("blog", "Topic", "informative", "long", "en")
    assert len(short["sections"]) == B.section_count("short") == 2
    assert len(med["sections"]) == 3
    assert len(long["sections"]) == 5
    assert len(long["sections"]) > len(short["sections"])


def test_script_always_has_hook_and_cta_beats():
    d = B.assemble("script", "My channel", "casual", "short", "en")
    headings = [s["heading"] for s in d["sections"]]
    assert headings[0].startswith("HOOK")
    assert "CALL TO ACTION" in headings[-1]


def test_caption_is_tiny_two_section_scaffold():
    d = B.assemble("caption", "Eid sale", "promotional" if False else "casual",
                   "long", "en")
    # caption ignores the length scale — always a compact 2-section scaffold
    assert len(d["sections"]) == 2
    assert d["sections"][1]["heading"] == "Hashtags"


def test_sections_carry_placeholder_prompts_never_fabricated_facts():
    d = B.assemble("blog", "Interest rates", "informative", "medium", "en")
    # every body prompt is a bracketed placeholder the user completes — the mock
    # never asserts a real fact about the topic
    for s in d["sections"]:
        assert s["prompt"].startswith("[") and s["prompt"].endswith("]")


def test_text_block_joins_title_hook_sections_cta():
    d = B.assemble("outline", "Launch plan", "professional", "medium", "en")
    assert d["text"].startswith("# ")
    assert d["hook"] in d["text"]
    for s in d["sections"]:
        assert ("## " + s["heading"]) in d["text"]
    assert d["cta"] in d["text"]


def test_bad_input_still_returns_usable_scaffold_with_problems():
    d = B.assemble("tweet", "", "angry", "huge", "fr")
    # total: never raises; returns a scaffold + the problem keys for the UI
    assert isinstance(d["text"], str) and d["text"]
    assert "bad_format" in d["problems"]
    assert "topic_required" in d["problems"]


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"blog_writer: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
