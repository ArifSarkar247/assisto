"""aifinal round 2 item 1 (owner 4 Nov 00:25): server speech-to-text when
the phone's own engine cannot write Bangla. The app records a short WAV
(max 45 s), we send it to Gemini (the saved main Gemini key) and get the words
back in BANGLA SCRIPT — never romanized. The audio is held in memory for the
one request and never stored. A failed transcription costs nothing
(charge -> refund); every request is in the AI usage log (no text)."""
import base64
import logging
import re
import time

from .i18n import pick

log = logging.getLogger(__name__)

MAX_BYTES = 1_600_000          # ~50 s of 16 kHz mono 16-bit WAV
# geminifix 4 Nov: the id comes from the one Gemini place (Owner Admin ->
# AI levels, core/gemini_models.py); MODEL stays as the shipped default.
MODEL = "gemini-3.5-flash-lite"
CREDITS = 1
_BN = re.compile(r"[ঀ-৿]")

PROMPT = {
    "bn": ("Transcribe this speech exactly. The speaker talks Bangla (Bengali), "
           "maybe with some English words. Write the Bangla words in BENGALI SCRIPT "
           "(বাংলা হরফ) — NEVER romanize Bangla into Latin letters. Keep English "
           "words and names as they are. Output ONLY the transcript, no notes."),
    "en": ("Transcribe this speech exactly. Output ONLY the transcript. If a part is "
           "Bangla, write that part in Bengali script, never romanized."),
}


def _key():
    from . import integrations
    try:
        if integrations.is_enabled("gemini"):
            return (integrations.get("gemini") or {}).get("api_key") or ""
    except Exception:  # noqa: BLE001
        pass
    return ""


def model():
    from . import gemini_models as GM
    return GM.resolve(GM.get("voice"), "voice")


