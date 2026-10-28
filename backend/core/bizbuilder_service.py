"""
WP-BIZBUILDER — the business agent builder (service layer).

The shop owner writes instructions, tone, FAQs, hours, hand-over rules,
delivery charges and minimum prices in plain Bangla / Banglish / English; the
pure parser (core.logic.bizbuilder) turns them into a VERSIONED agent card
(BizAgentCard). One card per shop is live ("published"); the builder edits one
"draft"; history rows are "archived" and can be rolled back.

How the live card reaches the existing sales agent (core.bizagent_service):
  * publish() SYNCS the shared settings the agent already uses — tone, hours,
    who-replies mode, takeover idle timeout (SellerAgent), delivery charges
    (OwnerPolicy) and minimum prices (Product.min_price) — so the setup
    screen, the order pricing and the number post-check all agree;
  * the rest is read at reply time through small hooks: card FAQs in the
    rule-first FAQ list, the owner's greeting/address/tone (style()), the
    hand-over keywords and big-order limit, the bargaining floor (only ever
    RAISED), style notes as fenced DATA in the LLM prompt.

TEST CHAT / PREVIEW: the real compose() runs inside a transaction that is
ALWAYS rolled back, with bizagent_service.SANDBOX set, so nothing can be sent
to a customer or pushed to the owner (send_* raise, notify_seller records);
the draft card is applied inside that transaction only. The AI router is used
only when the owner asks ("use AI"), pre-paid as ONE ai_sales reply outside
the rolled-back transaction and refunded when no AI answer was used.
"""
import logging
import uuid
from datetime import timedelta

from django.core.cache import cache
from django.db import transaction
from django.db.models import Max
from django.utils import timezone

from . import bizagent_service as S
from .logic import bizagent as BZ
from .logic import bizbuilder as BB
from .logic import business_ai as bai

log = logging.getLogger(__name__)

RISK_CARD = "card_keyword"
FLAG = "business_agent"
TEST_TTL = 3600
TEST_TURNS = 24
_MISS = object()

FORM_KEYS = ("instructions", "tone", "greeting", "address_term", "faqs", "hours", "hours_text",
             "reply_mode", "delivery", "delivery_text", "takeover_text", "takeover_keywords",
             "big_order_over", "idle_minutes", "pause_on_handoff", "max_discount_pct",
             "no_discount", "min_prices")


# ===================================================================== live card
def card_for(business):
    """The shop's LIVE card (dict) or None. Memoised on the instance for one
    message / request."""
    if business is None:
        return None
    c = getattr(business, "_bb_card", _MISS)
    if c is _MISS:
        from .models import BizAgentCard
        c = BizAgentCard.objects.filter(business=business, status="published") \
            .order_by("-version").values_list("card", flat=True).first() or None
        business._bb_card = c
    return c


def forget(business):
    if business is not None and hasattr(business, "_bb_card"):
        del business._bb_card


def floor_for(business, product):
    return BB.floor_for(card_for(business), product)


def big_order_limit(business):
    return BB.big_order_limit(card_for(business), bai.BIG_ORDER_THRESHOLD)


def handoff_keyword(business, text):
    return BB.handoff_keyword(card_for(business), text)


def _first_reply(thread, hours=12):
    since = timezone.now() - timedelta(hours=hours)
    return not thread.messages.filter(direction="out", created_at__gte=since).exists()


def style(business, thread, d, lang):
    """Greeting / address / tone on the customer-facing text of a compose()
    result. Never touches the seller's proposal; never adds a digit."""
    card = card_for(business)
    if not card or not d.get("text"):
        return d
    if d.get("risk"):
        kind = "holding"
    elif d.get("kind") == "order":
        kind = "order"
    else:
        kind = "text"
    rule = d.get("rule") or ""
    if d["text"] == bai.assistant_disclosure(lang)["full"]:
        rule = "disclosure"
    try:
        first = _first_reply(thread)
    except Exception:  # noqa: BLE001 — styling never breaks a reply
        first = False
    d["text"] = BB.style_reply(d["text"], card, lang, first=first, kind=kind, rule=rule)
    return d


