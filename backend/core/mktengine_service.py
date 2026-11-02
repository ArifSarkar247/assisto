"""mktengine — Marketing Engine v1, the DB side (flag `marketing_engine`).

Storage: the generic per-user PaCollectionItem store (no migration):
  collection "mkt_profile"  one row per business: {business_id, answers}
  collection "mkt_plan"     one row per business: {business_id, lang, start,
                            generated_at, items[], facts[], ai}
Facts come from the business's REAL data only (POS sales, catalog, CRM leads,
open quotes) — see facts_for(). Follow-ups are REALLY sent through retention
automation (core.retention_service): an approved follow-up item becomes a
RetentionAutomation row, and the existing retention_run cron sends it through
core.logic.msg_guard (STOP, per-customer / per-business caps, quiet hours,
Meta 24 h rules) — this module never sends a message itself.
Facebook publishing goes through the Graph client (core.bizagent_graph) ONLY
when Meta has approved page publishing for our app (Owner Admin →
Integrations → meta_app → page_publish_approved) and the shop's Page is
connected; otherwise the app offers copy / share with an honest note.
"""
import logging
from datetime import timedelta

from django.db.models import Count, F, Max, Q, Sum
from django.utils import timezone

from .logic import mktengine as M

log = logging.getLogger("assisto.mktengine")

FLAG = "marketing_engine"
COL_PROFILE = "mkt_profile"
COL_PLAN = "mkt_plan"
SALES_DAYS = 90
SLOW_DAYS = 60
AI_FEATURE = "mktengine"


def flag_on(user, play=False):
    try:
        from . import feature_flags as FF
        return FF.is_on(FLAG, user, play)
    except Exception:
        return False


# ------------------------------------------------------------------ storage
def _row(user, business, col):
    from .models import PaCollectionItem
    for r in PaCollectionItem.objects.filter(user=user, collection=col).order_by("id"):
        if (r.data or {}).get("business_id") == business.id:
            return r
    return None


def _save(user, business, col, data):
    from .models import PaCollectionItem
    data = dict(data, business_id=business.id)
    r = _row(user, business, col)
    if r is None:
        return PaCollectionItem.objects.create(user=user, collection=col, data=data)
    r.data = data
    r.save(update_fields=["data", "updated_at"])
    return r


def get_answers(user, business):
    r = _row(user, business, COL_PROFILE)
    return dict((r.data or {}).get("answers") or {}) if r else {}


def save_answers(user, business, raw, partial=False):
    clean, problems = M.validate_answers(raw, partial=partial)
    if problems and not partial:
        return clean, problems
    if partial:
        merged = dict(get_answers(user, business), **clean)
        clean = merged
    _save(user, business, COL_PROFILE, {"answers": clean,
                                        "updated_at": timezone.now().isoformat()})
    return clean, [p for p in problems if not p.startswith("missing_")]


def get_plan(user, business):
    r = _row(user, business, COL_PLAN)
    return dict(r.data) if r else None


def _store_plan(user, business, plan):
    _save(user, business, COL_PLAN, plan)


# ------------------------------------------------------------------ facts
def _biz_q(business):
    # legacy single-shop rows carry business=NULL + user=owner
    return Q(business=business) | Q(business__isnull=True, user=business.user)


