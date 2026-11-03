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
  GET    chat/status                   {ai_available, reason, free} (aivoice)

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
import logging
import re

from django.db.models import Q, Max
from django.http import StreamingHttpResponse
from django.shortcuts import get_object_or_404
from django.utils import timezone

from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import ai
from . import ai_chat_guard as G
from . import credits_out
from .i18n import req_lang, pick
from .logic import brain
from .models import ChatSession, ChatMessage

log = logging.getLogger(__name__)

# How many prior turns to feed the model as context (keeps cost + tokens bounded).
_HISTORY_TURNS = 20

# The chat instruction (bn, en) — module level so manage.py ai_token_audit
# counts exactly what a chat turn sends.
CHAT_TASK = (
    "তুমি Assisto, একজন বাংলা-প্রথম সহকারী। উত্তর সবসময় বাংলায় (বাংলা "
    "হরফে) দাও — প্রশ্নের উত্তর প্রথম বাক্যেই, সংক্ষেপে ও সত্যভাবে। "
    "'আমার কাছে আপনার তথ্য নেই' দিয়ে কখনো শুরু করবে না। প্রশ্ন তার "
    "নিজের রেকর্ড নিয়ে হলে তবেই নিচের DATA দেখবে; কোনো সংখ্যা বা তথ্য বানাবে না।",
    "You are Assisto, a Bangla-first assistant. Reply in English — answer "
    "the question in the first sentence, briefly and truthfully. Never open "
    "by saying you don't have the user's data. Use the DATA below only when "
    "the question is about their own records; never invent numbers or facts.")
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
    turns = []
    for m in qs:
        c = m.text
        pt = (m.meta or {}).get("photo_text") if m.role == "assistant" else ""
        if pt:
            # aifinal round 2 item 2: the photo stays in the chat's context as
            # its stored vision description (never the image bytes)
            c = c + "\n\n[Photo shared earlier in this chat — text seen in it]: " + pt
        turns.append({"role": m.role, "content": c})
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


def _level_need(level):
    try:
        from . import ai_levels_service as ALS
        return int(ALS.credits(level))
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


def _photo_context(request):
    """aifinal PART 1a: the TEXT answer of the photo the user attached
    earlier in this chat (the app sends its chat-vision job id), so follow-up
    questions about that photo work without re-sending it. Only the user's own
    finished job from the last 6 hours; the image itself is never kept."""
    try:
        raw = (request.data.get("photo_job") if hasattr(request, "data") else None) \
            or request.query_params.get("photo_job")
        pk = int(raw or 0)
        if pk <= 0:
            return ""
        from datetime import timedelta
        from .logic import chat_vision as CV
        from .models import PhotoStudioJob
        job = PhotoStudioJob.objects.filter(
            user=request.user, pk=pk, feature=CV.FEATURE, status="done",
            done_at__gte=timezone.now() - timedelta(hours=6)).first()
        return str(((job.options or {}).get("answer") or "") if job else "")[:1500]
    except Exception:  # noqa: BLE001 — a bad id never breaks the chat
        return ""


PHOTO_NOTE = (
    "ব্যবহারকারী এই চ্যাটে আগে একটি ছবি দিয়েছিলেন; ছবিতে যা দেখা গেছে তা DATA-তে "
    "আছে। পরের প্রশ্নের উত্তর সেখান থেকে দাও — 'আমি ছবি দেখতে পাচ্ছি না' বা "
    "'কিছু দেখতে পাচ্ছি না' কখনো বলবে না।",
    "The user attached a photo earlier in this chat; what was seen in it is in "
    "the DATA. Answer follow-ups from that — never say you cannot see the photo "
    "or cannot see anything.")


