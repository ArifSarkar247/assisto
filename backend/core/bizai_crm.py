"""bizai pillar 2 — CRM automation (owner 4 Nov 02:05).

  * SEGMENTS from the shop's own sales (last purchase, value, interest):
    champion / loyal / new / at_risk_30 / at_risk_60 / lost_90 / one_time,
    plus a "high value" flag (top 20 % by spend) and each customer's
    favourite product line. Pure + explainable (every customer shows why).
  * WIN-BACK LADDER 30 / 60 / 90 days: three retention automations (the
    existing, guarded send pipeline — STOP, quiet hours, caps, credits,
    attribution) with a draft per stage; the AI can rewrite a draft (credits,
    numbers guard: it may never add a price or a claim); ONE tap approves
    and switches the three stages on.
  * OUTCOMES come from retention attribution (customers back, sales brought
    back) — shown on the Business-home outcome card and here.
"""
import logging
from collections import defaultdict
from datetime import timedelta

from django.db.models import Count, Max, Sum
from django.utils import timezone

from .i18n import pick

log = logging.getLogger(__name__)

SEGMENTS = ("champion", "loyal", "new", "at_risk_30", "at_risk_60", "lost_90", "one_time")
LADDER = (  # (stage, days_without, days_until)
    ("wb30", 30, 60),
    ("wb60", 60, 90),
    ("wb90", 90, 0),
)
LADDER_NAME = {"wb30": "Win-back 30", "wb60": "Win-back 60", "wb90": "Win-back 90"}

DRAFTS = {
    "wb30": ("{name}, অনেক দিন দেখা হয়নি! {shop}-এ নতুন জিনিস এসেছে — সময় পেলে একবার দেখে যাবেন।",
             "{name}, it's been a while! New things have arrived at {shop} — have a look when you can."),
    "wb60": ("{name}, {shop} আপনাকে মিস করছে। আপনার পছন্দের জিনিস আবার স্টকে আছে — উত্তর দিলেই রেখে দেব।",
             "{name}, {shop} misses you. Your favourites are back in stock — reply and we'll keep one for you."),
    "wb90": ("{name}, অনেক দিন পর মনে পড়ল! {shop}-এ আবার এলে খুশি হব। আর মেসেজ না চাইলে STOP লিখুন।",
             "{name}, we'd love to see you again at {shop}. Reply STOP if you'd rather not hear from us."),
}


# ===================================================================== pure
def segment_of(recency_days, purchases):
    """Pure: one customer → segment (recency first, then frequency)."""
    if recency_days is None:
        return "one_time"
    if recency_days >= 90:
        return "lost_90"
    if recency_days >= 60:
        return "at_risk_60"
    if recency_days >= 30:
        return "at_risk_30" if purchases >= 2 else "one_time"
    if purchases >= 4:
        return "champion"
    if purchases >= 2:
        return "loyal"
    return "new"


def value_cut(spends, share=0.2):
    """Smallest spend that is in the top `share` of customers (≥ 1 customer)."""
    vals = sorted((v for v in spends if v > 0), reverse=True)
    if not vals:
        return None
    k = max(1, int(round(len(vals) * share)))
    return vals[k - 1]


def mask_phone(key):
    k = str(key or "")
    return (k[:3] + "•••••" + k[-3:]) if len(k) >= 8 else "•••"


