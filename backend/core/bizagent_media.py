"""
G1 — Business AI Agent: customer PHOTOS and VOICE NOTES.

Photos (Night Salesman §1):
  1. perceptual match at cost 0 — average hash + difference hash + colour
     histogram of every catalog photo (Pillow on our CPU; no model weights, so
     no licence question). A customer who re-sends the Page's own product photo
     or a screenshot of the post matches instantly.
  2. if that is not sure AND a vision provider is connected (Owner Admin →
     Integrations: Claude / OpenAI / Gemini vision, the same adapters as
     "image in chat") AND the seller has credits: ONE vision call describes the
     photo and reads any text in it (address, phone, size chart, payment
     screenshot). Charged as `ai_sales_vision` credits (admin-editable in
     Owner Admin → Pricing); the provider cost is booked in Profit Guard and on
     the message row (cost per image).
  3. the description is matched to the catalog in code; prices always come
     from the catalog, never from the model.
  Images live only in memory for the call — never written to disk or the DB.

Voice notes (§ voice): transcribed by the owner's transcription key
(Integrations → "Voice-note transcription", OpenAI audio API), charged as
`ai_sales_voice` credits; without a key the customer is asked to type and the
seller is notified (never silent, never a fake transcript).

HONEST LIMIT: the provider calls are unit-tested with mocked transports; the
first real call happens when the owner connects a key.
"""
import base64
import io
import logging
import math
import urllib.request

log = logging.getLogger(__name__)

MAX_BYTES = 6 * 1024 * 1024
MAX_AUDIO_BYTES = 10 * 1024 * 1024
FETCH_TIMEOUT = 15


# ===================================================================== fetch
def _http_fetch(url, headers=None):
    """GET raw bytes (size-capped). Returns (status, bytes, content_type)."""
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as r:
            data = r.read(MAX_AUDIO_BYTES + 1)
            return r.status, data, r.headers.get("Content-Type", "")
    except Exception as e:  # noqa: BLE001
        return 0, b"", type(e).__name__


_fetch = _http_fetch


def set_fetch(fn):
    """Tests: install a fake byte fetcher. Returns the previous one."""
    global _fetch
    prev = _fetch
    _fetch = fn or _http_fetch
    return prev


def decode_data_url(url):
    """data:image/png;base64,.... → (bytes, mime) — ONLY accepted for
    test-mode channels (the self-test has no Meta CDN)."""
    if not (url or "").startswith("data:") or ";base64," not in url:
        return b"", ""
    head, b64 = url.split(",", 1)
    try:
        return base64.b64decode(b64[: MAX_BYTES * 2]), head[5:].split(";")[0]
    except Exception:
        return b"", ""


def fetch_attachment(ch, att, token=""):
    """Bytes of one attachment: Messenger/IG give a CDN url; WhatsApp gives a
    media id (GET /{id} → url, then GET url with the token)."""
    url = att.get("url") or ""
    if url.startswith("data:"):
        if not ch.test_mode:
            return b"", "", "data_url_not_allowed"
        data, mime = decode_data_url(url)
        return data, mime or att.get("mime", ""), "" if data else "bad_data_url"
    if ch.kind == "whatsapp_cloud" and not ch.test_mode:
        url = ""                       # real WhatsApp: only the Graph media id is trusted
    if att.get("media_id") and not url:
        from . import bizagent_graph as G
        if not token:
            return b"", "", "no_token"
        r = G._get(str(att["media_id"]), token)
        url = (r.get("json") or {}).get("url") or ""
        if not url:
            return b"", "", "media_lookup_failed"
        status, data, ctype = _fetch(url, {"Authorization": "Bearer " + token})
    elif url.startswith("https://"):
        status, data, ctype = _fetch(url, {})
    else:
        return b"", "", "no_url"
    if status != 200 or not data:
        return b"", "", "fetch_failed"
    return data, (att.get("mime") or ctype or "").split(";")[0], ""


# ===================================================================== signatures
def _img(data):
    from PIL import Image
    im = Image.open(io.BytesIO(data))
    im.load()
    return im.convert("RGB")


def _trim(im):
    """Drop flat borders (phone screenshots add white/black bars)."""
    from PIL import ImageChops
    try:
        bg = im.getpixel((0, 0))
        if not (min(bg) > 235 or max(bg) < 20):
            return im                  # only white/black screenshot bars are trimmed
        from PIL import Image
        diff = ImageChops.difference(im, Image.new("RGB", im.size, bg))
        bbox = diff.convert("L").point(lambda v: 255 if v > 18 else 0).getbbox()
        if bbox and (bbox[2] - bbox[0]) > im.size[0] * 0.3 and (bbox[3] - bbox[1]) > im.size[1] * 0.3:
            return im.crop(bbox)
    except Exception:
        pass
    return im


