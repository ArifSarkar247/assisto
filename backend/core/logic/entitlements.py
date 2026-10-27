"""plans-v2 — the ONE pure answer to "may this plan do X?" (owner order 27 Oct).

Pure: no Django, no DB. The service layer (core/entitlements_service.py)
feeds it the normalized PricingConfig `plans_v2` block and the account's
plan; every server gate asks through that service, never through literals.

Tiers (what a plan id means for business features):
  free      Free
  premium   Premium, Annual (Premium yearly), Probashi, legacy Family
  business  Business, and FOUNDER (lifetime founder counts as Business
            wherever Business is required — owner rule)
A running free trial counts as the config's `trial_plan` (default
"business") while plans_v2 is ON; with the flag OFF nothing here is used.

Capabilities (only what is really built — owner rule "never sell what is
not built"; Team members and Marketing automation are NOT here):
  crm_write               create leads / deals / pipelines / stages / tasks
                          (Free = view only; existing records stay editable)
  crm_followup_reminders  follow-up dates, next steps, reminders, suggestions
  automation              CRM automation rules, retention automation
                          (thank-you + review ask after a purchase, win-back,
                          birthday, dues, back-in-stock), CRM bulk WhatsApp
  ai_sales_agent          the AI sales agent (Messenger / WhatsApp / website
                          chat replies, COD order confirmation, follow-ups)
                          and the shop AI reply / bargaining console
  booking_bot             appointment booking page going live
  reports                 weekly / monthly sales reports, bank-loan report,
                          business insights (the daily totals stay free as
                          part of "Digital Ledger basic")
  ledger_ai_addons        khata voice entry, paper-khata scan, payment match
Numbers:
  crm_contacts            CRM people (leads + contacts) per account, summed
                          over every CRM the account owns. Business carries a
                          high HIDDEN safety cap (nothing is unlimited); the
                          app shows "Unlimited" at/above unlimited_display_at.
"""

TIERS = ("free", "premium", "business")

CAPS = ("crm_write", "crm_followup_reminders", "automation", "ai_sales_agent",
        "booking_bot", "reports", "ledger_ai_addons")

# plan id (core.plans.PLANS + legacy) -> tier
PLAN_TIER = {
    "free": "free",
    "premium": "premium", "annual": "premium", "probashi": "premium",
    "family": "premium",
    "business": "business", "founder": "business",
}

_CAP_DEFAULTS = {
    "free":     {"crm_write": False, "crm_followup_reminders": False,
                 "automation": False, "ai_sales_agent": False,
                 "booking_bot": False, "reports": False,
                 "ledger_ai_addons": False},
    "premium":  {"crm_write": True, "crm_followup_reminders": True,
                 "automation": False, "ai_sales_agent": False,
                 "booking_bot": False, "reports": False,
                 # today Premium already has these (credits still charged)
                 "ledger_ai_addons": True},
    "business": {c: True for c in CAPS},
}
_CONTACT_DEFAULTS = {"free": 20, "premium": 500, "business": 50000}
# (min, max) per tier: an owner typo can never open an unlimited CRM
_CONTACT_BOUNDS = {"free": (0, 1000), "premium": (1, 100000),
                   "business": (1, 1000000)}
TRIAL_PLANS = ("premium", "business")
TRIAL_DAYS_BOUNDS = (0, 30)
DISPLAY_BOUNDS = (100, 1000000)


def defaults():
    """The flat PricingConfig `plans_v2` block (Owner Admin edits it)."""
    d = {"trial_days": 7, "trial_plan": "business",
         "unlimited_display_at": 10000}
    for t in TIERS:
        d["%s_crm_contacts" % t] = _CONTACT_DEFAULTS[t]
        for c in CAPS:
            d["%s_%s" % (t, c)] = _CAP_DEFAULTS[t][c]
    return d


def _int(v, fb):
    if isinstance(v, bool):
        return fb
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return fb


