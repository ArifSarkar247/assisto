"""invoices — lifeassisto.com/r/<token>: the QR on an Assisto invoice.

No login: the signed token IS the permission (core.logic.invoice_calc). Shows
ONLY what proves the paper is genuine — shop, BIN, invoice number, date, total
and whether it was cancelled. Never the buyer, never cost/profit. noindex,
no-store, no JS, no ads, rate-limited per IP (views_quote._rate_ok).
"""
from django.shortcuts import render
from django.views.decorators.http import require_GET

from .views_quote import _rate_ok, money, num, when

GET_PER_MIN = 30

TXT = {
    "bn": {"title": "রসিদ যাচাই", "ok": "এই রসিদ Assisto-তে আছে — আসল।",
           "cancelled": "এই রসিদ বাতিল করা হয়েছে।", "shop": "দোকান / প্রতিষ্ঠান",
           "bin": "BIN", "number": "ইনভয়েস নম্বর", "date": "তারিখ", "time": "সময়",
           "total": "মোট", "bad": "এই রসিদ খুঁজে পাওয়া যায়নি বা লিংক বদলানো হয়েছে।",
           "limited": "অনেকবার চেষ্টা হয়েছে। কয়েক মিনিট পরে আবার খুলুন।",
           "check": "কাগজের রসিদের সাথে নম্বর, তারিখ ও মোট মিলিয়ে দেখুন। না মিললে রসিদটা নকল হতে পারে।",
           "by": "Assisto দিয়ে তৈরি রসিদ"},
    "en": {"title": "Receipt check", "ok": "This receipt exists in Assisto — genuine.",
           "cancelled": "This receipt was CANCELLED.", "shop": "Shop / business",
           "bin": "BIN", "number": "Invoice no.", "date": "Date", "time": "Time",
           "total": "Total", "bad": "This receipt was not found, or the link was changed.",
           "limited": "Too many tries. Please open again in a few minutes.",
           "check": "Match the number, date and total with your paper. If they differ, the paper may be fake.",
           "by": "Receipt made with Assisto"},
}


def _render(request, ctx, status=200):
    resp = render(request, "web/invoice_verify.html", ctx, status=status)
    resp["Cache-Control"] = "no-store"
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["X-Frame-Options"] = "DENY"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Content-Type-Options"] = "nosniff"
    return resp


@require_GET
def verify_page(request, token):
    from core.invoice_views import public_status
    from core.logic import invoice_calc as IC
    from core.logic import msg_guard as MG
    lang = request.GET.get("lang") if request.GET.get("lang") in ("bn", "en") else "bn"
    B = TXT[lang]
    if not _rate_ok(request, "r", GET_PER_MIN, 60):
        return _render(request, {"lang": lang, "B": B, "state": "limited"}, 429)
    parsed = IC.parse_token(token)
    st = public_status(*parsed) if parsed else None
    if st is None:
        return _render(request, {"lang": lang, "B": B, "state": "bad"}, 404)
    at = MG.local(st["issued_at"])
    return _render(request, {
        "lang": lang, "B": B, "state": "cancelled" if st["cancelled"] else "ok",
        "shop": st["shop"] or "—", "bin": num(st["bin"], lang) if st["bin"] else "",
        "number": num(st["number"], lang), "date": when(st["issued_at"], lang),
        "time": num("%02d:%02d" % (at.hour, at.minute), lang),
        "total": money(st["total"], lang),
        "other": "en" if lang == "bn" else "bn", "token": token})