def signature(data):
    """{"ahash", "dhash", "hist"} of an image (bytes) or None when unreadable."""
    try:
        im = _trim(_img(data))
    except Exception:
        return None
    from PIL import Image
    g = im.convert("L")
    a = g.resize((8, 8), Image.BILINEAR)
    px = list(a.getdata())
    avg = sum(px) / 64.0
    ah = 0
    for v in px:
        ah = (ah << 1) | (1 if v >= avg else 0)
    d = g.resize((9, 8), Image.BILINEAR)
    dp = list(d.getdata())
    dh = 0
    for y in range(8):
        for x in range(8):
            dh = (dh << 1) | (1 if dp[y * 9 + x] > dp[y * 9 + x + 1] else 0)
    small = im.resize((48, 48), Image.BILINEAR)
    hist = [0] * 64
    for r, gg, b in small.getdata():
        hist[(r // 64) * 16 + (gg // 64) * 4 + (b // 64)] += 1
    tot = float(sum(hist)) or 1.0
    return {"ahash": "%016x" % ah, "dhash": "%016x" % dh,
            "hist": [round(h / tot, 4) for h in hist]}


def _ham(a, b):
    try:
        return bin(int(a, 16) ^ int(b, 16)).count("1")
    except (TypeError, ValueError):
        return 64


def similarity(s1, s2):
    """0..1. Hash similarity (structure) weighted with histogram intersection
    (colour) so a different-coloured variant of the same cut scores lower."""
    if not s1 or not s2:
        return 0.0
    hs = 1 - (_ham(s1["ahash"], s2["ahash"]) + _ham(s1["dhash"], s2["dhash"])) / 128.0
    h1, h2 = s1.get("hist") or [], s2.get("hist") or []
    hi = sum(min(a, b) for a, b in zip(h1, h2)) if h1 and h2 else 0.0
    return round(0.65 * hs + 0.35 * hi, 4)


def _photo_bytes(p):
    try:
        with p.photo.open("rb") as f:
            return f.read(MAX_BYTES)
    except Exception:
        return b""


def product_sigs(business):
    """[(product, sig)] for every catalog product with a photo; signatures
    are cached in BizProductSig and refreshed when the photo changes."""
    from django.db.models import Q
    from .models import BizProductSig, Product
    out = []
    qs = Product.objects.filter(user=business.user).filter(
        Q(business=business) | Q(business__isnull=True)).exclude(photo="").exclude(photo=None)
    for p in qs[:500]:
        name = p.photo.name or ""
        row = BizProductSig.objects.filter(product=p).first()
        if row is None or row.photo_name != name or not row.ahash:
            sig = signature(_photo_bytes(p))
            if sig is None:
                continue
            BizProductSig.objects.update_or_create(
                product=p, defaults={"photo_name": name, "ahash": sig["ahash"],
                                     "dhash": sig["dhash"], "hist": sig["hist"]})
        else:
            sig = {"ahash": row.ahash, "dhash": row.dhash, "hist": row.hist}
        out.append((p, sig))
    return out


def visual_matches(business, data, limit=3):
    """[(score, product_id)] best first (cost 0)."""
    sig = signature(data)
    if sig is None:
        return []
    scored = [(similarity(sig, s), p.id) for p, s in product_sigs(business)]
    scored.sort(key=lambda x: -x[0])
    return scored[:limit]


# ===================================================================== vision
def vision_provider():
    """(slug, conf, cost_usd) of the active vision provider, or ('', {}, 0)."""
    try:
        from . import chat_vision_service as CVS
        return CVS._active()
    except Exception:
        return "", {}, 0.0


def describe(user, data, mime, lang, catalog_names):
    """ONE paid vision call. Returns (parsed | None, info) where info =
    {"charged": credits, "cost_bdt": float, "error": str}. Credits are charged
    BEFORE the call and refunded when the provider fails (never a fake
    answer)."""
    from . import billing
    from . import vision_providers as VP
    from .logic import bizagent_g1 as G1
    slug, conf, cost_usd = vision_provider()
    info = {"charged": 0, "cost_bdt": 0.0, "error": "", "provider": slug}
    if not slug:
        info["error"] = "no_provider"
        return None, info
    c = billing.cfg()
    table = (c.get("action_costs") or {}).get("ai_sales_vision") or {}
    cost_usd = max(float(cost_usd or 0), float(table.get("provider_cost") or 0))
    res = billing.charge(user, "ai_sales_vision", qty=1, note="bizagent.vision")
    if not res["ok"]:
        info["error"] = res.get("reason") or "insufficient"
        return None, info
    info["charged"] = int(res.get("charged") or 0)
    try:
        raw = VP.ask(slug, conf, image_bytes=data, mime=mime or "image/jpeg",
                     system=G1.vision_task(lang, catalog_names),
                     question="Describe this photo for the shop as JSON.")
    except VP.VisionError as e:
        if info["charged"]:
            billing.credit(user, "adjust", info["charged"], note="bizagent.vision_refund")
        info["charged"] = 0
        info["error"] = "vision_" + str(e)[:40]
        return None, info
    info["cost_bdt"] = round(cost_usd * float(c.get("usd_bdt") or 120), 4)
    try:
        billing.record_cost("ai", info["cost_bdt"])
    except Exception:
        pass
    return G1.parse_vision(raw), info


# ===================================================================== voice
def stt_config():
    from . import integrations
    try:
        if not integrations.is_enabled("voice_transcribe"):
            return {}
        conf = integrations.get("voice_transcribe") or {}
    except Exception:
        return {}
    return conf if conf.get("api_key") else {}


def _openai_transcribe(conf, data, mime, lang):
    """OpenAI audio transcription (multipart). Returns text or raises."""
    import requests
    model = (conf.get("model") or "gpt-4o-mini-transcribe").strip()
    ext = {"audio/ogg": "ogg", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/aac": "aac",
           "audio/wav": "wav", "audio/webm": "webm", "audio/amr": "amr"}.get(
        (mime or "").split(";")[0], "ogg")
    r = requests.post("https://api.openai.com/v1/audio/transcriptions",
                      headers={"Authorization": "Bearer %s" % conf.get("api_key", "")},
                      files={"file": ("voice.%s" % ext, data, mime or "audio/ogg")},
                      data={"model": model, "language": "bn" if lang != "en" else "en"},
                      timeout=60)
    if r.status_code != 200:
        raise RuntimeError("http_%d" % r.status_code)
    return (r.json().get("text") or "").strip()


_transcriber = _openai_transcribe


def set_transcriber(fn):
    global _transcriber
    prev = _transcriber
    _transcriber = fn or _openai_transcribe
    return prev


def transcribe(user, data, mime, lang="bn"):
    """(text | '', info). Charged `ai_sales_voice` credits first, refunded on
    a provider failure."""
    from . import billing
    conf = stt_config()
    info = {"charged": 0, "cost_bdt": 0.0, "error": ""}
    if not conf:
        info["error"] = "no_key"
        return "", info
    if not data or len(data) > MAX_AUDIO_BYTES:
        info["error"] = "too_large"
        return "", info
    res = billing.charge(user, "ai_sales_voice", qty=1, note="bizagent.voice")
    if not res["ok"]:
        info["error"] = res.get("reason") or "insufficient"
        return "", info
    info["charged"] = int(res.get("charged") or 0)
    try:
        text = _transcriber(conf, data, mime, lang)
    except Exception as e:  # noqa: BLE001
        if info["charged"]:
            billing.credit(user, "adjust", info["charged"], note="bizagent.voice_refund")
        info["charged"] = 0
        info["error"] = "stt_" + type(e).__name__
        return "", info
    c = billing.cfg()
    try:
        per_min = float(conf.get("cost_per_minute_usd") or 0)
    except (TypeError, ValueError):
        per_min = 0.0
    table = (c.get("action_costs") or {}).get("ai_sales_voice") or {}
    # a voice note is capped at ~2 minutes by the charge; book the larger estimate
    usd = max(per_min * 2, float(table.get("provider_cost") or 0))
    info["cost_bdt"] = round(usd * float(c.get("usd_bdt") or 120), 4)
    try:
        billing.record_cost("ai", info["cost_bdt"])
    except Exception:
        pass
    return (text or "")[:2000], info


def approx_seconds(n_bytes):
    """Rough length of an Opus/AAC voice note (≈2 kB/s) — for display only."""
    return int(math.ceil((n_bytes or 0) / 2000.0))