_FAILED_TASK = re.compile(
    r"(never reached me|did(?:n't| not) (?:reach|come through)|(?:can(?:'|no)t|cannot|"
    r"unable to|could(?:n't| not)) (?:see|view|open|access|read) (?:the |your |that |this |any )?"
    r"(?:image|photo|picture|screenshot|file|attachment)|no (?:image|photo|screenshot|attachment)"
    r" (?:was |has been )?(?:attached|shared|sent|received)|"
    r"ছবি(?:টি|টা)?\s*(?:দেখতে পাচ্ছি না|পাইনি|পৌঁছায়নি|আসেনি)|স্ক্রিনশট(?:টি|টা)?\s*(?:পাইনি|পৌঁছায়নি|আসেনি))",
    re.I)


def _failed_task(reply, photo=""):
    """True when the answer says the AI could not do the task."""
    return bool(_FAILED_TASK.search(str(reply or "")[:600]))


def _refund_turn(user, meta_out, why):
    """aifinal PART 1c: give back what this turn charged + log the reason."""
    n = int((meta_out or {}).get("charged") or 0)
    if user is None or n <= 0:
        return
    try:
        from . import billing
        billing.credit(user, "adjust", n, note="ai_refund:" + why)
        meta_out["charged"] = 0
        meta_out["refunded"] = n
        from . import ai_usage_log
        ai_usage_log.mark_refunded(user, n, why)
        log.info("chat: refunded %s credits (%s)", n, why)
    except Exception:  # noqa: BLE001
        log.exception("chat: refund failed (%s)", why)


def _chat_level(request):
    """aifinal PART 3: the answer level the user picked ('normal' | 'better' |
    'best'), or None while the owner switch is off. Unknown -> the default
    (Normal); the server never picks a dearer level than the app sent."""
    try:
        from . import ai_levels_service as ALS
        if not ALS.enabled():
            return None
        raw = (request.data.get("level") if hasattr(request, "data") else "") \
            or request.query_params.get("level")
        return ALS.resolve(raw)
    except Exception:  # noqa: BLE001
        return None


