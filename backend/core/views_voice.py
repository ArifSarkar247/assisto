"""Part 3 — Assisto Voice server endpoints (a3-voice).

GET /api/v1/voice/config   -> optional "Hey/Hi Assisto" wake-word setup.
GET /api/v1/voice/youtube?q=<song artist>
                           -> {available, video_id, title, channel}

Wake word is key-gated: honestly OFF ("coming when the key is set") until the
owner saves a Picovoice AccessKey and the keyword-file URL(s) on the
Integrations page and the integration test marks it working. Detection runs on
the phone (Porcupine, on-device); no audio ever reaches this server. A Picovoice
AccessKey is designed to be embedded in client apps (scoped to the owner's
account, metered per device), so returning it to a logged-in user is expected.
It is never logged.

YouTube search uses the owner's YouTube Data API key SERVER-SIDE only (the key
never goes to the app). Results are cached per query, and each user has an
admin-editable daily cap (pricing limits.voice_youtube_daily) because the free
quota is 10,000 units/day and one search costs 100.
"""
import json
import urllib.parse
import urllib.request

from django.core.cache import cache
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView


def wake_config():
    from . import integrations
    cfg = integrations.get("picovoice") if integrations.is_enabled("picovoice") else {}
    key = (cfg.get("access_key") or "").strip()
    raw = (cfg.get("keyword_url") or "").strip()
    urls = [u.strip() for u in raw.split(",") if u.strip()]
    try:
        sens = float(cfg.get("sensitivity") or 0.6)
    except (TypeError, ValueError):
        sens = 0.6
    sens = min(0.95, max(0.1, sens))
    available = bool(key) and bool(urls) and all(u.startswith("https://") for u in urls)
    return {
        "available": available,
        "access_key": key if available else "",
        "keyword_url": urls[0] if available else "",
        "keyword_urls": urls if available else [],
        "sensitivity": sens,
        "engine": "porcupine",
    }


class VoiceConfigView(APIView):
    def get(self, request):
        return Response({"wake": wake_config()})


def youtube_search(key, q):
    """One YouTube Data API v3 search (100 quota units). Returns a dict or None."""
    params = urllib.parse.urlencode({
        "part": "snippet", "type": "video", "maxResults": 1, "q": q,
        "regionCode": "BD", "safeSearch": "moderate", "key": key,
    })
    with urllib.request.urlopen(
            "https://www.googleapis.com/youtube/v3/search?" + params, timeout=8) as r:
        data = json.loads(r.read().decode())
    for it in data.get("items") or []:
        vid = (it.get("id") or {}).get("videoId")
        if vid:
            sn = it.get("snippet") or {}
            return {"video_id": vid, "title": sn.get("title", ""),
                    "channel": sn.get("channelTitle", "")}
    return None


def _daily_cap():
    try:
        from . import billing
        from .logic import pricing
        return pricing.limits(billing.cfg()).get("voice_youtube_daily", 40)
    except Exception:  # noqa: BLE001
        return 40


class VoiceYoutubeView(APIView):
    def get(self, request):
        from . import integrations
        q = " ".join((request.query_params.get("q") or "").split())[:120]
        if not q:
            return Response({"available": False, "reason": "empty"})
        if not integrations.is_enabled("youtube"):
            return Response({"available": False, "reason": "no_key"})
        key = (integrations.get("youtube").get("api_key") or "").strip()
        if not key:
            return Response({"available": False, "reason": "no_key"})
        ck = "va_yt:" + q.lower()
        hit = cache.get(ck)
        if hit:
            return Response({"available": True, "cached": True, **hit})
        cap = _daily_cap()
        uk = f"va_yt_n:{request.user.pk}:{timezone.localdate().isoformat()}"
        used = cache.get(uk, 0)
        if cap <= 0 or used >= cap:
            return Response({"available": False, "reason": "daily_limit"})
        cache.set(uk, used + 1, 60 * 60 * 26)
        try:
            res = youtube_search(key, q)
        except Exception:  # noqa: BLE001  (quota / network) -> honest fallback
            return Response({"available": False, "reason": "error"})
        if not res:
            return Response({"available": False, "reason": "not_found"})
        cache.set(ck, res, 60 * 60 * 24 * 7)
        return Response({"available": True, **res})
