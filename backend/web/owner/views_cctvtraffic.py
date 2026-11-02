"""cctvguard (owner CCTV order G): Owner Admin -> CCTV traffic. Per account,
this month (or ?month=YYYY-MM): paid live traffic (our TURN relay + the
Imou/EZVIZ cloud ESTIMATE), direct/P2P bytes, minutes, the pooled cap and
where each account stands. Numbers only — no video, no snapshots, no names
of places (order I: the owner never sees anyone's camera)."""
import re

from django.utils import timezone
from django.views.decorators.http import require_http_methods

from .base import owner_view, page

_MONTH = re.compile(r"^\d{4}-\d{2}$")

L = {
    "bn": {"title": "সিসিটিভি ট্রাফিক", "month": "মাস", "account": "অ্যাকাউন্ট",
           "cams": "ক্যামেরা", "paid": "খরচের ট্রাফিক (MB)", "turn": "আমাদের রিলে, ফোনের হিসাব / TURN সার্ভারের হিসাব (MB)",
           "vendor": "ক্লাউড-লাইভ অনুমান (MB, মিনিট)", "direct": "সরাসরি / একই Wi-Fi (MB, ফ্রি)",
           "minutes": "লাইভ মিনিট (রিলে)", "cap": "সীমা (MB)", "state": "অবস্থা",
           "none": "এই মাসে কোনো লাইভ ট্রাফিক নেই।",
           "intro": "শুধু সংখ্যা — কারো ভিডিও বা ছবি এখানে কখনো দেখা যায় না। ক্লাউড-লাইভ (Imou/EZVIZ) = বিটরেট × সময়ের অনুমান, ভেন্ডরের বিল নয়।",
           "enforced": "সীমা চালু (মালিক নিশ্চিত করেছেন)", "not_enforced": "সীমা শুধু গোনা হচ্ছে — চাপানো হচ্ছে না (Pricing → cctv_plan → limits_owner_confirmed বন্ধ)",
           "per_cam": "ক্যামেরাপ্রতি সীমা", "lv": {"ok": "ঠিক আছে", "notice": "৮০%+", "paused": "রিলে বন্ধ", "off": "গোনা হচ্ছে"}},
    "en": {"title": "CCTV traffic", "month": "Month", "account": "Account",
           "cams": "Cameras", "paid": "Paid traffic (MB)", "turn": "Our relay, phone-reported / TURN-logged (MB)",
           "vendor": "Cloud live estimate (MB, min)", "direct": "Direct / same Wi-Fi (MB, free)",
           "minutes": "Live minutes (relay)", "cap": "Cap (MB)", "state": "State",
           "none": "No live traffic this month.",
           "intro": "Numbers only — nobody's video or photos are ever shown here. Cloud live (Imou/EZVIZ) = bitrate × time ESTIMATE, not the vendor bill.",
           "enforced": "Cap enforced (owner confirmed)", "not_enforced": "Cap only counted — not enforced (Pricing → cctv_plan → limits_owner_confirmed off)",
           "per_cam": "per camera", "lv": {"ok": "OK", "notice": "80%+", "paused": "relay paused", "off": "counting"}},
}


@require_http_methods(["GET"])
@owner_view()
def cctv_traffic(request):
    from core import cctv_traffic as CT
    from core.logic import cctv_traffic as T
    month = request.GET.get("month") or ""
    if not _MONTH.match(month):
        month = T.month_key(timezone.now())
    rows, c = CT.admin_rows(month)
    lang = getattr(request, "owner_lang", "bn")
    lab = L.get(lang, L["bn"])
    for r in rows:
        r["level_label"] = lab["lv"].get(r["level"], r["level"])
        r["paid_mb"] = round(r["relay_mb"], 1)
    return page(request, "owner/cctv_traffic.html",
                {"rows": rows, "month": month, "L": lab, "cfg": c},
                nav="cctv_traffic")
