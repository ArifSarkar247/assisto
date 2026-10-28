"""
P1 — Business AI Agent HTTP surface (all under /api/v1/bizagent/).

PUBLIC (Meta calls these; the signature is the auth):
  GET  webhook/meta        hub.challenge verify (verify token from Owner Admin → Meta app)
  POST webhook/meta        Messenger + Page comments + Instagram (X-Hub-Signature-256)
  GET  webhook/whatsapp    hub.challenge verify
  POST webhook/whatsapp    WhatsApp Cloud API messages + statuses
  → idempotent by message id, fast 200, processing right after (worker thread +
    `manage.py bizagent_process` sweep).

SELLER (signed-in business owner; staff may read threads/approvals):
  GET  setup                         everything the setup screen needs
  POST settings                      AI on/off, tone, hours, approvals, delivery, policies
  POST channels                      connect a Page / IG account / WhatsApp number
  POST channels/<id>/toggle          enable/disable one channel
  POST channels/<id>/delete          disconnect (token wiped)
  POST couriers/<courier>            save courier merchant keys (encrypted)
  GET  approvals                     pending risky replies
  POST approvals/<id>/approve        {text?} send (edited text = a human reply)
  POST approvals/<id>/reject
  GET  threads, threads/<id>
  POST threads/<id>/handover {on}    human takes over (AI paused) / resume AI
  POST threads/<id>/send {text}      seller's own reply
  POST threads/<id>/template {name, params}   WhatsApp approved template (outside 24 h)
  POST orders/<id>/book {courier}    real courier booking
  POST orders/<id>/status {status}   manual status (delivered → Sale)
  GET  reports                       daily summaries + today live
  GET  plan, POST plan/trial, POST plan/checkout {plan}
"""
import json
from datetime import timedelta
import logging

from django.http import HttpResponse, JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from rest_framework.response import Response
from rest_framework.views import APIView

from . import bizagent_guard as GD
from . import bizagent_service as S
from .business_views import _require_business, _owner_only, _err
from .i18n import req_lang
from .logic import bizagent as BZ
from .logic import business_ai as bai

log = logging.getLogger(__name__)

MAX_BODY = 1024 * 1024


# =========================================================== webhooks (public)
def _verify_get(request):
    tok = (S.meta_app() or {}).get("verify_token") or ""
    ch = BZ.verify_handshake(request.GET, tok)
    if ch is None:
        return HttpResponse("forbidden", status=403, content_type="text/plain")
    return HttpResponse(ch, content_type="text/plain")


def _webhook(request, source):
    if request.method == "GET":
        return _verify_get(request)
    if request.method != "POST":
        return HttpResponse(status=405)
    raw = request.body or b""
    if len(raw) > MAX_BODY:
        return HttpResponse("too large", status=413)
    try:
        payload = json.loads(raw.decode("utf-8") or "{}")
    except (ValueError, UnicodeDecodeError):
        return HttpResponse("bad json", status=400)
    sig = request.headers.get("X-Hub-Signature-256", "")
    secret = (S.meta_app() or {}).get("app_secret") or ""
    parser = BZ.parse_whatsapp if source == "whatsapp" else BZ.parse_meta
    if BZ.verify_signature(secret, raw, sig):
        ids = S.ingest(source, payload)
    else:
        # self-test path: ONLY test-mode channels, each with its own secret
        ok = [ch for ch, sec in S.test_secrets_for(payload, parser)
              if BZ.verify_signature(sec, raw, sig)]
        if not ok:
            return HttpResponse("bad signature", status=403)
        ids = S.ingest(source, payload, test_only_ids={c.pk for c in ok})
    S.kick(ids)
    return JsonResponse({"ok": True, "queued": len(ids)})


@csrf_exempt
def webhook_meta(request):
    return _webhook(request, "meta")


@csrf_exempt
def webhook_whatsapp(request):
    return _webhook(request, "whatsapp")


# =========================================================== seller API
def _ctx(request, owner=True, cap=None):
    prof, role, bad = _require_business(request)
    if bad:
        return None, None, None, bad
    if owner:
        g = _owner_only(request, role)
        if g:
            return None, None, None, g
    if cap:
        # plans-v2: setting the AI Sales Agent up (switching it on,
        # connecting a channel) needs the shop owner's Business plan.
        from . import entitlements_service as ES
        g = ES.check(prof.user, cap, req_lang(request))
        if g:
            return None, None, None, g
    return prof, role, S.agent_for(prof), None