def facts_for(business, now=None):
    """The business's REAL numbers. Nothing here is estimated."""
    from .models import Product, Sale, SaleLine
    now = now or timezone.now()
    since = now - timedelta(days=SALES_DAYS)
    owner = business.user
    sales = Sale.objects.filter(_biz_q(business), voided_at__isnull=True, created_at__gte=since)
    agg = sales.aggregate(n=Count("id"), total=Sum("total"))
    lines = (SaleLine.objects.filter(sale__in=sales)
             .values("product_name").annotate(qty=Sum("qty"), rev=Sum(F("qty") * F("unit_price")))
             .order_by("-qty", "-rev")[:5])
    products = list(Product.objects.filter(_biz_q(business)).order_by("name")[:500])
    by_name = {p.name: p for p in products}
    top = []
    for r in lines:
        p = by_name.get(r["product_name"])
        top.append({"name": r["product_name"], "qty": int(r["qty"] or 0),
                    "revenue": int(r["rev"] or 0) / 100.0,
                    "price": float(p.price) if p is not None and p.price else 0,
                    "description": (p.description or "")[:160] if p is not None else ""})
    sold_recent = set(SaleLine.objects.filter(
        sale__in=Sale.objects.filter(_biz_q(business), voided_at__isnull=True,
                                     created_at__gte=now - timedelta(days=SLOW_DAYS)))
        .values_list("product_name", flat=True).distinct())
    slow = [{"name": p.name, "stock": p.stock, "price": float(p.price)}
            for p in products if p.stock > 0 and p.price and p.name not in sold_recent]
    slow.sort(key=lambda s: -s["stock"])
    per_cust = (sales.exclude(customer__isnull=True).values("customer")
                .annotate(n=Count("id")))
    customers_90d = per_cust.count()
    repeat = per_cust.filter(n__gte=2).count()
    priced = [p for p in products if p.price]
    newest = max(priced, key=lambda p: p.updated_at, default=None)
    facts = {
        "shop": (business.shop_name or "").strip()[:60],
        "top_products": top,
        "slow_movers": slow[:5],
        "catalog": [{"name": p.name, "price": float(p.price), "description": (p.description or "")[:160]}
                    for p in sorted(priced, key=lambda p: -float(p.price))[:5]],
        "catalog_priced": len(priced),
        "newest": {"name": newest.name, "price": float(newest.price)} if newest else {},
        "sales_90d_count": int(agg["n"] or 0),
        "sales_90d_total": int(agg["total"] or 0) / 100.0,
        "customers_90d": customers_90d,
        "repeat_customers": repeat,
    }
    facts.update(_crm_facts(owner, now))
    facts["open_quotes"] = _open_quotes(business, now)
    return facts


def _crm_facts(owner, now):
    out = {"leads_total": 0, "leads_new_30d": 0, "leads_won": 0}
    try:
        from crm.models import Lead
        qs = Lead.objects.filter(org__owner=owner)
        out["leads_total"] = qs.count()
        out["leads_new_30d"] = qs.filter(created_at__gte=now - timedelta(days=30)).count()
        out["leads_won"] = qs.filter(status="won").count()
    except Exception:  # noqa: BLE001 — CRM absent never breaks the plan
        log.exception("mktengine crm facts")
    return out


def _open_quotes(business, now):
    try:
        from crm.models import ShopQuote
        return ShopQuote.objects.filter(business=business, state__in=("issued", "viewed"),
                                        valid_until__gt=now).count()
    except Exception:  # noqa: BLE001
        return 0


# ------------------------------------------------------------------ plan
def generate(user, business, lang="bn", now=None):
    """Build (or rebuild) the plan from the saved answers + fresh facts.
    Approved / edited items survive a rebuild. Returns (plan, problem)."""
    answers = get_answers(user, business)
    if not M.is_complete(answers):
        return None, "questionnaire_incomplete"
    now = now or timezone.now()
    from .logic import msg_guard as MG
    start = MG.local(now).date()
    facts = facts_for(business, now)
    built = M.build_plan(answers, facts, lang, start)
    old = get_plan(user, business) or {}
    built["items"] = M.merge_regenerated(old.get("items"), built["items"])
    built["generated_at"] = now.isoformat()
    built["raw_facts"] = {k: facts.get(k) for k in (
        "sales_90d_count", "repeat_customers", "customers_90d", "leads_total", "catalog_priced")}
    _store_plan(user, business, built)
    return built, None


def find_item(plan, item_id):
    for it in (plan or {}).get("items") or []:
        if it.get("id") == item_id:
            return it
    return None


