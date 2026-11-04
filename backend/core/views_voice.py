"""Part 3 — Assisto Voice server endpoints (a3-voice, k1-wake).

GET /api/v1/voice/config   -> optional "Hey/Hi/Ok Assisto" wake-word setup.
GET /api/v1/voice/wake-model/<name>
                           -> one model file of the on-device wake word.
GET /api/v1/voice/youtube?q=<song artist>
                           -> {available, video_id, title, channel}

Wake word (k1-wake): openWakeWord-style on-device detection with OUR OWN model
(Picovoice was removed: its Free Tier ended 30 Jun 2026). The model files and a
manifest.json (produced by .github/workflows/wakeword-train.yml) live in
core/wakeword_models/ (override: settings.WAKEWORD_DIR). Until a trained,
licence-cleared model is installed the config honestly says
available=false / reason="model_pending" and the app shows "coming soon".
Detection runs on the phone; no audio ever reaches this server — the server
only hands out the model files (public, no user data).

YouTube search uses the owner's YouTube Data API key SERVER-SIDE only (the key
never goes to the app). Results are cached per query, and each user has an
admin-editable daily cap (pricing limits.voice_youtube_daily) because the free
quota is 10,000 units/day and one search costs 100.
"""
import json
import os
import re
import urllib.parse
import urllib.request

from django.conf import settings
from django.core.cache import cache
from django.http import FileResponse, Http404
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

# ---- k1-wake ----
# Two feature back-ends (tools/wakeword/ww/features.py): openWakeWord's split
# mel + embedding models, or one Google speech_embedding "e2e" model.
_ROLE_SETS = ({"mel", "embed", "wake"}, {"e2e", "wake"})
_ROLE_ORDER = ("mel", "embed", "e2e", "wake")
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}\.onnx$")
_SHA_RE = re.compile(r"^[0-9a-f]{64}$")
SENSITIVITY_DEFAULTS = {"low": 0.7, "normal": 0.5, "high": 0.3}


def wake_dir():
    return str(getattr(settings, "WAKEWORD_DIR", "") or
               os.path.join(os.path.dirname(os.path.abspath(__file__)), "wakeword_models"))


def load_manifest():
    """The installed model manifest, validated; None when absent/invalid.

    manifest.json = {"version": "2026.10.1", "engine": "openwakeword",
      "licence_cleared": true, "frames": 16,
      "feature_backend": "e2e"|"oww", "window_samples": 12400,
      "files": [{"role": "mel"|"embed"|"e2e"|"wake", "name": "x.onnx", "sha256": "…", "size": n}],
      "thresholds": {"low": .., "normal": .., "high": ..},
      "eval": {...measured numbers from the CI evaluation...}}
    """
    p = os.path.join(wake_dir(), "manifest.json")
    try:
        with open(p, encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(m, dict):
        return None
    files = m.get("files") or []
    roles = {}
    for e in files if isinstance(files, list) else []:
        if not isinstance(e, dict):
            return None
        name, sha, role = str(e.get("name", "")), str(e.get("sha256", "")).lower(), e.get("role")
        if role not in _ROLE_ORDER or not _NAME_RE.match(name) or not _SHA_RE.match(sha):
            return None
        if not os.path.isfile(os.path.join(wake_dir(), name)):
            return None
        roles[role] = {"role": role, "name": name, "sha256": sha,
                       "size": int(e.get("size") or os.path.getsize(os.path.join(wake_dir(), name)))}
    if set(roles) not in _ROLE_SETS:
        return None
    try:
        window = int(m.get("window_samples") or 12400)
    except (TypeError, ValueError):
        return None
    th = dict(SENSITIVITY_DEFAULTS)
    for k, v in (m.get("thresholds") or {}).items():
        if k in th:
            try:
                th[k] = min(0.99, max(0.01, float(v)))
            except (TypeError, ValueError):
                pass
    try:
        frames = int(m.get("frames") or 16)
    except (TypeError, ValueError):
        frames = 16
    return {"version": str(m.get("version") or ""), "licence_cleared": m.get("licence_cleared") is True,
            "files": [roles[r] for r in _ROLE_ORDER if r in roles], "thresholds": th,
            "frames": min(64, max(4, frames)),
            "feature_backend": "e2e" if "e2e" in roles else "oww",
            "window_samples": min(48000, max(1280, window))}


def wake_config(request=None):
    m = load_manifest()
    base = {"engine": "openwakeword", "phrases": ["Hey Assisto", "Hi Assisto", "Ok Assisto"]}
    if not m:
        return {**base, "available": False, "reason": "model_pending", "files": [],
                "thresholds": dict(SENSITIVITY_DEFAULTS), "version": ""}
    if not m["licence_cleared"]:
        # Never hand out a model whose training inputs are not cleared for a
        # commercial app (see .phaseB/MODEL_LICENSES.md).
        return {**base, "available": False, "reason": "licence_pending", "files": [],
                "thresholds": m["thresholds"], "version": m["version"]}
    files = []
    for e in m["files"]:
        path = "/api/v1/voice/wake-model/" + e["name"]
        url = request.build_absolute_uri(path) if request is not None else path
        files.append({**e, "url": url})
    return {**base, "available": True, "reason": "", "files": files,
            "thresholds": m["thresholds"], "frames": m["frames"], "version": m["version"],
            "feature_backend": m["feature_backend"], "window_samples": m["window_samples"]}


class VoiceConfigView(APIView):
    def get(self, request):
        return Response({"wake": wake_config(request)})


class WakeModelFileView(APIView):
    """Model files are public (open model, no user data) and small; only the
    names listed in the manifest can be fetched (no path traversal)."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request, name):
        m = load_manifest()
        if not m or not m["licence_cleared"] or name not in {e["name"] for e in m["files"]}:
            raise Http404
        resp = FileResponse(open(os.path.join(wake_dir(), name), "rb"),
                            content_type="application/octet-stream")
        resp["Cache-Control"] = "public, max-age=86400"
        return resp


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


class VoiceTranscribeView(APIView):
    """aifinal round 2: POST /voice/transcribe {audio_b64, mime, lang} ->
    {ok, text}. Bangla in Bangla script; never charged when it fails."""
    def post(self, request):
        from . import voice_transcribe as VT
        from .i18n import req_lang
        code, body = VT.transcribe(request.user, request.data or {}, req_lang(request))
        return Response(body, status=code)



class VoiceRouteView(APIView):
    """wakeword: POST /voice/route {text, lang} -> one FIXED phone action
    (core/voice_router.py). Never executes anything; the app confirms."""
    def post(self, request):
        from . import voice_router
        d = request.data or {}
        lang = "en" if str(d.get("lang") or "") == "en" else "bn"
        return Response(voice_router.route(request.user, d.get("text") or "", lang))
