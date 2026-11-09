"""qbiz — lifeassisto.com/kh/<token>: one khata customer's own due + history
(read-only). The signed, expiring token IS the permission
(core.khata_duelink). No login, noindex, no-store, no JS, no ads, rate-limited
per IP. Shows no notes, no phone, nothing about other customers."""
from django.shortcuts import render
from django.views.decorators.http import require_GET

from .views_quote import _rate_ok

GET_PER_MIN = 30

TXT = {
    "bn": {"title": "আপনার হিসাব", "due": "আপনার বাকি", "advance": "দোকানে আপনার অগ্রিম",
           "clear": "কোনো বাকি নেই — হিসাব পরিষ্কার।", "date": "তারিখ", "what": "লেনদেন",
           "gave": "বাকি", "paid": "জমা", "bal": "ব্যালান্স", "none": "এখনো কোনো লেনদেন নেই।",
           "more": "আরও পুরোনো লেনদেন আছে — দোকানে জিজ্ঞেস করুন।",
           "bad": "লিংকটি পুরোনো হয়ে গেছে বা বদলানো হয়েছে। দোকানের কাছে নতুন লিংক চান।",
           "limited": "অনেকবার চেষ্টা হয়েছে। কয়েক মিনিট পরে আবার খুলুন।",
           "wrong": "কোনো লেনদেন ভুল মনে হলে সরাসরি দোকানকে জানান।",
           "private": "এই পাতা শুধু আপনার জন্য — অন্য কাউকে লিংকটি দেবেন না।",
           "by": "Assisto ডিজিটাল খাতা"},
    "en": {"title": "Your account", "due": "You owe", "advance": "Your advance with the shop",
           "clear": "Nothing due — all settled.", "date": "Date", "what": "Entry",
           "gave": "Credit", "paid": "Paid", "bal": "Balance", "none": "No entries yet.",
           "more": "There are older entries — ask the shop.",
           "bad": "This link has expired or was changed. Ask the shop for a new one.",
           "limited": "Too many tries. Please open again in a few minutes.",
           "wrong": "If an entry looks wrong, tell the shop directly.",
           "private": "This page is only for you — please do not forward the link.",
           "by": "Assisto digital khata"},
}


def _render(request, ctx, status=200):
    resp = render(request, "web/khata_due.html", ctx, status=status)
    resp["Cache-Control"] = "no-store"
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["X-Frame-Options"] = "DENY"
    resp["Referrer-Policy"] = "no-referrer"
    resp["X-Content-Type-Options"] = "nosniff"
    return resp


@require_GET
def due_page(request, token):
    from core import khata_duelink as KD
    lang = request.GET.get("lang") if request.GET.get("lang") in ("bn", "en") else "bn"
    B = TXT[lang]
    base = {"lang": lang, "B": B, "token": token, "other": "en" if lang == "bn" else "bn"}
    if not _rate_ok(request, "kh", GET_PER_MIN, 60):
        return _render(request, {**base, "state": "limited"}, 429)
    pid = KD.parse_token(token)
    st = KD.public_statement(pid, lang) if pid else None
    if st is None:
        return _render(request, {**base, "state": "bad"}, 404)
    more = st["more"]
    return _render(request, {**base, "state": st["state"], "s": st,
                             "more": more})
