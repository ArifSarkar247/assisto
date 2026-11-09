"""
cctv_connect — brand-cloud connectors for existing cameras (CCTV Guard V3,
part A1, agent cctvconnect). One adapter per vendor behind one interface
(base.Provider): EZVIZ, Imou, Hikvision Hik-Connect, Dahua DoLynk.

Every connector is OFF until its developer key exists in Owner Admin →
Integrations AND that integration's Test passed (status "working"); the app
never shows an OFF connector. Keys never live in the repo.

Grants (what a user authorized) are sealed with Fernet and bound to ONE site:
seal(site_id, grant) / unseal(site_id, blob) refuse a blob from another site.
"""
import json

from .base import ConnectError, Provider, hint_text  # noqa: F401
from .ezviz import EzvizAdapter
from .hikconnect import HikConnectAdapter
from .dolynk import ARC_OK, DolynkAdapter, DolynkArcAdapter
from .imou import ImouAdapter

ADAPTERS = {a.id: a for a in (HikConnectAdapter, DolynkAdapter, DolynkArcAdapter,
                              EzvizAdapter, ImouAdapter)}
ORDER = ("hikconnect", "dolynk", "dolynk_arc", "ezviz", "imou")   # BD market share order
CAMERA_VENDOR = {"hikconnect": "hikvision", "dolynk": "dahua", "dolynk_arc": "dahua",
                 "ezviz": "ezviz", "imou": "imou"}
SIGNED_IN = {"dolynk": "DoLynk sign-in OK", "dolynk_arc": ARC_OK}


def adapter(pid, http=None, now=None, cfg=None):
    """An adapter with its saved keys (or `cfg` in tests), else None."""
    cls = ADAPTERS.get(pid)
    if cls is None:
        return None
    if cfg is None:
        from ... import integrations as I
        cfg = I.get(cls.integration) or {}
    return cls(cfg, http=http, now=now)


def enabled(pid):
    """ON only when the key exists AND the owner's Test passed."""
    cls = ADAPTERS.get(pid)
    if cls is None:
        return False
    try:
        from ... import integrations as I
        if not I.is_enabled(cls.integration):
            return False
        if pid in SIGNED_IN and not _signed_in(pid):
            return False          # keys alone never switch it on: a signed sign-in did
        return cls(I.get(cls.integration) or {}).configured()
    except Exception:
        return False


DOLYNK_OK = SIGNED_IN["dolynk"]


def _signed_in(pid):
    from ...models import Integration
    obj = Integration.objects.filter(slug=ADAPTERS[pid].integration).first()
    return bool(obj and SIGNED_IN[pid] in (obj.detail or ""))


def dolynk_signin(cfg, http=None, arc=False):
    """Owner Admin Test: a SIGNED "Obtaining AppAccessToken" call (and, for
    Open ARC, the ARC account login). -> (ok, detail); keys are never shown.
    Only ok switches the camera link on."""
    cls = DolynkArcAdapter if arc else DolynkAdapter
    a = cls(cfg, http=http)
    if not a.configured():
        if arc:
            return False, ("DoLynk ARC: Access Key, Secret Access Key, Product ID, ARC email, "
                           "ARC password and the switch (on) are all needed")
        return False, "DoLynk: Access Key and Secret Access Key are both needed"
    try:
        a.signin()
    except ConnectError as e:
        return False, ("%s: sign-in answered %s %s — stays OFF." % (
            "DoLynk ARC" if arc else "DoLynk", e.code, e.msg)).strip()
    return True, SIGNED_IN[cls.id] + " (signed token received)"


def enabled_ids():
    return [p for p in ORDER if enabled(p)]


# ---------------------------------------------------------------- sealing
def _fernet():
    from ... import integrations as I
    return I._fernet()


def seal(site_id, grant):
    body = json.dumps({"site": int(site_id), "g": grant}, separators=(",", ":"))
    return _fernet().encrypt(body.encode()).decode()


def unseal(site_id, blob):
    """-> grant dict, or {} when the blob is broken / from another site."""
    if not blob:
        return {}
    try:
        d = json.loads(_fernet().decrypt(str(blob).encode()).decode())
    except Exception:
        return {}
    if not isinstance(d, dict) or d.get("site") != int(site_id):
        return {}
    g = d.get("g")
    return g if isinstance(g, dict) else {}


def test_integration(pid, cfg, http=None):
    """Owner Admin "Test" button: a token / signed call proves the keys."""
    a = ADAPTERS[pid](cfg, http=http)
    if not a.configured():
        return False, "%s: missing keys" % a.name
    try:
        if pid == "hikconnect":
            from . import hikconnect as H
            H._token_cache.pop(cfg.get("app_key"), None)
            a.token()
        elif pid in SIGNED_IN:
            a.signin()
        else:
            a.client().call("accessToken")
    except ConnectError as e:
        return False, "%s: %s %s" % (a.name, e.code, e.msg)
    except Exception as e:  # noqa: BLE001 - ImouError from accessToken
        return False, "%s: %s" % (a.name, str(e)[:120])
    return True, "%s access token OK" % a.name


def imou_oauth_check(cfg, http=None):
    """Owner Admin Test for the Imou OAuth project keys: a refresh with a
    dummy token must fail as a bad GRANT (keys accepted), never as
    invalid_client (keys wrong). No user data is touched."""
    a = ImouAdapter(cfg, http=http)
    if not a.oauth_ready():
        return False, "OAuth: fill all three OAuth fields (Access Key, Secret Key, H5 page link)"
    if not str(cfg.get("oauth_h5_url")).startswith("https://"):
        return False, "OAuth: the H5 page link must start with https://"
    try:
        a._token_call({"grant_type": "refresh_token", "refresh_token": "assisto-key-check"})
    except ConnectError as e:
        if e.code == "oauth_invalid_client":
            return False, "OAuth: Access Key / Secret Key not accepted by Imou"
        if e.code in ("network",) or e.code.startswith("http_5"):
            return False, "OAuth: could not reach Imou (%s)" % e.code
        return True, "OAuth keys accepted (%s)" % e.code
    return True, "OAuth keys accepted"