def after_handoff(thread, risk):
    """The card's "pause the agent in that chat after a hand-over" rule."""
    card = card_for(thread.business)
    if not card or not risk or risk == "seller_approves_all":
        return
    if (card.get("takeover") or {}).get("pause_on_handoff") and not thread.owner_takeover:
        from . import bizagent_guard as GD
        GD.take_over(thread, actor=None)
        GD.audit(thread.business, "card_pause", thread=thread, reason=risk)


# ===================================================================== form + versions
def clean_form(form):
    """Only known keys, bounded sizes (the owner's text is stored as DATA)."""
    f = {}
    for k in FORM_KEYS:
        if k not in (form or {}):
            continue
        v = form[k]
        if k == "faqs":
            rows = []
            for r in (v or [])[:BB.MAX_FAQS * 2]:
                if isinstance(r, dict):
                    rows.append({"q": str(r.get("q") or "")[:BB.MAX_Q + 50],
                                 "a": str(r.get("a") or "")[:BB.MAX_A + 50]})
            f[k] = rows
        elif k in ("hours", "delivery"):
            f[k] = {str(a)[:20]: str(b)[:20] for a, b in (v or {}).items()} if isinstance(v, dict) else {}
        elif k == "min_prices":
            f[k] = {str(a)[:12]: str(b)[:14] for a, b in (v or {}).items()} if isinstance(v, dict) else {}
        elif k == "takeover_keywords":
            f[k] = [str(x)[:40] for x in v][:BB.MAX_KEYWORDS] if isinstance(v, list) else str(v or "")[:800]
        elif isinstance(v, bool) or v is None:
            f[k] = v
        else:
            f[k] = str(v)[:BB.MAX_TEXT if k == "instructions" else 1000]
    return f


def build(business, form):
    return BB.build_card(form, S.catalog_for(business))


def _next_version(business):
    from .models import BizAgentCard
    return (BizAgentCard.objects.filter(business=business).aggregate(m=Max("version"))["m"] or 0) + 1


def draft_row(business):
    from .models import BizAgentCard
    return BizAgentCard.objects.filter(business=business, status="draft").first()


def live_row(business):
    from .models import BizAgentCard
    return BizAgentCard.objects.filter(business=business, status="published").order_by("-version").first()


def save_draft(business, user, form):
    from .models import BizAgentCard
    src = clean_form(form)
    card = build(business, src)
    live = card_for(business)
    with transaction.atomic():
        row = BizAgentCard.objects.select_for_update().filter(business=business, status="draft").first()
        if row is None:
            row = BizAgentCard(business=business, version=_next_version(business), status="draft")
        row.card, row.source, row.changed = card, src, BB.diff(live, card)
        row.created_by = user if getattr(user, "pk", None) else None
        row.save()
    return row


def discard_draft(business):
    from .models import BizAgentCard
    return BizAgentCard.objects.filter(business=business, status="draft").delete()[0]


def sync_to_shop(business, card):
    """Write the card's shared settings where the agent already reads them."""
    from .models import OwnerPolicy, Product
    agent = S.agent_for(business)
    fields = ["tone"]
    agent.tone = card.get("tone") if card.get("tone") in BB.TONES else agent.tone
    if card.get("hours"):
        agent.hours = dict(card["hours"])
        fields.append("hours")
    if card.get("reply_mode") == "outside_hours" and (card.get("hours") or agent.hours):
        agent.ai_mode = "outside_hours"
        fields.append("ai_mode")
    elif card.get("reply_mode") == "always" and agent.ai_mode == "outside_hours":
        agent.ai_mode = "always"
        fields.append("ai_mode")
    idle = (card.get("takeover") or {}).get("idle_minutes")
    if idle is not None:
        agent.takeover_idle_minutes = int(idle)
        fields.append("takeover_idle_minutes")
    agent.save(update_fields=fields + ["updated_at"])
    dl = card.get("delivery") or {}
    if dl:
        pol = business.policies.first() or OwnerPolicy(user=business.user, business=business)
        if BB._dec(dl.get("inside_dhaka")) is not None:
            pol.delivery_inside = BB._dec(dl["inside_dhaka"])
        if BB._dec(dl.get("outside_dhaka")) is not None:
            pol.delivery_outside = BB._dec(dl["outside_dhaka"])
        if "free_over" in dl:
            pol.free_delivery_over = BB._dec(dl.get("free_over")) or None
        pol.save()
    for pid, v in (card.get("min_prices") or {}).items():
        d = BB._dec(v)
        if d is not None and d > 0:
            Product.objects.filter(pk=int(pid), user=business.user, price__gte=d).update(min_price=d)
    return agent


