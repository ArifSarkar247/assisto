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
from .i18n import req_lang, pick
from .logic import brain
from .models import ChatSession, ChatMessage

# How many prior turns to feed the model as context (keeps cost + tokens bounded).
_HISTORY_TURNS = 20


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


def _produce_reply(user, session, text, lang, history):
    """Produce the assistant reply for `text` given prior `history`.

    Returns (reply_text, meta_dict, cards). Tries keyed AI when available;
    otherwise (or on any AIUnavailable) falls back to the free, honest Brain.
    Never raises, never returns an empty reply.
    """
    # user-data context (deterministic, never fabricated) — reused as the
    # DATA the model may ground on, and as the Brain fallback itself.
    ctx = brain.answer(user, text, lang)

    if ai.available():
        try:
            requested_tier = "cheap"
            reply, cost = ai.generate(
                task=pick(
                    lang,
                    "তুমি Assisto, একজন বাংলা-প্রথম সহকারী। ব্যবহারকারীর সাথে "
                    "স্বাভাবিক কথোপকথন চালাও — সংক্ষেপে, সত্যভাবে, বাংলায় (যদি সে "
                    "ইংরেজিতে না বলে)। নিচের DATA-তে তার নিজের তথ্যের সারাংশ আছে; "
                    "শুধু সেটাই সত্য তথ্য হিসেবে ধরবে, কোনো সংখ্যা বা তথ্য বানাবে না।",
                    "You are Assisto, a Bangla-first assistant. Hold a natural "
                    "conversation — briefly and truthfully, in English if the user "
                    "writes in English. The DATA below summarises the user's own "
                    "data; treat only it as factual and never invent numbers or facts."),
                data=f"User's latest message: {text}\n\nTheir data summary:\n{ctx['reply']}",
                tier=requested_tier, feature="chat", max_tokens=700,
                user=user, history=history)
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
            meta = {
                "source": "ai",
                "model": ai.TIER_MODEL.get(eff, "cheap"),
                "tier": eff,
                "cost_usd": round(cost, 6),
                # every plan pays credits (nothing is unlimited)
                "credits": credits,
                "cards": ctx.get("cards", []),
            }
            return reply, meta, ctx.get("cards", [])
        except ai.AIUnavailable:
            # kill-switch / budget / user-limit / guard-over / every provider
            # failed -> degrade to the free, honest Brain answer below.
            pass

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
        reply, meta, cards = _produce_reply(u, s, text, lang, history)
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
        reply, meta, cards = _produce_reply(u, s, text, lang, history)
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

        # drop every message AFTER the last user turn (the old assistant reply,
        # and anything stray) so the transcript stays clean.
        s.messages.filter(created_at__gte=last_user.created_at) \
                  .exclude(id=last_user.id).delete()

        history = _history_for(s, upto_id=last_user.id)
        reply, meta, cards = _produce_reply(u, s, last_user.text, lang, history)
        asst = ChatMessage.objects.create(session=s, role="assistant",
                                           text=reply, meta=meta)
        s.save()
        return Response({
            "message": _msg_row(asst),
            "cards": cards,
            "ai_used": meta.get("source") == "ai",
            "ai_enabled": ai.key_present(),
        })
