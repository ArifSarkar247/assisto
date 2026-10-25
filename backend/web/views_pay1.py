"""pay1 — lifeassisto.com/premium (website checkout) + /pay/return.

Mobile-first, one language per page (?lang=en, default Bangla), no JS.
Sign-in = phone OTP through the existing core.otp service (purpose 'login');
the session is a random token (only its SHA-256 is stored) in an HttpOnly,
Secure, SameSite=Lax cookie that lives 30 minutes. Payment = the same
gateway order + the same entitlement service the app uses, so whatever is
bought here is on the account everywhere instantly.
"""
import hashlib
import secrets
from datetime import timedelta

from django.conf import settings
from django.http import HttpResponseRedirect
from django.shortcuts import render
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from .views import _lang

COOKIE = "as_pay"
SESSION_MIN = 30

TXT = {
    "bn": {
        "title": "Assisto প্রিমিয়াম", "lead": "bKash, Nagad বা কার্ডে কিনুন — আপনার অ্যাকাউন্টে সঙ্গে সঙ্গে চালু হবে, অ্যাপেও।",
        "login_h": "আপনার Assisto নম্বর দিয়ে ঢুকুন", "phone": "মোবাইল নম্বর",
        "send": "কোড পাঠান", "code": "৬ সংখ্যার কোড", "verify": "যাচাই করুন",
        "sent": "এই নম্বরে Assisto অ্যাকাউন্ট থাকলে একটি কোড পাঠানো হয়েছে।",
        "bad_code": "কোডটি মেলেনি। আবার চেষ্টা করুন।", "bad_phone": "সঠিক মোবাইল নম্বর দিন (যেমন 01XXXXXXXXX)।",
        "sms_off": "SMS এখনও চালু হয়নি — অ্যাপ থেকে কিনুন অথবা পরে চেষ্টা করুন।",
        "wait": "একটু পরে আবার চেষ্টা করুন।",
        "signed_in": "লগইন করা আছে", "logout": "বের হন", "current": "এখনকার প্ল্যান",
        "until": "মেয়াদ", "monthly": "মাসিক", "yearly": "বার্ষিক", "per_mo": "/মাস", "per_yr": "/বছর",
        "buy": "কিনুন", "renew": "নবায়ন করুন", "packs": "AI ক্রেডিট প্যাক", "credits": "ক্রেডিট",
        "pay_note": "পেমেন্ট হয় EPS-এর নিরাপদ পেজে (bKash / Nagad / কার্ড)। আমরা কার্ড বা পিন দেখি না।",
        "off": "ওয়েবসাইট থেকে কেনা এখন বন্ধ আছে। অ্যাপ থেকে কিনুন।",
        "not_ready": "অনলাইন পেমেন্ট শিগগির চালু হবে — মালিক পেমেন্ট গেটওয়ে যুক্ত করলেই।",
        "ok_h": "পেমেন্ট সফল", "ok_b": "আপনার কেনাকাটা চালু হয়েছে — অ্যাপে এখনই দেখা যাবে।",
        "pending_h": "পেমেন্ট যাচাই হচ্ছে", "pending_b": "কয়েক মিনিটের মধ্যে নিশ্চিত হবে। টাকা কাটা হলে কিছুই হারাবে না।",
        "fail_h": "পেমেন্ট হয়নি", "fail_b": "টাকা কাটা হয়নি বা পেমেন্ট বাতিল হয়েছে। আবার চেষ্টা করতে পারেন।",
        "neutral_h": "ধন্যবাদ — পেমেন্টের তথ্য পাওয়া গেছে", "neutral_b": "যাচাই শেষ হলে প্ল্যান অ্যাপে দেখা যাবে। টাকা কাটা হলে কিছুই হারাবে না।",
        "unknown_h": "অর্ডার পাওয়া যায়নি", "open_app": "অ্যাপে ফিরে যান", "back": "প্রিমিয়াম পেজে ফিরুন",
        "managed_by_play": "আপনার সাবস্ক্রিপশন Google Play থেকে চলছে — সেখান থেকেই পরিবর্তন করুন।",
        "gateway_error": "পেমেন্ট শুরু করা যায়নি। একটু পরে আবার চেষ্টা করুন।",
        "safety": "জরুরি SOS, স্ক্যাম সতর্কতা ও ওষুধ রিমাইন্ডার সবসময় ফ্রি।",
        "ai_line": "প্রতি মাসে {n} AI ক্রেডিট",
        "no_unlimited": "কোনো প্ল্যানই সীমাহীন নয় — প্রতিটি প্ল্যানে প্রতি মাসে নির্দিষ্ট AI ক্রেডিট থাকে, শেষ হলে ক্রেডিট প্যাক কিনতে পারেন।",
    },
    "en": {
        "title": "Assisto Premium", "lead": "Pay with bKash, Nagad or card — it turns on for your account instantly, in the app too.",
        "login_h": "Sign in with your Assisto number", "phone": "Mobile number",
        "send": "Send code", "code": "6-digit code", "verify": "Verify",
        "sent": "If this number has an Assisto account, a code has been sent.",
        "bad_code": "That code did not match. Please try again.", "bad_phone": "Enter a valid mobile number (e.g. 01XXXXXXXXX).",
        "sms_off": "SMS is not switched on yet — buy in the app or try later.",
        "wait": "Please try again in a little while.",
        "signed_in": "Signed in", "logout": "Sign out", "current": "Current plan",
        "until": "Until", "monthly": "Monthly", "yearly": "Yearly", "per_mo": "/month", "per_yr": "/year",
        "buy": "Buy", "renew": "Renew", "packs": "AI credit packs", "credits": "credits",
        "pay_note": "You pay on EPS's secure page (bKash / Nagad / card). We never see your card or PIN.",
        "off": "Buying on the website is switched off right now. Please buy in the app.",
        "not_ready": "Online payment is coming soon — as soon as the owner connects the payment gateway.",
        "ok_h": "Payment received", "ok_b": "Your purchase is active — you will see it in the app right away.",
        "pending_h": "Checking your payment", "pending_b": "It will be confirmed within a few minutes. If money was taken, nothing is lost.",
        "fail_h": "Payment not completed", "fail_b": "No money was taken or the payment was cancelled. You can try again.",
        "neutral_h": "Thanks — we got your payment details", "neutral_b": "Once it is confirmed you will see your plan in the app. If money was taken, nothing is lost.",
        "unknown_h": "Order not found", "open_app": "Back to the app", "back": "Back to Premium",
        "managed_by_play": "Your subscription runs through Google Play — change it there.",
        "gateway_error": "Could not start the payment. Please try again shortly.",
        "safety": "Emergency SOS, scam alerts and medicine reminders are always free.",
        "ai_line": "{n} AI credits every month",
        "no_unlimited": "No plan is unlimited — each plan includes a set number of AI credits every month; if you run out you can buy a credit pack.",
    },
}


