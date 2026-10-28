"""
Assisto AI Chat (Part 3) — ChatGPT-like multi-turn chat with history.

Endpoints (all /api/v1/, DRF Token auth):
  GET    chat/sessions?query=          list sessions (pinned first, then recent;
                                        optional search over title + message text)
  POST   chat/sessions                 create an empty session
  PATCH  chat/sessions/<id>            {title?, pinned?, archived?}
  DELETE chat/sessions/<id>            delete a session
  GET    chat/sessions/<id>/messages   full transcript
  POST   chat/sessions/<id>/send       {text} -> append user msg + produce reply
  GET/POST chat/sessions/<id>/stream   SSE token stream of the reply
  POST   chat/sessions/<id>/regenerate {edit?} -> re-answer the last user turn

Routing (the single source of truth is `_produce_reply`):
  * AI key enabled + under budget/limit + guard not 'over'  -> ai.generate() with
    the FULL prior-turn context + a user-data summary; credits charged via
    billing.charge('ai_msg_<tier>') with effective_tier (profit-guard downgrade);
    refund-on-provider-failure is handled inside ai.generate. The stored assistant
    message carries meta {model, credits, cost_usd, source:'ai'}.
  * No key / kill-switch / guard 'over' / provider failure  -> Brain.answer()
    (L1 user-data / L2 help KB / L4 honest needs-key). FREE, never charged, never
    empty, never fabricated. meta {source:'brain', level, handler, credits:0}.

credout: when the user cannot cover the AI call (AIUnavailable('credits')) the
request is answered HTTP 402 {reason:'credits', code:'out_of_credits'} and the
turn is undone (no user message, no reply, nothing charged; a regenerate keeps
the old reply), so the app keeps the typed text, opens the buy-credits sheet
and re-sends it once.

Honesty: a no-key chat still gives real answers over the user's own data and the
app's offline KB, and an honest "needs a key" for general questions — we never
invent a fact and never charge for a Brain answer.
"""
from django.db.models import Q, Max
from django.http import StreamingHttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone

from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import ai
from . import credits_out
from .i18n import req_lang, pick
from .logic import brain
from .models import ChatSession, ChatMessage

# How many prior turns to feed the model as context (keeps cost + tokens bounded).
_HISTORY_TURNS = 20

# The chat instruction (bn, en) — module level so manage.py ai_token_audit
# counts exactly what a chat turn sends.
CHAT_TASK = (
    "তুমি Assisto, একজন বাংলা-প্রথম সহকারী। ব্যবহারকারীর সাথে "
    "স্বাভাবিক কথোপকথন চালাও — সংক্ষেপে, সত্যভাবে, বাংলায় (যদি সে "
    "ইংরেজিতে না বলে)। নিচের DATA-তে তার নিজের তথ্যের সারাংশ আছে; "
    "শুধু সেটাই সত্য তথ্য হিসেবে ধরবে, কোনো সংখ্যা বা তথ্য বানাবে না।",
    "You are Assisto, a Bangla-first assistant. Hold a natural "
    "conversation — briefly and truthfully, in English if the user "
    "writes in English. The DATA below summarises the user's own "
    "data; treat only it as factual and never invent numbers or facts.")
CHAT_DATA = "User's latest message: {text}\n\nTheir data summary:\n{summary}"


# ---------------------------------------------------------------------------
# serialisation helpers
# ---------------------------------------------------------------------------
def _session_row(s, last=None):
    if last is None:
        last = s.messages.order_by("-created_at", "-id").first()
    snippet = ""
    if last:
        snippet = (last.text or "").strip().replace("\n", " ")
        if len(snippet) > 80:
            snippet = snippet[:80].rstrip() + "…"
    return {
        "id": s.id,
        "title": s.title or "",
        "pinned": s.pinned,
        "archived": s.archived,
        "source": s.source,
        "updated": s.updated_at.isoformat() if s.updated_at else None,
        "snippet": snippet,
    }


