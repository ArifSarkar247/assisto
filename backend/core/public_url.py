"""publicurl: the ONE base for every link that leaves the server.

Vendor callbacks (DoLynk / ARC / Imou), email unsubscribe links, account
recovery "not me" links, retention stop links, Meta data-deletion status,
anti-theft photo links, POS webhooks, call photos, share cards... all build
on public_base_url(). Production (DEBUG off, ASSISTO_BASE_URL unset) now
defaults to https://api.lifeassisto.com (settings.py); before the fix it was
http://127.0.0.1:8700, which no vendor and no user phone can reach.

check_public_base() is a Django system check (Error assisto.E_PUBLIC_URL):
`manage.py migrate` / `check` refuse to run in production when the base is
not https or points at the server itself, and the app logs it at start.
"""
import logging
from urllib.parse import urlsplit

from django.conf import settings
from django.core import checks

log = logging.getLogger(__name__)

PUBLIC_BASE_DEFAULT = "https://api.lifeassisto.com"
LOCAL_HOSTS = ("127.0.0.1", "localhost", "0.0.0.0", "::1", "10.0.2.2")


def public_base_url():
    """The public base, no trailing slash ("" only when unset in a test)."""
    return str(getattr(settings, "ASSISTO_BASE_URL", "") or "").strip().rstrip("/")


def public_url(path):
    """public_base_url() + path ("/api/v1/...")."""
    return public_base_url() + ("" if str(path).startswith("/") else "/") + str(path)


def problem(base=None):
    """None when `base` is a reachable public https base, else a short reason."""
    base = public_base_url() if base is None else str(base or "").strip()
    if not base:
        return "ASSISTO_BASE_URL is empty"
    parts = urlsplit(base)
    host = (parts.hostname or "").lower()
    if parts.scheme != "https":
        return "ASSISTO_BASE_URL must be https (got %s://)" % (parts.scheme or "?")
    if not host or host in LOCAL_HOSTS or host.startswith("127.") or host.endswith(".local"):
        return "ASSISTO_BASE_URL points at this server, not the public domain"
    return None


def guard_on():
    return bool(getattr(settings, "PUBLIC_URL_GUARD", False))


@checks.register(checks.Tags.compatibility)
def check_public_base(app_configs=None, **kwargs):
    if not guard_on():
        return []
    why = problem()
    if not why:
        return []
    return [checks.Error(
        why, hint="Unset ASSISTO_BASE_URL (production default %s) or set it to the "
                  "public https domain." % PUBLIC_BASE_DEFAULT,
        id="assisto.E_PUBLIC_URL")]


def log_at_start():
    """gunicorn does not run system checks: say it loudly in the log."""
    if guard_on():
        why = problem()
        if why:
            log.critical("PUBLIC URL WRONG: %s - vendor callbacks and email links "
                         "will not reach the server", why)