def publish(business, user, row=None):
    """Make the draft (or `row`) the live card. The card is re-built from the
    owner's source text against the CURRENT catalog (a price may have changed
    since the draft was saved). Returns the published row."""
    from . import bizagent_guard as GD
    from .models import BizAgentCard
    with transaction.atomic():
        row = row or BizAgentCard.objects.select_for_update().filter(
            business=business, status="draft").first()
        if row is None:
            return None
        live = card_for(business)
        card = build(business, row.source or {})
        BizAgentCard.objects.filter(business=business, status="published").exclude(pk=row.pk) \
            .update(status="archived")
        row.card, row.changed = card, BB.diff(live, card)
        row.status, row.published_at = "published", timezone.now()
        row.save()
        sync_to_shop(business, card)
    business._bb_card = card
    GD.audit(business, "card_publish", actor=user, version=row.version, changed=row.changed)
    return row


def rollback(business, user, version):
    """Publish a copy of an older version as a NEW version (history kept)."""
    from .models import BizAgentCard
    old = BizAgentCard.objects.filter(business=business, version=int(version)) \
        .exclude(status="draft").first()
    if old is None:
        return None
    discard_draft(business)
    row = save_draft(business, user, old.source or {})
    return publish(business, user, row)


def versions(business, limit=20):
    from .models import BizAgentCard
    return [{"version": r.version, "status": r.status, "changed": r.changed or [],
             "published_at": r.published_at.isoformat() if r.published_at else None,
             "created_at": r.created_at.isoformat()}
            for r in BizAgentCard.objects.filter(business=business).order_by("-version")[:limit]]


def catalog_rows(business):
    """Owner-only: the products the card links to, with their minimum price."""
    return [{"id": p["id"], "name": p["name"], "price": p["price"], "min_price": p["min_price"],
             "stock": p["stock"], "has_min": (BB._dec(p["min_price"]) or 0) > 0}
            for p in S.catalog_for(business)][:300]


def ai_reply_credits():
    try:
        from . import billing
        row = (billing.cfg().get("action_costs") or {}).get("ai_sales") or {}
        return int(row.get("credits") if isinstance(row, dict) else row or 3)
    except Exception:  # noqa: BLE001
        return 3


def _row_out(row, lang):
    if row is None:
        return None
    c = row.card or {}
    return {"version": row.version, "status": row.status, "card": c, "source": row.source or {},
            "summary": BB.summary(c, lang), "changed": row.changed or [],
            "rejected": c.get("rejected") or [], "warnings": c.get("warnings") or [],
            "understood": c.get("understood") or [],
            "published_at": row.published_at.isoformat() if row.published_at else None,
            "updated_at": row.updated_at.isoformat()}


def state(business, user, lang):
    from . import ai
    agent = S.agent_for(business)
    return {"schema": BB.SCHEMA,
            "live": _row_out(live_row(business), lang),
            "draft": _row_out(draft_row(business), lang),
            "versions": versions(business),
            "catalog": catalog_rows(business),
            "agent": {"ai_enabled": agent.ai_enabled, "tone": agent.tone, "hours": agent.hours,
                      "ai_mode": agent.ai_mode, "takeover_idle_minutes": agent.takeover_idle_minutes},
            "ai": {"key_present": ai.key_present(), "credits_per_reply": ai_reply_credits(),
                   "balance": int(getattr(user, "ai_credits", 0) or 0)},
            "hard_rules": hard_rules(lang)}


