"""
vision_providers.py — switchable, key-gated cloud VISION adapters for
"image in chat" (h1-home). Same shape as core/photo_providers.py:

    ask(slug, cfg, *, image_bytes, mime, system, question) -> str (raw reply text)

Raises VisionError on any failure (the caller keeps the job funded for a retry
and never shows a fake answer). Nothing here decides money or safety —
core/chat_vision_service.py does that BEFORE and AFTER calling us.

  * vision_claude  — Anthropic Messages API through the official `anthropic`
                     SDK (lazy import, like core/ai.py). Default model
                     claude-sonnet-5-5. A server-side refusal fallback is
                     requested when the installed SDK supports it.
  * vision_openai  — Chat Completions with an image_url data: URI.
  * vision_gemini  — generateContent with inline image data.

The image bytes live only in this call's memory — never written to disk/DB.

HONEST LIMIT: unit-tested with a mocked SDK/HTTP layer only; the first real
call happens when the owner connects a key.
"""
import base64

TIMEOUT_S = 60
MAX_TOKENS = 1500

DEFAULT_MODELS = {
    "vision_claude": "claude-sonnet-5-5",
    "vision_openai": "gpt-4o-mini",
    "vision_gemini": "gemini-2.5-flash",
}


class VisionError(Exception):
    pass


def _http():
    import requests
    return requests


def ask(slug, cfg, *, image_bytes, mime="image/jpeg", system="", question=""):
    fn = {"vision_claude": _claude, "vision_openai": _openai,
          "vision_gemini": _gemini}.get(slug)
    if fn is None:
        raise VisionError("unknown_provider")
    if not image_bytes:
        raise VisionError("no_image")
    try:
        text = fn(cfg or {}, image_bytes=image_bytes, mime=mime, system=system,
                  question=(question or "").strip() or "What is in this photo?")
    except VisionError:
        raise
    except Exception as e:  # noqa: BLE001 — SDK/network/JSON errors -> honest failure
        raise VisionError(type(e).__name__)
    text = (text or "").strip()
    if not text:
        raise VisionError("empty_reply")
    return text


def _b64(data):
    return base64.standard_b64encode(data).decode("ascii")


def _claude(cfg, *, image_bytes, mime, system, question):
    try:
        import anthropic
    except ImportError:
        raise VisionError("sdk_missing")
    client = anthropic.Anthropic(api_key=cfg.get("api_key", ""), timeout=TIMEOUT_S,
                                 max_retries=1)
    model = (cfg.get("model") or DEFAULT_MODELS["vision_claude"]).strip()
    content = [
        {"type": "image", "source": {"type": "base64", "media_type": mime,
                                     "data": _b64(image_bytes)}},
        {"type": "text", "text": question},
    ]
    kwargs = dict(model=model, max_tokens=MAX_TOKENS, system=system,
                  messages=[{"role": "user", "content": content}])
    try:
        # server-side refusal fallback (routes a policy decline to a fallback
        # model inside the same call); older SDKs reject the kwarg -> plain call
        resp = client.beta.messages.create(
            betas=["server-side-fallback-2026-07-01"], fallbacks="default", **kwargs)
    except TypeError:
        resp = client.messages.create(**kwargs)
    if getattr(resp, "stop_reason", "") == "refusal":
        raise VisionError("refused")
    return "".join(getattr(b, "text", "") for b in (resp.content or [])
                   if getattr(b, "type", "") == "text")


def _openai(cfg, *, image_bytes, mime, system, question):
    rq = _http()
    model = (cfg.get("model") or DEFAULT_MODELS["vision_openai"]).strip()
    # AF-13: store=False — never kept in the OpenAI dashboard log / evals
    body = {"model": model, "max_tokens": MAX_TOKENS, "store": False,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": [
                    {"type": "text", "text": question},
                    {"type": "image_url", "image_url": {
                        "url": "data:%s;base64,%s" % (mime, _b64(image_bytes))}},
                ]}]}
    r = rq.post("https://api.openai.com/v1/chat/completions", json=body,
                timeout=TIMEOUT_S,
                headers={"Authorization": "Bearer %s" % cfg.get("api_key", "")})
    if r.status_code != 200:
        raise VisionError("http_%d" % r.status_code)
    choices = r.json().get("choices") or []
    if not choices:
        raise VisionError("empty_reply")
    return (choices[0].get("message") or {}).get("content") or ""


def _gemini(cfg, *, image_bytes, mime, system, question):
    rq = _http()
    model = (cfg.get("model") or DEFAULT_MODELS["vision_gemini"]).strip()
    url = ("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
           % model)
    body = {"systemInstruction": {"parts": [{"text": system}]},
            "contents": [{"parts": [
                {"inline_data": {"mime_type": mime, "data": _b64(image_bytes)}},
                {"text": question}]}],
            "generationConfig": {"maxOutputTokens": MAX_TOKENS}}
    r = rq.post(url, json=body, timeout=TIMEOUT_S,
                headers={"x-goog-api-key": cfg.get("api_key", "")})
    if r.status_code != 200:
        raise VisionError("http_%d" % r.status_code)
    out = []
    for cand in r.json().get("candidates") or []:
        for part in ((cand.get("content") or {}).get("parts") or []):
            if part.get("text"):
                out.append(part["text"])
        if out:
            break
    if not out:
        raise VisionError("blocked_or_empty")
    return "".join(out)
