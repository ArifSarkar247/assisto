"""
social.py — the deterministic, key-free draft generator behind Assisto's
SOCIAL-MEDIA POST & CAPTION composer (issue #135, SPEC v2.1 §21, ADVANCED).

Agent Studio gains one more "mini-tool": the user picks a PLATFORM
(Facebook / Instagram / LinkedIn / WhatsApp-status), a TOPIC/goal, a TONE and a
LENGTH, and we DRAFT a ready-to-post body + a short caption + hashtags + a few
suggested emoji. The user then edits it, watches a per-platform character
count, and copies / shares it to the platform's own app — **never** auto-posts.

This module is PURE, exactly like `agent_studio.py`: no Django, no DB, no
network, no clock, **no AI**. It is a DETERMINISTIC TEMPLATE GENERATOR — same
inputs always give the same draft — so the on-device Dart mirror produces an
identical preview offline and the tests can pin it.

HONEST AI, KEY-GATED
--------------------
The "AI drafts it for you" promise is served, right now, by this deterministic
template engine and is clearly labelled a MOCK ("AI-generated — review before
posting"). It never calls a model and never needs a key. When an AI key is
present (Integrations → `core.ai.generate`), the app/executor MAY route the
same request to the real provider for a richer draft — the request/plan shape
here is the contract; nothing in this file calls a model. `draft()` therefore
returns `ai_required=False, mock=True` so callers can be honest about which
path produced the text.

NEVER AUTO-POST
---------------
We only ever produce TEXT and a share INTENT (a deep link / share-sheet target).
Actually posting is always a manual action the user takes inside the target
app. `share_target()` returns where to send the text; it posts nothing.

Everything is plain stdlib and hand-verified in social_tests_snippets.py.
"""

# ------------------------------------------------------------------ platforms
# Per-platform character limits (the hard ceiling the UI counts against) plus
# a "comfortable" soft length used to pick how much body text to draft. Limits
# are the well-known public caps; we keep them here so the UI counter and the
# generator can never drift. Text the UI shows is localised by key; the engine
# never emits prose.

PLATFORMS = {
    "facebook":  {"limit": 63206, "soft": 480,  "hashtags": 3, "emoji": True},
    "instagram": {"limit": 2200,  "soft": 300,  "hashtags": 8, "emoji": True},
    "linkedin":  {"limit": 3000,  "soft": 700,  "hashtags": 5, "emoji": False},
    "whatsapp":  {"limit": 700,   "soft": 180,  "hashtags": 2, "emoji": True},
}

PLATFORM_TYPES = tuple(PLATFORMS.keys())
TONES = ("friendly", "professional", "funny", "inspirational", "promotional")
LENGTHS = ("short", "medium", "long")
LANGS = ("bn", "banglish", "en")

# How the chosen LENGTH scales the soft target (×). "short" keeps it tight;
# "long" goes fuller but is still clamped to the platform's hard limit.
_LENGTH_SCALE = {"short": 0.45, "medium": 1.0, "long": 1.6}

# A small, deterministic emoji palette per tone (NOT Bangla — safe in .dart too,
# but the engine is the source of truth). The UI shows these as tappable chips.
_TONE_EMOJI = {
    "friendly":      ["😊", "👍", "🙌", "✨"],
    "professional":  ["📊", "✅", "💼", "🔹"],
    "funny":         ["😂", "😄", "🎉", "🙃"],
    "inspirational": ["🌟", "🚀", "💪", "🙏"],
    "promotional":   ["🔥", "🎁", "⏰", "🛒"],
}

