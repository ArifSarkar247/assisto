"""halaladz: Owner Admin -> HalalAdz support inbox. Every HalalAdz support
thread (SupportTicket topic="halaladz") in one list — unread first, unread
counts, open / resolved filter — and a thread page with photos + voice notes
(signed, expiring media links), quick replies, a free reply and Resolve.
Each reply / resolve goes to the owner audit log."""
from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page

FILTERS = ("open", "resolved", "all")

L = {
    "bn": {"title": "HalalAdz সাপোর্ট", "open": "খোলা", "resolved": "সমাধান হয়েছে",
           "all": "সব", "unread": "না-পড়া", "none": "এখনো কোনো বার্তা নেই।",
           "user": "ব্যবহারকারী", "linked": "HalalAdz অ্যাকাউন্ট", "last": "শেষ বার্তা",
           "reply": "উত্তর পাঠান", "quick": "দ্রুত উত্তর", "resolve": "সমাধান হয়েছে চিহ্ন দিন",
           "reopen": "আবার খুলুন", "back": "← সব বার্তা", "you": "আপনি",
           "photo": "ছবি", "voice": "ভয়েস", "placeholder": "উত্তর লিখুন…",
           "off": "HALALADZ_SHARED_SECRET সেট না থাকায় ব্যবহারকারীরা এখন নতুন বার্তা পাঠাতে পারছেন না।"},
    "en": {"title": "HalalAdz support", "open": "Open", "resolved": "Resolved",
           "all": "All", "unread": "Unread", "none": "No messages yet.",
           "user": "User", "linked": "HalalAdz account", "last": "Last message",
           "reply": "Send reply", "quick": "Quick replies", "resolve": "Mark resolved",
           "reopen": "Re-open", "back": "← All threads", "you": "You",
           "photo": "Photo", "voice": "Voice", "placeholder": "Write a reply…",
           "off": "HALALADZ_SHARED_SECRET is not set, so users can't send new messages now."},
}


def _l(request):
    return L["en" if getattr(request, "owner_lang", "bn") == "en" else "bn"]


@require_http_methods(["GET"])
@owner_view(perm="act_support")
def hz_inbox(request):
    from core import halaladz as HZ
    from core.models import SupportTicket
    from core.views_halaladz import inbox_rows
    st = request.GET.get("status") or "open"
    if st not in FILTERS:
        st = "open"
    rows = [HZ.ticket_dict(t, with_user=True) for t in inbox_rows(st)]
    unread = sum(SupportTicket.objects.filter(topic=HZ.TOPIC)
                 .values_list("unread_owner", flat=True))
    return page(request, "owner/halaladz_inbox.html", {
        "rows": rows, "st": st, "filters": FILTERS, "L": _l(request),
        "unread_total": unread, "enabled": HZ.enabled()}, nav="halaladz")


@require_http_methods(["GET"])
@owner_view(perm="act_support")
def hz_thread(request, pk):
    from core import halaladz as HZ
    from core.models import SupportTicket
    t = SupportTicket.objects.filter(pk=pk, topic=HZ.TOPIC).select_related("user").first()
    if t is None:
        raise Http404
    if t.unread_owner:
        t.unread_owner = 0
        t.save(update_fields=["unread_owner"])
    lang = getattr(request, "owner_lang", "bn")
    quick = [en if lang == "en" else bn for bn, en in HZ.QUICK_REPLIES]
    return page(request, "owner/halaladz_thread.html", {
        "t": HZ.ticket_dict(t, with_user=True), "L": _l(request),
        "msgs": [HZ.message_dict(m) for m in t.messages.all()],
        "quick": quick}, nav="halaladz")


@require_http_methods(["POST"])
@owner_view(perm="act_support")
def hz_thread_act(request, pk):
    from core import halaladz as HZ
    from core.models import SupportTicket
    t = SupportTicket.objects.filter(pk=pk, topic=HZ.TOPIC).select_related("user").first()
    if t is None:
        raise Http404
    back = "/owner/halaladz-support/%d" % t.pk
    action = request.POST.get("action") or ""
    if action == "reply":
        m = HZ.owner_reply(t, request.owner, request.POST.get("text") or "")
        S.audit(request, request.owner, "halaladz.reply", "support:%s" % t.pk,
                after={"ok": m is not None}, ok=m is not None)
        return done(back, "saved" if m is not None else "invalid")
    if action in ("resolve", "reopen"):
        t.resolved = action == "resolve"
        if t.resolved:
            t.unread_owner = 0
        t.save(update_fields=["resolved", "unread_owner"])
        S.audit(request, request.owner, "halaladz." + action, "support:%s" % t.pk)
        return done(back)
    return done(back, "invalid")