def _flavour(request):
    v = request.query_params.get("flavour") or (
        request.data.get("flavour") if request.method == "POST" else "")
    return "play" if v == "play" else "apk"


def _channel_row(c):
    return {"id": c.id, "kind": c.kind, "external_id": c.external_id,
            "display_name": c.display_name, "status": c.status,
            "status_detail": c.status_detail, "enabled": c.enabled,
            "test_mode": c.test_mode, "has_token": bool(c.token_enc),
            "connected_at": c.connected_at.isoformat() if c.connected_at else None}


def _catalog_check(prof):
    cat = S.catalog_for(prof)
    th = S.sa_cfg()["low_stock_default"]
    return {"products": len(cat),
            "priced": sum(1 for p in cat if (BZ._dec(p["price"]) or 0) > 0),
            "in_stock": sum(1 for p in cat if int(p["stock"] or 0) > 0),
            "low_stock": BZ.low_stock(cat, th),
            "missing_price": [p["name"] for p in cat if (BZ._dec(p["price"]) or 0) <= 0][:10]}


def _settings_row(a, prof):
    pol = prof.policies.first()
    return {"ai_enabled": a.ai_enabled, "tone": a.tone, "hours": a.hours or {},
            "approve_all": a.approve_all, "cod_enabled": a.cod_enabled,
            "payment_link_enabled": a.payment_link_enabled,
            "low_stock_alert": a.low_stock_alert, "daily_report": a.daily_report,
            "default_courier": a.default_courier,
            # ---- g1 ----
            "ai_mode": a.ai_mode, "resume_minutes": a.resume_minutes,
            "rules_enabled": a.rules_enabled, "quiet_hours": a.quiet_hours or {},
            "morning_summary": a.morning_summary, "morning_hour": a.morning_hour,
            "followups_enabled": a.followups_enabled,
            "followup_after_hours": a.followup_after_hours, "followup_max": a.followup_max,
            "upsell_enabled": a.upsell_enabled, "bundle_rules": a.bundle_rules or [],
            "auto_courier": a.auto_courier, "vision_enabled": a.vision_enabled,
            "voice_enabled": a.voice_enabled, "comment_dm": a.comment_dm,
            # ---- biz-v2 ----
            "takeover_idle_minutes": a.takeover_idle_minutes, "daily_ai_cap": a.daily_ai_cap,
            "thread_daily_cap": a.thread_daily_cap,
            "delivery_inside": str(pol.delivery_inside) if pol else "0",
            "delivery_outside": str(pol.delivery_outside) if pol else "0",
            "free_over": str(pol.free_delivery_over) if pol and pol.free_delivery_over else "",
            "returns": pol.returns if pol else "", "payment_note": pol.payment_note if pol else ""}


def meta_ready():
    m = S.meta_app() or {}
    return {"app": bool(m.get("app_id")), "secret": bool(m.get("app_secret")),
            "verify_token": bool(m.get("verify_token"))}


class SetupView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        cfg = S.sa_cfg()
        return Response({
            "business": {"id": prof.id, "shop_name": prof.shop_name},
            "settings": _settings_row(a, prof),
            "channels": [_channel_row(c) for c in prof.seller_channels.order_by("id")],
            "kill": cfg["kill"], "ai_kill": cfg["ai_kill"],
            "catalog": _catalog_check(prof),
            "couriers": S.courier_state(a),
            "plan": S.plan_status(a, flavour=_flavour(request)),
            "meta_ready": meta_ready(),
            "pending_approvals": prof.chat_threads.filter(
                messages__status="pending_approval").count(),
            "g1": _g1_state(a),
            # ---- biz-v2: what the app may show + today's paid AI calls ----
            "features": GD.features(prof, meta_ready(), _g1_state(a)["vision_ready"]),
            "ai_today": {"used": GD.ai_calls_today(prof), "cap": a.daily_ai_cap},
            # plans-v2: may the AI agent run for this shop (owner's plan)?
            "plans_v2": _agent_entitled(prof),
        })