def _msg_row(m):
    return {
        "id": m.id,
        "role": m.role,
        "text": m.text,
        "meta": m.meta or {},
        "created": m.created_at.isoformat() if m.created_at else None,
    }


# ---------------------------------------------------------------------------
# the one place a reply is produced (shared by send / stream / regenerate)
# ---------------------------------------------------------------------------
def _history_for(session, upto_id=None):
    """Prior turns as [{role, content}] for ai.generate. Excludes system rows
    and (when regenerating) anything at/after `upto_id`."""
    qs = session.messages.exclude(role="system").order_by("created_at", "id")
    if upto_id is not None:
        qs = qs.filter(id__lt=upto_id)
    turns = [{"role": m.role, "content": m.text} for m in qs]
    return turns[-_HISTORY_TURNS:]


def ai_cm():
    from . import billing
    return billing.cfg().get("credit_model") or {}


def _mode_need(mode):
    try:
        from . import billing
        from .logic import pricing, pricing_40 as P40
        return int(pricing.credit_cost(P40.MODE_ACTION[mode], billing.cfg()) or 0)
    except Exception:  # noqa: BLE001
        return 0


def _chat_mode(request):
    """pricing-40: the chat mode for this request — the app's `mode`
    ('quick'|'smart'|'pro') or the owner's default — ONLY while the
    credit_model block is enabled; None otherwise (today's behaviour)."""
    try:
        from . import billing
        cm = billing.cfg().get("credit_model") or {}
        if not cm.get("enabled"):
            return None
        from . import plans
        from .logic import pricing_40 as P40
        allowed = P40.plan_modes(cm, plans.effective_plan(request.user))
        m = str((request.data.get("mode") if hasattr(request, "data") else "")
                or request.query_params.get("mode") or "").strip().lower()
        # a plan may only pick its own modes (Opus on every chat = Premium Pro);
        # anything else falls back to the plan's default
        return m if m in allowed else allowed[0]
    except Exception:  # noqa: BLE001
        return None


