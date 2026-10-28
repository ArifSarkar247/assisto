"""crm100 — ONE customer history page + one customer list.

Everything a seller knows about one customer, from their OWN business data
only: khata entries and the due, POS sales, online orders with payment
status, AI sales chats, CRM leads / deals / tasks / notes, price quotes,
messages sent from the CRM and tagada SMS. One person = one normalised
phone (business_selling.normalize_phone). A khata customer or lead without
a phone is still shown on its own (anchor-only).

Scope (never another shop's data):
  * shop data: the business the requester owns or is ACTIVE staff of
    (core.business_views.resolve_business with ?business=<id>; else their
    own profile — never auto-created on a read);
  * CRM data: only orgs the requester is a member of;
  * customer book only (the supplier book is owner-only and is not a
    "customer"); no cost / profit / minimum price anywhere.

Speed (500+ customers): every source is one bounded query; phone matching
uses `phone__endswith=<last 4 digits>` inside the shop's own rows and then
an exact normalised compare in Python, so "01712-345678", "+8801712345678"
and "01712345678" are the same person. The timeline is cursor-paged
(`before` = ISO time of the last item shown).

The server returns codes + numbers; the app renders every word (bn / en).
"""
from datetime import datetime, timezone as dt_timezone

from django.db.models import Count, Max, Q, Sum
from django.utils import timezone
from django.utils.dateparse import parse_datetime

DEFAULT_LIMIT, MAX_LIMIT = 40, 100
SOURCES = ("khata", "sale", "order", "chat", "lead", "deal", "activity",
           "quote", "message", "sms")
OPEN_ORDER = ("new", "confirmed", "packed", "shipped")


class Scope:
    def __init__(self, user, business=None, role=None, org_ids=()):
        self.user = user
        self.business = business
        self.role = role
        self.org_ids = list(org_ids)

    @property
    def owner(self):
        return self.business.user if self.business is not None else None


def scope_for(request):
    """(Scope, None) or (None, error Response) for a bad ?business=."""
    from core import business_views as BV
    from .models import CrmMember
    org_ids = list(CrmMember.objects.filter(user=request.user)
                   .values_list("org_id", flat=True))
    bid = request.query_params.get("business")
    if not bid and request.method == "POST":
        try:
            bid = request.data.get("business")
        except Exception:  # noqa: BLE001
            bid = None
    if bid:
        prof, role = BV.resolve_business(request)
        if prof is None:
            return None, BV._require_business(request)[2]
        return Scope(request.user, prof, role, org_ids), None
    prof = getattr(request.user, "business", None) if _has_business(request.user) else None
    return Scope(request.user, prof, "owner" if prof else None, org_ids), None


def _has_business(user):
    from core.models import BusinessProfile
    return BusinessProfile.objects.filter(user=user).exists()


# ------------------------------------------------------------------ phones
def phone_key(phone):
    from core.logic.business_selling import normalize_phone
    from core.logic.business_khata import normalize_digits
    k = normalize_phone(normalize_digits(str(phone or "")))
    return k if len(k) >= 6 else ""


def _match(qs, field, key):
    """Rows of `qs` whose `field` normalises to `key` (bounded by the
    last-4-digits suffix filter, exact compare in Python)."""
    if not key:
        return []
    rows = qs.filter(**{field + "__endswith": key[-4:]})
    return [r for r in rows if phone_key(getattr(r, field)) == key]


def _ids_match(qs, field, key, *extra):
    if not key:
        return []
    out = []
    for row in qs.filter(**{field + "__endswith": key[-4:]}).values_list("id", field, *extra):
        if phone_key(row[1]) == key:
            out.append(row)
    return out


def _iso(dt):
    return dt.isoformat() if dt else None


def _p(v):
    from core.logic.business_selling import taka_to_poisha
    return taka_to_poisha(v or 0)


def _cut(s, n=160):
    s = str(s or "")
    return s if len(s) <= n else s[: n - 1] + "…"


# ------------------------------------------------------------------ identity
class Person:
    """Who we are looking at: the phone key + the rows that are them."""

    def __init__(self, key="", name="", phone=""):
        self.key, self.name, self.phone = key, name, phone
        self.party_ids, self.customer_ids, self.order_ids = [], [], []
        self.thread_ids, self.lead_ids = [], []


