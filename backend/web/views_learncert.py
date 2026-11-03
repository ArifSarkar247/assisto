"""learncert — lifeassisto.com/verify/<code>: the QR on an Assisto learning
certificate (core.learn_cert).

No login. Shows ONLY name, course, level, date and valid / revoked — never the
score, phone, email or account. Always carries the "not an official
qualification" line. noindex, no-store, no JS, no ads, rate-limited per IP.
Answers even while the app flag is OFF, so an issued certificate keeps
verifying. /verify/ (no code) is a small form to type the code from paper.
"""
from django.shortcuts import redirect, render
from django.views.decorators.http import require_GET

from core import learn_cert as LC

from .views_quote import _rate_ok

GET_PER_MIN = 30

TXT = {
    "bn": {"title": "সনদ যাচাই", "ok": "এই সনদ Assisto-তে আছে — আসল ও বৈধ।",
           "revoked": "এই সনদ বাতিল করা হয়েছে — আর বৈধ নয়।",
           "name": "নাম", "course": "কোর্স", "level": "লেভেল", "date": "তারিখ",
           "code": "যাচাই কোড",
           "bad": "এই কোডে কোনো সনদ পাওয়া যায়নি। কোডটা আবার মিলিয়ে দেখুন।",
           "limited": "অনেকবার চেষ্টা হয়েছে। কয়েক মিনিট পরে আবার খুলুন।",
           "ask": "সনদের নিচে লেখা যাচাই কোডটা লিখুন (যেমন ALC-ABCD-EFGH-JKLM)।",
           "go": "যাচাই করুন",
           "check": "কাগজ বা ছবির সনদের সাথে নাম, কোর্স, লেভেল ও তারিখ মিলিয়ে দেখুন। না মিললে সনদটা নকল হতে পারে।",
           "og": "Assisto শেখার সনদ — %s"},
    "en": {"title": "Certificate check", "ok": "This certificate exists in Assisto — genuine and valid.",
           "revoked": "This certificate was REVOKED — it is no longer valid.",
           "name": "Name", "course": "Course", "level": "Level", "date": "Date",
           "code": "Verify code",
           "bad": "No certificate was found for this code. Please check the code again.",
           "limited": "Too many tries. Please open again in a few minutes.",
           "ask": "Type the verify code printed on the certificate (like ALC-ABCD-EFGH-JKLM).",
           "go": "Check",
           "check": "Match the name, course, level and date with the paper or picture. If they differ, it may be fake.",
           "og": "Assisto learning certificate — %s"},
}


def _lang(request):
    v = request.GET.get("lang")
    return v if v in ("bn", "en") else "bn"


def _render(request, ctx, status=200):
    lang = ctx["lang"]
    ctx.setdefault("B", TXT[lang])
    ctx["disclaimer"] = LC.DISCLAIMER[lang]
    ctx["other"] = "en" if lang == "bn" else "bn"
    ctx.setdefault("og_desc", LC.DISCLAIMER[lang])
    resp = render(request, "web/learncert_verify.html", ctx, status=status)
    resp["Cache-Control"] = "no-store"
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["X-Frame-Options"] = "DENY"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Content-Type-Options"] = "nosniff"
    return resp


@require_GET
def verify_form(request):
    lang = _lang(request)
    code = request.GET.get("code")
    if code:
        c = LC.normalize_code(code)
        if c:
            return redirect("/verify/%s?lang=%s" % (c, lang))
        return _render(request, {"lang": lang, "state": "bad", "form": True}, 404)
    return _render(request, {"lang": lang, "state": "form", "form": True})


@require_GET
def verify_page(request, code):
    lang = _lang(request)
    if not _rate_ok(request, "lc", GET_PER_MIN, 60):
        return _render(request, {"lang": lang, "state": "limited"}, 429)
    row = LC.find(code)
    if row is None:
        return _render(request, {"lang": lang, "state": "bad", "form": True}, 404)
    v = LC.public_view(row, lang)
    return _render(request, {
        "lang": lang, "state": "ok" if v["valid"] else "revoked", "v": v,
        "og_title": TXT[lang]["og"] % v["name"],
        "og_desc": "%s · %s — %s" % (v["course"], v["level"], LC.DISCLAIMER[lang]),
    })