def hard_rules(lang):
    """What the card can NEVER change (shown in the builder, honest)."""
    rows = (("এজেন্ট সবসময় বলে সে দোকানের এআই সহকারী — কখনো মানুষ নয়।",
             "The agent always says it is the shop's AI assistant — never a human."),
            ("সর্বনিম্ন দাম কখনো গ্রাহককে বলা হয় না, তার নিচে কখনো বিক্রি নয়।",
             "Your minimum price is never told to a customer and never undercut."),
            ("দাম ও স্টক শুধু আপনার ক্যাটালগ থেকে — বানানো সংখ্যা যায় না।",
             "Prices and stock come only from your catalog — no made-up numbers."),
            ("রিফান্ড বা অভিযোগ সবসময় আপনার কাছে আসে।", "Refunds and complaints always come to you."),
            ("STOP লিখলে আর মেসেজ যায় না; ২৪ ঘণ্টার বাইরে শুধু অনুমোদিত টেমপ্লেট।",
             "STOP is always honoured; outside 24 hours only approved templates."),
            ("আপনার লেখা নির্দেশনা শুধু তথ্য — কেউ “সব নিয়ম ভুলে যাও” লিখলেও কিছু বদলায় না।",
             "Your text is data only — “ignore all rules” changes nothing."))
    return [bai.pick(lang, bn, en) for bn, en in rows]


# ===================================================================== sandbox
def _apply_card_in_tx(business, card):
    """INSIDE the rolled-back transaction: make `card` the live card."""
    from .models import BizAgentCard
    BizAgentCard.objects.filter(business=business, status="published").update(status="archived")
    BizAgentCard.objects.create(business=business, version=_next_version(business) + 1000,
                                status="published", card=card)
    sync_to_shop(business, card)
    business._bb_card = card


def _fresh_state(lang="bn"):
    return {"turns": [], "order_draft": {}, "opted_out": False, "takeover": False,
            "disclosed": False, "lang": lang, "id": uuid.uuid4().hex[:12]}


def _test_key(business, session):
    return "bb:test:%s:%s" % (business.pk, "".join(ch for ch in str(session or "")[:40]
                                                   if ch.isalnum() or ch in "-_"))


ORDER_DONE = ("(টেস্ট) এখানে অর্ডারটি নিশ্চিত হতো — আসল চ্যাটে অর্ডার নম্বরসহ ইনভয়েস যেত। "
              "কোনো অর্ডার তৈরি হয়নি, কিছু পাঠানো হয়নি।",
              "(Test) The order would be confirmed here — a real chat gets the invoice with the "
              "order number. No order was created and nothing was sent.")


def _simulate(business, st, text, lang_hint):
    """One customer message through the REAL pipeline decisions (opt-out,
    takeover, who-replies, compose). Runs inside the rolled-back sandbox."""
    from . import bizagent_g1_service as G1S
    from .logic import bizagent_g1 as G1
    from .models import ChatThread, Message
    agent = S.agent_for(business)
    text = (text or "")[:S.MAX_INBOUND]
    lang = BZ.sticky_lang(text, st.get("lang") or lang_hint or "bn") if text else (st.get("lang") or "bn")
    st["lang"] = lang
    now = timezone.now()
    t = ChatThread.objects.create(user=business.user, business=business, channel="website",
                                  external_user_id="builder-test-" + st["id"], customer_name="",
                                  order_draft=dict(st.get("order_draft") or {}), lang=lang,
                                  last_inbound_at=now, last_message_at=now,
                                  ai_disclosed=bool(st.get("disclosed")))
    for turn in st["turns"][-TEST_TURNS:]:
        Message.objects.create(thread=t, direction="in" if turn["who"] == "customer" else "out",
                               text=turn["text"][:2000], is_ai=turn["who"] == "agent",
                               status="received" if turn["who"] == "customer" else "sent")
    Message.objects.create(thread=t, direction="in", text=text, status="received")
    out = {"customer": text, "reply": "", "outcome": "reply", "reason": "", "reason_text": "",
           "proposal": "", "source": "", "rule": "", "owner_push": None, "lang": lang}
    if st.get("opted_out"):
        out.update(outcome="opted_out_silent", reason="opted_out")
        return out, t
    if text and G1.is_opt_out(text):
        st["opted_out"] = True
        out.update(reply=G1.opt_out_ack(lang), outcome="opted_out", source="system")
        return out, t
    if st.get("takeover"):
        out.update(outcome="human", reason="human_mode",
                   reason_text=bai.pick(lang, "আপনি চ্যাটটি নিয়েছেন — এজেন্ট চুপ, আপনার কাছে পুশ যেত।",
                                        "You took over — the agent stays quiet; you would get a push."))
        return out, t
    allowed, why = G1.may_ai_reply(
        mode=agent.ai_mode, ai_enabled=True,
        in_business_hours=G1.in_business_hours(agent.hours, G1S._minute_of_day(now)),
        human_mode=False, paused_until_ts=None, now_ts=now.timestamp())
    if not allowed:
        out.update(outcome="quiet", reason=why,
                   reason_text=bai.pick(lang, "এখন এজেন্ট উত্তর দিত না (আপনার “কে উত্তর দেবে” সেটিং)।",
                                        "The agent would not reply now (your who-replies setting)."))
        return out, t
    d = S.compose(business, agent, t, text, lang)
    out["source"] = d.get("source") or "rule"
    out["rule"] = d.get("rule") or ""
    if d.get("order_action") == "confirm":
        out.update(reply=bai.pick(lang, *ORDER_DONE), outcome="order_confirmed")
        t.order_draft = {}
    elif d.get("risk"):
        risk = d["risk"]
        out.update(reply=d.get("text") or "", outcome="handoff", reason=risk,
                   reason_text=BB.reason_text(risk, lang), proposal=d.get("proposal") or "",
                   owner_push={"title": bai.pick(lang, "অনুমোদন দরকার", "Approval needed"),
                               "body": BB.reason_text(risk, lang)})
        card = card_for(business) or {}
        if risk != "seller_approves_all" and (card.get("takeover") or {}).get("pause_on_handoff"):
            st["takeover"] = True
    else:
        body = d.get("text") or ""
        if body:
            body = BZ.with_disclosure(lang, body, not st.get("disclosed"))
            st["disclosed"] = True
        out["reply"] = body
        if d.get("order_action") == "cancel":
            t.order_draft = {}
    return out, t