def _call(key, wav, mime, lang):
    from . import ai
    from .gemini_models import thinking_off_config
    m = model()
    gen = {"maxOutputTokens": 600, "temperature": 0}
    if thinking_off_config(m):
        gen["thinkingConfig"] = thinking_off_config(m)
    body = {"contents": [{"role": "user", "parts": [
        {"inline_data": {"mime_type": mime, "data": base64.b64encode(wav).decode()}},
        {"text": PROMPT["bn" if lang == "bn" else "en"]}]}],
        "generationConfig": gen}
    url = ("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % m)
    try:
        r = ai._post(url, body, {"x-goog-api-key": key, "content-type": "application/json"})
    except ai.ProviderError as e:
        from . import ai_health as AH
        if e.kind in AH.HARD_KINDS:
            code, _, why = (e.detail or "").partition(": ")
            AH.mark_down("gemini", m, e.kind, code, why)
        raise
    cands = r.get("candidates") or []
    text = "".join(p.get("text", "") for p in
                   ((cands[0].get("content") or {}).get("parts") or [])
                   if not p.get("thought")) if cands else ""
    u = r.get("usageMetadata") or {}
    return text.strip(), int(u.get("promptTokenCount", 0) or 0), \
        int(u.get("candidatesTokenCount", 0) or 0)


# geminioff: honest, actionable (the phone's own keyboard mic is free)
OFF_MSG = ("সার্ভারে কথা লেখা এখন বন্ধ। কি-বোর্ডের মাইক (যেমন Gboard) চাপুন, ভাষা বাংলা দিন — "
           "ফোন নিজেই বিনা খরচে বাংলায় লিখবে। কোনো ক্রেডিট কাটা হয়নি।",
           "Server voice typing is paused. Tap your keyboard's mic (e.g. Gboard) with Bangla "
           "selected — your phone writes it for free. No credits were used.")


def _alt_stt():
    try:
        from .bizagent_media import stt_config
        return stt_config()
    except Exception:  # noqa: BLE001
        return {}


def _alt_call(conf):
    def run(_key, wav, mime, lang):
        from .bizagent_media import _openai_transcribe
        text = _openai_transcribe(conf, wav, mime, lang)
        return text, 0, 0
    return run


def looks_romanized(text, lang):
    """A Bangla request that came back in Latin letters only (= romanized)."""
    return lang == "bn" and bool(text) and not _BN.search(text) and \
        len(re.findall(r"[A-Za-z]{2,}", text)) >= 3


def transcribe(user, data, lang="bn", call=None):
    """(status, body). call = test seam (key, wav, mime, lang) -> (text, in, out)."""
    from . import billing
    from .models import AIUsage
    lang = "en" if str(data.get("lang") or lang) == "en" else "bn"
    try:
        wav = base64.b64decode(str(data.get("audio_b64") or ""), validate=False)
    except Exception:  # noqa: BLE001
        wav = b""
    if not wav:
        return 400, {"ok": False, "reason": "no_audio"}
    if len(wav) > MAX_BYTES:
        return 413, {"ok": False, "reason": "too_long"}
    mime = str(data.get("mime") or "audio/wav")
    if mime not in ("audio/wav", "audio/x-wav", "audio/mp4", "audio/aac", "audio/ogg"):
        mime = "audio/wav"
    key = _key()
    from . import ai_health as AH
    if key and call is None and AH.is_down("gemini", model()):
        # geminifix / geminioff: Gemini said 404 / 402 / 403 (or the 24 h
        # breaker is open) -> no doomed call; a non-Gemini path if one exists
        key = ""
    provider = "gemini"
    if not key and call is None:
        alt = _alt_stt()
        if alt:
            # geminioff: the OpenAI speech-to-text key (Integrations ->
            # Voice-note transcription), the only non-Gemini audio path —
            # Claude cannot take audio
            key, provider = "alt", "openai"
            call = _alt_call(alt)
    if not key and call is None:
        log.info("voice: server transcription unavailable (no Gemini / STT key)")
        return 503, {"ok": False, "reason": "unavailable", "use_phone": True,
                     "message": pick(lang, OFF_MSG[0], OFF_MSG[1])}
    if call is None or provider != "gemini":
        try:
            from . import ai_router as R
            conf = R.cfg()
            capped = R.total_capped(conf) or R.provider_capped(provider, conf)
        except Exception:  # noqa: BLE001
            capped = False
        if capped:
            # geminioff: the Owner Admin daily AI caps hold here too
            return 503, {"ok": False, "reason": "unavailable", "use_phone": True,
                         "message": pick(lang, OFF_MSG[0], OFF_MSG[1])}
    res = billing.charge(user, "voice_transcribe", note="voice.transcribe", exact=CREDITS)
    if not res["ok"]:
        return 402, {"ok": False, "reason": "credits"}
    charged = int(res.get("charged") or 0)
    t0 = time.monotonic()
    text, itok, otok, err = "", 0, 0, ""
    audio_s = max(0.0, (len(wav) - 44) / 32000.0)     # seconds of 16 kHz mono WAV
    try:
        text, itok, otok = (call or _call)(key, wav, mime, lang)
        if not text:
            err = "empty"
        elif looks_romanized(text, lang):
            err = "romanized"
    except Exception as e:  # noqa: BLE001
        err = getattr(e, "kind", "") or type(e).__name__
    finally:
        del wav
    ms = int((time.monotonic() - t0) * 1000)
    from .ai_config import DEFAULT_PRICES
    used = model()
    p = DEFAULT_PRICES.get(used, {"in": 0.3, "out": 2.5})
    cost = (itok * 0.30 + otok * float(p["out"])) / 1e6      # audio input $0.30 / 1M
    if provider == "openai":
        # per-minute price from the STT integration (default $0.003 / min)
        alt = _alt_stt()
        used = (alt.get("model") or "gpt-4o-mini-transcribe")[:40]
        try:
            per_min = float(alt.get("cost_per_minute_usd") or 0.003)
        except (TypeError, ValueError):
            per_min = 0.003
        cost = per_min * max(1.0, audio_s / 60.0)
    refunded = 0
    if err and charged:
        billing.credit(user, "adjust", charged, note="ai_refund:voice", spend_ref=res.get("spend_ref"))
        refunded, charged = charged, 0
    try:
        AIUsage.objects.create(user=user, feature="voice.transcribe", model=used[:40],
                               provider=provider, input_tokens=itok, output_tokens=otok,
                               cost_usd=cost, latency_ms=ms, ok=not err, error_kind=err[:30],
                               credits_charged=charged + refunded, refunded=refunded,
                               tier="voice", task_class="voice")
    except Exception:  # noqa: BLE001
        pass
    if err:
        log.info("voice: transcription failed (%s), refunded %s", err, refunded)
        return 502, {"ok": False, "reason": "failed", "refunded": refunded,
                     "message": pick(lang, "কথাটি লেখা গেল না — কোনো ক্রেডিট কাটা হয়নি।",
                                     "Couldn't write that down — no credits were used.")}
    return 200, {"ok": True, "text": text[:2000], "credits": charged}