def _produce_reply(user, session, text, lang, history, credout=False, mode=None,
                   photo="", level=None):
    """Produce the assistant reply for `text` given prior `history`.

    Returns (reply_text, meta_dict, cards). Tries keyed AI when available;
    otherwise (or on any AIUnavailable) falls back to the free, honest Brain.
    Never raises, never returns an empty reply.
    """
    # AF-3: crisis handover BEFORE any AI call (works with no key, 0 credits):
    # the calm fixed line + 999 / owner-confirmed helplines + an OFFER to
    # tell family. Nothing else is answered in this turn.
    from .agentcore import crisis_guard as CG
    from . import ai_prompt as AP
    lang = AP.reply_lang(text, lang)   # ailang: answer in the user's language
    crisis = CG.detect(text)
    if crisis["crisis"]:
        reply, card = CG.respond(user, crisis, lang, surface="chat")
        return reply, {"source": "crisis", "credits": 0, "crisis": CG.log_detail(crisis),
                       "cards": [card]}, [card]

    # user-data context (deterministic, never fabricated) — reused as the
    # DATA the model may ground on, and as the Brain fallback itself.
    ctx = brain.answer(user, text, lang)

    unavailable = ""
    if ai.available():
        try:
            requested_tier = "cheap"
            summary = ctx["reply"]
            # aibar: the user's own text is capped on EVERY path (before, only
            # with the pricing-40 block on: a 50k paste cost ~৳24 for 1 credit)
            # and the Brain's "needs a key" line is never sent as if it were
            # the user's data.
            limit = G.USER_TEXT_MAX
            if level:
                mode = None                  # the level path replaces the modes
                from . import ai_levels_service as ALS
                limit = int((ALS.spec(level) or {}).get("max_chars") or G.USER_TEXT_MAX)
            if mode:
                cm = ai_cm()
                limit = int(cm.get("user_text_max_chars") or G.USER_TEXT_MAX)
            ai_text, _cut = G.cap_text(text, limit)
            if ctx.get("level") == "L4":
                summary = "-"
            task_text = pick(lang, *CHAT_TASK)
            # aifinal PART 6: general information only + safe mode for minors
            from . import ai_compliance as AC
            safe_mode = AC.is_minor(user)
            task_text += "\n" + AC.system_rules(user)
            if photo:
                summary = ("[Photo attached earlier in this chat — what Assisto saw]\n"
                           + photo + "\n\n" + summary)
                task_text += "\n" + pick(lang, *PHOTO_NOTE)
            if not mode:
                # legacy path (no pricing-40 caps): bound the context too
                history = G.cap_history(history)
            meta_out = {}
            # AF-2 (maskall): the user's text, the Brain summary of their own
            # data and the earlier turns go to the provider MASKED (phones,
            # NID, account/card numbers, e-mails -> tokens); the reply comes
            # back with the real values. History is masked FIRST so the same
            # earlier turn gets the same tokens every time (prompt cache).
            from .agentcore import trust as _T
            vault = _T.Vault()
            history = vault.mask_request(history=history)[2]
            if level:
                reply, cost = ai.generate(
                    task="", extra_system=task_text,
                    data=CHAT_DATA.format(text=ai_text, summary=summary),
                    tier=requested_tier, feature="chat." + level, max_tokens=700,
                    user=user, history=history, out_meta=meta_out, pii=vault, level=level)
            elif mode:
                # pricing-40: the chat instruction goes into the SYSTEM block so
                # system + instruction (>= 512 tokens) is one cacheable prefix
                # shared by every user of that language; free hard-question
                # check decides the Opus auto-upgrade (capped per month).
                from .logic import pricing_40 as P40
                reply, cost = ai.generate(
                    task="", extra_system=task_text,
                    data=CHAT_DATA.format(text=ai_text, summary=summary),
                    tier=requested_tier, feature="chat." + mode, max_tokens=700,
                    user=user, history=history, mode=mode, out_meta=meta_out,
                    upgrade=(mode == "smart" and P40.is_hard_question(text)), pii=vault)
            else:
                reply, cost = ai.generate(
                    task=task_text,
                    data=CHAT_DATA.format(text=ai_text, summary=summary),
                    tier=requested_tier, feature="chat", max_tokens=700,
                    user=user, history=history, pii=vault, out_meta=meta_out)
            # aieval guard: the chat cannot act outside the app — a sentence
            # claiming it sent / called / paid / posted is removed (honest
            # line); a cure promise / self-prescribed dose is removed too.
            from . import ai_guard
            n_money = 0
            try:
                reply, _flags = ai_guard.clean_assistant_answer(reply, lang)
                # aibar: no invented taka amounts — a money figure that is not in
                # the user's text, their data summary or the earlier turns is cut
                # (own-data question) or marked as an estimate (general question).
                reply, n_money = ai_guard.scrub_ungrounded_money(
                    reply, text, ctx["reply"], [h.get("content", "") for h in (history or [])],
                    lang=lang, strict=ctx.get("level") == "L1")
            except Exception:  # noqa: BLE001 — a guard bug never costs the answer
                log.exception("chat: answer guard failed")
            if _failed_task(reply, photo):
                # aifinal round 2 item 6: the answer itself says the AI could
                # not do the task ("the screenshot never reached me", "I can't
                # see the image") -> no charge; the answer is still shown
                _refund_turn(user, meta_out, "chat:task_not_done")
            if not (reply or "").strip():
                # aifinal PART 1c: nothing usable came back -> credits back at
                # once, then the honest free answer below
                _refund_turn(user, meta_out, "chat:empty_after_guard")
                raise ai.AIUnavailable("queued")
            # billing.charge inside ai.generate used effective_tier; recompute it
            # here only to record which action/credits were booked into meta.
            from . import billing
            eff = billing.effective_tier(user, requested_tier)
            # aibar: the credits ACTUALLY taken for this answer (the router's
            # charge result; family pool / free quick quota included) — not a
            # re-computation from the price list.
            credits = int(meta_out.get("charged") or 0)
            if mode:
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
            bal = G.balance(user)
            if bal is not None:
                meta["balance"] = bal
            if meta_out.get("refunded"):
                meta["refunded"] = int(meta_out["refunded"])   # shown: "no credits used"
            if mode == "quick" and credits == 0:
                meta["free_quota"] = True       # one of today's free quick answers
            if level:
                from .logic import ai_levels as AL
                meta["level"] = level
                meta["model"] = {"normal": "assisto-lite", "better": "assisto",
                                 "best": "assisto-pro"}.get(level, "assisto")
                if AL.hint_better(text, level):
                    meta["hint_better"] = True    # a hint only — never an upgrade
            # aifinal PART 6: label + consult-a-professional line on legal /
            # medical / financial topics; safe mode for under-18 accounts
            reply, topic = AC.add_professional_line(reply, text, lang)
            meta["ai_generated"] = True
            if topic:
                meta["pro_topic"] = topic
            if safe_mode:
                meta["safe_mode"] = True
            # aifinal PART 5: up to 3 real in-app actions (fixed allow-list)
            from . import ai_actions
            acts = ai_actions.suggest(user, text)
            if acts:
                meta["actions"] = acts
            if _cut:
                meta["text_cut"] = True
            if n_money:
                meta["money_grounding"] = n_money
            return reply, meta, ctx.get("cards", [])
        except ai.AIUnavailable as e:
            unavailable = e.reason or "queued"
            # credout: out of credits is NOT degraded silently — the view
            # undoes the turn and answers 402 so the app can offer the
            # buy-credits sheet and re-send the same text.
            if e.reason == "credits" and credout:
                raise credits_out.CreditsOut(
                    _level_need(level) if level
                    else _mode_need(mode) if mode
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
    if unavailable:
        meta["ai_unavailable"] = unavailable
        # aibar: keys exist but AI could not answer THIS turn — say why
        # (limit / daily cap / providers down), never "no key yet".
        if ctx.get("level") == "L4":
            reply = G.unavailable_line(unavailable, lang) or reply
    if not (reply or "").strip():
        reply = brain._l4_needs_ai(lang)  # belt-and-braces: never empty
    return reply, meta, ctx.get("cards", [])



# ---------------------------------------------------------------------------
# aibar: idempotent turns + burst limit (shared by send / stream)
# ---------------------------------------------------------------------------
def _find_turn(session, cid):
    """(user message, its assistant reply or None) for the app's client_id,
    or (None, None) when this id was never seen in this session."""
    if not cid:
        return None, None
    um = session.messages.filter(role="user", meta__client_id=cid).order_by("id").first()
    if um is None:
        return None, None
    nxt = session.messages.filter(role="user", id__gt=um.id).order_by("id").first()
    qs = session.messages.filter(role="assistant", id__gt=um.id)
    if nxt is not None:
        qs = qs.filter(id__lt=nxt.id)
    return um, qs.order_by("id").first()


def _in_progress(lang):
    return Response({"ok": False, "code": "in_progress", "reason": "in_progress",
                     "detail": pick(lang, "আগের পাঠানো উত্তরটি তৈরি হচ্ছে — এক মুহূর্ত।",
                                    "Your earlier send is still being answered — one moment.")},
                    status=status.HTTP_409_CONFLICT)


def _gate(request, session, text, lang):
    """Before a new turn: replay an already answered client_id, report one
    still in flight, or refuse a burst. Returns (response | None, cid,
    replay_assistant | None). A crisis message is never rate-limited."""
    cid = G.client_id(request)
    um, asst = _find_turn(session, cid)
    if um is not None:
        if asst is not None:
            return None, cid, asst
        return _in_progress(lang), cid, None
    from .agentcore import crisis_guard as CG
    if not CG.detect(text)["crisis"]:
        wait = G.burst_retry_after(request.user, session.source or "ai")
        if wait:
            resp = Response(G.rate_limited_body(lang, wait),
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
            resp["Retry-After"] = str(wait)
            return resp, cid, None
    return None, cid, None


def _send_payload(asst, replayed=False):
    meta = asst.meta or {}
    out = {
        "message": _msg_row(asst),
        "cards": meta.get("cards", []),
        "ai_used": meta.get("source") == "ai",
        "ai_enabled": ai.key_present(),
    }
    if replayed:
        out["replayed"] = True
    return out


def _sse(reply, asst, cards, meta, replayed=False):
    import json as _j

    def gen():
        # chunk the final text into SSE "token" events (~120 chars each).
        step = 120
        for i in range(0, len(reply), step):
            piece = reply[i:i + step]
            # aivoice: "chunk" is the key the app reads (it read only
            # chunk/value, so a "text"-only token rendered as an EMPTY
            # reply); "text" stays for older readers.
            yield "event: token\ndata: " + _j.dumps(
                {"chunk": piece, "text": piece}) + "\n\n"
        done = {"message_id": asst.id, "cards": cards,
                "ai_used": meta.get("source") == "ai",
                "source": meta.get("source"),
                # aivoice: the full reply too, so a client that missed a
                # token still shows the whole answer.
                "text": reply,
                # aibar: credits taken / balance / honest flags per message
                "meta": {k: meta[k] for k in _PUBLIC_META if k in meta}}
        if replayed:
            done["replayed"] = True
        yield "event: done\ndata: " + _j.dumps(done) + "\n\n"

    resp = StreamingHttpResponse(gen(), content_type="text/event-stream")
    resp["Cache-Control"] = "no-cache"
    resp["X-Accel-Buffering"] = "no"
    return resp


# meta keys the app may read on a reply (never cost_usd internals beyond these)
_PUBLIC_META = ("source", "model", "credits", "balance", "free_quota", "text_cut",
                "money_grounding", "ai_unavailable", "level", "crisis")

# ---------------------------------------------------------------------------
# GET /chat/status — aivoice: is keyed AI usable right now? (honest no-key state)
# ---------------------------------------------------------------------------
# The free parts that work with NO key (the app lists them in the no-key
# banner). Codes, not text — the app owns the wording (bn / en ARB).
FREE_WITHOUT_KEY = ("own_data", "app_help", "phone_commands", "voice_input")


def chat_status_payload():
    """{ai_available, reason, free}. reason: None when AI is usable,
    'no_key' when no provider key is configured, 'paused' when a key exists
    but the daily budget / kill-switch keeps AI off right now. Never raises:
    an error reads as 'paused' (we never claim AI we cannot deliver)."""
    try:
        if ai.available():
            return {"ai_available": True, "reason": None,
                    "free": list(FREE_WITHOUT_KEY)}
        reason = "paused" if ai.key_present() else "no_key"
    except Exception:  # noqa: BLE001
        reason = "paused"
    return {"ai_available": False, "reason": reason,
            "free": list(FREE_WITHOUT_KEY)}


class ChatStatusView(APIView):
    def get(self, request):
        return Response(chat_status_payload())


class ChatLevelsView(APIView):
    """aifinal PART 3: GET /chat/levels — the answer-level picker (credits per
    answer shown BEFORE sending, max length, temporarily unavailable)."""
    def get(self, request):
        from . import ai_levels_service as ALS
        return Response(ALS.app_payload(request.user, req_lang(request)))


class ChatWelcomeCreditsView(APIView):
    """aifinal PART 4: POST /chat/welcome-credits — the 20 free AI credits,
    ONCE per verified phone + device (antifarm). Idempotent: a second call
    answers granted 0 with the reason."""
    def post(self, request):
        from . import ai_levels_service as ALS
        from . import ai_prompt as AP
        from .otp import device_id
        n, why = ALS.grant_welcome(request.user, device_id(request))
        lang = req_lang(request)
        return Response({"granted": n, "reason": why, "balance": G.balance(request.user),
                         "message": pick(lang, "স্বাগতম! AI-তে ব্যবহারের জন্য %s ফ্রি ক্রেডিট পেলেন (সাধারণ লেভেলে)।"
                                         % AP.to_bn_digits(str(n)),
                                         "Welcome! You got %d free AI credits (for Normal answers)." % n)
                         if n else ""})


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

        stop, cid, replay = _gate(request, s, text, lang)
        if stop is not None:
            return stop
        if replay is not None:       # aibar: same client_id -> same answer, no charge
            return Response(_send_payload(replay, replayed=True))

        first = not s.messages.filter(role="user").exists()
        user_msg = ChatMessage.objects.create(session=s, role="user", text=text,
                                              meta={"client_id": cid} if cid else {})
        if first:
            s.derive_title(text)

        history = _history_for(s, upto_id=user_msg.id)
        try:
            reply, meta, cards = _produce_reply(u, s, text, lang, history,
                                            credout=credits_out.supported(request),
                                            mode=_chat_mode(request),
                                            photo=_photo_context(request),
                                            level=_chat_level(request))
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

        stop, cid, replay = _gate(request, s, text, lang)
        if stop is not None:
            return stop
        if replay is not None:       # aibar: same client_id -> same answer, no charge
            rm = replay.meta or {}
            return _sse(replay.text, replay, rm.get("cards", []), rm, replayed=True)

        first = not s.messages.filter(role="user").exists()
        user_msg = ChatMessage.objects.create(session=s, role="user", text=text,
                                              meta={"client_id": cid} if cid else {})
        if first:
            s.derive_title(text)
        history = _history_for(s, upto_id=user_msg.id)
        try:
            reply, meta, cards = _produce_reply(u, s, text, lang, history,
                                            credout=credits_out.supported(request),
                                            mode=_chat_mode(request),
                                            photo=_photo_context(request),
                                            level=_chat_level(request))
        except credits_out.CreditsOut as e:
            # credout: a plain 402 JSON (not an SSE stream) — nothing saved.
            user_msg.delete()
            return credits_out.response(u, lang, e.need)
        asst = ChatMessage.objects.create(session=s, role="assistant",
                                           text=reply, meta=meta)
        s.save()
        # aibar honest limit: the reply is complete (and has passed every
        # guard: action claims, medical, invented money) BEFORE the first
        # token is sent — guarded text only, never raw provider tokens.
        return _sse(reply, asst, cards, meta)


# ---------------------------------------------------------------------------
# POST /chat/sessions/<id>/regenerate  — re-answer the last user turn
# ---------------------------------------------------------------------------
def _regen_wait(user, session):
    """Regenerates replace the reply (no new user turn), so they are counted
    on the AI usage log: at most the chat's per-minute rate of AI chat calls
    in the last minute."""
    try:
        from datetime import timedelta
        from django.conf import settings as _s
        from .models import AIUsage
        per_min = int(getattr(_s, "AI_CHAT_RATE_PER_MIN", 10))
        since = timezone.now() - timedelta(seconds=60)
        n = AIUsage.objects.filter(user=user, created_at__gte=since,
                                   feature__startswith="chat").count()
        return 60 if per_min > 0 and n >= per_min else 0
    except Exception:  # noqa: BLE001
        return 0


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
        # aibar: regenerate is an AI call too — the same burst limit (counted
        # on stored turns, so a regenerate loop is bounded by the hour cap of
        # the chat's turns plus this check on recent AI answers).
        wait = _regen_wait(u, s)
        if wait:
            resp = Response(G.rate_limited_body(lang, wait),
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
            resp["Retry-After"] = str(wait)
            return resp

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
                                            mode=_chat_mode(request),
                                            photo=_photo_context(request),
                                            level=_chat_level(request))
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
