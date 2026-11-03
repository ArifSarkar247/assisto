"""safeplans: Owner Admin -> Safety plans. Prices, limits, credit costs, ad
ratios + daily caps, cost assumptions, School Safe customers; the worst-case
40 % table, the Play Console product list the owner must create, and ad
revenue against unlocks. Numbers only — the owner never sees any location.
Every save goes through pricing_apply (PricingConfig audit) AND OwnerAudit."""
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page

INT_FIELDS = ("child_price_bdt", "child_requests", "child_guardians", "family_price_bdt",
              "family_credits", "family_members", "family_history_days",
              "family_update_min", "school_price_bdt", "school_min_students",
              "school_guardians", "school_requests", "free_requests",
              "cost_location_request", "cost_live_trip", "pack_valid_days",
              "ads_for_day", "ads_for_request", "day_pass_hours", "day_pass_requests",
              "day_unlocks_per_day", "request_unlocks_per_day",
              "paid_maps_child", "paid_maps_family", "paid_maps_school",
              "sms_per_account", "sms_per_student")
NUM_FIELDS = ("usd_bdt", "paid_map_call_usd", "request_server_bdt", "member_server_bdt",
              "sms_bdt", "ad_value_bdt_low", "invoice_fee", "play_fee", "vat")

L = {
    "bn": {"title": "নিরাপত্তা প্ল্যান", "intro": "চাইল্ড প্ল্যান, সেফ ফ্যামিলি, স্কুল সেফ — দাম, সীমা, ক্রেডিট, বিজ্ঞাপন-আনলক। শুধু সংখ্যা — কারো লোকেশন এখানে কখনো দেখা যায় না। SOS, বিপদের খবর ও স্কুলের স্বয়ংক্রিয় খবর সবসময় ফ্রি।",
           "on_sale": "বিক্রি চালু (Play প্রোডাক্ট বানানোর পরে)", "save": "সংরক্ষণ", "reason": "কারণ",
           "profit": "৪০% লাভের হিসাব (সবচেয়ে খারাপ অবস্থা)", "plan": "প্ল্যান", "price": "দাম ৳",
           "net": "হাতে আসে ৳", "cost": "খরচ ৳", "pct": "লাভ %", "fail": "৪০%-এর নিচে",
           "products": "Play Console-এ যা বানাতে হবে (আমরা বানাই না)", "type": "ধরন",
           "ads": "বিজ্ঞাপনের আয় বনাম আনলক", "ads_rev": "যাচাই করা বিজ্ঞাপন / আয় ৳",
           "unlocks": "দিন-পাস / অনুরোধ আনলক", "ucost": "আনলকের খরচ ৳", "subs": "চলতি সাবস্ক্রিপশন",
           "packs": "বিক্রি হওয়া প্যাক", "schools": "স্কুল সেফ গ্রাহক (Play-র বাইরে ইনভয়েস)",
           "code": "কোড", "name": "নাম", "students": "শিক্ষার্থী (পেইড)", "covered": "যুক্ত",
           "paid_until": "পেইড পর্যন্ত", "invoice": "ইনভয়েস", "admins": "স্কুল-স্টাফ ইউজার আইডি",
           "drivers": "বাস-ড্রাইভার ইউজার আইডি", "active": "চালু", "add": "স্কুল যোগ / হালনাগাদ",
           "none": "এখনো কোনো স্কুল নেই।", "fields": "সংখ্যা", "bad": "ভুল সংখ্যা"},
    "en": {"title": "Safety plans", "intro": "Child Plan, Safe Family, School Safe — prices, limits, credits, ad unlocks. Numbers only — nobody's location is ever shown here. SOS, danger alerts and automatic school alerts are always free.",
           "on_sale": "On sale (after the Play products exist)", "save": "Save", "reason": "Reason",
           "profit": "40 % profit check (worst case)", "plan": "Plan", "price": "Price ৳",
           "net": "Net ৳", "cost": "Cost ৳", "pct": "Profit %", "fail": "below 40 %",
           "products": "Create these in Play Console (we never do)", "type": "Type",
           "ads": "Ad revenue vs unlocks", "ads_rev": "Verified ads / revenue ৳",
           "unlocks": "Day passes / request unlocks", "ucost": "Unlock cost ৳", "subs": "Active subscriptions",
           "packs": "Packs sold", "schools": "School Safe customers (invoiced outside Play)",
           "code": "Code", "name": "Name", "students": "Students (paid)", "covered": "Linked",
           "paid_until": "Paid until", "invoice": "Invoice", "admins": "School staff user ids",
           "drivers": "Bus driver user ids", "active": "Active", "add": "Add / update school",
           "none": "No schools yet.", "fields": "Numbers", "bad": "Invalid number"},
}


def _ids(raw):
    out = []
    for p in str(raw or "").replace(" ", "").split(","):
        if p.isdigit():
            out.append(int(p))
    return out


@require_http_methods(["GET", "POST"])
@owner_view(perm="payments", write_perm="owner")
def safe_plans(request):
    from core import billing
    from core import safe_plans as SPS
    from core.logic import safe_plans as SP
    from core.views_build61 import pricing_apply
    lang = getattr(request, "owner_lang", "bn")
    lab = L.get(lang, L["bn"])
    cur = billing.cfg()["safe_plans"]
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action", "")
        reason = request.POST.get("reason", "").strip()[:200] or "safe_plans"
        new = dict(cur)
        new["schools"] = {k: dict(v) for k, v in cur["schools"].items()}
        bad = []
        if action == "save":
            new["on_sale"] = request.POST.get("on_sale") == "on"
            for k in INT_FIELDS + NUM_FIELDS:
                raw = request.POST.get(k, "").strip()
                if raw == "":
                    continue
                try:
                    new[k] = float(raw) if k in NUM_FIELDS else int(raw)
                except ValueError:
                    bad.append(k)
        elif action == "school":
            code = SP.norm_code(request.POST.get("code"))
            try:
                students = int(request.POST.get("students") or 0)
            except ValueError:
                students = -1
                bad.append("students")
            new["schools"][code] = {
                "name": request.POST.get("name", "")[:80], "students": students,
                "paid_until": request.POST.get("paid_until", "")[:10],
                "invoice_ref": request.POST.get("invoice_ref", "")[:40],
                "active": request.POST.get("active") == "on",
                "admin_ids": _ids(request.POST.get("admin_ids")),
                "driver_ids": _ids(request.POST.get("driver_ids"))}
        if bad:
            ctx["error"] = lab["bad"] + ": " + ", ".join(bad)
            status = 400
        else:
            ok, payload = pricing_apply(request.owner.id, {"config": {"safe_plans": new},
                                                           "reason": reason})
            if ok:
                S.audit(request, request.owner, "safe_plans.update", "safe_plans:%s" % action,
                        after={"action": action, "_reason": reason})
                return done("/owner/safe-plans")
            ctx["error"] = ", ".join(payload.get("problems") or ["error"])
            status = 400
    c = billing.cfg()["safe_plans"]
    ctx.update({"L": lab, "c": c, "profit": SP.profit_table(c),
                "products": SP.play_products(c), "report": SPS.admin_report(),
                "int_fields": [(k, c[k]) for k in INT_FIELDS],
                "num_fields": [(k, c[k]) for k in NUM_FIELDS]})
    return page(request, "owner/safe_plans.html", ctx, status=status, nav="safe_plans")