def _produce_reply(user, session, text, lang, history, credout=False, mode=None):
    """Produce the assistant reply for `text` given prior `history`.

    Returns (reply_text, meta_dict, cards). Tries keyed AI when available;
    otherwise (or on any AIUnavailable) falls back to the free, honest Brain.
    Never raises, never returns an empty reply.
    """
    # AF-3: crisis handover BEFORE any AI call (works with no key, 0 credits):
    # the calm fixed line + 999 / owner-confirmed helplines + an OFFER to
    # tell family. Nothing else is answered in this turn.
    from .agentcore import crisis_guard as CG
    crisis = CG.detect(text)
    if crisis["crisis"]:
        reply, card = CG.respond(user, crisis, lang, surface="chat")
        return reply, {"source": "crisis", "credits": 0, "crisis": CG.log_detail(crisis),
                       "cards": [card]}, [card]

    # user-data context (deterministic, never fabricated) — reused as the
    # DATA the model may ground on, and as the Brain fallback itself.
    ctx = brain.answer(user, text, lang)

    if ai.available():
        try:
            requested_tier = "cheap"
            ai_text = text
            summary = ctx["reply"]
            if mode:
                # pricing-40 (enabled only): cap the user's own text, and do
                # not send the Brain's "needs a key" line as if it were data
                cm = ai_cm()
                ai_text = text[: int(cm.get("user_text_max_chars") or 4000)]
                if ctx.get("level") == "L4":
                    summary = "-"
            meta_out = {}
            if mode:
                # pricing-40: the chat instruction goes into the SYSTEM block so
                # system + instruction (>= 512 tokens) is one cacheable prefix
                # shared by every user of that language; free hard-question
                # check decides the Opus auto-upgrade (capped per month).
                from .logic import pricing_40 as P40
                reply, cost = ai.generate(
                    task="", extra_system=pick(lang, *CHAT_TASK),
                    data=CHAT_DATA.format(text=ai_text, summary=summary),
                    tier=requested_tier, feature="chat." + mode, max_tokens=700,
                    user=user, history=history, mode=mode, out_meta=meta_out,
                    upgrade=(mode == "smart" and P40.is_hard_question(text)))
            else:
                reply, cost = ai.generate(
                    task=pick(lang, *CHAT_TASK),
                    data=CHAT_DATA.format(text=ai_text, summary=summary),
                    tier=requested_tier, feature="chat", max_tokens=700,
                    user=user, history=history)
            # aieval guard: the chat cannot act outside the app — a sentence
            # claiming it sent / called / paid / posted is removed (honest
            # line); a cure promise / self-prescribed dose is removed too.
            from . import ai_guard
            reply, _flags = ai_guard.clean_assistant_answer(reply, lang)
            # billing.charge inside ai.generate used effective_tier; recompute it
            # here only to record which action/credits were booked into meta.
            from . import billing
            from .logic import pricing
            eff = billing.effective_tier(user, requested_tier)
            action = pricing.TIER_ACTION.get(eff, "ai_msg_cheap")
            try:
                credits = pricing.credits_for(action, 1, billing.cfg())
            except Exception:
                credits = 0
            if mode:
                credits = int(meta_out.get("charged") or 0)
                tier_label = {"quick": "assisto-lite", "smart": "assisto",
                              "pro": "assisto-pro"}.get(mode, "assisto")
                if meta_out.get("upgraded"):
                    tier_label = "assisto-pro"
            meta = {
                "source": "ai",
                "model": tier_label if mode else ai.TIER_MODEL.get(eff, "cheap"),
                "tier": eff,
                "cost_usd": round(cost, 6),
                # every plan pays credits (nothing is unlimited)
                "credits": credits,
                "cards": ctx.get("cards", []),
            }
            return reply, meta, ctx.get("cards", [])
        except ai.AIUnavailable as e:
            # credout: out of credits is NOT degraded silently — the view
            # undoes the turn and answers 402 so the app can offer the
            # buy-credits sheet and re-send the same text.
            if e.reason == "credits" and credout:
                raise credits_out.CreditsOut(
                    _mode_need(mode) if mode
                    else credits_out.need_for_tier(user, requested_tier))
            # kill-switch / budget / user-limit / guard-over / every provider
            # failed -> degrade to the free, honest Brain answer below.

    # ---- no-key (or degraded) Brain answer: real, free, never charged ----
    meta = {
        "source": "brain",
        "level": ctx.get("level"),
        "handler": ctx.get("handler"),
        "credits": 0,
        "cards": ctx.get("cards", []),
    }
    reply = ctx["reply"]
    if not (reply or "").strip():
        reply = brain._l4_needs_ai(lang)  # belt-and-braces: never empty
    return reply, meta, ctx.get("cards", [])


# ---------------------------------------------------------------------------
# GET/POST /chat/sessions  — list + create
# ---------------------------------------------------------------------------
class ChatSessionsView(APIView):
    def get(self, request):
        u = request.user
        qs = ChatSession.objects.filter(user=u)
        # exclude archived unless explicitly asked
        if (request.query_params.get("archived") or "").lower() not in ("1", "true"):
            qs = qs.filter(archived=False)
        src = (request.query_params.get("source") or "").strip()
        if src in ("ai", "home"):
            qs = qs.filter(source=src)
        query = (request.query_params.get("query") or "").strip()
        if query:
            qs = qs.filter(
                Q(title__icontains=query) | Q(messages__text__icontains=query)
            ).distinct()
        # pinned first, then most-recent activity.
        qs = qs.annotate(last_at=Max("messages__created_at")) \
               .order_by("-pinned", "-updated_at")
        rows = [_session_row(s) for s in qs[:200]]
        return Response({"sessions": rows})

    def post(self, request):
        u = request.user
        title = (request.data.get("title") or "").strip()
        s = ChatSession.objects.create(user=u, title=title[:120],
                                       title_custom=bool(title))
        return Response(_session_row(s), status=status.HTTP_201_CREATED)