def edit_item(user, business, item_id, data):
    plan = get_plan(user, business)
    it = find_item(plan, item_id)
    if it is None:
        return None, ["not_found"]
    it, probs = M.apply_edit(it, data if isinstance(data, dict) else {})
    if probs:
        return None, probs
    _store_plan(user, business, plan)
    return it, []


# ------------------------------------------------------------------ AI polish
POLISH_TASK = (
    "You are a marketing copy editor for a small shop in Bangladesh. Rewrite the "
    "marketing text inside <data> so it sounds {tone} and fits this business: {ctx}. "
    "Write in {lang_name}. Keep it about the same length. HARD RULES: keep every price, "
    "number and date exactly as written; never add a new number, price, percentage, "
    "count of customers, review, testimonial or claim that is not in the text; keep "
    "product names unchanged; keep any {{variable}} placeholders unchanged. Return only "
    "the rewritten text.")


def polish(user, business, item_id, lang="bn"):
    """Personalise one item with the AI router (credits + daily caps of the
    existing router). Returns (item, problem). A rewrite that adds a number is
    refused (numbers_ok) — the original stays."""
    from . import ai
    plan = get_plan(user, business)
    it = find_item(plan, item_id)
    if it is None:
        return None, "not_found"
    if it.get("kind") in ("calendar", "followup"):
        return None, "not_polishable"
    answers = get_answers(user, business)
    ctx = "%s, %s, customers: %s" % (
        M.label("business_type", answers.get("business_type"), "en"), answers.get("area", ""),
        ", ".join(M.label("customers", c, "en") for c in answers.get("customers") or []))
    task = POLISH_TASK.format(tone=M.label("tone", answers.get("tone"), "en").lower(), ctx=ctx,
                              lang_name="English" if lang == "en" else "Bangla (Bengali script, Bangla digits)")
    try:
        text, _cost = ai.generate(task, data=it["body"], tier="cheap", max_tokens=700,
                                  feature=AI_FEATURE, user=user, pii=True)
    except ai.AIUnavailable as e:
        return None, "ai_" + str(getattr(e, "reason", "") or "no_key")
    except Exception:  # noqa: BLE001
        log.exception("mktengine polish")
        return None, "ai_failed"
    text = (text or "").strip()[:M.MAX_BODY]
    if not text:
        return None, "ai_failed"
    if not M.numbers_ok(it["body"], text):
        return None, "ai_changed_numbers"
    it["original_body"] = it.get("original_body") or it["body"]
    it["body"] = text
    it["polished"] = True
    it["status"] = "draft"          # the owner approves the new wording again
    _store_plan(user, business, plan)
    return it, None


# ------------------------------------------------------------------ follow-ups -> retention
def retention_state(user, play=False):
    from . import retention_service as RS
    return {"flag": RS.flag_on(user, play), "plan_ok": RS.plan_ok(user)}


def _template_from_item(it, lang):
    """The owner's edited wording (first paragraph) for `lang`, else the
    generated template."""
    bn, en = it.get("template_bn") or "", it.get("template_en") or ""
    if it.get("edited"):
        first = (it.get("body") or "").split("\n\n")[0].strip()
        if first:
            if lang == "en":
                en = first
            else:
                bn = first
    return bn, en