def _bool(v, fb):
    if isinstance(v, bool):
        return v
    if v in (0, 1):
        return bool(v)
    if isinstance(v, str) and v.lower() in ("true", "false", "1", "0", "on", "off"):
        return v.lower() in ("true", "1", "on")
    return fb


def normalize(raw):
    """Project any stored dict onto the known shape, clamped. Never mutates."""
    raw = raw if isinstance(raw, dict) else {}
    base = defaults()
    out = {}
    lo, hi = TRIAL_DAYS_BOUNDS
    out["trial_days"] = max(lo, min(hi, _int(raw.get("trial_days"), base["trial_days"])))
    tp = str(raw.get("trial_plan") or base["trial_plan"]).strip().lower()
    out["trial_plan"] = tp if tp in TRIAL_PLANS else base["trial_plan"]
    lo, hi = DISPLAY_BOUNDS
    out["unlimited_display_at"] = max(lo, min(hi, _int(
        raw.get("unlimited_display_at"), base["unlimited_display_at"])))
    for t in TIERS:
        k = "%s_crm_contacts" % t
        lo, hi = _CONTACT_BOUNDS[t]
        out[k] = max(lo, min(hi, _int(raw.get(k), base[k])))
        for c in CAPS:
            k = "%s_%s" % (t, c)
            out[k] = _bool(raw.get(k), base[k])
    return out


def problems(raw):
    """Owner-edit problems (refuse instead of silently clamping)."""
    if raw is None:
        return []
    if not isinstance(raw, dict):
        return ["bad_plans_v2"]
    out = []
    for k, v in raw.items():
        if k == "trial_plan":
            if str(v).strip().lower() not in TRIAL_PLANS:
                out.append("bad_plans_v2")
            continue
        if isinstance(v, bool):
            continue
        n = _int(v, None)
        if n is None:
            out.append("bad_plans_v2")
            continue
        if k == "trial_days":
            lo, hi = TRIAL_DAYS_BOUNDS
        elif k == "unlimited_display_at":
            lo, hi = DISPLAY_BOUNDS
        elif k.endswith("_crm_contacts") and k.split("_")[0] in _CONTACT_BOUNDS:
            lo, hi = _CONTACT_BOUNDS[k.split("_")[0]]
        else:
            continue
        if not lo <= n <= hi:
            out.append("bad_plans_v2")
    return list(dict.fromkeys(out))


def tier_of(plan_id):
    return PLAN_TIER.get(plan_id or "free", "free")


def tier_for(plan_id, paid_active, trial_active, cfg):
    """The tier for a resolved core.plans.effective_plan() id. A running trial
    only RAISES a free account to the trial plan; it never lowers a paid one."""
    t = tier_of(plan_id) if paid_active else "free"
    if trial_active and TIERS.index(cfg["trial_plan"]) > TIERS.index(t):
        t = cfg["trial_plan"]
    return t


def allows(tier, cap, cfg):
    return bool(cfg.get("%s_%s" % (tier, cap), False))


def contacts_limit(tier, cfg):
    return int(cfg["%s_crm_contacts" % tier])


def needed_plan(cap, cfg):
    """The cheapest tier that has `cap` (None = no tier has it)."""
    for t in TIERS:
        if allows(t, cap, cfg):
            return t
    return None


def needed_for_contacts(used, cfg, current="free"):
    """The cheapest tier ABOVE `current` whose contact limit has room for one
    more (None = no higher tier has room, e.g. Business at its safety cap)."""
    start = TIERS.index(current) + 1 if current in TIERS else 0
    for t in TIERS[start:]:
        if used < contacts_limit(t, cfg):
            return t
    return None


def contact_status(tier, used, cfg):
    lim = contacts_limit(tier, cfg)
    return {"used": int(used), "limit": lim,
            "unlimited": lim >= cfg["unlimited_display_at"],
            "can_add": used < lim,
            "over": used > lim}