# ---------------------------------------------------------------------------
# PATCH/DELETE /chat/sessions/<id>  — rename / pin / archive / delete
# ---------------------------------------------------------------------------
class ChatSessionDetailView(APIView):
    def _get(self, request, sid):
        return get_object_or_404(ChatSession, id=sid, user=request.user)

    def patch(self, request, sid):
        s = self._get(request, sid)
        if "title" in request.data:
            t = (request.data.get("title") or "").strip()
            s.title = t[:120]
            s.title_custom = True  # a manual rename is sticky
        if "pinned" in request.data:
            s.pinned = bool(request.data.get("pinned"))
        if "archived" in request.data:
            s.archived = bool(request.data.get("archived"))
        s.save()
        return Response(_session_row(s))

    def delete(self, request, sid):
        s = self._get(request, sid)
        s.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


# ---------------------------------------------------------------------------
# GET /chat/sessions/<id>/messages  — full transcript
# ---------------------------------------------------------------------------
class ChatMessagesView(APIView):
    def get(self, request, sid):
        s = get_object_or_404(ChatSession, id=sid, user=request.user)
        msgs = [_msg_row(m) for m in s.messages.order_by("created_at", "id")]
        return Response({"session": _session_row(s), "messages": msgs})


# ---------------------------------------------------------------------------
# POST /chat/sessions/<id>/send  — append user msg + produce the reply
# ---------------------------------------------------------------------------
class ChatSendView(APIView):
    def post(self, request, sid):
        u = request.user
        lang = req_lang(request)
        s = get_object_or_404(ChatSession, id=sid, user=u)
        text = (request.data.get("text") or "").strip()
        if not text:
            return Response(
                {"detail": pick(lang, "কিছু লিখুন।", "Type something.")},
                status=status.HTTP_400_BAD_REQUEST)

        first = not s.messages.filter(role="user").exists()
        user_msg = ChatMessage.objects.create(session=s, role="user", text=text)
        if first:
            s.derive_title(text)

        history = _history_for(s, upto_id=user_msg.id)
        try:
            reply, meta, cards = _produce_reply(u, s, text, lang, history,
                                            credout=credits_out.supported(request),
                                            mode=_chat_mode(request))
        except credits_out.CreditsOut as e:
            user_msg.delete()        # nothing saved; the title is not saved either
            return credits_out.response(u, lang, e.need)
        asst = ChatMessage.objects.create(session=s, role="assistant",
                                           text=reply, meta=meta)
        s.save()  # bump updated_at
        return Response({
            "message": _msg_row(asst),
            "cards": cards,
            "ai_used": meta.get("source") == "ai",
            "ai_enabled": ai.key_present(),
        })


# ---------------------------------------------------------------------------
# GET/POST /chat/sessions/<id>/stream  — SSE token stream of the reply
# ---------------------------------------------------------------------------
class ChatStreamView(APIView):
    """Server-Sent-Events stream of the reply. We compute the full reply via the
    same `_produce_reply` path (so credits/kill-switch/Brain-fallback are all
    identical to /send), persist it, then emit it as token chunks. If the provider
    lib doesn't support real token streaming we simply chunk the final text — the
    app handles both. Robust by construction: a chunked final answer is always a
    valid SSE stream."""
    def get(self, request, sid):
        return self._run(request, sid, (request.query_params.get("text") or "").strip())

    def post(self, request, sid):
        return self._run(request, sid, (request.data.get("text") or "").strip())

    def _run(self, request, sid, text):
        u = request.user
        lang = req_lang(request)
        s = get_object_or_404(ChatSession, id=sid, user=u)
        if not text:
            return Response(
                {"detail": pick(lang, "কিছু লিখুন।", "Type something.")},
                status=status.HTTP_400_BAD_REQUEST)

        first = not s.messages.filter(role="user").exists()
        user_msg = ChatMessage.objects.create(session=s, role="user", text=text)
        if first:
            s.derive_title(text)
        history = _history_for(s, upto_id=user_msg.id)
        try:
            reply, meta, cards = _produce_reply(u, s, text, lang, history,
                                            credout=credits_out.supported(request),
                                            mode=_chat_mode(request))
        except credits_out.CreditsOut as e:
            # credout: a plain 402 JSON (not an SSE stream) — nothing saved.
            user_msg.delete()
            return credits_out.response(u, lang, e.need)
        asst = ChatMessage.objects.create(session=s, role="assistant",
                                           text=reply, meta=meta)
        s.save()

        def gen():
            import json as _j
            # chunk the final text into SSE "token" events (~120 chars each).
            step = 120
            for i in range(0, len(reply), step):
                piece = reply[i:i + step]
                yield "event: token\ndata: " + _j.dumps({"text": piece}) + "\n\n"
            done = {"message_id": asst.id, "cards": cards,
                    "ai_used": meta.get("source") == "ai",
                    "source": meta.get("source")}
            yield "event: done\ndata: " + _j.dumps(done) + "\n\n"

        resp = StreamingHttpResponse(gen(), content_type="text/event-stream")
        resp["Cache-Control"] = "no-cache"
        resp["X-Accel-Buffering"] = "no"
        return resp