def _agent_entitled(prof):
    from . import entitlements_service as ES
    owner = prof.user
    on = ES.on(owner)
    return {"on": on, "allowed": (not on) or ES.allows(owner, "ai_sales_agent"),
            "needed_plan": "business"}


def _g1_state(a):
    """What the advanced agent can do on THIS server right now (honest)."""
    from . import bizagent_media as M
    from .logic import pricing
    cfg = S.full_cfg()
    slug, _conf, _cost = M.vision_provider()
    return {"vision_ready": bool(slug), "voice_ready": bool(M.stt_config()),
            "vision_credits": pricing.credit_cost("ai_sales_vision", cfg),
            "voice_credits": pricing.credit_cost("ai_sales_voice", cfg),
            "reply_credits": pricing.credit_cost("ai_sales", cfg),
            "widget": {"enabled": a.widget_enabled, "has_key": bool(a.widget_key)}}


class SettingsView(APIView):
    def post(self, request):
        d0 = request.data or {}
        turning_on = str(d0.get("ai_enabled", "")).lower() in ("1", "true", "on", "yes")
        prof, role, a, bad = _ctx(request, cap="ai_sales_agent" if turning_on else None)
        if bad:
            return bad
        lang = req_lang(request)
        d = request.data or {}
        for k in ("ai_enabled", "approve_all", "cod_enabled", "payment_link_enabled",
                  "low_stock_alert", "daily_report"):
            if k in d:
                setattr(a, k, bool(d.get(k)) if not isinstance(d.get(k), str)
                        else d.get(k).lower() in ("1", "true", "on", "yes"))
        if d.get("tone") in ("friendly", "formal", "short"):
            a.tone = d["tone"]
        if "hours" in d:
            h = d.get("hours") or {}
            if h and (BZ._hm(h.get("start")) is None or BZ._hm(h.get("end")) is None):
                return _err(lang, "সময় HH:MM আকারে দিন।", "Use HH:MM for hours.",
                            status=422, code="bad_hours")
            a.hours = {"start": h["start"], "end": h["end"]} if h else {}
        # ---- g1: who replies, quiet hours, follow-ups, sales rules ----
        from .logic import bizagent_g1 as G1
        if "ai_mode" in d:
            if d["ai_mode"] not in G1.MODES:
                return _err(lang, "অজানা মোড।", "Unknown mode.", status=422, code="bad_mode")
            a.ai_mode = d["ai_mode"]
        for k, lo, hi in (("resume_minutes", 1, G1.MAX_RESUME_MIN), ("morning_hour", 0, 23),
                          ("followup_after_hours", 1, 20), ("followup_max", 0, 3),
                          # biz-v2 (0 idle = the agent waits until handed back)
                          ("takeover_idle_minutes", 0, GD.IDLE_MAX_MIN),
                          ("daily_ai_cap", 0, GD.DAILY_AI_CAP_MAX),
                          ("thread_daily_cap", 1, GD.THREAD_CAP_MAX)):
            if k in d:
                setattr(a, k, G1.clamp_int(d.get(k), lo, hi, getattr(a, k)))
        for k in ("rules_enabled", "morning_summary", "followups_enabled", "upsell_enabled",
                  "auto_courier", "vision_enabled", "voice_enabled", "comment_dm"):
            if k in d:
                v = d.get(k)
                setattr(a, k, v.lower() in ("1", "true", "on", "yes") if isinstance(v, str)
                        else bool(v))
        if "quiet_hours" in d:
            qh = d.get("quiet_hours") or {}
            if qh and (BZ._hm(qh.get("start")) is None or BZ._hm(qh.get("end")) is None):
                return _err(lang, "সময় HH:MM আকারে দিন।", "Use HH:MM for hours.",
                            status=422, code="bad_hours")
            a.quiet_hours = {"start": qh["start"], "end": qh["end"]} if qh else {}
        if "bundle_rules" in d:
            a.bundle_rules = G1.normalize_bundle_rules(d.get("bundle_rules"))
        if "default_courier" in d:
            if d["default_courier"] and d["default_courier"] not in bai.COURIERS:
                return _err(lang, "অজানা কুরিয়ার।", "Unknown courier.", status=422,
                            code="bad_courier")
            a.default_courier = d["default_courier"] or ""
        if a.ai_enabled and not prof.seller_channels.filter(status="connected").exists():
            a.ai_enabled = False
            a.save()
            return _err(lang, "আগে একটি চ্যানেল যুক্ত করুন।", "Connect a channel first.",
                        status=409, code="no_channel")
        a.save()
        # delivery charges + policies live on OwnerPolicy (shared with the shop)
        pol_keys = ("delivery_inside", "delivery_outside", "free_over", "returns", "payment_note")
        if any(k in d for k in pol_keys):
            from .models import OwnerPolicy
            pol = prof.policies.first() or OwnerPolicy(user=prof.user, business=prof)
            for k, attr in (("delivery_inside", "delivery_inside"),
                            ("delivery_outside", "delivery_outside")):
                if k in d:
                    v = BZ._dec(d.get(k))
                    if v is None or v < 0:
                        return _err(lang, "ডেলিভারি চার্জ সঠিক সংখ্যা দিন।",
                                    "Enter a valid delivery charge.", status=422,
                                    code="bad_delivery")
                    setattr(pol, attr, v)
            if "free_over" in d:
                pol.free_delivery_over = BZ._dec(d.get("free_over")) or None
            if "returns" in d:
                pol.returns = str(d.get("returns") or "")[:2000]
            if "payment_note" in d:
                pol.payment_note = str(d.get("payment_note") or "")[:1000]
            pol.save()
        return Response({"ok": True, "settings": _settings_row(a, prof)})