def activate_followup(user, business, item_id, channel="in_app", lang="bn", play=False):
    """Approved follow-up item -> an ENABLED RetentionAutomation (created or
    updated). Validation, server maximums and the audit trail are retention's
    own. Returns (automation dict, problem)."""
    from . import retention_service as RS
    from .logic import retention as R
    from .models import RetentionAutomation
    plan = get_plan(user, business)
    it = find_item(plan, item_id)
    if it is None:
        return None, "not_found"
    if it.get("kind") != "followup" or it.get("followup_kind") not in M.FOLLOWUP_KINDS:
        return None, "not_followup"
    if it.get("status") != "approved":
        return None, "approve_first"
    st = retention_state(user, play)
    if not st["flag"]:
        return None, "retention_off"
    if not st["plan_ok"]:
        return None, "upgrade_required"
    bn, en = _template_from_item(it, lang)
    body = {"kind": it["followup_kind"], "channel": channel or R.CH_IN_APP,
            "name": (it.get("title") or "")[:R.MAX_NAME], "params": it.get("params") or {},
            "template_bn": bn, "template_en": en, "send_hour": R.DEFAULT_SEND_HOUR,
            "enabled": True}
    clean, problems = R.validate(body, channels_ready=RS.channels_ready(business))
    if problems:
        return None, problems[0]
    existing = None
    if it.get("automation_id"):
        existing = RetentionAutomation.objects.filter(pk=it["automation_id"], business=business).first()
    if existing is None:
        if RetentionAutomation.objects.filter(business=business).count() >= RS.cfg()["max_automations"]:
            return None, "too_many"
        a = RetentionAutomation.objects.create(business=business, **clean)
        RS.audit_change(business, user, None, a)
    else:
        before = {k: getattr(existing, k) for k in ("enabled", "params", "template_bn", "template_en",
                                                    "channel", "send_hour", "name", "wa_template")}
        for k, v in clean.items():
            setattr(existing, k, v)
        existing.save()
        a = existing
        RS.audit_change(business, user, before, a)
    it["automation_id"] = a.id
    it["activated_at"] = timezone.now().isoformat()
    _store_plan(user, business, plan)
    return {"id": a.id, "kind": a.kind, "enabled": a.enabled, "channel": a.channel}, None


def automation_status(business, plan):
    """Live on/off of each activated follow-up (the owner may switch it off in
    the retention screen — this screen must agree)."""
    from .models import RetentionAutomation
    ids = [it.get("automation_id") for it in (plan or {}).get("items") or [] if it.get("automation_id")]
    if not ids:
        return {}
    return {a.id: a.enabled for a in RetentionAutomation.objects.filter(business=business, id__in=ids)}


# ------------------------------------------------------------------ publish
def _page_channel(business):
    from .models import SellerChannel
    return (SellerChannel.objects.filter(business=business, kind="messenger", enabled=True,
                                         test_mode=False, status="connected")
            .exclude(token_enc="").order_by("id").first())


def publish_state(business):
    """Honest readiness of one-tap Facebook publishing."""
    approved = False
    try:
        from . import integrations
        approved = bool((integrations.get("meta_app") or {}).get("page_publish_approved"))
    except Exception:  # noqa: BLE001
        approved = False
    ch = _page_channel(business) if approved else None
    if not approved:
        reason = "meta_review_pending"
    elif ch is None:
        reason = "page_not_connected"
    else:
        reason = ""
    return {"facebook": reason == "", "instagram": False, "reason": reason,
            "page": ch.display_name if ch else ""}


def publish(user, business, item_id):
    """Post an APPROVED text item to the shop's Facebook Page. Returns
    (result, problem). Never claims success without a Graph post id."""
    from . import bizagent_graph as G
    from . import bizagent_service as BS
    plan = get_plan(user, business)
    it = find_item(plan, item_id)
    if it is None:
        return None, "not_found"
    if it.get("status") != "approved":
        return None, "approve_first"
    st = publish_state(business)
    if not st["facebook"]:
        return None, st["reason"]
    ch = _page_channel(business)
    token = BS.channel_token(ch)
    if not token:
        return None, "page_not_connected"
    status, body = G._transport("POST", "%s/%s/feed" % (G.base_url(), ch.external_id),
                                {"Content-Type": "application/json",
                                 "Authorization": "Bearer %s" % token},
                                {"message": it["body"]})
    pid = (body or {}).get("id") if isinstance(body, dict) else None
    if status != 200 or not pid:
        err = ((body or {}).get("error") or {}).get("message", "") if isinstance(body, dict) else ""
        log.warning("mktengine publish failed status=%s %s", status, err[:120])
        return None, "publish_failed"
    it["published"] = {"facebook": str(pid), "at": timezone.now().isoformat()}
    _store_plan(user, business, plan)
    return {"id": str(pid)}, None
