"""cctvroles (CCTV Guard V3 J): Owner Admin -> CCTV installer partners.
Partners (approve / suspend), the sites each one set up (setup status only),
this month's commission per Premium AI site and the commission LEDGER
(cctvprice, owner-decided 17 Nov 12:35: 10 % of the net Premium AI part only,
never the base plan — core/logic/cctv_partner.COMMISSION_RULES). The page
never pays: a person marks a ledger row paid (with a reference) after paying
by hand. Never a photo, a clip or an alert of any site (CCTV Guard V3 K)."""
from django.http import HttpResponseRedirect
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import owner_view, page

L = {
    "bn": {"title": "সিসিটিভি ইনস্টলার পার্টনার",
           "intro": "এলাকার সিসিটিভি মিস্ত্রি যাঁরা জায়গার মালিকের QR/কোড দিয়ে সেটআপ করেন। তাঁরা শুধু সেটআপের অবস্থা দেখেন — কখনো ভিডিও, ছবি বা সতর্কতা নয়। এই পাতাতেও কারো ক্যামেরার কিছু দেখা যায় না।",
           "rules": "কমিশনের নিয়ম — মালিকের সিদ্ধান্ত (১৭ নভেম্বর ১২:৩৫)",
           "rules_line": "শুধু Premium AI জায়গায়: নেট মাসিক Premium AI অংশের %(pct)s%%, প্রথম %(months)s মাস; মূল ৫০০ টাকার (২ ক্যামেরা) প্ল্যানে কখনো কমিশন নয়; ফ্রি ট্রায়ালের মাস গোনা হয় না। প্রতিটি পরিশোধিত Premium AI মাসে খাতায় একটি লাইন \"পাওনা\" হয়; কিছুই নিজে থেকে দেওয়া হয় না।",
           "partners": "পার্টনার", "name": "নাম", "area": "এলাকা", "status": "অবস্থা",
           "sites": "জায়গা", "paying": "টাকা দিচ্ছে", "proposed": "এই মাসের কমিশন (টাকা)",
           "approve": "অনুমোদন", "suspend": "স্থগিত", "reason": "কারণ (লগে থাকবে)",
           "none": "এখনো কোনো পার্টনার আবেদন নেই।",
           "payouts": "কমিশনের খাতা", "payouts_none": "এখনো কোনো লাইন নেই — কোনো Premium AI জায়গা এখনো টাকা দেয়নি।",
           "ledger_cols": ["তারিখ", "পার্টনার", "জায়গা", "মাস নং", "নেট Premium AI", "কমিশন", "অবস্থা", ""],
           "owed": "পাওনা", "paid": "দেওয়া হয়েছে", "void": "বাতিল",
           "mark_paid": "দেওয়া হয়েছে চিহ্ন দিন", "mark_void": "বাতিল", "paid_ref": "রেফারেন্স (bKash/ব্যাংক)",
           "sum_owed": "মোট পাওনা", "sum_paid": "মোট দেওয়া",
           "setup_done": "সেটআপ শেষ", "setup_todo": "সেটআপ বাকি",
           "st": {"pending": "অপেক্ষায়", "approved": "অনুমোদিত", "suspended": "স্থগিত"},
           "yes": "হ্যাঁ", "no": "না", "total": "এই মাসে মোট"},
    "en": {"title": "CCTV installer partners",
           "intro": "Local CCTV technicians who set up a place with its owner's QR / code. They see only the setup status — never video, photos or alerts. Nothing of anyone's cameras is shown on this page either.",
           "rules": "Commission rules — OWNER-DECIDED (17 Nov 12:35)",
           "rules_line": "Premium AI places only: %(pct)s%% of the net monthly Premium AI part, for the first %(months)s months; never on the base 500 Tk (2-camera) plan; free-trial months do not count. Each paid Premium AI month adds one \"owed\" line to the ledger; nothing is paid automatically.",
           "partners": "Partners", "name": "Name", "area": "Area", "status": "Status",
           "sites": "Places", "paying": "Paying", "proposed": "Commission this month (Tk)",
           "approve": "Approve", "suspend": "Suspend", "reason": "Reason (kept in the log)",
           "none": "No partner applications yet.",
           "payouts": "Commission ledger", "payouts_none": "No lines yet — no Premium AI place has paid yet.",
           "ledger_cols": ["Date", "Partner", "Place", "Month no.", "Net Premium AI", "Commission", "Status", ""],
           "owed": "owed", "paid": "paid", "void": "void",
           "mark_paid": "Mark paid", "mark_void": "Void", "paid_ref": "Reference (bKash / bank)",
           "sum_owed": "Total owed", "sum_paid": "Total paid",
           "setup_done": "setup done", "setup_todo": "setup pending",
           "st": {"pending": "pending", "approved": "approved", "suspended": "suspended"},
           "yes": "yes", "no": "no", "total": "Total this month"},
}