class ChannelsView(APIView):
    def post(self, request):
        """Connect a channel. The token is checked against Graph (honest
        status); a channel already owned by another business is refused."""
        from .models import SellerChannel
        from . import bizagent_graph as G
        prof, role, a, bad = _ctx(request, cap="ai_sales_agent")
        if bad:
            return bad
        lang = req_lang(request)
        d = request.data or {}
        kind = d.get("kind")
        ext = str(d.get("external_id") or "").strip()
        token = str(d.get("token") or "").strip()
        if kind not in BZ.CHANNELS or not ext.isdigit() or len(ext) > 32:
            return _err(lang, "চ্যানেলের ধরন বা আইডি সঠিক নয়।", "Channel type or ID is not valid.",
                        status=422, code="bad_channel")
        if not token:
            return _err(lang, "অ্যাক্সেস টোকেন দিন।", "Enter the access token.", status=422,
                        code="no_token")
        ch = SellerChannel.objects.filter(kind=kind, external_id=ext).first()
        if ch and ch.business_id != prof.id:
            return _err(lang, "এই চ্যানেলটি অন্য একটি ব্যবসায় যুক্ত।",
                        "This channel is connected to another business.", status=409,
                        code="channel_taken")
        if ch is None:
            ch = SellerChannel(business=prof, kind=kind, external_id=ext)
        ch.token_enc = S.enc({"token": token})
        ch.test_mode = False
        if kind == BZ.CH_WHATSAPP:
            r = G.whatsapp_number_info(token, ext)
            name = (r.get("json") or {}).get("verified_name") or \
                (r.get("json") or {}).get("display_phone_number") or ""
        else:
            r = G.page_info(token)
            name = (r.get("json") or {}).get("name") or ""
        if r["ok"]:
            ch.status, ch.status_detail = "connected", ""
            ch.display_name = (d.get("display_name") or name or ext)[:120]
            ch.connected_at = timezone.now()
            if kind == BZ.CH_MESSENGER:
                sub = G.subscribe_page(token, ext)
                if not sub["ok"]:
                    ch.status_detail = ("webhook subscribe: " + sub["error"])[:200]
            elif kind == BZ.CH_WHATSAPP:
                # e2e-sales: the number's WhatsApp Business Account must be
                # subscribed to our app, or Meta never sends its messages
                waba = str(d.get("waba_id") or "").strip()
                m = S.meta_app() or {}
                wabas = [waba] if waba.isdigit() and len(waba) <= 32 else \
                    G.waba_ids_for_token(token, m.get("app_id"), m.get("app_secret"))
                if not wabas:
                    ch.status_detail = "webhook subscribe: waba_not_found"
                for w in wabas[:3]:
                    sub = G.subscribe_waba(token, w)
                    if not sub["ok"]:
                        ch.status_detail = ("webhook subscribe: " + sub["error"])[:200]
        else:
            ch.status = "error"
            ch.status_detail = r.get("error", "")[:200]
            ch.display_name = (d.get("display_name") or ext)[:120]
        ch.save()
        GD.audit(prof, "channel_connect", actor=request.user, kind=kind, channel_id=ch.id,
                 status=ch.status)
        return Response({"ok": ch.status == "connected", "channel": _channel_row(ch)},
                        status=201 if ch.status == "connected" else 200)


