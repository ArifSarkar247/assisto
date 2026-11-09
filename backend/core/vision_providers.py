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
    # geminifix 4 Nov: one place for Gemini ids (core/gemini_models.py);
    # gemini-2.5-flash is no longer offered to new keys (HTTP 404 live)
    "vision_gemini": "gemini-3.5-flash-lite",
}

_HARD = {401: "auth", 402: "billing", 403: "auth", 404: "not_found"}


class VisionError(Exception):
    pass


def _http():
    import requests
    return requests


def ask(slug, cfg, *, image_bytes, mime="image/jpeg", system="", question="",
        timeout=None, max_tokens=None, usage=None):
    """`timeout` / `max_tokens` override the defaults (cctvaicheck uses a
    short budget inside the minute tick); a dict passed as `usage` is filled
    with the provider's own token counts {input_tokens, output_tokens} when
    the reply carries them (for the AIUsage ledger)."""
    opts = {"timeout": timeout or TIMEOUT_S, "max_tokens": max_tokens or MAX_TOKENS,
            "usage": usage if isinstance(usage, dict) else {}}
    fn = {"vision_claude": _claude, "vision_openai": _openai,
          "vision_gemini": _gemini}.get(slug)
    if fn is None:
        raise VisionError("unknown_provider")
    if not image_bytes:
        raise VisionError("no_image")
    try:
        text = fn(cfg or {}, image_bytes=image_bytes, mime=mime, system=system,
                  question=(question or "").strip() or "What is in this photo?",
                  opts=opts)
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


def _claude(cfg, *, image_bytes, mime, system, question, opts=None):
    opts = opts or {"timeout": TIMEOUT_S, "max_tokens": MAX_TOKENS, "usage": {}}
    try:
        import anthropic
    except ImportError:
        raise VisionError("sdk_missing")
    client = anthropic.Anthropic(api_key=cfg.get("api_key", ""), timeout=opts["timeout"],
                                 max_retries=1)
    model = (cfg.get("model") or DEFAULT_MODELS["vision_claude"]).strip()
    content = [
        {"type": "image", "source": {"type": "base64", "media_type": mime,
                                     "data": _b64(image_bytes)}},
        {"type": "text", "text": question},
    ]
    kwargs = dict(model=model, max_tokens=opts["max_tokens"], system=system,
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
    u = getattr(resp, "usage", None)
    if u is not None:
        opts["usage"].update(input_tokens=int(getattr(u, "input_tokens", 0) or 0),
                             output_tokens=int(getattr(u, "output_tokens", 0) or 0))
    return "".join(getattr(b, "text", "") for b in (resp.content or [])
                   if getattr(b, "type", "") == "text")


def _openai(cfg, *, image_bytes, mime, system, question, opts=None):
    opts = opts or {"timeout": TIMEOUT_S, "max_tokens": MAX_TOKENS, "usage": {}}
    rq = _http()
    model = (cfg.get("model") or DEFAULT_MODELS["vision_openai"]).strip()
    # AF-13: store=False — never kept in the OpenAI dashboard log / evals
    body = {"model": model, "max_tokens": opts["max_tokens"], "store": False,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": [
                    {"type": "text", "text": question},
                    {"type": "image_url", "image_url": {
                        "url": "data:%s;base64,%s" % (mime, _b64(image_bytes))}},
                ]}]}
    r = rq.post("https://api.openai.com/v1/chat/completions", json=body,
                timeout=opts["timeout"],
                headers={"Authorization": "Bearer %s" % cfg.get("api_key", "")})
    if r.status_code != 200:
        raise VisionError("http_%d" % r.status_code)
    data = r.json()
    u = data.get("usage") if isinstance(data.get("usage"), dict) else {}
    if u:
        opts["usage"].update(input_tokens=int(u.get("prompt_tokens") or 0),
                             output_tokens=int(u.get("completion_tokens") or 0))
    choices = data.get("choices") or []
    if not choices:
        raise VisionError("empty_reply")
    return (choices[0].get("message") or {}).get("content") or ""


def _gemini(cfg, *, image_bytes, mime, system, question, opts=None):
    opts = opts or {"timeout": TIMEOUT_S, "max_tokens": MAX_TOKENS, "usage": {}}
    rq = _http()
    from . import ai_health as AH
    from . import gemini_models as GM
    model = GM.resolve((cfg.get("model") or GM.get("vision")).strip(), "vision")
    if AH.is_down("gemini", model):
        raise VisionError("down")          # 404/402/403 seen recently: no doomed call
    url = ("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
           % model)
    body = {"systemInstruction": {"parts": [{"text": system}]},
            "contents": [{"parts": [
                {"inline_data": {"mime_type": mime, "data": _b64(image_bytes)}},
                {"text": question}]}],
            "generationConfig": {"maxOutputTokens": opts["max_tokens"]}}
    r = rq.post(url, json=body, timeout=opts["timeout"],
                headers={"x-goog-api-key": cfg.get("api_key", "")})
    if r.status_code != 200:
        if r.status_code in _HARD:
            from .ai import _error_message
            AH.mark_down("gemini", model, _HARD[r.status_code], "http_%d" % r.status_code,
                         _error_message(r))
        raise VisionError("http_%d" % r.status_code)
    data = r.json()
    u = data.get("usageMetadata") if isinstance(data.get("usageMetadata"), dict) else {}
    if u:
        opts["usage"].update(input_tokens=int(u.get("promptTokenCount") or 0),
                             output_tokens=int(u.get("candidatesTokenCount") or 0))
    out = []
    for cand in data.get("candidates") or []:
        for part in ((cand.get("content") or {}).get("parts") or []):
            if part.get("text"):
                out.append(part["text"])
        if out:
            break
    if not out:
        raise VisionError("blocked_or_empty")
    return "".join(out)