def premium_ai(site):
    """Is this site's owner on Premium AI (an entitled cctv_premium_ai
    token)? Owner-decided 17 Nov; sold once the Play product exists."""
    from core import cctv_plan_service as CPS
    return CPS.premium_ai_active(site.owner)


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
    """Partner rows with their places' setup + this month's commission."""
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
            # 10 % of the NET Premium AI part only (never the base plan)
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


def ledger_rows(limit=300):
    """The commission ledger (newest first) + totals owed / paid."""
    from django.db.models import Sum
    from core.models import CctvCommissionEntry
    qs = CctvCommissionEntry.objects.select_related("partner")
    out = [{"id": e.id, "created": e.created, "partner": e.partner.name or "#%d" % e.partner_id,
            "partner_id": e.partner_id, "site_id": e.site_id, "month": e.month,
            "no": e.paid_month_no, "net": e.premium_ai_net_bdt, "amount": e.amount_bdt,
            "status": e.status, "paid_ref": e.paid_ref} for e in qs[:limit]]
    sums = {k: int(qs.filter(status=k).aggregate(s=Sum("amount_bdt"))["s"] or 0)
            for k in ("owed", "paid")}
    return out, sums


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
        if act in ("mark_paid", "mark_void") and reason:
            from core.models import CctvCommissionEntry
            e = CctvCommissionEntry.objects.filter(pk=request.POST.get("entry") or 0,
                                                   status="owed").first()
            ref = request.POST.get("paid_ref", "").strip()[:80]
            if e is not None and (act == "mark_void" or ref):
                e.status = "paid" if act == "mark_paid" else "void"
                e.paid_at = timezone.now()
                e.paid_ref = ref
                e.save(update_fields=["status", "paid_at", "paid_ref"])
                S.audit(request, request.owner, "cctv_commission." + act, "commission:%s" % e.pk,
                        before={"status": "owed"},
                        after={"status": e.status, "amount_bdt": e.amount_bdt, "_reason": reason})
            return HttpResponseRedirect("/owner/cctv-partners")
        if p is not None and act in ("approve", "suspend") and reason:
            before = p.status
            p.status = "approved" if act == "approve" else "suspended"
            p.decided_at = timezone.now()
            p.save(update_fields=["status", "decided_at"])
            S.audit(request, request.owner, "cctv_partner." + act, "partner:%s" % p.pk,
                    before={"status": before}, after={"status": p.status, "_reason": reason})
        return HttpResponseRedirect("/owner/cctv-partners")
    data, total = rows()
    ledger, sums = ledger_rows()
    for e in ledger:
        e["status_label"] = lab.get(e["status"], e["status"])
    for r in data:
        r["status_label"] = lab["st"].get(r["status"], r["status"])
    prop = CPT.COMMISSION_PROPOSAL
    return page(request, "owner/cctv_partners.html",
                {"rows": data, "total": total, "L": lab, "ledger": ledger, "sums": sums,
                 "rules_line": lab["rules_line"] % {"pct": prop["pct_of_net"],
                                                    "months": prop["months"]},
                 "approved": prop["approved"]},
                nav="cctv_partners")