def matrix(cfg):
    """{tier: {cap: bool, ..., crm_contacts: n, crm_unlimited: bool}}."""
    out = {}
    for t in TIERS:
        row = {c: allows(t, c, cfg) for c in CAPS}
        row["crm_contacts"] = contacts_limit(t, cfg)
        row["crm_unlimited"] = row["crm_contacts"] >= cfg["unlimited_display_at"]
        out[t] = row
    return out


# bn/en reason lines for the 402 body + the app sheet (the app also has ARB
# copies; the server line is what older/other clients show).
_PLAN_NAME = {"free": ("ফ্রি", "Free"), "premium": ("প্রিমিয়াম", "Premium"),
              "business": ("বিজনেস", "Business")}
_REASON = {
    "crm_contacts": ("আপনার প্ল্যানে CRM-এ সর্বোচ্চ {limit}টি কন্টাক্ট রাখা যায় ({used}টি আছে)। নতুন কন্টাক্ট যোগ করতে {plan} নিন — আগের সব কন্টাক্ট যেমন আছে তেমনই থাকবে।",
                     "Your plan keeps up to {limit} CRM contacts (you have {used}). Get {plan} to add more — every contact you already have stays as it is."),
    "crm_write": ("ফ্রি প্ল্যানে লিড, ডিল, পাইপলাইন ও কাজ শুধু দেখা যায়। নতুন যোগ করতে {plan} নিন।",
                  "On Free, leads, deals, pipeline and tasks are view only. Get {plan} to add new ones."),
    "crm_followup_reminders": ("ফলো-আপ রিমাইন্ডার {plan} প্ল্যানে আছে।",
                               "Follow-up reminders come with {plan}."),
    "automation": ("অটোমেশন (রিটেনশন বার্তা, CRM নিয়ম) {plan} প্ল্যানে আছে।",
                   "Automation (retention messages, CRM rules) comes with {plan}."),
    "ai_sales_agent": ("AI সেলস এজেন্ট {plan} প্ল্যানে আছে।",
                       "The AI Sales Agent comes with {plan}."),
    "booking_bot": ("বুকিং পেজ চালু করতে {plan} প্ল্যান লাগে।",
                    "Putting the booking page live needs {plan}."),
    "reports": ("সাপ্তাহিক ও মাসিক রিপোর্ট {plan} প্ল্যানে আছে। দিনের হিসাব ফ্রি-তেই দেখা যায়।",
                "Weekly and monthly reports come with {plan}. Daily totals stay free."),
    "ledger_ai_addons": ("খাতার এই AI সুবিধা {plan} প্ল্যানে আছে।",
                         "This khata AI tool comes with {plan}."),
}


def bn_digits(s):
    return "".join(chr(0x09E6 + ord(c) - 48) if "0" <= c <= "9" else c for c in str(s))


def reason_text(feature, needed, limit=None, used=None):
    """(bn, en) for a refusal."""
    bn, en = _REASON.get(feature, _REASON["crm_write"])
    pb, pe = _PLAN_NAME.get(needed or "business", _PLAN_NAME["business"])
    lim = "" if limit is None else limit
    us = "" if used is None else used
    return (bn.format(plan=pb, limit=bn_digits(lim), used=bn_digits(us)),
            en.format(plan=pe, limit=lim, used=us))


def upgrade_body(feature, needed, current, lang="bn", limit=None, used=None):
    """The ONE structured 402 body every plans-v2 gate returns."""
    bn, en = reason_text(feature, needed, limit, used)
    return {"error": "upgrade_required", "reason": "upgrade_required",
            "upgrade": True, "feature": feature,
            "needed_plan": needed, "plan_required": needed,   # older clients
            "current_plan": current, "limit": limit, "used": used,
            "message": {"bn": bn, "en": en},
            "detail": bn if lang == "bn" else en}