def resolve(scope, params):
    """Build the Person from ?phone= | ?party= | ?lead= | ?customer= |
    ?order=. Returns (Person, None) or (None, "not_found")."""
    from core.models import Customer, KhataParty, Order
    from .models import Lead
    prof = scope.business
    p = Person()
    anchor_party = anchor_lead = None
    raw_phone = str(params.get("phone") or "").strip()
    if params.get("party"):
        if prof is None:
            return None, "not_found"
        anchor_party = KhataParty.objects.filter(
            business=prof, book="customer", pk=_int(params.get("party"))).first()
        if anchor_party is None:
            return None, "not_found"
        raw_phone = raw_phone or anchor_party.phone
        p.name = anchor_party.name
    elif params.get("lead"):
        anchor_lead = Lead.objects.filter(org_id__in=scope.org_ids,
                                          pk=_int(params.get("lead"))).first()
        if anchor_lead is None:
            return None, "not_found"
        raw_phone = raw_phone or anchor_lead.phone or anchor_lead.whatsapp
        p.name = anchor_lead.name or anchor_lead.company
    elif params.get("customer"):
        c = Customer.objects.filter(user=scope.owner, pk=_int(params.get("customer"))).first() \
            if prof is not None else None
        if c is None:
            return None, "not_found"
        raw_phone, p.name = raw_phone or c.phone, c.name
    elif params.get("order"):
        o = Order.objects.filter(user=scope.owner, pk=_int(params.get("order"))).first() \
            if prof is not None else None
        if o is None:
            return None, "not_found"
        raw_phone, p.name = raw_phone or o.customer_phone, o.customer_name
    p.key = phone_key(raw_phone)
    p.phone = raw_phone
    if not p.key and anchor_party is None and anchor_lead is None:
        return None, "not_found"
    if prof is not None:
        parties = KhataParty.objects.filter(business=prof, book="customer")
        p.party_ids = [r[0] for r in _ids_match(parties, "phone", p.key)]
        if anchor_party is not None and anchor_party.id not in p.party_ids:
            p.party_ids.append(anchor_party.id)
        if p.key:
            p.customer_ids = list(Customer.objects.filter(
                user=prof.user, phone_key=p.key).filter(
                Q(business=prof) | Q(business__isnull=True)).values_list("id", flat=True))
            p.order_ids = [r[0] for r in _ids_match(
                Order.objects.filter(user=prof.user).filter(
                    Q(business=prof) | Q(business__isnull=True)), "customer_phone", p.key)]
            from core.models import ChatThread
            p.thread_ids = [r[0] for r in _ids_match(
                ChatThread.objects.filter(user=prof.user).filter(
                    Q(business=prof) | Q(business__isnull=True)), "customer_phone", p.key)]
    if scope.org_ids:
        leads = Lead.objects.filter(org_id__in=scope.org_ids)
        ids = {r[0] for r in _ids_match(leads, "phone", p.key)}
        ids |= {r[0] for r in _ids_match(leads, "whatsapp", p.key)}
        if anchor_lead is not None:
            ids.add(anchor_lead.id)
        p.lead_ids = sorted(ids)
    if not p.name:
        p.name = _best_name(p)
    return p, None


def _int(v, d=0):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return d


def _best_name(p):
    from core.models import Customer, KhataParty, Order
    from .models import Lead
    for model, ids, field in ((KhataParty, p.party_ids, "name"),
                              (Customer, p.customer_ids, "name"),
                              (Order, p.order_ids, "customer_name")):
        if ids:
            n = (model.objects.filter(pk__in=ids).exclude(**{field: ""})
                 .values_list(field, flat=True).first())
            if n:
                return n
    if p.lead_ids:
        lead = Lead.objects.filter(pk__in=p.lead_ids).first()
        if lead:
            return lead.name or lead.company
    return ""


