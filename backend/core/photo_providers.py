"""
photo_providers.py — switchable, key-gated cloud image adapters for Photo
Studio (ps1-photo). One function per provider, same contract:

    run(slug, cfg, *, feature, image_bytes, prompt, mime) -> bytes (PNG/JPEG)

Raises ProviderError on any failure (the caller keeps the job funded for a
retry and never shows a fake result). Nothing here decides money or safety —
core/photo_studio_service.py does that BEFORE calling us.

HONEST LIMIT: the request shapes follow each provider's public API docs
(Gemini generateContent with inline image + IMAGE response modality, OpenAI
images edits/generations, Replicate predictions). They are unit-tested with a
mocked HTTP layer only; the first real call happens when the owner connects a
key. Every call carries the face rule in the instruction text.
"""
import base64
import json

TIMEOUT_S = 90

# Prepended to every provider instruction: the "same person, best version" rule.
FACE_RULE = (
    "Keep every person's face, identity, face shape, eye/nose/lip shape and size, "
    "skin colour, age and gender exactly as in the input photo. Do not add, remove "
    "or replace any person's face. Do not add nudity or change clothing to be "
    "revealing. Do not change any text, numbers, seals or signatures. "
)

DEFAULT_MODELS = {
    "photo_gemini": "gemini-2.5-flash-image",
    "photo_openai": "gpt-image-1",
    "photo_replicate": "",
}


class ProviderError(Exception):
    pass


def _http():
    import requests
    return requests


def _instruction(feature, prompt):
    p = (prompt or "").strip()
    if feature == "enhance_cloud":
        p = ("Restore and enhance this photo naturally: sharpen, denoise, fix "
             "low light, keep it realistic. " + p)
    return FACE_RULE + p


def run(slug, cfg, *, feature, image_bytes=None, prompt="", mime="image/jpeg"):
    fn = {"photo_gemini": _gemini, "photo_openai": _openai,
          "photo_replicate": _replicate}.get(slug)
    if fn is None:
        raise ProviderError("unknown_provider")
    if feature != "generate" and not image_bytes:
        raise ProviderError("no_image")
    try:
        return fn(cfg or {}, feature=feature, image_bytes=image_bytes,
                  prompt=_instruction(feature, prompt), mime=mime)
    except ProviderError:
        raise
    except Exception as e:  # noqa: BLE001 — network/JSON errors -> honest failure
        raise ProviderError(type(e).__name__)


def _gemini(cfg, *, feature, image_bytes, prompt, mime):
    rq = _http()
    model = (cfg.get("model") or DEFAULT_MODELS["photo_gemini"]).strip()
    url = ("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
           % model)
    parts = [{"text": prompt}]
    if image_bytes:
        parts.append({"inline_data": {"mime_type": mime,
                                      "data": base64.b64encode(image_bytes).decode()}})
    body = {"contents": [{"parts": parts}],
            "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]}}
    r = rq.post(url, json=body, timeout=TIMEOUT_S,
                headers={"x-goog-api-key": cfg.get("api_key", "")})
    if r.status_code != 200:
        raise ProviderError("http_%d" % r.status_code)
    j = r.json()
    for cand in j.get("candidates") or []:
        for part in ((cand.get("content") or {}).get("parts") or []):
            data = (part.get("inlineData") or part.get("inline_data") or {}).get("data")
            if data:
                return base64.b64decode(data)
    # blocked by the provider's own safety filter, or no image returned
    raise ProviderError("no_image_returned")


def _openai(cfg, *, feature, image_bytes, prompt, mime):
    rq = _http()
    model = (cfg.get("model") or DEFAULT_MODELS["photo_openai"]).strip()
    headers = {"Authorization": "Bearer %s" % cfg.get("api_key", "")}
    if feature == "generate":
        r = rq.post("https://api.openai.com/v1/images/generations", timeout=TIMEOUT_S,
                    headers=headers,
                    json={"model": model, "prompt": prompt, "n": 1, "size": "1024x1024"})
    else:
        ext = "png" if mime == "image/png" else "jpg"
        r = rq.post("https://api.openai.com/v1/images/edits", timeout=TIMEOUT_S,
                    headers=headers,
                    data={"model": model, "prompt": prompt, "n": "1"},
                    files={"image": ("input.%s" % ext, image_bytes, mime)})
    if r.status_code != 200:
        raise ProviderError("http_%d" % r.status_code)
    data = (r.json().get("data") or [{}])[0]
    if data.get("b64_json"):
        return base64.b64decode(data["b64_json"])
    if data.get("url"):
        g = rq.get(data["url"], timeout=TIMEOUT_S)
        if g.status_code == 200:
            return g.content
    raise ProviderError("no_image_returned")


def _replicate(cfg, *, feature, image_bytes, prompt, mime):
    rq = _http()
    version = (cfg.get("model") or "").strip()
    if not version:
        raise ProviderError("no_model")
    inp = {"prompt": prompt}
    if image_bytes:
        inp["image"] = "data:%s;base64,%s" % (mime, base64.b64encode(image_bytes).decode())
    r = rq.post("https://api.replicate.com/v1/predictions", timeout=TIMEOUT_S,
                headers={"Authorization": "Bearer %s" % cfg.get("api_token", ""),
                         "Prefer": "wait=60", "Content-Type": "application/json"},
                data=json.dumps({"version": version, "input": inp}))
    if r.status_code not in (200, 201):
        raise ProviderError("http_%d" % r.status_code)
    j = r.json()
    if j.get("status") not in ("succeeded",):
        raise ProviderError("not_finished_%s" % (j.get("status") or "unknown"))
    out = j.get("output")
    if isinstance(out, list):
        out = out[0] if out else None
    if not isinstance(out, str) or not out.startswith("https://"):
        raise ProviderError("no_image_returned")
    g = rq.get(out, timeout=TIMEOUT_S)
    if g.status_code != 200:
        raise ProviderError("download_%d" % g.status_code)
    return g.content