class ChannelToggleView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        ch = prof.seller_channels.filter(pk=pk).first()
        if not ch:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        ch.enabled = bool(request.data.get("enabled", True))
        ch.save(update_fields=["enabled"])
        GD.audit(prof, "channel_on" if ch.enabled else "channel_off", actor=request.user,
                 channel_id=ch.id)
        return Response({"ok": True, "channel": _channel_row(ch)})


class ChannelDeleteView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        ch = prof.seller_channels.filter(pk=pk).first()
        if not ch:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        GD.audit(prof, "channel_disconnect", actor=request.user, kind=ch.kind, channel_id=ch.id)
        ch.delete()
        if not prof.seller_channels.filter(status="connected").exists() and a.ai_enabled:
            a.ai_enabled = False
            a.save(update_fields=["ai_enabled", "updated_at"])
        return Response({"ok": True})


class CourierKeysView(APIView):
    def post(self, request, courier):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        lang = req_lang(request)
        if courier not in bai.COURIERS:
            return _err(lang, "অজানা কুরিয়ার।", "Unknown courier.", status=404)
        try:
            S.save_courier_keys(a, courier, request.data or {})
        except RuntimeError:
            return _err(lang, "সার্ভারে এনক্রিপশন কি নেই — এখন সংরক্ষণ করা যাচ্ছে না।",
                        "The server has no encryption key — cannot store keys yet.",
                        status=503, code="no_fernet")
        return Response({"ok": True, "couriers": S.courier_state(a)})


def _msg_row(m):
    return {"id": m.id, "direction": m.direction, "text": m.text, "is_ai": m.is_ai,
            "source": m.reply_source, "rule": (m.meta or {}).get("rule", ""),
            "image_url": (m.meta or {}).get("image_url", ""),
            "status": m.status, "kind": m.kind, "risk_reason": m.risk_reason,
            "send_error": m.send_error, "confidence": m.confidence,
            # AF-10: the rule-made handoff summary (bn + en lines, contacts
            # partly hidden) on approval / handoff rows
            "handoff_card": (m.meta or {}).get("card") if m.direction == "out" else None,
            "created_at": m.created_at.isoformat()}


def _thread_row(t):
    last = t.messages.order_by("-created_at", "-id").first()
    pend = t.messages.filter(status="pending_approval").order_by("-created_at", "-id").first()
    now = timezone.now()
    paused = t.ai_paused_until if (t.ai_paused_until and t.ai_paused_until > now) else None
    return {"id": t.id, "channel": t.channel, "customer_name": t.customer_name or
            t.customer_phone or t.external_user_id[-6:],
            "customer_phone": t.customer_phone, "handover": t.owner_takeover,
            # g1: per-chat toggle + the human pause (AI resumes at paused_until)
            "reply_mode": "human" if t.owner_takeover else "ai",
            "paused_until": paused.isoformat() if paused else None,
            "paused_by": t.paused_by if paused else "",
            "opted_out": t.opted_out,
            # biz-v2: inbox status (agent / owner / attention) + unread
            "status": GD.thread_status(t, now), "unread": GD.unread(t),
            "takeover_at": t.takeover_at.isoformat() if t.takeover_at else None,
            "last_text": last.text[:120] if last else "",
            "last_at": (t.last_message_at or t.created_at).isoformat(),
            "pending": t.messages.filter(status="pending_approval").count(),
            # AF-10: thread-header handoff card = the newest open handoff's card
            "handoff_card": (pend.meta or {}).get("card") if pend else None,
            "in_window": bai.within_service_window(
                t.last_inbound_at.timestamp() if t.last_inbound_at else None,
                timezone.now().timestamp()),
            "order_draft": {k: v for k, v in (t.order_draft or {}).items()
                            if k in ("product", "qty", "name", "phone", "address", "area",
                                     "state")}}