# ------------------------------------------------------------------ summary
def summary(scope, p, now=None):
    from core.models import (ChatThread, KhataEntry, Order, Sale, SmsLog)
    from .models import Activity, CustomerMessage, Deal, Lead, ShopQuote
    from . import shop_quote as SQ
    now = now or timezone.now()
    prof = scope.business
    out = {"name": p.name, "phone": p.phone, "phone_key": p.key,
           "sources": [], "khata_due_poisha": 0, "khata_parties": p.party_ids,
           "orders_count": 0, "orders_open": 0, "orders_cod_to_collect_poisha": 0,
           "orders_returned": 0, "orders_payment_to_check": 0,
           "sales_count": 0, "sales_total_poisha": 0, "sales_due_poisha": 0,
           "chats_count": len(p.thread_ids), "last_chat_at": None,
           "leads": [], "deals_open": 0, "tasks_open": 0, "quotes_open": 0,
           "last_contact_at": None, "opted_out": False,
           "role": scope.role or "", "has_business": prof is not None,
           "has_crm": bool(scope.org_ids)}
    last = []
    if p.party_ids:
        out["sources"].append("khata")
        agg = KhataEntry.objects.filter(party_id__in=p.party_ids).aggregate(
            gave=Sum("amount_poisha", filter=Q(direction="gave")),
            got=Sum("amount_poisha", filter=Q(direction="got")), last=Max("at"))
        out["khata_due_poisha"] = int(agg["gave"] or 0) - int(agg["got"] or 0)
        last.append(agg["last"])
    if p.customer_ids:
        sales = Sale.objects.filter(customer_id__in=p.customer_ids, voided_at__isnull=True)
        agg = sales.aggregate(n=Count("id"), total=Sum("total"), due=Sum("due"),
                              last=Max("created_at"))
        if agg["n"]:
            out["sources"].append("sale")
            out.update(sales_count=agg["n"], sales_total_poisha=int(agg["total"] or 0),
                       sales_due_poisha=int(agg["due"] or 0))
            last.append(agg["last"])
    if p.order_ids:
        out["sources"].append("order")
        rows = list(Order.objects.filter(pk__in=p.order_ids).values(
            "status", "payment", "payment_status", "total", "created_at"))
        out["orders_count"] = len(rows)
        for r in rows:
            if r["status"] in OPEN_ORDER:
                out["orders_open"] += 1
                if (r["payment"] or "cod") == "cod":
                    out["orders_cod_to_collect_poisha"] += _p(r["total"])
            if r["status"] == "returned":
                out["orders_returned"] += 1
            if r["payment_status"] == "pending_verification":
                out["orders_payment_to_check"] += 1
        last.append(max(r["created_at"] for r in rows))
    if p.thread_ids:
        out["sources"].append("chat")
        lc = ChatThread.objects.filter(pk__in=p.thread_ids).aggregate(
            m=Max("last_message_at"), c=Max("created_at"))
        out["last_chat_at"] = _iso(lc["m"] or lc["c"])
        last.append(lc["m"] or lc["c"])
    if p.lead_ids:
        out["sources"].append("crm")
        out["leads"] = [{"id": r["id"], "org": r["org_id"], "name": r["name"] or r["company"],
                         "status": r["status"], "score": r["score"]}
                        for r in Lead.objects.filter(pk__in=p.lead_ids).values(
                            "id", "org_id", "name", "company", "status", "score")]
        out["deals_open"] = Deal.objects.filter(lead_id__in=p.lead_ids, state="open").count()
        out["tasks_open"] = Activity.objects.filter(lead_id__in=p.lead_ids, kind="task",
                                                    done=False).count()
        last.append(Activity.objects.filter(lead_id__in=p.lead_ids).aggregate(
            m=Max("created_at"))["m"])
    if prof is not None and p.key:
        qs = ShopQuote.objects.filter(business=prof, phone_key=p.key)
        out["quotes_open"] = sum(1 for q in qs.filter(state__in=SQ.OPEN_STATES)
                                 if SQ.effective_state(q, now) in SQ.OPEN_STATES)
    if p.key:
        mq = CustomerMessage.objects.filter(phone_key=p.key).filter(_msg_scope(scope))
        last.append(mq.aggregate(m=Max("created_at"))["m"])
        if prof is not None:
            canon = _canon(p.key)
            if canon:
                last.append(SmsLog.objects.filter(business=prof, phone=canon,
                                                  purpose="tagada").aggregate(
                    m=Max("created_at"))["m"])
            try:
                from core.logic import msg_guard as MG
                out["opted_out"] = bool(MG.is_opted_out(prof.pk, p.key))
            except Exception:  # noqa: BLE001
                pass
    vals = [x for x in last if x]
    out["last_contact_at"] = _iso(max(vals)) if vals else None
    return out