# ===================================================================== segments
def segments(business, now=None, members=20):
    from . import retention_service as RS
    from .models import Customer, SaleLine
    now = now or timezone.now()
    since = now - timedelta(days=365)
    rows = list(RS._sales(business).filter(created_at__gte=since).values("customer_id")
                .annotate(last=Max("created_at"), n=Count("id"), spend=Sum("total"))[:20000])
    if not rows:
        return {"total": 0, "segments": [{"key": k, "count": 0, "members": []} for k in SEGMENTS],
                "high_value_min_poisha": None}
    cut = value_cut([int(r["spend"] or 0) for r in rows])
    ids = [r["customer_id"] for r in rows]
    custs = {c.id: c for c in Customer.objects.filter(id__in=ids)}
    fav = defaultdict(lambda: defaultdict(int))
    for cid, name, qty in SaleLine.objects.filter(
            sale__customer_id__in=ids, sale__voided_at__isnull=True,
            sale__created_at__gte=since).values_list("sale__customer_id", "product_name", "qty")[:50000]:
        fav[cid][name] += int(qty or 1)
    out = {k: [] for k in SEGMENTS}
    for r in rows:
        c = custs.get(r["customer_id"])
        if c is None:
            continue
        rec = (now - r["last"]).days
        seg = segment_of(rec, r["n"])
        top = max(fav[c.id].items(), key=lambda kv: kv[1])[0] if fav[c.id] else ""
        out[seg].append({"customer_id": c.id, "name": c.name or "", "phone": mask_phone(c.phone_key),
                         "days": rec, "purchases": r["n"], "spend_poisha": int(r["spend"] or 0),
                         "high_value": cut is not None and int(r["spend"] or 0) >= cut,
                         "interest": top})
    res = []
    for k in SEGMENTS:
        lst = sorted(out[k], key=lambda x: (-x["spend_poisha"], x["days"]))
        res.append({"key": k, "count": len(lst), "members": lst[:members]})
    return {"total": len(rows), "segments": res, "high_value_min_poisha": cut}


# ===================================================================== ladder
def _ladder_autos(business):
    from .models import RetentionAutomation
    by = {}
    for a in RetentionAutomation.objects.filter(business=business, kind="winback"):
        st = (a.params or {}).get("bizai_stage") or \
            {v: k for k, v in LADDER_NAME.items()}.get(a.name)
        if st in LADDER_NAME and st not in by:
            by[st] = a
    return by


def _stage_audience(business, a, text, now, lang):
    """(due now, cost, sample) for one stage. A stage not created yet has no
    sends to subtract: who WOULD get it right now."""
    from . import retention_service as RS
    from .logic import msg_guard as MG
    try:
        if a.pk is None:
            stop = MG.opted_out_keys(business.pk)
            n = len([e for e in RS._events(a, now or timezone.now(),
                                           RS.cfg()["max_audience_scan"])
                     if e["key"] not in stop])
            return n, RS.cost_estimate(a, text, n), ""
        prev = RS.preview(a, now=now, lang=lang)
        return int(prev.get("due_now") or 0), prev.get("cost"), prev.get("sample_text") or ""
    except Exception:  # noqa: BLE001
        log.exception("bizai.ladder preview")
        return 0, RS.cost_estimate(a, text, 0), ""


def ladder(business, lang="bn", now=None):
    """The three stages: audience now, draft, on/off, cost estimate, results."""
    from . import retention_service as RS
    from .models import RetentionAutomation
    autos = _ladder_autos(business)
    stages = []
    for st, lo, hi in LADDER:
        a = autos.get(st) or RetentionAutomation(
            business=business, kind="winback", channel="in_app",
            params={"days_without": lo, "days_until": hi, "bizai_stage": st},
            template_bn=DRAFTS[st][0], template_en=DRAFTS[st][1])
        text = a.template_bn if lang == "bn" else a.template_en
        n, cost, sample = _stage_audience(business, a, text, now, lang)
        stages.append({"stage": st, "days_without": lo, "days_until": hi,
                       "enabled": bool(a.pk and a.enabled), "id": a.pk,
                       "channel": a.channel, "draft": text, "sample": sample,
                       "audience": n, "cost": cost,
                       "results": RS.summary(a) if a.pk else None})
    return {"stages": stages}


