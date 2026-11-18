"""Request plumbing for the web owner panel: the HTTPS/session/stage/CSRF gate,
rendering with bn/en strings, and small form helpers."""
import hmac
import json
import re
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


def owner_view(stage="full", perm="owner", write_perm=None):
    """Gate a view: HTTPS, live owner session at `stage`, owner / staff-role
    re-check on every request, session-bound CSRF token on every POST (on top
    of Django's CsrfViewMiddleware), security headers on every response.
    adminsafe: `perm` names a security.PERMS entry; the default "owner" keeps
    every existing page owner-only, a staff role sees only what it holds."""
    def deco(fn):
        @wraps(fn)
        def wrapper(request, *args, **kwargs):
            refused = https_gate(request)
            if refused:
                return refused
            sess = S.load_session(request)
            request.owner_lang = _lang_of(request, sess)
            role = S.panel_role(sess.user) if sess is not None else None
            if sess is None or role is None:
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
            request.owner_role = role
            need = (write_perm or perm) if request.method == "POST" else perm
            if stage == "full" and not S.has_perm(role, need):
                S.audit(request, sess.user, "staff.denied", target=request.path[:160],
                        after={"role": role, "perm": need}, ok=False)
                if request.method == "GET" and request.path == "/owner/" and \
                        S.has_perm(role, "users"):
                    return S.harden(HttpResponseRedirect("/owner/users"))
                return S.harden(page(request, "owner/forbidden.html",
                                     {"need": need}, status=403))
            return S.harden(fn(request, *args, **kwargs))
        return wrapper
    return deco


def page(request, template, ctx=None, status=200, nav=""):
    lang = getattr(request, "owner_lang", "bn")
    sess = getattr(request, "owner_session", None)
    c = {"T": strings(lang), "lang": lang, "other_lang": "en" if lang == "bn" else "bn",
         "ot": sess.csrf if sess else "", "owner": getattr(request, "owner", None),
         "nav": nav, "path": request.path, "msg": request.GET.get("m", ""),
         # adminsafe: the signed-in role (owner / support / moderator /
         # finance / readonly) and what it may do — the nav hides the rest
         "role": getattr(request, "owner_role", "owner"),
         "can": {k: S.has_perm(getattr(request, "owner_role", "owner"), k)
                 for k in S.PERMS}}
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
        # pricing-40: real AI cost per credit above the safe level today
        try:
            from core import ai_cost_alert
            c["cost_alert"] = ai_cost_alert.banner()
        except Exception:
            c["cost_alert"] = None
    c.update(ctx or {})
    resp = render(request, template, c, status=status)
    if lang == "bn":
        resp.content = bn_html(resp.content.decode("utf-8")).encode("utf-8")
    return resp


# owneradmin: Bangla mode shows Bangla digits everywhere on the page — in
# text only (never inside tags / attributes, so form values, links and ids stay
# ASCII), and never in machine text (<code>, <pre>, <textarea>, <script>,
# <style>, <kbd>, <samp>) or in elements marked lang="en" / translate="no".
_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
_RAW = ("code", "pre", "textarea", "script", "style", "kbd", "samp")
_TAG = re.compile(r"(<!--.*?-->|<[^>]*>)", re.S)
_ENT = re.compile(r"(&#?\w+;)")
_NAME = re.compile(r"</?\s*([a-zA-Z][a-zA-Z0-9]*)")
_MARK = re.compile(r"""\blang\s*=\s*["']?en\b|\btranslate\s*=\s*["']?no\b""", re.I)


_TOKEN = re.compile(r"\S+")
_PHONE = re.compile(r"\+?\d[\d-]{9,}")
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def keeps_ascii(token):
    """Machine tokens keep ASCII digits in Bangla mode: anything with a Latin
    letter (RMX3491, claude-opus-5-5, 10.0.0.1-ish hosts), phone numbers and
    long ids (7+ digits in a row) — owners copy / compare those."""
    core = token.strip("()[]{}<>,.;:!?“”‘’\"'")
    if re.search(r"[A-Za-z]", core) or re.search(r"\d{7,}", core):
        return True
    return bool(_PHONE.fullmatch(core)) and not _DATE.fullmatch(core)


def _bn_words(t):
    return _TOKEN.sub(lambda m: m.group(0) if keeps_ascii(m.group(0))
                      else m.group(0).translate(_BN_DIGITS), t)


def _bn_text(t):
    return "".join(x if x.startswith("&") else _bn_words(x) for x in _ENT.split(t))


def bn_html(html):
    out, raw = [], []            # raw: [tag, depth] of the machine-text element we are in
    for part in _TAG.split(html):
        if not part:
            continue
        if part.startswith("<"):
            m = _NAME.match(part)
            if m and not part.startswith("<!"):
                name = m.group(1).lower()
                closing = part.startswith("</")
                selfclose = part.endswith("/>")
                if raw:
                    if name == raw[-1][0]:
                        raw[-1][1] += -1 if closing else (0 if selfclose else 1)
                        if raw[-1][1] == 0:
                            raw.pop()
                elif not closing and not selfclose and (name in _RAW or _MARK.search(part)) \
                        and name not in ("input", "img", "br", "meta", "link", "hr"):
                    raw.append([name, 1])
            out.append(part)
        else:
            out.append(part if raw else _bn_text(part))
    return "".join(out)


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