# ---------------------------------------------------------------------------
# POST /chat/sessions/<id>/regenerate  — re-answer the last user turn
# ---------------------------------------------------------------------------
class ChatRegenerateView(APIView):
    """Re-answer the last user turn, replacing the last assistant message. An
    optional {edit} first replaces the last USER message text (edit+regenerate)."""
    def post(self, request, sid):
        u = request.user
        lang = req_lang(request)
        s = get_object_or_404(ChatSession, id=sid, user=u)

        last_user = s.messages.filter(role="user").order_by("-created_at", "-id").first()
        if not last_user:
            return Response(
                {"detail": pick(lang, "আগে একটি বার্তা পাঠান।", "Send a message first.")},
                status=status.HTTP_400_BAD_REQUEST)

        edit = request.data.get("edit")
        old_text = last_user.text
        if edit is not None:
            edit = (edit or "").strip()
            if not edit:
                return Response(
                    {"detail": pick(lang, "সম্পাদিত বার্তা খালি হতে পারে না।",
                                    "Edited message can't be empty.")},
                    status=status.HTTP_400_BAD_REQUEST)
            last_user.text = edit
            last_user.save(update_fields=["text"])
            # a first-turn edit should refresh an auto-derived title too
            if not s.title_custom:
                s.derive_title(edit)

        history = _history_for(s, upto_id=last_user.id)
        try:
            reply, meta, cards = _produce_reply(u, s, last_user.text, lang, history,
                                            credout=credits_out.supported(request),
                                            mode=_chat_mode(request))
        except credits_out.CreditsOut as e:
            # credout: the old reply stays (it is only dropped after a new
            # reply exists) and an edit is undone.
            if last_user.text != old_text:
                last_user.text = old_text
                last_user.save(update_fields=["text"])
            return credits_out.response(u, lang, e.need)

        # drop every message AFTER the last user turn (the old assistant reply,
        # and anything stray) so the transcript stays clean.
        s.messages.filter(created_at__gte=last_user.created_at) \
                  .exclude(id=last_user.id).delete()

        asst = ChatMessage.objects.create(session=s, role="assistant",
                                           text=reply, meta=meta)
        s.save()
        return Response({
            "message": _msg_row(asst),
            "cards": cards,
            "ai_used": meta.get("source") == "ai",
            "ai_enabled": ai.key_present(),
        })