def _sha(v):
    return hashlib.sha256(str(v).encode()).hexdigest()


def _user(request):
    from core.models import WebCheckoutSession
    raw = request.COOKIES.get(COOKIE, "")
    if not raw:
        return None
    s = WebCheckoutSession.objects.filter(token_hash=_sha(raw),
                                          expires_at__gt=timezone.now()).select_related("user").first()
    return s.user if s and s.user.is_active else None


def _secure():
    return not getattr(settings, "DEBUG", False)


def _ctx(request, **kw):
    lang = _lang(request)
    from core.payments import catalog, gateway as G
    pc = catalog.pay_cfg()
    c = {"lang": lang, "P": TXT[lang], "qlang": "?lang=en" if lang == "en" else "",
         "amp_lang": "&lang=en" if lang == "en" else "",
         "web_on": pc["web_enabled"] and pc["gateway_enabled"], "gw_ready": G.get() is not None}
    c.update(kw)
    return c


def _plans(lang):
    from core.payments import catalog
    rows = catalog.products("gateway", lang)
    subs = {}
    for r in rows:
        if r["kind"] == "sub":
            subs.setdefault(r["plan"], {"plan": r["plan"], "title": r["title"]})[r["period"]] = r
    try:
        from core import billing
        from core.logic.pricing import _bn_num
        cplans = billing.cfg()["plans"]
        for k, sub in subs.items():
            n = int((cplans.get(k) or {}).get("credits") or 0)
            if n > 0:
                sub["ai_line"] = TXT[lang]["ai_line"].format(
                    n=_bn_num(n) if lang == "bn" else n)
    except Exception:
        pass
    return [subs[k] for k in ("premium", "business") if k in subs], \
        [r for r in rows if r["kind"] == "pack"]


def _page(request, status=200, **kw):
    lang = _lang(request)
    u = kw.pop("user", None) or _user(request)
    subs, packs = _plans(lang)
    state = None
    if u is not None:
        from core.payments import entitlement as E
        state = E.summary(u)
    resp = render(request, "web/premium.html",
                  _ctx(request, user=u, subs=subs, packs=packs, state=state,
                       renew=request.GET.get("renew", "")[:32], **kw), status=status)
    resp["Cache-Control"] = "no-store"
    resp["X-Frame-Options"] = "DENY"
    resp["Referrer-Policy"] = "same-origin"
    return resp