def run_sandbox(business, user, texts, *, card=None, state_in=None, allow_ai=False, lang="bn"):
    """Run customer `texts` (in order, one conversation) against `card`
    (None = the live card) with NOTHING persisted or sent. Returns
    (results, state_out, ai_info)."""
    from . import ai, billing
    st = dict(state_in or _fresh_state(lang))
    want_ai = bool(allow_ai) and ai.key_present()
    prepaid = 0
    ai_info = {"key_present": ai.key_present(), "credits_per_reply": ai_reply_credits(),
               "charged": 0, "used": False, "error": ""}
    if want_ai:
        res = billing.charge(user, "ai_sales", qty=1, note="bizagent.builder_test")
        if not res["ok"]:
            want_ai = False
            ai_info["error"] = res.get("reason") or "credits"
        else:
            prepaid = int(res["charged"] or 0)
    sb = {"user": user, "allow_ai": want_ai, "pushes": []}
    token = S.SANDBOX.set(sb)
    results = []
    try:
        with transaction.atomic():
            if card is not None:
                _apply_card_in_tx(business, card)
            for text in texts:
                sb["ai_needed"] = False
                r, t = _simulate(business, st, text, lang)
                r["ai_needed"] = bool(sb.get("ai_needed")) or r["source"] in ("ai", "fallback")
                r["ai_used"] = r["source"] == "ai"
                r["live_credits"] = ai_reply_credits() if r["ai_needed"] else 0
                st["order_draft"] = dict(t.order_draft or {})
                st["turns"].append({"who": "customer", "text": text[:2000]})
                if r["reply"]:
                    st["turns"].append({"who": "agent", "text": r["reply"][:2000]})
                st["turns"] = st["turns"][-TEST_TURNS:]
                results.append(r)
            transaction.set_rollback(True)
    finally:
        S.SANDBOX.reset(token)
        forget(business)
    used = bool(sb.get("ai_used")) and not sb.get("ai_error")
    if prepaid and not used:
        billing.credit(user, "adjust", prepaid, note="bizagent.builder_test_refund")
        prepaid = 0
    if used and sb.get("ai_cost_usd"):
        billing.record_ai_cost_usd(sb["ai_cost_usd"])
    ai_info.update(charged=prepaid, used=used, error=ai_info["error"] or sb.get("ai_error", ""))
    return results, st, ai_info


