"""cctvroles (CCTV Guard V3 J): Owner Admin -> CCTV installer partners.
Partners (approve / suspend), the sites each one set up (setup status only),
the PROPOSED commission per paying site and payouts. The commission rules
are a PROPOSAL marked "needs owner approval" — this page pays nothing, queues
nothing and promises nothing (core/logic/cctv_partner.COMMISSION_PROPOSAL).
Never a photo, a clip or an alert of any site (CCTV Guard V3 K)."""
from django.http import HttpResponseRedirect
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import owner_view, page

L = {
    "bn": {"title": "সিসিটিভি ইনস্টলার পার্টনার",
           "intro": "এলাকার সিসিটিভি মিস্ত্রি যাঁরা জায়গার মালিকের QR/কোড দিয়ে সেটআপ করেন। তাঁরা শুধু সেটআপের অবস্থা দেখেন — কখনো ভিডিও, ছবি বা সতর্কতা নয়। এই পাতাতেও কারো ক্যামেরার কিছু দেখা যায় না।",
           "rules": "কমিশনের নিয়ম — প্রস্তাব, মালিকের অনুমোদন লাগবে",
           "rules_line": "শুধু Premium AI জায়গায়: নেট মাসিক Premium AI দামের %(pct)s%%, প্রথম %(months)s মাস; ফ্রি ট্রায়ালের মাস গোনা হয় না। Premium AI এখনো বিক্রি হয় না, তাই আজ প্রস্তাবিত কমিশন ০। কিছুই নিজে থেকে দেওয়া হয় না।",
           "partners": "পার্টনার", "name": "নাম", "area": "এলাকা", "status": "অবস্থা",
           "sites": "জায়গা", "paying": "টাকা দিচ্ছে", "proposed": "প্রস্তাবিত কমিশন (এই মাস, টাকা)",
           "approve": "অনুমোদন", "suspend": "স্থগিত", "reason": "কারণ (লগে থাকবে)",
           "none": "এখনো কোনো পার্টনার আবেদন নেই।",
           "payouts": "পেমেন্ট", "payouts_none": "কোনো পেমেন্ট হয়নি। কমিশনের নিয়ম মালিক অনুমোদন করার আগে কোনো পেমেন্ট হবে না।",
           "setup_done": "সেটআপ শেষ", "setup_todo": "সেটআপ বাকি",
           "st": {"pending": "অপেক্ষায়", "approved": "অনুমোদিত", "suspended": "স্থগিত"},
           "yes": "হ্যাঁ", "no": "না", "total": "মোট (প্রস্তাব)"},
    "en": {"title": "CCTV installer partners",
           "intro": "Local CCTV technicians who set up a place with its owner's QR / code. They see only the setup status — never video, photos or alerts. Nothing of anyone's cameras is shown on this page either.",
           "rules": "Commission rules — PROPOSAL, needs owner approval",
           "rules_line": "Premium AI places only: %(pct)s%% of the net monthly Premium AI price, for the first %(months)s months; free-trial months do not count. Premium AI is not on sale yet, so the proposed commission is 0 today. Nothing is paid automatically.",
           "partners": "Partners", "name": "Name", "area": "Area", "status": "Status",
           "sites": "Places", "paying": "Paying", "proposed": "Proposed commission (this month, Tk)",
           "approve": "Approve", "suspend": "Suspend", "reason": "Reason (kept in the log)",
           "none": "No partner applications yet.",
           "payouts": "Payouts", "payouts_none": "No payouts. No payout happens before the owner approves the commission rules.",
           "setup_done": "setup done", "setup_todo": "setup pending",
           "st": {"pending": "pending", "approved": "approved", "suspended": "suspended"},
           "yes": "yes", "no": "no", "total": "Total (proposal)"},
}


def premium_ai(site):
    """Seam: is this site on the Premium AI tier? The tier is a PROPOSAL
    (owner_actions/CCTV_PRICING_V3_BN.md) — nothing sells it yet."""
    return False


def _ai_net_month(cameras):
    from core.logic import cctv_plan as CP
    from core.logic import cctv_premium_ai as PA
    from core import cctv_plan_service as CPS
    try:
        n = max(1, int(cameras or 1))
        return PA.AI_ADDON_BDT_PER_CAMERA * n * CP.net_share(CPS.cfg())
    except Exception:
        return 0.0


def rows(now=None):
    """Partner rows with their places' setup + the PROPOSED commission."""
    from core.cctv_partner_views import paying, site_setup
    from core.logic import cctv_partner as CPT
    from core.models import CctvPartner
    now = now or timezone.now()
    out, total = [], 0
    for p in CctvPartner.objects.select_related("user").all()[:300]:
        sites = []
        for link in p.links.filter(status="active").select_related("site")[:100]:
            s = link.site
            pay, trial, cams = paying(s, now)
            months = 0
            if link.accepted_at:
                months = max(1, (now - link.accepted_at).days // 30)
            # the Premium AI tier is a proposal, not on sale: no site is on
            # it yet, so the proposal gives 0 today (shown honestly)
            prem = premium_ai(s)
            prop = CPT.proposed_commission(_ai_net_month(cams), months, trial,
                                           premium_ai=prem) if pay else 0
            total += prop
            st = site_setup(s, now)
            sites.append({"id": s.id, "cameras": st["cameras"], "online": st["online"],
                          "done": st["done"], "paying": pay and not trial, "proposed": prop})
        out.append({"id": p.id, "user_id": p.user_id, "name": p.name, "area": p.area,
                    "status": p.status, "created": p.created, "sites": sites,
                    "proposed": sum(x["proposed"] for x in sites)})
    return out, total


@require_http_methods(["GET", "POST"])
@owner_view()
def cctv_partners(request):
    from core.logic import cctv_partner as CPT
    from core.models import CctvPartner
    lang = getattr(request, "owner_lang", "bn")
    lab = L.get(lang, L["bn"])
    if request.method == "POST":
        act = request.POST.get("action", "")
        reason = request.POST.get("reason", "").strip()[:200]
        p = CctvPartner.objects.filter(pk=request.POST.get("partner") or 0).first()
        if p is not None and act in ("approve", "suspend") and reason:
            before = p.status
            p.status = "approved" if act == "approve" else "suspended"
            p.decided_at = timezone.now()
            p.save(update_fields=["status", "decided_at"])
            S.audit(request, request.owner, "cctv_partner." + act, "partner:%s" % p.pk,
                    before={"status": before}, after={"status": p.status, "_reason": reason})
        return HttpResponseRedirect("/owner/cctv-partners")
    data, total = rows()
    for r in data:
        r["status_label"] = lab["st"].get(r["status"], r["status"])
    prop = CPT.COMMISSION_PROPOSAL
    return page(request, "owner/cctv_partners.html",
                {"rows": data, "total": total, "L": lab,
                 "rules_line": lab["rules_line"] % {"pct": prop["pct_of_net"],
                                                    "months": prop["months"]},
                 "approved": prop["approved"]},
                nav="cctv_partners")