def _msg_scope(scope):
    q = Q(pk__in=[])
    if scope.business is not None:
        q |= Q(business=scope.business)
    if scope.org_ids:
        q |= Q(org_id__in=scope.org_ids, business__isnull=True)
    return q


def _canon(key):
    from core.otp import normalize_bd_phone
    try:
        return normalize_bd_phone(key) or ""
    except Exception:  # noqa: BLE001
        return ""


# ------------------------------------------------------------------ timeline
def _before(qs, field, before):
    return qs.filter(**{field + "__lt": before}) if before else qs


def timeline(scope, p, before=None, limit=DEFAULT_LIMIT, kinds=None, now=None):
    """(items newest first, next_before or None)."""
    from core.models import (ChatThread, KhataEntry, Message as ChatMessage, Order,
                             Sale, SmsLog)
    from .models import Activity, CustomerMessage, Deal, Lead, ShopQuote
    from . import shop_quote as SQ
    now = now or timezone.now()
    limit = max(1, min(MAX_LIMIT, int(limit or DEFAULT_LIMIT)))
    want = set(kinds or SOURCES) & set(SOURCES)
    n = limit + 1
    items, more = [], False

    def take(rows, build):
        nonlocal more
        rows = list(rows[:n])
        if len(rows) > limit:
            more = True
            rows = rows[:limit]
        for r in rows:
            items.append(build(r))

    prof = scope.business
    if "khata" in want and p.party_ids:
        take(_before(KhataEntry.objects.filter(party_id__in=p.party_ids), "at", before)
             .order_by("-at", "-id"),
             lambda e: {"kind": "khata", "at": _iso(e.at), "dir": e.direction,
                        "amount_poisha": e.amount_poisha, "note": _cut(e.note),
                        "ref": {"type": "party", "id": e.party_id}, "id": "k%d" % e.id})
    if "sale" in want and p.customer_ids:
        take(_before(Sale.objects.filter(customer_id__in=p.customer_ids), "created_at",
                     before).order_by("-created_at", "-id"),
             lambda s: {"kind": "sale", "at": _iso(s.created_at),
                        "amount_poisha": s.total, "due_poisha": s.due,
                        "payment": s.payment_method, "voided": s.voided_at is not None,
                        "ref": {"type": "sale", "id": s.id}, "id": "s%d" % s.id})
    if "order" in want and p.order_ids:
        take(_before(Order.objects.filter(pk__in=p.order_ids), "created_at", before)
             .order_by("-created_at", "-id"),
             lambda o: {"kind": "order", "at": _iso(o.created_at),
                        "amount_poisha": _p(o.total), "status": o.status,
                        "payment": o.payment, "payment_status": o.payment_status,
                        "channel": o.channel, "items": len(o.items or []),
                        "first_item": _cut((o.items or [{}])[0].get("name", ""), 60)
                        if o.items else "",
                        "ref": {"type": "order", "id": o.id}, "id": "o%d" % o.id})
    if "chat" in want and p.thread_ids:
        threads = (ChatThread.objects.filter(pk__in=p.thread_ids)
                   .annotate(n_msgs=Count("messages")))
        rows = []
        for t in threads:
            at = t.last_message_at or t.created_at
            if before and at >= before:
                continue
            rows.append((at, t))
        rows.sort(key=lambda x: x[0], reverse=True)
        last_text = {}
        for tid in [t.id for _, t in rows[:n]]:
            m = (ChatMessage.objects.filter(thread_id=tid).order_by("-created_at", "-id")
                 .values("text", "direction", "is_ai").first())
            last_text[tid] = m or {}
        take([t for _, t in rows],
             lambda t: {"kind": "chat", "at": _iso(t.last_message_at or t.created_at),
                        "channel": t.channel, "messages": t.n_msgs,
                        "last_text": _cut(last_text.get(t.id, {}).get("text", ""), 140),
                        "last_dir": last_text.get(t.id, {}).get("direction", ""),
                        "last_ai": bool(last_text.get(t.id, {}).get("is_ai")),
                        "opted_out": t.opted_out,
                        "ref": {"type": "thread", "id": t.id}, "id": "c%d" % t.id})
    if p.lead_ids:
        if "lead" in want:
            take(_before(Lead.objects.filter(pk__in=p.lead_ids), "created_at", before)
                 .order_by("-created_at"),
                 lambda l: {"kind": "lead", "at": _iso(l.created_at),
                            "status": l.status, "source": l.source,
                            "name": l.name or l.company,
                            "ref": {"type": "lead", "id": l.id, "org": l.org_id},
                            "id": "l%d" % l.id})
        if "deal" in want:
            take(_before(Deal.objects.filter(lead_id__in=p.lead_ids).select_related("stage"),
                         "updated_at", before).order_by("-updated_at"),
                 lambda d: {"kind": "deal", "at": _iso(d.updated_at), "title": _cut(d.title, 80),
                            "amount_poisha": _p(d.value), "state": d.state,
                            "stage": d.stage.name if d.stage_id else "",
                            "next_step": _cut(d.next_step, 80),
                            "ref": {"type": "deal", "id": d.id}, "id": "d%d" % d.id})
        if "activity" in want:
            take(_before(Activity.objects.filter(lead_id__in=p.lead_ids), "created_at",
                         before).order_by("-created_at", "-id"),
                 lambda a: {"kind": "activity", "at": _iso(a.created_at), "sub": a.kind,
                            "subject": _cut(a.subject, 80), "body": _cut(a.body),
                            "done": a.done, "due_at": _iso(a.due_at),
                            "ref": {"type": "lead", "id": a.lead_id}, "id": "a%d" % a.id})
    if "quote" in want and prof is not None and p.key:
        take(_before(ShopQuote.objects.filter(business=prof, phone_key=p.key), "created_at",
                     before).order_by("-created_at"),
             lambda q: {"kind": "quote", "at": _iso(q.created_at),
                        "state": SQ.effective_state(q, now),
                        "amount_poisha": q.total_poisha, "items": len(q.items or []),
                        "order": q.order_id, "valid_until": _iso(q.valid_until),
                        "ref": {"type": "quote", "id": q.id}, "id": "q%d" % q.id})
    if "message" in want and p.key:
        take(_before(CustomerMessage.objects.filter(phone_key=p.key).filter(_msg_scope(scope)),
                     "created_at", before).order_by("-created_at", "-id"),
             lambda m: {"kind": "message", "at": _iso(m.created_at), "channel": m.channel,
                        "status": m.status, "reason": m.reason, "purpose": m.purpose,
                        "text": _cut(m.text), "credits": m.credits,
                        "ref": {"type": "message", "id": m.id}, "id": "m%d" % m.id})
    if "sms" in want and prof is not None and p.key:
        canon = _canon(p.key)
        if canon:
            take(_before(SmsLog.objects.filter(business=prof, phone=canon, purpose="tagada"),
                         "created_at", before).order_by("-created_at", "-id"),
                 lambda s: {"kind": "sms", "at": _iso(s.created_at), "purpose": s.purpose,
                            "status": s.status, "reason": s.reason, "credits": s.credits,
                            "ref": {"type": "sms", "id": s.id}, "id": "t%d" % s.id})
    items.sort(key=lambda x: (x["at"] or ""), reverse=True)
    if len(items) > limit:
        more = True
        items = items[:limit]
    nxt = items[-1]["at"] if (more and items) else None
    return items, nxt