def default_samples(business, card, lang):
    """The preview's sample customer messages (bn + Banglish + en), built from
    the owner's own catalog / FAQ / hand-over words — never invented facts."""
    cat = S.catalog_for(business)
    p = next((x for x in cat if int(x.get("stock") or 0) > 0), cat[0] if cat else None)
    out = ["আসসালামু আলাইকুম", "ডেলিভারি চার্জ কত?", "dokan koyta porjonto khola?",
           "are you a human?"]
    if p:
        out += ["%s er dam koto?" % p["name"], "%s ৫০০ টাকায় দিবেন?" % p["name"]]
    for f in (card or {}).get("faqs", [])[:2]:
        out.append(f["q"].split("|")[0][:120])
    for k in ((card or {}).get("takeover") or {}).get("keywords", [])[:1]:
        out.append("%s e nite chai" % k)
    out += ["product ta baje, taka ferot chai", "ki ki product ache?"]
    return out[:12]


def preview(business, user, samples=None, *, form=None, lang="bn"):
    """"How the agent would reply": each sample in its OWN fresh chat, with
    the card built from `form` (unsaved) or the draft (else the live card).
    Rule paths only — the AI is never called here (ai_needed + its credit
    cost are shown instead)."""
    if form is not None:
        card = build(business, clean_form(form))
    else:
        row = draft_row(business)
        card = row.card if row else None
    texts = [str(s)[:500] for s in (samples or default_samples(business, card or card_for(business), lang))
             if str(s).strip()][:20]
    out = []
    for text in texts:
        res, _st, _ai = run_sandbox(business, user, [text], card=card, lang=lang)
        out.extend(res)
    return {"card": card, "results": out}


def test_chat(business, user, session, text, *, allow_ai=False, use="draft", reset=False, lang="bn"):
    """The builder's TEST CHAT: one customer message in a multi-turn test
    conversation (state in the cache for an hour). Nothing is sent."""
    key = _test_key(business, session)
    st = None if reset else cache.get(key)
    st = st or _fresh_state(lang)
    card = None
    if use == "draft":
        row = draft_row(business)
        card = row.card if row else None
    if not (text or "").strip():
        cache.set(key, st, TEST_TTL)
        return {"result": None, "turns": st["turns"], "ai": {}}
    res, st, ai_info = run_sandbox(business, user, [text], card=card, state_in=st,
                                   allow_ai=allow_ai, lang=lang)
    cache.set(key, st, TEST_TTL)
    return {"result": res[0], "turns": st["turns"], "ai": ai_info,
            "takeover": st.get("takeover", False), "opted_out": st.get("opted_out", False)}


# ===================================================================== takeover inbox
def takeover_inbox(business, lang, limit=60):
    """Chats that need the owner (attention) + chats the owner holds, with the
    agent's reason. Take over / hand back / reply use the existing endpoints
    (threads/<id>/handover, threads/<id>/send — the same send code as
    WhatsApp/Messenger/website)."""
    from . import bizagent_guard as GD
    from .models import Message
    rows, counts = GD.inbox(business, limit=300)
    out = []
    for t, st, un in rows:
        if st not in (GD.ST_ATTENTION, GD.ST_OWNER):
            continue
        pend = Message.objects.filter(thread=t, status="pending_approval").order_by("-id").first()
        last_in = t.messages.filter(direction="in").order_by("-created_at", "-id").first()
        reason = (pend.risk_reason if pend else "") or ("human_mode" if t.owner_takeover else "")
        out.append({"thread_id": t.id, "customer": t.customer_name or "", "channel": t.channel,
                    "status": st, "unread": un, "owner_takeover": bool(t.owner_takeover),
                    "reason": reason,
                    "reason_text": BB.reason_text(reason, lang) if reason and reason != "human_mode"
                    else bai.pick(lang, "আপনি উত্তর দিচ্ছেন", "You are replying"),
                    "pending_id": pend.id if pend else None,
                    "proposal": (pend.text or "")[:500] if pend else "",
                    "last_message": (last_in.text if last_in else "")[:200],
                    "last_at": t.last_message_at.isoformat() if t.last_message_at else None})
        if len(out) >= limit:
            break
    return {"items": out, "counts": {"attention": counts.get(GD.ST_ATTENTION, 0),
                                     "owner": counts.get(GD.ST_OWNER, 0)}}
