"""publicurl: the vendor callback links (DoLynk Open IoT, DoLynk ARC, Imou).

URL = public_base_url() + the vendor path + an unguessable token. The token
was sha256(key id + SECRET_KEY) only, so a token seen in a screenshot could
never be changed. Now a per-integration random salt (kept inside the
encrypted integration config as "cb_salt") is mixed in: rotate(slug) makes a
new salt, the old link answers 404 at once, and reregister(slug) tells the
vendor the new link where our code registers it (Imou setMessageCallback,
DoLynk addCallbackConfig + subscriptions, ARC setCallbackConfig). With no salt
saved the token is exactly the old one (nothing breaks before a rotation).

EZVIZ and Hik-Connect have no push callback in our code (alarms are polled),
so they have nothing to rotate.

Self-test: a message whose deviceId is SELFTEST_SERIAL proves the public
route + token + signature end to end and is answered {"selftest": ...}; it
never becomes an alert a user sees (management command cctv_callback_selftest).
"""
import hashlib
import hmac
import logging
import secrets

from .public_url import public_url

log = logging.getLogger(__name__)

CALLBACK_SLUGS = ("dolynk", "dolynk_arc", "imou")
PATHS = {"dolynk": "/api/v1/cctv/dolynk/callback/",
         "dolynk_arc": "/api/v1/cctv/dolynk/arc/",
         "imou": "/api/v1/shop/imou/callback/"}
SALT_KEY = "cb_salt"
SELFTEST_SERIAL = "ASSISTOSELFTEST"


def _cfg(slug):
    from . import integrations as I
    return I.get(slug) or {}


def key_id(slug, cfg):
    return str((cfg or {}).get("app_id" if slug == "imou" else "access_key") or "")


def salt(slug, cfg=None):
    cfg = _cfg(slug) if cfg is None else cfg
    return str((cfg or {}).get(SALT_KEY) or "")


def token(slug, kid, salt_=""):
    from django.conf import settings
    sfx = (":" + salt_) if salt_ else ""
    if slug == "imou":
        from .logic import imou as IM
        return IM.callback_token(kid, settings.SECRET_KEY + sfx)
    arc = slug == "dolynk_arc"
    return hashlib.sha256(("dolynk-%s:%s:%s%s" % ("arc" if arc else "cb", kid,
                                                   settings.SECRET_KEY, sfx)).encode()
                          ).hexdigest()[:32]


def url(slug, cfg=None):
    """The full public https callback link ("" when the keys are not saved)."""
    cfg = _cfg(slug) if cfg is None else cfg
    kid = key_id(slug, cfg)
    if not kid:
        return ""
    return public_url(PATHS[slug] + token(slug, kid, salt(slug, cfg)))


def token_ok(slug, cfg, given):
    kid = key_id(slug, cfg)
    if not kid:
        return False
    return hmac.compare_digest(token(slug, kid, salt(slug, cfg)), str(given or ""))


def rotate(slug):
    """New salt -> new link; the old link stops at once. False = no keys."""
    from . import integrations as I
    if slug not in CALLBACK_SLUGS:
        raise ValueError("no callback for %s" % slug)
    if not key_id(slug, _cfg(slug)):
        return False
    I.save(slug, {SALT_KEY: secrets.token_hex(16)})
    return True


def _active_grants(pid):
    from .logic import cctv_connect as CC
    from .models import CctvCloudLink
    out = []
    for link in CctvCloudLink.objects.filter(provider=pid, status="active"):
        g = CC.unseal(link.site_id, link.grant_blob)
        if g:
            out.append(g)
    return out


def reregister(slug):
    """Tell the vendor our current link. -> "registered" | "no_keys" |
    "failed" (then the owner pastes the link in the vendor console)."""
    from .logic import cctv_connect as CC
    cb = url(slug)
    if not cb:
        return "no_keys"
    try:
        a = CC.adapter(slug)
        if a is None or not a.configured():
            return "no_keys"
        if slug == "imou":
            from .logic import imou as IM
            c = a.client()
            ok = False
            # imou-real: capabilityEvent = person / motion on current models
            for flags in (IM.CALLBACK_FLAGS + ",numberstat", IM.CALLBACK_FLAGS,
                          "alarm,deviceStatus"):
                try:
                    c.set_callback(cb, flags)
                    ok = True
                    break
                except IM.ImouError:
                    continue
            for g in _active_grants("imou"):
                if g.get("mode") == "oauth":
                    a.after_link(g, cb)
            return "registered" if ok else "failed"
        if slug == "dolynk_arc":
            return "registered" if a.after_link({}, cb) else "failed"
        grants = _active_grants("dolynk") or [{"serials": []}]
        ok = False
        for g in grants:
            try:
                ok = a.after_link(g, cb) is not None or ok
            except Exception:  # noqa: BLE001 — a device error never stops the rest
                continue
        return "registered" if ok else "failed"
    except Exception as e:  # noqa: BLE001
        log.info("callback reregister %s failed: %s", slug, type(e).__name__)
        return "failed"


def is_selftest(m):
    return isinstance(m, dict) and str(m.get("deviceId") or "") == SELFTEST_SERIAL


def selftest_answer(slug, m):
    """A verified self-test message: never an alert; say what it proved."""
    kind = ""
    if slug.startswith("dolynk"):
        from .logic.cctv_connect import dolynk as DL
        kind = DL.classify(m.get("msgType"))[0] or ""
    log.info("callback selftest received: %s", slug)
    return {"selftest": "received", "test": True, "vendor": slug, "kind": kind}
