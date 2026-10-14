"""
social_tests_snippets.py — plain-assert tests for the SOCIAL-MEDIA POST &
CAPTION composer (#135, §21). Pure stdlib. `python social_tests_snippets.py`
or import and call run_all(). The generator is deterministic, so every
assertion below is hand-verified against fixed inputs.
"""

try:  # Django harness: core.logic.social_tests_snippets
    from core.logic import social as S
except ImportError:  # standalone
    import social as S  # noqa: E402


# --------------------------------------------------------------- validation

def test_validate_ok():
    assert S.validate("instagram", "Eid sale", "promotional", "short", "bn") == []


def test_validate_catches_each_bad_input():
    assert "bad_platform" in S.validate("tiktok", "x")
    assert "topic_required" in S.validate("facebook", "   ")
    assert "bad_tone" in S.validate("facebook", "x", tone="angry")
    assert "bad_length" in S.validate("facebook", "x", length="huge")
    assert "bad_lang" in S.validate("facebook", "x", lang="fr")


# --------------------------------------------------------------- determinism

def test_draft_is_deterministic():
    a = S.draft("facebook", "New coffee shop", "friendly", "medium", "en")
    b = S.draft("facebook", "New coffee shop", "friendly", "medium", "en")
    assert a == b


def test_draft_shape_and_honest_flags():
    d = S.draft("instagram", "Launch day", "promotional", "medium", "banglish")
    for k in ("platform", "tone", "length", "lang", "caption", "body",
              "hashtags", "emoji", "chars", "ai_required", "mock", "problems"):
        assert k in d, k
    # honest: mock, deterministic, never needs a key
    assert d["ai_required"] is False
    assert d["mock"] is True
    assert d["problems"] == []


# --------------------------------------------------------------- limits

def test_body_never_exceeds_platform_limit():
    for plat in S.PLATFORM_TYPES:
        for length in S.LENGTHS:
            d = S.draft(plat, "A very long topic " * 20, "professional",
                        length, "en")
            assert len(d["body"]) <= S.PLATFORMS[plat]["limit"]
            assert d["chars"]["over"] is False


def test_whatsapp_tighter_than_facebook():
    wa = S.draft("whatsapp", "Festival", "friendly", "long", "en")
    fb = S.draft("facebook", "Festival", "friendly", "long", "en")
    assert S.PLATFORMS["whatsapp"]["limit"] < S.PLATFORMS["facebook"]["limit"]
    assert len(wa["body"]) <= S.PLATFORMS["whatsapp"]["limit"]
    assert len(fb["body"]) >= len(wa["body"])  # fb soft target is larger


def test_char_count_over_flag():
    cc = S.char_count("x" * 800, "whatsapp")  # wa limit 700
    assert cc["used"] == 800
    assert cc["limit"] == 700
    assert cc["over"] is True
    assert cc["remaining"] == -100


def test_length_scales_body():
    short = S.draft("linkedin", "Hiring", "professional", "short", "en")
    long = S.draft("linkedin", "Hiring", "professional", "long", "en")
    assert len(long["body"]) > len(short["body"])


# --------------------------------------------------------------- hashtags/emoji

def test_hashtags_capped_per_platform():
    for plat in S.PLATFORM_TYPES:
        tags = S.hashtags("Growth marketing tips for small teams", plat)
        assert len(tags) <= S.PLATFORMS[plat]["hashtags"]
        assert all(t.startswith("#") for t in tags)


def test_hashtags_from_topic_words_first():
    tags = S.hashtags("Winter Sale", "instagram")
    assert "#Winter" in tags and "#Sale" in tags


def test_hashtags_fill_for_short_topic():
    # one-word topic still yields a useful set via deterministic fillers
    tags = S.hashtags("Hi", "instagram")
    assert len(tags) == S.PLATFORMS["instagram"]["hashtags"]


def test_emoji_hidden_for_linkedin():
    assert S.emoji_suggestions("friendly", "linkedin") == []
    assert len(S.emoji_suggestions("friendly", "facebook")) > 0


# --------------------------------------------------------------- caption/share

def test_caption_is_one_line_and_bounded():
    cap = S.caption("A very long topic that keeps going " * 10, "promotional")
    assert "\n" not in cap
    assert len(cap) <= 120


def test_compose_for_share_appends_hashtags_and_clamps():
    out = S.compose_for_share("Hello world", ["#A", "#B"], "whatsapp")
    assert "Hello world" in out
    assert "#A #B" in out
    big = S.compose_for_share("y" * 1000, ["#A"], "whatsapp")
    assert len(big) <= S.PLATFORMS["whatsapp"]["limit"]


def test_share_target_never_posts_and_prefers_sheet():
    for plat in S.PLATFORM_TYPES:
        t = S.share_target(plat)
        assert t["platform"] == plat
        assert t["prefer_share_sheet"] is True
        assert t["web"].startswith("https://")
        assert t["app_scheme"].endswith("://")


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"social: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
