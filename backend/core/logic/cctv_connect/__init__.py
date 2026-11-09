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
from .imou import DolynkAdapter, ImouAdapter

ADAPTERS = {a.id: a for a in (HikConnectAdapter, DolynkAdapter, EzvizAdapter, ImouAdapter)}
ORDER = ("hikconnect", "dolynk", "ezviz", "imou")   # BD market share order
CAMERA_VENDOR = {"hikconnect": "hikvision", "dolynk": "dahua", "ezviz": "ezviz",
                 "imou": "imou"}


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
        return cls(I.get(cls.integration) or {}).configured()
    except Exception:
        return False


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
        else:
            a.client().call("accessToken")
    except ConnectError as e:
        return False, "%s: %s %s" % (a.name, e.code, e.msg)
    except Exception as e:  # noqa: BLE001 - ImouError from accessToken
        return False, "%s: %s" % (a.name, str(e)[:120])
    return True, "%s access token OK" % a.name