class ApprovalsView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        from .models import Message
        rows = []
        for m in Message.objects.filter(thread__business=prof, status="pending_approval") \
                .select_related("thread").order_by("created_at")[:100]:
            last_in = m.thread.messages.filter(direction="in", created_at__lte=m.created_at) \
                .order_by("-created_at").first()
            r = _msg_row(m)
            r.update({"thread_id": m.thread_id, "channel": m.thread.channel,
                      "customer_name": m.thread.customer_name or m.thread.customer_phone,
                      "customer_text": last_in.text if last_in else "",
                      "problems": (m.meta or {}).get("problems") or []})
            rows.append(r)
        return Response({"approvals": rows})


def _pending(prof, pk):
    from .models import Message
    return Message.objects.filter(pk=pk, thread__business=prof).select_related("thread").first()


class ApprovalApproveView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        lang = req_lang(request)
        m = _pending(prof, pk)
        if not m:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        text = request.data.get("text")
        res = S.approve(m, text=text if text is not None else None, actor=request.user)
        if not res["ok"] and res.get("reason") == "not_pending":
            return _err(lang, "এটি আর অপেক্ষায় নেই।", "This is no longer pending.",
                        status=409, code="not_pending")
        if not res["ok"] and res.get("reason") == "empty":
            return _err(lang, "উত্তর খালি।", "The reply is empty.", status=422, code="empty")
        return Response(res)


class ApprovalRejectView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        m = _pending(prof, pk)
        if not m:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        return Response({"ok": S.reject(m)})


class ThreadsView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        qs = prof.chat_threads.exclude(seller_channel=None).order_by("-last_message_at",
                                                                      "-created_at")[:100]
        return Response({"threads": [_thread_row(t) for t in qs]})


def _thread(prof, pk):
    return prof.chat_threads.filter(pk=pk).exclude(seller_channel=None).first()


class ThreadDetailView(APIView):
    def get(self, request, pk):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        t = _thread(prof, pk)
        if not t:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        GD.mark_read(t)     # biz-v2: the owner opened the chat
        msgs = [_msg_row(m) for m in t.messages.order_by("created_at", "id")]
        orders = [{"id": o.id, "status": o.status, "total": str(o.total),
                   "tracking": o.tracking, "courier": o.courier,
                   "courier_live": o.courier_live, "payment_status": o.payment_status,
                   "items": o.items or [], "draft": o.status == "new" and o.via_agent}
                  for o in t.orders.all()]
        row = _thread_row(t)
        # biz-v2: when an idle takeover hands the chat back to the agent
        idle = GD.clamp(a.takeover_idle_minutes, 0, GD.IDLE_MAX_MIN, 60)
        row["handback_at"] = ((t.takeover_at + timedelta(minutes=idle)).isoformat()
                              if t.owner_takeover and t.takeover_at and idle > 0 else None)
        return Response({"thread": row, "messages": msgs, "orders": orders})


class ThreadHandoverView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        t = _thread(prof, pk)
        if not t:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        if bool(request.data.get("on", True)):
            GD.take_over(t, actor=request.user)
        else:
            GD.hand_back(t, actor=request.user)
        return Response({"ok": True, "handover": t.owner_takeover})


class ThreadSendView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        lang = req_lang(request)
        t = _thread(prof, pk)
        if not t:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        text = str(request.data.get("text") or "").strip()[:2000]
        if not text:
            return _err(lang, "বার্তা খালি।", "Message is empty.", status=422, code="empty")
        m = S.seller_send(t, text)
        return Response({"ok": m.status == "sent", "message": _msg_row(m)},
                        status=201 if m.status == "sent" else 200)


class ThreadTemplateView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        lang = req_lang(request)
        t = _thread(prof, pk)
        if not t:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        name = str(request.data.get("name") or "").strip()
        if not name or len(name) > 512 or not all(c.isalnum() or c == "_" for c in name):
            return _err(lang, "টেমপ্লেটের নাম সঠিক নয়।", "Template name is not valid.",
                        status=422, code="bad_template")
        params = [str(p)[:200] for p in (request.data.get("params") or [])][:10]
        # business-initiated WhatsApp conversations cost money: need credits
        # when the owner has set a rate (charged on Meta's 'sent' status).
        if BZ.wa_charge_credits("marketing", S.full_cfg()) > int(prof.user.ai_credits or 0):
            return _err(lang, "টেমপ্লেট পাঠাতে ক্রেডিট দরকার।",
                        "Credits are needed to send a template.", status=402,
                        code="credits")
        m = S.send_template(t, name, str(request.data.get("lang") or "bn")[:8], params)
        return Response({"ok": m.status == "sent", "message": _msg_row(m)})


