"""
Backend localisation. Every user-facing string the app displays must follow the
user's selected language. The app sends `Accept-Language: bn|en` on every request
(from its current locale); endpoints resolve it with `req_lang()` and pick the
right text with `pick()` / `localise()`.
"""


def req_lang(request):
    """'en' or 'bn' (default 'bn') from the Accept-Language header, falling back
    to the authenticated user's stored language."""
    la = (request.META.get("HTTP_ACCEPT_LANGUAGE") or "").strip().lower()
    if la.startswith("en"):
        return "en"
    if la.startswith("bn"):
        return "bn"
    u = getattr(request, "user", None)
    if getattr(u, "is_authenticated", False) and getattr(u, "language", None) in ("bn", "en"):
        return u.language
    return "bn"


def is_play_flavour(request):
    """play-nomed: True when the request comes from the Google Play build
    (the app sends `X-Assisto-Flavour: play`). Google Play does not allow a
    personal developer account to publish medical features, so for this
    flavour the server never creates medicine rows from chat (it falls back to
    a plain reminder) and never suggests medicine prompts. The website APK
    sends no header and is unaffected."""
    try:
        v = (request.META.get("HTTP_X_ASSISTO_FLAVOUR") or "").strip().lower()
    except Exception:
        return False
    return v == "play"


MEDICAL_SUGGESTION_KEYS = ("onboard_medicine", "medicine_due")


def pick(lang, bn, en):
    return en if lang == "en" else bn


def localise(lang, obj, *fields):
    """Return a copy of dict `obj` where each `<field>` is set from
    `<field>_<lang>` (falling back to `<field>_bn`), dropping the _bn/_en pair."""
    out = {}
    for k, v in obj.items():
        base = k[:-3] if (k.endswith("_bn") or k.endswith("_en")) else None
        if base and base in fields:
            continue
        out[k] = v
    for f in fields:
        if (f + "_bn") in obj or (f + "_en") in obj:
            out[f] = obj.get(f + "_" + lang) or obj.get(f + "_bn") or obj.get(f + "_en")
    return out