@require_http_methods(["GET", "POST"])
def premium(request):
    from core import otp
    lang = _lang(request)
    P = TXT[lang]
    if request.method == "GET":
        return _page(request)
    action = request.POST.get("action", "")
    phone = (request.POST.get("phone") or "").strip()[:24]
    if action == "send":
        canon = otp.normalize_bd_phone(phone)
        if not canon:
            return _page(request, 400, error=P["bad_phone"], phone=phone)
        exists = otp.find_user_by_phone(canon) is not None
        try:
            otp.issue(canon, "login", request=request, lang=lang, send=exists)
        except otp.OtpError as e:
            msg = P["sms_off"] if e.reason == "sms_not_configured" else P["wait"]
            return _page(request, 429 if e.http_status == 429 else 400, error=msg, phone=phone)
        return _page(request, info=P["sent"], phone=phone, step="code")
    if action == "verify":
        try:
            proof = otp.verify(phone, "login", request.POST.get("code", ""))
        except otp.OtpError:
            return _page(request, 400, error=P["bad_code"], phone=phone, step="code")
        canon = otp.consume_proof(proof, "login", phone)
        u = otp.find_user_by_phone(canon) if canon else None
        if u is None or not u.is_active:
            return _page(request, 400, error=P["bad_code"], phone=phone, step="code")
        from core.models import WebCheckoutSession
        raw = secrets.token_urlsafe(32)
        WebCheckoutSession.objects.filter(user=u, expires_at__lte=timezone.now()).delete()
        WebCheckoutSession.objects.create(user=u, token_hash=_sha(raw),
                                          expires_at=timezone.now() + timedelta(minutes=SESSION_MIN))
        nxt = "/premium" + ("?lang=en" if lang == "en" else "")
        resp = HttpResponseRedirect(nxt)
        resp.set_cookie(COOKIE, raw, max_age=SESSION_MIN * 60, httponly=True,
                        secure=_secure(), samesite="Lax", path="/")
        return resp
    if action == "logout":
        from core.models import WebCheckoutSession
        raw = request.COOKIES.get(COOKIE, "")
        if raw:
            WebCheckoutSession.objects.filter(token_hash=_sha(raw)).delete()
        resp = HttpResponseRedirect("/premium" + ("?lang=en" if lang == "en" else ""))
        resp.delete_cookie(COOKIE, path="/")
        return resp
    if action == "buy":
        u = _user(request)
        if u is None:
            return _page(request, 401, error=P["login_h"])
        from core.payments import gateway as G, service as S
        try:
            o = S.checkout(u, request.POST.get("sku", "")[:32], source="web",
                           idem="web-" + (request.POST.get("idem", "")[:40] or secrets.token_hex(8)),
                           ip=_ip(request), lang=lang)
        except S.PayError as e:
            msg = {"channel_off": P["off"], "not_configured": P["not_ready"],
                   "managed_by_play": P["managed_by_play"]}.get(e.reason, P["gateway_error"])
            return _page(request, 400 if e.status < 500 else 503, error=msg, user=u)
        url = (o.raw or {}).get("redirect_url", "")
        gw = G.get(o.provider)
        if o.status == "paid" or not url or gw is None or not gw.redirect_allowed(url):
            return HttpResponseRedirect("/pay/return?o=%d%s" % (o.pk, "&lang=en" if lang == "en" else ""))
        return HttpResponseRedirect(url)
    return _page(request, 400)


def pay_return(request):
    """The gateway sends the browser here (success / fail / cancel). We verify
    with the gateway's status API before saying anything."""
    from core.payments import service as S
    lang = _lang(request)
    o = S.handle_return(request.GET)
    u = _user(request)
    if o is None and request.GET.get("o", "").isdigit() and u is not None:
        from core.models import PaymentOrder
        o = PaymentOrder.objects.filter(pk=int(request.GET["o"]), user=u).first()
    # Order number, amount and result only for the signed-in owner or the
    # browser carrying the signed return token we gave the gateway; anyone
    # else holding just a (guessable) tx id gets a neutral page.
    allowed = o is not None and (
        (u is not None and o.user_id == u.pk) or
        S.return_token_ok(o.merchant_tx_id, request.GET.get("t", "")))
    state = "unknown"
    if o is not None and allowed:
        state = {"paid": "ok", "pending": "pending", "created": "pending"}.get(o.status, "fail")
    elif o is not None or request.GET.get("MerchantTransactionId") or \
            request.GET.get("merchantTransactionId"):
        state = "neutral"
    shown = o if allowed else None
    resp = render(request, "web/pay_return.html",
                  _ctx(request, order=shown, state=state,
                       deep_link="assisto://payments/done?order=%d" % o.pk if shown else
                       "assisto://payments/done"))
    resp["Cache-Control"] = "no-store"
    resp["Referrer-Policy"] = "no-referrer"
    return resp


def _ip(request):
    xff = request.META.get("HTTP_X_FORWARDED_FOR", "")
    return (xff.split(",")[0].strip() if xff else request.META.get("REMOTE_ADDR", ""))[:45]
