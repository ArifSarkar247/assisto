"""imou-real: READ-ONLY readiness check of every CCTV brand cloud before a
real-camera test (owner order 17 Nov).

  manage.py cctv_vendor_check            # imou, ezviz, dolynk, hikconnect

Per brand: keys saved? token call, device-list call, callback link https?
Prints ONLY OK / a vendor error code / counts — never a key, token or the
callback's secret part. The result also lands on the Owner Admin
integration card (integrations.record_check), so an old green never hides a
key that stopped working. Changes no camera, no subscription, no setting.
"""
import re
from urllib.parse import urlparse

from django.core.management.base import BaseCommand

BRANDS = ("imou", "ezviz", "dolynk", "hikconnect")


def _code(e):
    s = "%s %s" % (getattr(e, "code", "") or "", getattr(e, "hint", "") or "")
    m = re.findall(r"[A-Z]{2,4}\d{3,4}|\b\d{5}\b|not_configured|network|http_\d+|token_expired|"
                   r"no_token|bad_json", s)
    return m[0] if m else type(e).__name__


def callback_state(url):
    """'https' (usable) | 'localhost' | 'http' | 'none' — never the URL."""
    if not url:
        return "none"
    u = urlparse(url)
    host = (u.hostname or "").lower()
    if host in ("localhost", "127.0.0.1", "::1") or host.endswith(".local"):
        return "localhost"
    return "https" if u.scheme == "https" else "http"


def _callback(pid, cfg):
    try:
        if pid == "imou":
            from core.watchman_views import imou_callback_url
            return imou_callback_url(cfg.get("app_id")) if cfg.get("app_id") else ""
        if pid == "dolynk":
            from core.cctv_connect_views import dolynk_callback_url
            return dolynk_callback_url(cfg.get("access_key"))
    except Exception:  # noqa: BLE001
        return ""
    return None          # this brand has no push callback


def check(pid, http=None):
    """-> dict(brand, keys, token, devices, callback). Read-only vendor calls."""
    from core import integrations as I
    from core.logic import cctv_connect as CC
    cls = CC.ADAPTERS[pid]
    cfg = I.get(cls.integration) or {}
    a = cls(cfg, http=http)
    row = {"brand": pid, "keys": "set" if a.configured() else "missing",
           "token": "-", "devices": "-", "callback": "-"}
    cb = _callback(pid, cfg)
    if cb is not None:
        row["callback"] = callback_state(cb)
    if not a.configured():
        return row
    step = "token"
    try:
        if pid == "imou":
            c = a.client()
            c.token()
            row["token"] = "OK"
            step = "devices"
            d = c.call("deviceBaseList", {"token": c.token(), "bindId": -1, "limit": 20,
                                          "type": "bindAndShare", "needApInfo": False}) or {}
            row["devices"] = "OK %d" % len(d.get("deviceList") or [])
        elif pid == "ezviz":
            c = a.client()
            c.token()
            row["token"] = "OK"
            step = "devices"
            d = c.call("/api/lapp/device/list", {"pageStart": 0, "pageSize": 20})
            row["devices"] = "OK %d" % (len(d) if isinstance(d, list) else 0)
        elif pid == "dolynk":
            a.client().token(fresh=True)
            row["token"] = "OK"
        else:
            a.token()
            row["token"] = "OK"
        I.record_check(cls.integration, True, "", "readiness")
    except Exception as e:  # noqa: BLE001 - every vendor error is a code here
        row[step] = "FAIL %s" % _code(e)
        I.record_check(cls.integration, False, _code(e), "readiness " + step)
    return row


class Command(BaseCommand):
    help = "Read-only readiness of the CCTV brand clouds (codes only, never keys)."

    def add_arguments(self, parser):
        parser.add_argument("--brand", choices=BRANDS, action="append")

    def handle(self, *args, **opts):
        for pid in opts.get("brand") or BRANDS:
            r = check(pid)
            self.stdout.write("%-10s keys=%s token=%s devices=%s callback=%s" % (
                r["brand"], r["keys"], r["token"], r["devices"], r["callback"]))