def parse_before(v):
    if not v:
        return None
    dt = parse_datetime(str(v))
    if dt is None:
        return None
    if timezone.is_naive(dt):
        dt = timezone.make_aware(dt)
    return dt


# ------------------------------------------------------------------ directory
def directory(scope, q="", limit=50, offset=0, only=None):
    """One merged customer list: khata customers, till customers, order
    customers, AI-chat customers and CRM leads — one row per person."""
    from core.models import ChatThread, Customer, KhataEntry, KhataParty, Order
    from .models import Lead
    prof = scope.business
    rows = {}

    def row(key, fallback_id):
        k = key or fallback_id
        if k not in rows:
            rows[k] = {"key": k, "phone_key": key, "phone": "", "name": "",
                       "sources": [], "due_poisha": 0, "orders": 0,
                       "last_at": None, "party_id": None, "lead_id": None,
                       "lead_org": None}
        return rows[k]

    def bump(r, at):
        if at and (r["last_at"] is None or at > r["last_at"]):
            r["last_at"] = at

    def src(r, s):
        if s not in r["sources"]:
            r["sources"].append(s)

    if prof is not None:
        parties = list(KhataParty.objects.filter(business=prof, book="customer",
                                                 archived=False)
                       .values("id", "name", "phone"))
        agg = {r["party_id"]: r for r in KhataEntry.objects.filter(
            party__business=prof, party__book="customer").order_by().values("party_id").annotate(
            gave=Sum("amount_poisha", filter=Q(direction="gave")),
            got=Sum("amount_poisha", filter=Q(direction="got")), last=Max("at"))}
        for pr in parties:
            r = row(phone_key(pr["phone"]), "party:%d" % pr["id"])
            src(r, "khata")
            a = agg.get(pr["id"]) or {}
            r["due_poisha"] += int(a.get("gave") or 0) - int(a.get("got") or 0)
            r["party_id"] = r["party_id"] or pr["id"]
            r["name"] = r["name"] or pr["name"]
            r["phone"] = r["phone"] or pr["phone"]
            bump(r, a.get("last"))
        for c in (Customer.objects.filter(user=prof.user)
                  .filter(Q(business=prof) | Q(business__isnull=True))
                  .order_by().annotate(last=Max("sales__created_at")).values("id", "name", "phone",
                                                                 "phone_key", "last")):
            key = phone_key(c["phone_key"] or c["phone"])
            if not key:
                continue
            r = row(key, "cust:%d" % c["id"])
            src(r, "sale")
            r["name"] = r["name"] or c["name"]
            r["phone"] = r["phone"] or c["phone"]
            bump(r, c["last"])
        for o in (Order.objects.filter(user=prof.user)
                  .filter(Q(business=prof) | Q(business__isnull=True))
                  .exclude(customer_phone="").order_by().values("customer_phone")
                  .annotate(n=Count("id"), last=Max("created_at"),
                            nm=Max("customer_name"))):
            key = phone_key(o["customer_phone"])
            if not key:
                continue
            r = row(key, "")
            src(r, "order")
            r["orders"] += o["n"]
            r["name"] = r["name"] or (o["nm"] or "")
            r["phone"] = r["phone"] or o["customer_phone"]
            bump(r, o["last"])
        for t in (ChatThread.objects.filter(user=prof.user)
                  .filter(Q(business=prof) | Q(business__isnull=True))
                  .exclude(customer_phone="").order_by().values("customer_phone")
                  .annotate(last=Max("last_message_at"), nm=Max("customer_name"))):
            key = phone_key(t["customer_phone"])
            if not key:
                continue
            r = row(key, "")
            src(r, "chat")
            r["name"] = r["name"] or (t["nm"] or "")
            r["phone"] = r["phone"] or t["customer_phone"]
            bump(r, t["last"])
    if scope.org_ids:
        for ld in Lead.objects.filter(org_id__in=scope.org_ids).values(
                "id", "org_id", "name", "company", "phone", "whatsapp", "updated_at"):
            key = phone_key(ld["phone"] or ld["whatsapp"])
            r = row(key, "lead:%d" % ld["id"])
            src(r, "crm")
            r["lead_id"] = r["lead_id"] or ld["id"]
            r["lead_org"] = r["lead_org"] or ld["org_id"]
            r["name"] = r["name"] or ld["name"] or ld["company"]
            r["phone"] = r["phone"] or ld["phone"] or ld["whatsapp"]
            bump(r, ld["updated_at"])
    out = list(rows.values())
    if only:
        out = [r for r in out if only in r["sources"] or
               (only == "due" and r["due_poisha"] > 0)]
    qq = str(q or "").strip().lower()
    if qq:
        from core.logic.business_khata import normalize_digits
        qd = "".join(ch for ch in normalize_digits(qq) if ch.isdigit())
        out = [r for r in out if qq in (r["name"] or "").lower() or
               (qd and len(qd) >= 3 and qd in (r["phone_key"] or ""))]
    far = datetime(1970, 1, 1, tzinfo=dt_timezone.utc)
    out.sort(key=lambda r: (r["last_at"] or far, r["name"]), reverse=True)
    total = len(out)
    limit = max(1, min(200, int(limit or 50)))
    offset = max(0, int(offset or 0))
    page = out[offset: offset + limit]
    for r in page:
        r["last_at"] = _iso(r["last_at"])
    return {"results": page, "total": total, "offset": offset, "limit": limit,
            "next_offset": offset + limit if offset + limit < total else None}
