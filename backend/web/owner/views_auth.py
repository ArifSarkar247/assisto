"""Login -> (first time) 2FA enrolment -> 2FA verify -> panel. Logout."""
from django.contrib.auth import get_user_model
from django.http import HttpResponseRedirect
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import _lang_of, https_gate, owner_view, page

User = get_user_model()


def _find_user(ident):
    """Phone in any format (core/phone.py canonical, the same lookup as the
    app's auth/login), else exact username/email."""
    ident = (ident or "").strip()
    if not ident:
        return None
    from core.phone import find_user, canonical_phone
    u = find_user(ident)
    if u is None:
        u = (User.objects.filter(phone=ident).first()
             or User.objects.filter(email=ident.lower()).first()
             or User.objects.filter(username=ident).first())
    return u


def _acct_key(ident):
    from core.phone import canonical_phone
    try:
        canon = canonical_phone(ident)
    except Exception:
        canon = None
    return "acct:" + (canon or (ident or "").strip().lower())[:100]


def _mins(sec):
    return max(1, (int(sec) + 59) // 60)


def _bare(request, template, ctx=None, status=200):
    request.owner_lang = _lang_of(request)
    return S.harden(page(request, template, ctx, status=status))


@require_http_methods(["GET", "POST"])
def login_view(request):
    refused = https_gate(request)
    if refused:
        return refused
    sess = S.load_session(request)
    if sess is not None and S.is_owner(sess.user) and request.method == "GET":
        return S.harden(HttpResponseRedirect({"mfa": "/owner/2fa", "enrol": "/owner/enrol"}
                                             .get(sess.stage, "/owner/")))
    if request.method == "GET":
        return _bare(request, "owner/login.html")

    lang = _lang_of(request)
    from .i18n import strings
    T = strings(lang)
    ident = request.POST.get("phone", "")
    password = request.POST.get("password", "")
    ip_key = "ip:" + S.client_ip(request)
    acct_key = _acct_key(ident)
    left = max(S.lock_remaining(ip_key), S.lock_remaining(acct_key))
    if left:
        S.audit(request, None, "login.locked", target=S.client_ip(request), ok=False)
        return _bare(request, "owner/login.html",
                     {"error": T["err_locked"].format(m=_mins(left))}, status=429)
    user = _find_user(ident)
    ok = bool(user and password and user.check_password(password) and S.is_owner(user))
    if not ok:
        S.register_fail(ip_key)
        S.register_fail(acct_key)
        S.audit(request, user if (user and user.is_superuser) else None, "login.fail",
                target=("user:%s" % user.pk) if user else "unknown", ok=False,
                after={"reason": "bad_credentials_or_not_owner"})
        return _bare(request, "owner/login.html", {"error": T["err_login"]}, status=401)
    S.clear_fails(acct_key)
    from core.models import OwnerTOTP
    totp = OwnerTOTP.objects.filter(user=user).first()
    stage = "mfa" if (totp and totp.confirmed_at) else "enrol"
    if sess is not None:
        sess.delete()
    request.owner_lang = lang
    raw, _ = S.create_session(request, user, stage)
    S.audit(request, user, "login.password_ok", target="user:%s" % user.pk,
            after={"next": stage})
    resp = HttpResponseRedirect("/owner/2fa" if stage == "mfa" else "/owner/enrol")
    S.set_cookie(resp, raw)
    return S.harden(resp)


def _finish_login(request, sess, method):
    sess.stage = "full"
    sess.save(update_fields=["stage"])
    raw = S.rotate_session(sess)       # new cookie after 2FA (no fixation)
    S.clear_fails("mfa:%s" % sess.user_id)
    S.clear_fails("ip:" + S.client_ip(request))
    S.audit(request, sess.user, "login.success", target="user:%s" % sess.user_id,
            after={"method": method})
    return raw


@require_http_methods(["GET", "POST"])
@owner_view(stage="mfa")
def mfa_view(request):
    from .i18n import strings
    T = strings(request.owner_lang)
    sess = request.owner_session
    if request.method == "GET":
        return page(request, "owner/mfa.html")
    key = "mfa:%s" % sess.user_id
    left = S.lock_remaining(key)
    if left:
        return page(request, "owner/mfa.html",
                    {"error": T["err_locked"].format(m=_mins(left))}, status=429)
    code = request.POST.get("code", "")
    from core.models import OwnerTOTP
    totp = OwnerTOTP.objects.filter(user=sess.user, confirmed_at__isnull=False).first()
    if totp is None:            # 2FA was reset meanwhile -> enrol afresh
        sess.stage = "enrol"
        sess.save(update_fields=["stage"])
        return HttpResponseRedirect("/owner/enrol")
    method = None
    if S.looks_like_recovery(code):
        if S.consume_recovery(totp, code):
            method = "recovery_code"
    else:
        c = S.verify_totp(S.decrypt(totp.secret_enc), code, totp.last_counter)
        if c is not None:
            totp.last_counter = c
            totp.save(update_fields=["last_counter", "updated_at"])
            method = "totp"
    if not method:
        S.register_fail(key)
        S.audit(request, sess.user, "login.mfa_fail", target="user:%s" % sess.user_id,
                ok=False)
        return page(request, "owner/mfa.html", {"error": T["err_code"]}, status=401)
    raw = _finish_login(request, sess, method)
    dest = "/owner/security?m=recovery_used" if method == "recovery_code" else "/owner/"
    resp = HttpResponseRedirect(dest)
    S.set_cookie(resp, raw)
    return resp


@require_http_methods(["GET", "POST"])
@owner_view(stage="enrol")
def enrol_view(request):
    from core.models import OwnerTOTP
    from .i18n import strings
    T = strings(request.owner_lang)
    sess = request.owner_session
    secret = S.decrypt(sess.pending_secret_enc)
    if not secret:
        secret = S.new_secret()
        sess.pending_secret_enc = S.encrypt(secret)
        sess.save(update_fields=["pending_secret_enc"])
    account = sess.user.phone or sess.user.username
    ctx = {"qr": S.qr_svg(S.otpauth_uri(secret, account)),
           "secret": S.group_secret(secret), "account": account}
    if request.method == "GET":
        return page(request, "owner/enrol.html", ctx)
    key = "mfa:%s" % sess.user_id
    left = S.lock_remaining(key)
    if left:
        ctx["error"] = T["err_locked"].format(m=_mins(left))
        return page(request, "owner/enrol.html", ctx, status=429)
    c = S.verify_totp(secret, request.POST.get("code", ""), 0)
    if c is None:
        S.register_fail(key)
        S.audit(request, sess.user, "2fa.enrol_fail", target="user:%s" % sess.user_id, ok=False)
        ctx["error"] = T["err_code"]
        return page(request, "owner/enrol.html", ctx, status=401)
    codes = S.new_recovery_codes()
    row, _ = OwnerTOTP.objects.get_or_create(user=sess.user)
    row.secret_enc = S.encrypt(secret)
    row.confirmed_at = timezone.now()
    row.last_counter = c
    row.recovery_hashes = [S.hash_recovery(x) for x in codes]
    row.save()
    sess.pending_secret_enc = ""
    sess.save(update_fields=["pending_secret_enc"])
    S.audit(request, sess.user, "2fa.enrolled", target="user:%s" % sess.user_id,
            after={"recovery_codes": len(codes)})
    raw = _finish_login(request, sess, "totp_enrol")
    resp = page(request, "owner/recovery_codes.html", {"codes": codes, "ot": sess.csrf})
    S.set_cookie(resp, raw)
    return resp


@require_http_methods(["POST"])
def logout_view(request):
    refused = https_gate(request)
    if refused:
        return refused
    sess = S.load_session(request)
    if sess is not None:
        import hmac
        sent = request.POST.get("_ot", "")
        if not (sent and hmac.compare_digest(sent, sess.csrf)):
            from django.http import HttpResponseForbidden
            return S.harden(HttpResponseForbidden("CSRF check failed"))
        S.audit(request, sess.user, "logout", target="user:%s" % sess.user_id)
        sess.delete()
    resp = HttpResponseRedirect("/owner/login")
    S.clear_cookie(resp)
    return S.harden(resp)