# Deterministic opener / closer skeletons keyed by tone. `{topic}` is filled in.
# These are neutral English seeds the engine uses for the MOCK draft; the Dart
# mirror carries the same seeds so previews match. Real-AI path replaces them.
_TONE_OPENER = {
    "friendly":      "Hey everyone! A quick word about {topic}.",
    "professional":  "Sharing an update on {topic}.",
    "funny":         "Okay, real talk about {topic} 😄",
    "inspirational": "Every big step starts somewhere — today it's {topic}.",
    "promotional":   "Don't miss this: {topic} is here!",
}
_TONE_BODY = {
    "friendly":      "Wanted to share this with you all and hear what you think.",
    "professional":  "Here are the key points and why they matter.",
    "funny":         "No, seriously, you had to be there. Here's the short version.",
    "inspirational": "Small, steady effort turns into something you'll be proud of.",
    "promotional":   "Limited time, genuinely worth a look — here are the details.",
}
_TONE_CTA = {
    "friendly":      "Let me know your thoughts in the comments!",
    "professional":  "Happy to discuss — reach out anytime.",
    "funny":         "Tag someone who needs to see this.",
    "inspirational": "Save this as your reminder for today.",
    "promotional":   "Tap the link / DM to grab yours.",
}


# --------------------------------------------------------------- small helpers

def _clean_topic(topic):
    """Trim and collapse whitespace; never return an empty string (the UI
    guards this too, but the engine must be total)."""
    t = " ".join(str(topic or "").split()).strip()
    return t or "this"


def _slug_words(topic, limit):
    """Topic → up to `limit` CamelCase hashtag words, de-duped, ASCII-word only
    so hashtags stay portable (non-ASCII topics still get a generic tag)."""
    import re
    words = re.findall(r"[A-Za-z0-9]+", str(topic or ""))
    out, seen = [], set()
    for w in words:
        tag = w.capitalize()
        low = tag.lower()
        if low not in seen:
            seen.add(low)
            out.append(tag)
        if len(out) >= limit:
            break
    return out


