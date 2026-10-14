"""
Photo enhance (launch gap E) — OWN photos only. This module is the SAFETY +
ROUTING brain, not an image editor. Hard rules:

- NEVER alter ID cards / official documents. The caller must declare the photo
  kind; anything flagged document-like is hard-blocked with a warning.
- No fabricated content. "Enhance" means only non-generative, faithful
  operations (denoise, sharpen, auto-levels/contrast, upscale) — we never add
  or invent people/objects/backgrounds.
- Processing path: an on-device / open-source CPU path is the default; a
  higher-quality cloud path is key-gated ("Available when <provider> added").

The actual pixel work happens on-device (Flutter) or in an owner-configured
cloud worker; this module decides WHAT is allowed and returns a plan.
"""
from .i18n import pick

# Faithful, non-generative operations only.
ALLOWED_OPS = ("denoise", "sharpen", "auto_levels", "contrast", "upscale")

# Kinds the UI may declare. Anything in _BLOCKED_KINDS is never processed.
PHOTO_KINDS = ("personal", "landscape", "family", "document", "id_card",
               "passport", "certificate", "nid", "official")
_BLOCKED_KINDS = {"document", "id_card", "passport", "certificate", "nid",
                  "official"}

# Operations we refuse outright because they fabricate content.
_FORBIDDEN_OPS = {"generate", "inpaint", "outpaint", "add_object", "remove_object",
                  "face_swap", "beautify_reshape", "background_replace"}

# ADVANCED (SPEC v2.1 §21): faithful on-device adjustments the app exposes as
# sliders/buttons. These are NON-generative, identity-safe transforms only.
BASIC_ADJUSTMENTS = ("brightness", "contrast", "saturation", "sharpness",
                     "rotate", "straighten", "crop", "resize")

# AI-enhance operations. These require an image-AI key and are surfaced
# key-gated + HONEST (no fake result). 'background_replace' is also a
# fabricating op and stays in _FORBIDDEN_OPS for the faithful plan() path.
AI_OPS = ("upscale", "denoise", "background_replace")

# Named preset bundles = ordinary faithful adjustments under a friendly label.
# `web_tool` presets DON'T edit pixels here — they link to the exact-size web
# passport tool (crop/resize only, never identity). `ai` marks key-gated.
_PRESETS = {
    "document": {"adjustments": ["contrast", "sharpness", "brightness"],
                 "web_tool": False, "ai": False},
    "portrait": {"adjustments": ["brightness", "saturation", "sharpness"],
                 "web_tool": False, "ai": False},
    "passport": {"adjustments": ["crop", "resize"],
                 "web_tool": True, "ai": False},
}


def presets(lang="bn"):
    """Faithful preset bundles for the ADVANCED editor. Pure metadata — the
    actual pixel work is the same non-generative adjustments done on-device."""
    labels = {
        "document": pick(lang, "ডকুমেন্ট স্ক্যান", "Document scan"),
        "portrait": pick(lang, "পোর্ট্রেট", "Portrait"),
        "passport": pick(lang, "পাসপোর্ট / আইডি সাইজ", "Passport / ID size"),
    }
    out = []
    for key, meta in _PRESETS.items():
        out.append({"id": key, "label": labels[key],
                    "adjustments": list(meta["adjustments"]),
                    "web_tool": meta["web_tool"], "ai": meta["ai"]})
    return out


def ai_ops(lang="bn"):
    """AI-enhance options, reported HONESTLY as key-gated. `available` reflects
    whether an image-AI provider is actually wired — never a fake 'ready'."""
    avail = cloud_available()
    labels = {
        "upscale": pick(lang, "AI আপস্কেল", "AI upscale"),
        "denoise": pick(lang, "AI ডিনয়েজ", "AI denoise"),
        "background_replace": pick(lang, "ব্যাকগ্রাউন্ড পরিষ্কার",
                                   "Background cleanup"),
    }
    return [{"op": o, "label": labels[o], "requires_key": True,
             "available": avail} for o in AI_OPS]


def is_document(kind):
    return (kind or "").strip().lower() in _BLOCKED_KINDS


def _block_message(lang):
    return pick(
        lang,
        "নিরাপত্তার জন্য পরিচয়পত্র বা সরকারি নথির ছবি পরিবর্তন করা হয় না। "
        "শুধু নিজের সাধারণ ছবি এনহ্যান্স করুন।",
        "For safety, ID cards and official documents are never altered. "
        "Only enhance your own ordinary photos.")


def allowed_ops(lang="bn"):
    labels = {
        "denoise": pick(lang, "নয়েজ কমানো", "Reduce noise"),
        "sharpen": pick(lang, "শার্প করা", "Sharpen"),
        "auto_levels": pick(lang, "অটো লেভেল", "Auto levels"),
        "contrast": pick(lang, "কনট্রাস্ট", "Contrast"),
        "upscale": pick(lang, "রেজ্যুলিউশন বাড়ানো", "Upscale"),
    }
    return [{"op": o, "label": labels[o]} for o in ALLOWED_OPS]


def cloud_available():
    """Higher-quality cloud enhance only when an owner photo-provider is wired.
    Until then the UI shows 'Available when <provider> added' and uses the
    on-device path."""
    try:
        from . import integrations
        for slug in ("photo_cloud", "replicate", "cloudinary"):
            if slug in getattr(integrations, "REGISTRY", {}) and integrations.is_enabled(slug):
                return True
    except Exception:
        pass
    return False


def plan(kind, ops, own_photo=True, lang="bn"):
    """Decide whether/how to enhance.

    Returns a dict with:
      allowed: bool
      reason:  machine code ('ok' | 'document_blocked' | 'not_own' |
               'forbidden_op' | 'no_ops')
      message: localized text
      ops:     the faithful ops that will run (empty if blocked)
      path:    'cloud' if available else 'device'
    """
    req = [o for o in (ops or []) if isinstance(o, str)]

    # Hard block: ID / official documents are never altered.
    if is_document(kind):
        return {"allowed": False, "reason": "document_blocked",
                "message": _block_message(lang), "ops": [], "path": "device"}

    # Own-photo attestation is required.
    if not own_photo:
        return {"allowed": False, "reason": "not_own", "ops": [], "path": "device",
                "message": pick(lang,
                                "শুধুমাত্র নিজের ছবি এনহ্যান্স করা যাবে।",
                                "You may only enhance your own photos.")}

    # Reject any fabricating operation.
    if any(o in _FORBIDDEN_OPS for o in req):
        return {"allowed": False, "reason": "forbidden_op", "ops": [], "path": "device",
                "message": pick(lang,
                                "কোনো কিছু যোগ বা বদলে দেওয়া হয় না—শুধু বিশ্বস্ত এনহ্যান্স।",
                                "We never add or fabricate content — faithful enhance only.")}

    safe = [o for o in req if o in ALLOWED_OPS]
    if not safe:
        return {"allowed": False, "reason": "no_ops", "ops": [], "path": "device",
                "message": pick(lang, "কোনো বৈধ এনহ্যান্স অপশন নির্বাচন করা হয়নি।",
                                "No valid enhance option selected.")}

    return {"allowed": True, "reason": "ok", "ops": safe,
            "path": "cloud" if cloud_available() else "device",
            "message": pick(lang, "এনহ্যান্স করা যাবে।", "Ready to enhance.")}
