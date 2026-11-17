"""publicurl: prove a vendor callback end to end over the PUBLIC internet.

    python manage.py cctv_callback_selftest            # every vendor with keys
    python manage.py cctv_callback_selftest --vendor dolynk

Posts one SIGNED test message (DoLynk Open IoT "Event message format":
sign = HMAC-SHA512(id, secretKey); ARC / Imou: token only, as the vendors
send) to https://api.lifeassisto.com/... (the same link the vendor console
holds), through nginx, to Django. Passes only when Django answers that it
received a verified TEST message. The test device id (ASSISTOSELFTEST) never
becomes an alert, a push or a stored event. Prints no token, no key.
"""
import hashlib
import hmac
import json
import time
import urllib.error
import urllib.request

from django.core.management.base import BaseCommand, CommandError


def _message(slug, cfg):
    from core.callback_links import SELFTEST_SERIAL
    now = int(time.time() * 1000)
    if slug == "imou":
        return {"msgType": "selftest", "deviceId": SELFTEST_SERIAL, "cid": "0",
                "id": "assisto-selftest-%d" % now, "time": now // 1000}
    mid = 9000000000000000000 + now
    m = {"accessKey": str(cfg.get("access_key") or ""),
         "productId": int(cfg.get("product_id") or 0) if str(cfg.get("product_id") or "").isdigit() else 0,
         "category": "IPC", "msgType": "smdHuman", "deviceId": SELFTEST_SERIAL,
         "channelId": 0, "utcTime": now, "localTime": now, "id": mid, "picUrls": []}
    if slug == "dolynk":
        m["sign"] = hmac.new(str(cfg.get("secret_key") or "").encode(), str(mid).encode(),
                             hashlib.sha512).hexdigest()
    return m


def post(url, body, timeout=20):
    req = urllib.request.Request(url, data=json.dumps([body]).encode(), method="POST",
                                 headers={"Content-Type": "application/json",
                                          "User-Agent": "assisto-callback-selftest"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read()[:65536] or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {}
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, {"error": type(e).__name__}


def run(slug, poster=post):
    """-> (ok, line) — line never holds the token."""
    from core import callback_links as CL
    from core import integrations as I
    cfg = I.get(slug) or {}
    url = CL.url(slug, cfg)
    if not url:
        return None, "%s: no keys saved - skipped" % slug
    shown = url.rsplit("/", 1)[0] + "/<token>"
    status, data = poster(url, _message(slug, cfg))
    ev = (data.get("events") or [{}])[0] if isinstance(data, dict) else {}
    ok = status == 200 and ev.get("selftest") == "received" and ev.get("test") is True
    if ok:
        return True, "%s: PASS %s -> HTTP 200, verified TEST message received (no alert)" % (
            slug, shown)
    why = ev.get("ignored") or ("HTTP %s" % status if status else data.get("error", "no answer"))
    return False, "%s: FAIL %s -> %s" % (slug, shown, why)


class Command(BaseCommand):
    help = "Post a signed test message to each vendor's PUBLIC callback link and check it."

    def add_arguments(self, parser):
        parser.add_argument("--vendor", action="append", default=[])

    def handle(self, *args, **o):
        from core import callback_links as CL
        from core.public_url import problem
        why = problem()
        if why:
            raise CommandError("public base not ready: %s" % why)
        slugs = o["vendor"] or list(CL.CALLBACK_SLUGS)
        bad = 0
        for slug in slugs:
            if slug not in CL.CALLBACK_SLUGS:
                raise CommandError("unknown vendor %s" % slug)
            ok, line = run(slug)
            self.stdout.write(line)
            bad += ok is False
        if bad:
            raise CommandError("%d callback self-test(s) failed" % bad)