def validate(platform, topic, tone="friendly", length="medium", lang="en"):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these."""
    problems = []
    if platform not in PLATFORM_TYPES:
        problems.append("bad_platform")
    if not str(topic or "").strip():
        problems.append("topic_required")
    if tone not in TONES:
        problems.append("bad_tone")
    if length not in LENGTHS:
        problems.append("bad_length")
    if lang not in LANGS:
        problems.append("bad_lang")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ----------------------------------------------------------------- generators

def hashtags(topic, platform):
    """Deterministic hashtag suggestions for a topic on a platform, capped at
    that platform's comfortable count. Topic words first, then stable generic
    fillers (so even a one-word or non-ASCII topic yields useful tags)."""
    cap = PLATFORMS.get(platform, PLATFORMS["facebook"])["hashtags"]
    tags = _slug_words(topic, cap)
    fillers = ["Bangladesh", "Community", "Tips", "Update", "Today",
               "Growth", "Deal", "Story"]
    for f in fillers:
        if len(tags) >= cap:
            break
        if f.lower() not in {t.lower() for t in tags}:
            tags.append(f)
    return ["#" + t for t in tags[:cap]]


def emoji_suggestions(tone, platform):
    """A short, deterministic emoji palette for the tone — empty if the platform
    discourages emoji (LinkedIn) so the UI can hide the chip row honestly."""
    if not PLATFORMS.get(platform, PLATFORMS["facebook"])["emoji"]:
        return []
    return list(_TONE_EMOJI.get(tone, _TONE_EMOJI["friendly"]))


def char_count(text, platform):
    """Character count + the platform's hard limit + whether we're over. The UI
    renders "used / limit" and turns red when `over`."""
    limit = PLATFORMS.get(platform, PLATFORMS["facebook"])["limit"]
    used = len(text or "")
    return {"used": used, "limit": limit, "remaining": limit - used,
            "over": used > limit}


def caption(topic, tone):
    """A short one-line caption (deterministic) for the post."""
    topic = _clean_topic(topic)
    lead = {"friendly": "A little about", "professional": "On the topic of",
            "funny": "Buckle up:", "inspirational": "Today's focus:",
            "promotional": "Now live:"}.get(tone, "On")
    cap = f"{lead} {topic}."
    # keep captions tight — one line
    return cap if len(cap) <= 120 else cap[:117].rstrip() + "..."


def draft(platform, topic, tone="friendly", length="medium", lang="en"):
    """MAIN ENTRY. Build a deterministic MOCK draft for the given inputs.

    Returns a dict the app renders + lets the user edit:

        {
          "platform", "tone", "length", "lang",
          "caption":  "<one-line caption>",
          "body":     "<the post body, clamped to the platform limit>",
          "hashtags": ["#..", ...],
          "emoji":    ["😊", ...],
          "chars":    {"used", "limit", "remaining", "over"},
          "ai_required": False,   # this mock never needs a key
          "mock": True,           # HONEST: template-generated, not real AI
          "problems": [..]        # validate() keys; non-empty ⇒ inputs invalid
        }

    Deterministic: identical inputs → identical output. No model, no key, no
    network, no clock. `lang` only tags the request (so a real-AI path can
    answer in bn/Banglish/en); the mock body stays neutral English seeds, which
    keeps zero-Bangla-in-dart trivially true for the mirrored generator."""
    problems = validate(platform, topic, tone, length, lang)
    p = PLATFORMS.get(platform, PLATFORMS["facebook"])
    topic = _clean_topic(topic)

    opener = _TONE_OPENER.get(tone, _TONE_OPENER["friendly"]).format(topic=topic)
    body_mid = _TONE_BODY.get(tone, _TONE_BODY["friendly"])
    cta = _TONE_CTA.get(tone, _TONE_CTA["friendly"])

    target = int(p["soft"] * _LENGTH_SCALE.get(length, 1.0))
    parts = [opener, body_mid]
    # "long" repeats the middle once for a fuller post; "short" drops the CTA.
    if length == "long":
        parts.append(body_mid)
    if length != "short":
        parts.append(cta)
    text = " ".join(parts)

    # pad deterministically toward the soft target (medium/long) without ever
    # exceeding the hard limit; trim to the hard limit as a final guard.
    while len(text) < target and len(text) < p["limit"]:
        text = text + " " + body_mid
        if len(text) >= target:
            break
    if len(text) > p["limit"]:
        text = text[: p["limit"]].rstrip()

    tags = hashtags(topic, platform)
    return {
        "platform": platform,
        "tone": tone,
        "length": length,
        "lang": lang,
        "caption": caption(topic, tone),
        "body": text,
        "hashtags": tags,
        "emoji": emoji_suggestions(tone, platform),
        "chars": char_count(text, platform),
        "ai_required": False,   # the mock is deterministic + key-free
        "mock": True,           # honest: template-generated, review before post
        "problems": problems,
    }


def compose_for_share(body, hashtags_list, platform):
    """Join body + hashtags into the single string the user copies / shares,
    clamped to the platform limit. Deterministic; posts nothing."""
    tail = " ".join(hashtags_list or [])
    text = (body or "").rstrip()
    if tail:
        text = (text + "\n\n" + tail).strip()
    limit = PLATFORMS.get(platform, PLATFORMS["facebook"])["limit"]
    if len(text) > limit:
        text = text[:limit].rstrip()
    return text


def share_target(platform):
    """Where the manual share goes — a deep-link scheme hint + whether we should
    fall back to the OS share sheet. We NEVER post; the user does, inside the
    app. The UI copies the text to the clipboard first, then opens the target.

        {"platform", "app_scheme", "web", "prefer_share_sheet"}

    Most networks do not accept prefilled post bodies via URL, so the honest
    default is: copy text → open the app (deep link) or the share sheet → the
    user pastes/edits and posts themselves."""
    targets = {
        "facebook":  {"app_scheme": "fb://",   "web": "https://facebook.com"},
        "instagram": {"app_scheme": "instagram://", "web": "https://instagram.com"},
        "linkedin":  {"app_scheme": "linkedin://", "web": "https://linkedin.com"},
        "whatsapp":  {"app_scheme": "whatsapp://", "web": "https://wa.me"},
    }
    t = targets.get(platform, targets["facebook"])
    # WhatsApp status is the one case a share-sheet target is clean; others we
    # also prefer the share sheet because post bodies can't be reliably prefilled.
    return {"platform": platform, "app_scheme": t["app_scheme"],
            "web": t["web"], "prefer_share_sheet": True}
