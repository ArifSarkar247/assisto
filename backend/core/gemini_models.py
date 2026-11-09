"""geminifix (live bug 4 Nov): the ONE place for Gemini model ids — text
(router slots + the Normal level), vision (photo in chat / CCTV) and voice
transcription. Owner-editable on Owner Admin -> AI levels
(PricingConfig.data["ai_levels"]["gemini_models"], normalized in
core/logic/ai_levels.py).

Default = gemini-3.5-flash-lite: badged "Stable" on Google's model list and
the official replacement named for gemini-2.5-flash on the deprecation page,
at the SAME paid price (in $0.30 / out $2.50 per 1M) so every credit price
and the 40 % rule stay as they are. Checked 4 Nov 2026:
  https://aistudio.google.com/docs/models        (was ai.google.dev/gemini-api/docs/models)
  https://aistudio.google.com/docs/deprecations
  https://aistudio.google.com/docs/pricing
The stable FLASH (gemini-3.6-flash, in $0.75 / out $3.75) can be chosen
here by the owner; it raises the Normal credit price (computed worst case).

RETIRED: ids Google lists as shut down / deprecated or no longer offered to
new keys. A saved row still holding one is served with the current id from
this block (only when that is not dearer) instead of a call that can only
404 — the saved config itself is never rewritten."""
KINDS = ("text", "vision", "voice")
DEFAULT_MODEL = "gemini-3.5-flash-lite"
DEFAULTS = {"text": DEFAULT_MODEL, "vision": DEFAULT_MODEL, "voice": DEFAULT_MODEL}

RETIRED = frozenset({
    "gemini-1.5-flash", "gemini-1.5-flash-8b", "gemini-1.5-pro",
    "gemini-2.0-flash", "gemini-2.0-flash-001", "gemini-2.0-flash-lite",
    "gemini-2.0-flash-lite-001", "gemini-2.5-flash", "gemini-2.5-pro",
    "gemini-3-pro-preview", "gemini-3.1-flash-lite-preview",
})


def _block():
    try:
        from . import ai_levels_service as ALS
        return ALS.cfg()[0].get("gemini_models") or {}
    except Exception:  # noqa: BLE001 — a bad block never breaks AI
        return {}


def get(kind="text"):
    m = _block().get(kind)
    return m if m else DEFAULTS.get(kind, DEFAULT_MODEL)


def resolve(model, kind="text", prices=None):
    """The id to SEND for a configured Gemini `model`: itself, unless it is
    retired — then the current id for `kind` when that is not dearer."""
    m = str(model or "").strip().lower()
    if not m:
        return get(kind)
    if m not in RETIRED:
        return m
    cur = get(kind)
    if cur in RETIRED:
        cur = DEFAULTS[kind]
    if prices is None:
        try:
            from . import ai_router as R
            prices = R.cfg()["prices"]
        except Exception:  # noqa: BLE001
            prices = None
    if prices:
        from .logic.ai_levels import price_of
        a, b = price_of(m, prices), price_of(cur, prices)
        if (float(b.get("in", 0)) > float(a.get("in", 0)) + 1e-9
                or float(b.get("out", 0)) > float(a.get("out", 0)) + 1e-9):
            return m          # never silently dearer — health fallback handles it
    return cur


def thinking_off_config(model):
    """generationConfig.thinkingConfig that turns thinking off, or None.
    Only the 2.5 family takes thinkingBudget=0; the 3.x flash(-lite) models
    default to minimal thinking and document thinking_level only — sending
    an unknown field there is a 400 (which never fails over)."""
    if str(model or "").startswith("gemini-2.5"):
        return {"thinkingBudget": 0}
    return None