class OrderBookView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        lang = req_lang(request)
        from .models import Order
        o = Order.objects.filter(pk=pk, business=prof).first()
        if not o:
            return _err(lang, "অর্ডার পাওয়া যায়নি।", "Order not found.", status=404)
        courier = request.data.get("courier") or a.default_courier
        if courier not in bai.COURIERS:
            return _err(lang, "কুরিয়ার বেছে নিন।", "Choose a courier.", status=422,
                        code="bad_courier")
        r = S.book_courier(o, courier, lang)
        if not r["ok"]:
            if r["error"] == "no_key":
                return _err(lang, "সেটআপে আগে এই কুরিয়ারের কী যুক্ত করুন।",
                            "Connect this courier's keys in setup first.", status=409,
                            code="no_key")
            if r["error"] == "bad_status":
                return _err(lang, "শুধু কনফার্ম করা অর্ডার বুক করা যায়।",
                            "Only confirmed orders can be booked.", status=409,
                            code="bad_status")
            return _err(lang, "কুরিয়ার বুকিং ব্যর্থ: " + r["error"],
                        "Courier booking failed: " + r["error"], status=502,
                        code="courier_error")
        return Response(r, status=201)


class OrderStatusView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        lang = req_lang(request)
        from .models import Order
        o = Order.objects.filter(pk=pk, business=prof).first()
        if not o:
            return _err(lang, "অর্ডার পাওয়া যায়নি।", "Order not found.", status=404)
        target = request.data.get("status")
        if target == "shipped" or not bai.can_transition(o.status, target):
            return _err(lang, "অবৈধ পরিবর্তন।", "Invalid transition.", status=422,
                        code="illegal_transition")
        o.status = target
        o.save(update_fields=["status"])
        if target == "delivered":
            S.record_sale(o)
        if target == "cancelled":
            from .models import Product, ProductVariant
            from django.db.models import F
            for it in o.items or []:   # give the reserved stock back
                if it.get("product_id"):
                    q = int(it.get("qty") or 1)
                    Product.objects.filter(pk=it["product_id"]).update(stock=F("stock") + q)
                    if it.get("variant"):
                        ProductVariant.objects.filter(product_id=it["product_id"],
                                                      vkey=it["variant"]).update(
                            stock=F("stock") + q)
        return Response({"ok": True, "status": o.status, "sale_id": o.sale_id})


class ReportsView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        today = timezone.localtime().date()
        rows = [{"day": r.day.isoformat(), **(r.data or {})}
                for r in prof.agent_reports.all()[:14]]
        return Response({"today": S.daily_stats(prof, today), "history": rows})


class PlanView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        return Response(S.plan_status(a, flavour=_flavour(request)))


class PlanTrialView(APIView):
    def post(self, request):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        lang = req_lang(request)
        if not S.start_trial(a):
            return _err(lang, "ফ্রি ট্রায়াল আগেই ব্যবহার হয়েছে।",
                        "The free trial was already used.", status=409, code="trial_used")
        return Response(S.plan_status(a), status=201)


class PlanCheckoutView(APIView):
    def post(self, request):
        from .payments import service as PS
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        lang = req_lang(request)
        plan = request.data.get("plan")
        if plan not in S.sa_cfg()["plans"]:
            return _err(lang, "অজানা প্ল্যান।", "Unknown plan.", status=422, code="bad_plan")
        try:
            o = PS.checkout(request.user, "seller_%s_monthly" % plan, source="app",
                            idem=str(request.data.get("idem") or "")[:64],
                            flavour=_flavour(request), lang=lang)
        except PS.PayError as e:
            return Response({"ok": False, "error": e.reason,
                             "detail": PS.message(e.reason, lang)}, status=e.status)
        return Response({"ok": True, "order_id": o.pk, "status": o.status,
                         "redirect_url": (o.raw or {}).get("redirect_url", "")}, status=201)
