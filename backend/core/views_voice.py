"""Part 3 — Assisto Voice server config (a3-voice).

GET /api/v1/voice/config -> the optional "Hey Assisto" wake-word setup.

Key-gated: the wake word stays honestly OFF ("coming when the key is set") until
the owner saves a Picovoice AccessKey and a "Hey Assisto" keyword-file URL on
the Integrations page AND the integration test marks it working. Wake-word
detection itself runs on the phone (Porcupine, on-device); no audio ever
reaches this server.

Note: a Picovoice AccessKey is designed to be embedded in client apps (it is
scoped to the owner's Picovoice account and metered per device), so returning
it to an authenticated user is expected. It is never logged.
"""
from rest_framework.response import Response
from rest_framework.views import APIView


def wake_config():
    from . import integrations
    cfg = integrations.get("picovoice") if integrations.is_enabled("picovoice") else {}
    key = (cfg.get("access_key") or "").strip()
    url = (cfg.get("keyword_url") or "").strip()
    try:
        sens = float(cfg.get("sensitivity") or 0.6)
    except (TypeError, ValueError):
        sens = 0.6
    sens = min(0.95, max(0.1, sens))
    available = bool(key) and url.startswith("https://")
    return {
        "available": available,
        "access_key": key if available else "",
        "keyword_url": url if available else "",
        "sensitivity": sens,
        "engine": "porcupine",
    }


class VoiceConfigView(APIView):
    def get(self, request):
        return Response({"wake": wake_config()})
