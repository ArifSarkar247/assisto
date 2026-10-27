"""Request plumbing for the web owner panel: the HTTPS/session/stage/CSRF gate,
rendering with bn/en strings, and small form helpers."""
import hmac
import json
from functools import wraps

from django.http import (HttpResponse, HttpResponseForbidden,
                         HttpResponsePermanentRedirect, HttpResponseRedirect)
from django.shortcuts import render

from . import security as S
from .i18n import strings

LOGIN_URL = "/owner/login"
STAGE_URL = {"mfa": "/owner/2fa", "enrol": "/owner/enrol", "full": "/owner/"}


def _lang_of(request, session=None):
    v = request.GET.get("lang") or request.POST.get("lang")
    if v in ("bn", "en"):
        return v
    if session is not None and session.lang in ("bn", "en"):
        return session.lang
    return "bn"


def https_gate(request):
    """None when the request may proceed, else the refusal response."""
    if S.require_https() and not request.is_secure():
        if request.method in ("GET", "HEAD"):
            return S.harden(HttpResponsePermanentRedirect(
                "https://%s%s" % (request.get_host(), request.get_full_path())))
        return S.harden(HttpResponseForbidden("HTTPS required"))
    return None


def owner_view(stage="full"):
    """Gate a view: HTTPS, live owner session at `stage`, superuser re-check
    on every request, session-bound CSRF token on every POST (on top of
    Django's CsrfViewMiddleware), security headers on every response."""
    def deco(fn):
        @wraps(fn)
        def wrapper(request, *args, **kwargs):
            refused = https_gate(request)
            if refused:
                return refused
            sess = S.load_session(request)
            request.owner_lang = _lang_of(request, sess)
            if sess is None or not S.is_owner(sess.user):
                if sess is not None:
                    sess.delete()
                resp = HttpResponseRedirect(LOGIN_URL)
                S.clear_cookie(resp)
                return S.harden(resp)
            if sess.stage != stage:
                return S.harden(HttpResponseRedirect(STAGE_URL.get(sess.stage, LOGIN_URL)))
            if request.method == "POST":
                sent = request.POST.get("_ot", "")
                if not (sent and hmac.compare_digest(sent, sess.csrf)):
                    return S.harden(HttpResponseForbidden("CSRF check failed"))
            if request.GET.get("lang") in ("bn", "en") and sess.lang != request.GET["lang"]:
                sess.lang = request.GET["lang"]
                sess.save(update_fields=["lang"])
            request.owner_session = sess
            request.owner = sess.user
            return S.harden(fn(request, *args, **kwargs))
        return wrapper
    return deco


def page(request, template, ctx=None, status=200, nav=""):
    lang = getattr(request, "owner_lang", "bn")
    sess = getattr(request, "owner_session", None)
    c = {"T": strings(lang), "lang": lang, "other_lang": "en" if lang == "bn" else "bn",
         "ot": sess.csrf if sess else "", "owner": getattr(request, "owner", None),
         "nav": nav, "path": request.path, "msg": request.GET.get("m", "")}
    if sess is not None:
        # calls-health: a panel-wide banner while call setup is unhealthy
        try:
            from core import call_health
            c["call_alert"] = call_health.cached_alert()
        except Exception:
            c["call_alert"] = None
        # ai-router: a panel-wide banner once a provider / the total crossed
        # the alert % of its daily spend cap today
        try:
            from core import ai_router
            c["ai_alert"] = ai_router.owner_alert()
        except Exception:
            c["ai_alert"] = None
    c.update(ctx or {})
    return render(request, template, c, status=status)


def done(path, msg="saved"):
    sep = "&" if "?" in path else "?"
    return HttpResponseRedirect("%s%sm=%s" % (path, sep, msg))


# ----------------------------------------------------------------- helpers
def to_int(v, default=None):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


def to_num(v):
    """Form string -> int/float; None when not a number."""
    s = str(v if v is not None else "").strip().replace(",", "")
    if s == "":
        return None
    try:
        return int(s)
    except ValueError:
        try:
            return float(s)
        except ValueError:
            return None


def flatten(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flatten(v, "%s%s." % (prefix, k)))
    elif isinstance(d, list):
        out[prefix[:-1]] = json.dumps(d, ensure_ascii=False, sort_keys=True)
    else:
        out[prefix[:-1]] = d
    return out


def diff(old, new):
    """{path: value} before/after of only the changed leaves."""
    fo, fn = flatten(old or {}), flatten(new or {})
    b, a = {}, {}
    for k in sorted(set(fo) | set(fn)):
        if fo.get(k) != fn.get(k):
            b[k], a[k] = fo.get(k), fn.get(k)
    return b, a


def plain(resp_text, content_type="text/plain; charset=utf-8"):
    return HttpResponse(resp_text, content_type=content_type)