# ---------------------------------------------------------------------------
# ai-report: report / flag an AI answer (Google Play AI-Generated Content policy)
# ---------------------------------------------------------------------------
# POST chat/report {message_id?, session_id?, surface?, reason, note?, text?}
#   message_id  — a stored assistant ChatMessage of THIS user (home / AI chat);
#                 the snapshot is then taken from the server copy, not the app.
#   text        — the answer as shown, for answers that are not stored in a
#                 chat session (photo answers, business AI drafts). Text only.
# GET  chat/report -> the caller's own reports (newest first, max 50).
# Rate limit: AI_REPORT_PER_HOUR (10) / AI_REPORT_PER_DAY (30) per user; the
# same message reported twice returns the first report (no duplicate row).
AI_REPORT_PER_HOUR = 10
AI_REPORT_PER_DAY = 30
_AI_REPORT_MAX_TEXT = 4000

_AI_REPORT_MSG = {
    "bad_reason": ("একটি কারণ বেছে নিন।", "Choose a reason."),
    "not_found": ("উত্তরটি পাওয়া যায়নি।", "That answer was not found."),
    "no_text": ("রিপোর্ট করার মতো কোনো উত্তর নেই।", "There is no answer to report."),
    "rate_limited": ("অনেকগুলো রিপোর্ট পাঠানো হয়েছে। কিছুক্ষণ পরে আবার চেষ্টা করুন।",
                     "Too many reports. Please try again later."),
    "ok": ("ধন্যবাদ। আমরা উত্তরটি পর্যালোচনা করব।",
           "Thank you. We will review this answer."),
}


def _ai_report_row(r):
    return {"id": r.id, "surface": r.surface, "reason": r.reason,
            "status": r.status, "message_id": r.message_id,
            "created_at": r.created_at.isoformat()}


class AiReportView(APIView):
    def get(self, request):
        from .models import AiAnswerReport
        rows = AiAnswerReport.objects.filter(user=request.user)[:50]
        return Response({"ok": True, "results": [_ai_report_row(r) for r in rows]})

    def post(self, request):
        from datetime import timedelta
        from .models import AiAnswerReport
        lang = req_lang(request)
        d = request.data or {}

        def err(code, st=400):
            bn, en = _AI_REPORT_MSG[code]
            return Response({"ok": False, "code": code, "detail": pick(lang, bn, en)},
                            status=st)

        reason = str(d.get("reason") or "").strip().lower()
        if reason not in AiAnswerReport.REASONS:
            return err("bad_reason")
        surface = str(d.get("surface") or "chat").strip().lower()
        if surface not in AiAnswerReport.SURFACES:
            surface = "other"
        note = str(d.get("note") or "").strip()[:500]

        msg = None
        mid = d.get("message_id")
        if mid not in (None, ""):
            try:
                mid = int(mid)
            except (TypeError, ValueError):
                return err("not_found", 404)
            msg = (ChatMessage.objects.select_related("session")
                   .filter(pk=mid, role="assistant", session__user=request.user)
                   .first())
            if msg is None:
                return err("not_found", 404)
            mine = AiAnswerReport.objects.filter(user=request.user, message=msg).first()
            if mine is not None:     # already reported: idempotent
                return Response({"ok": True, "duplicate": True,
                                 "detail": pick(lang, *_AI_REPORT_MSG["ok"]),
                                 **_ai_report_row(mine)}, status=200)
            text = msg.text or ""
            sid = str(msg.session_id)
        else:
            text = str(d.get("text") or "")
            sid = str(d.get("session_id") or "")[:40]
        text = text.strip()[:_AI_REPORT_MAX_TEXT]
        if not text:
            return err("no_text")

        now = timezone.now()
        recent = AiAnswerReport.objects.filter(user=request.user)
        if (recent.filter(created_at__gte=now - timedelta(hours=1)).count() >= AI_REPORT_PER_HOUR
                or recent.filter(created_at__gte=now - timedelta(days=1)).count() >= AI_REPORT_PER_DAY):
            resp = err("rate_limited", 429)
            resp["Retry-After"] = "3600"
            return resp

        r = AiAnswerReport.objects.create(
            user=request.user, surface=surface, message=msg, session_id_ref=sid,
            reason=reason, note=note, answer_text=text)
        return Response({"ok": True, "detail": pick(lang, *_AI_REPORT_MSG["ok"]),
                         **_ai_report_row(r)}, status=201)