def approve_ladder(business, actor, drafts=None, channel="in_app"):
    """One tap: create / update the three stages with the owner's drafts
    and switch them on. -> (ok, problem)."""
    from . import retention_service as RS
    from .logic import retention as R
    from .models import RetentionAutomation
    if channel not in R.CHANNELS:
        channel = "in_app"
    drafts = drafts if isinstance(drafts, dict) else {}
    autos = _ladder_autos(business)
    new = [st for st, _, _ in LADDER if st not in autos]
    if RetentionAutomation.objects.filter(business=business).count() + len(new) > \
            RS.cfg()["max_automations"]:
        return False, "too_many"
    for st, lo, hi in LADDER:
        d = drafts.get(st) or {}
        bn = str(d.get("bn") or DRAFTS[st][0])[:R.MAX_TEMPLATE]
        en = str(d.get("en") or DRAFTS[st][1])[:R.MAX_TEMPLATE]
        for txt in (bn, en):
            probs = R.template_problems("winback", txt)
            if probs:
                return False, probs[0]
        a = autos.get(st)
        before = None
        if a is None:
            a = RetentionAutomation(business=business, kind="winback")
        else:
            old = RetentionAutomation.objects.get(pk=a.pk)
            before = {k: getattr(old, k) for k in ("enabled", "params", "template_bn",
                                                    "template_en", "channel", "send_hour",
                                                    "name", "wa_template")}
        a.name = LADDER_NAME[st]
        a.params = {"days_without": lo, "days_until": hi, "bizai_stage": st,
                    "daily_cap": int((a.params or {}).get("daily_cap") or 50)}
        a.template_bn, a.template_en, a.channel, a.enabled = bn, en, channel, True
        a.save()
        try:
            RS.audit_change(business, actor, before, a)
        except Exception:  # noqa: BLE001
            log.exception("bizai.ladder audit")
    return True, ""


def stop_ladder(business, actor):
    for a in _ladder_autos(business).values():
        if a.enabled:
            a.enabled = False
            a.save(update_fields=["enabled", "updated_at"])
    return True


AI_TASK = ("Rewrite this short {lang_name} message from a small shop to a customer who has "
           "not bought for a while. Warm, short (max 2 sentences), no pressure. NEVER add a "
           "price, discount, number, date, claim or product that is not in the text. Keep "
           "{{name}} and {{shop}} placeholders unchanged. Return only the message.")


def ai_draft(user, stage, text, lang="bn"):
    """AI rewrite of one stage draft (the shared AI router: credits + caps).
    -> (text, problem). A rewrite that adds a number is refused."""
    from . import ai
    from .logic import mktengine as M
    from .logic import retention as R
    if stage not in LADDER_NAME:
        return None, "bad_stage"
    base = (text or DRAFTS[stage][0 if lang == "bn" else 1]).strip()[:R.MAX_TEMPLATE]
    task = AI_TASK.format(lang_name="English" if lang == "en" else
                          "Bangla (Bengali script, Bangla digits)")
    try:
        out, _cost = ai.generate(task, data=base, tier="cheap", max_tokens=300,
                                 feature="bizai.crm_draft", user=user, pii=True)
    except ai.AIUnavailable as e:
        return None, "ai_" + str(getattr(e, "reason", "") or "no_key")
    except Exception:  # noqa: BLE001
        log.exception("bizai.ai_draft")
        return None, "ai_failed"
    out = (out or "").strip()[:R.MAX_TEMPLATE]
    if not out:
        return None, "ai_failed"
    if not M.numbers_ok(base, out):
        return None, "ai_changed_numbers"
    for ph in ("{name}", "{shop}"):
        if ph in base and ph not in out:
            return None, "ai_dropped_placeholder"
    if R.template_problems("winback", out):
        return None, "ai_bad_template"
    return out, None


def problem_text(code, lang):
    return {
        "too_many": pick(lang, "অটোমেশনের সর্বোচ্চ সংখ্যা হয়ে গেছে — একটা মুছে আবার চেষ্টা করুন।",
                         "You have the most automations allowed — delete one and try again."),
        "ai_changed_numbers": pick(lang, "AI নতুন সংখ্যা যোগ করেছিল, তাই নেওয়া হয়নি — আগের লেখা আছে।",
                                   "The AI added a number, so it was not used — your text stays."),
    }.get(code, pick(lang, "কাজটি করা যায়নি।", "That did not work."))
