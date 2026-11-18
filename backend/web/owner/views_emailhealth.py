"""emailrel (16 Nov): Owner Admin -> Email health. Sent today, failures by
kind, bounces, the 24 h cap and where codes / reports stop, provider-quota
pause, last bounce check, and the suppression list (masked addresses only)
with "remove" for an address the user says is fixed. Numbers + masks only."""
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page

L = {
    "bn": {"title": "ইমেইল স্বাস্থ্য", "configured": "ইমেইল সংযুক্ত (Integrations → Email)",
           "not_configured": "ইমেইল সংযুক্ত নয় — কোড শুধু SMS-এ যাচ্ছে। ইন্টিগ্রেশন → ইমেইলে অ্যাপ পাসওয়ার্ড দিন।",
           "sent_today": "আজ পাঠানো", "failed_today": "আজ ব্যর্থ", "held_today": "আজ আটকে রাখা",
           "retried_today": "আবার চেষ্টায় গেছে", "used": "২৪ ঘণ্টায় পাঠানো / সীমা",
           "bulk_at": "রিপোর্ট বন্ধ হয়", "near_at": "শুধু কোড/নিরাপত্তা চলে", "bounces": "৭ দিনে বাউন্স",
           "suppressed": "বাউন্স তালিকায়", "unsub": "রিপোর্ট বন্ধ করেছেন",
           "quota": "Gmail দৈনিক সীমা বলেছে — সব ইমেইল থেমে আছে, আবার চেষ্টা", "last_poll": "শেষ বাউন্স-চেক",
           "never": "এখনো হয়নি", "kinds": "আজকের ব্যর্থতার ধরন", "recent": "সাম্প্রতিক ব্যর্থতা",
           "list": "পাঠানো বন্ধ — ঠিকানার তালিকা", "remove": "তালিকা থেকে সরান",
           "removed": "সরানো হয়েছে", "empty": "কোনো ব্যর্থতা নেই।",
           "intro": "কোড ও নিরাপত্তা ইমেইল সবার আগে যায়; সীমার কাছে রিপোর্ট আগে থামে। সাময়িক ত্রুটিতে ১ ও ৩ সেকেন্ড পরে আবার চেষ্টা হয়; স্থায়ী ত্রুটিতে নয়। ঠিকানা মাস্ক করা।",
           "provider_doc": "দিনে ~৫০০-র বেশি লাগলে: owner_actions/EMAIL_PROVIDER_BN.md (সিদ্ধান্ত আপনার)।",
           "k_temp": "সাময়িক (নেটওয়ার্ক/4xx)", "k_quota": "Gmail দৈনিক সীমা", "k_bounce": "ভুল ঠিকানা (বাউন্স)",
           "k_rejected": "প্রত্যাখ্যাত (ইনবক্স ভরা/নীতি)", "k_auth": "লগইন ভুল (App password)",
           "k_config": "সেটআপ নেই", "k_cap": "আমাদের দৈনিক সীমা", "k_unsub": "রিপোর্ট বন্ধ", "k_other": "অন্যান্য"},
    "en": {"title": "Email health", "configured": "Email connected (Integrations → Email)",
           "not_configured": "Email is not connected — codes go by SMS only. Add the app password in Integrations → Email.",
           "sent_today": "Sent today", "failed_today": "Failed today", "held_today": "Held today",
           "retried_today": "Delivered after a retry", "used": "Sent in 24 h / cap",
           "bulk_at": "Reports stop at", "near_at": "Only codes / security from", "bounces": "Bounces (7 days)",
           "suppressed": "On the bounce list", "unsub": "Unsubscribed from reports",
           "quota": "Gmail reported its daily limit — all email paused, next try", "last_poll": "Last bounce check",
           "never": "not yet", "kinds": "Today's failures by kind", "recent": "Recent failures",
           "list": "Not mailed — address list", "remove": "Remove from list",
           "removed": "Removed", "empty": "No failures.",
           "intro": "Codes and security mail go first; near the cap reports stop first. Temporary errors are retried after 1 and 3 seconds; permanent ones never. Addresses are masked.",
           "provider_doc": "Need more than ~500 a day: owner_actions/EMAIL_PROVIDER_BN.md (your decision).",
           "k_temp": "Temporary (network / 4xx)", "k_quota": "Gmail daily limit", "k_bounce": "Bad address (bounce)",
           "k_rejected": "Refused (inbox full / policy)", "k_auth": "Login refused (app password)",
           "k_config": "Not set up", "k_cap": "Our daily cap", "k_unsub": "Unsubscribed", "k_other": "Other"},
}


@require_http_methods(["GET", "POST"])
@owner_view()
def email_health(request):
    from core import email_sender as E
    from core.models import EmailSuppression
    lang = getattr(request, "owner_lang", "bn")
    lab = L.get(lang, L["bn"])
    if request.method == "POST":
        try:
            rid = int(request.POST.get("remove", "0"))
        except ValueError:
            rid = 0
        row = EmailSuppression.objects.filter(pk=rid).first()
        if row is not None:
            S.audit(request, request.owner, "email.unsuppress", "email:%s" % row.to_masked[:40],
                    before={"reason": row.reason, "hits": row.hits}, after={})
            row.delete()
        return done("/owner/email-health")
    card = E.health()
    card["kinds_today"] = [(lab.get("k_" + k, k), n) for k, n in card["kinds_today"]]
    for r in card["recent_failures"]:
        r["kind_label"] = lab.get("k_" + r["kind"], r["kind"])
    return page(request, "owner/email_health.html", {"card": card, "L": lab},
                nav="email_health")
