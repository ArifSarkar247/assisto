"""ai-reply-core (owner order 17 Nov): AI reply — the server side.

My Circle is end-to-end encrypted, so the server can NEVER read a chat. The
user's OWN phone decrypts an incoming message and sends its text here for a
moment; this module builds the reply and forgets the text. Nothing in here
stores, logs or shows message text — only text-free counters
(AiReplyEvent), the per-person modes (AiReplySetting), the compact style
profile (AiReplyProfile) and the "AI sent this" marks (AiReplyMark).

Entry points (views_ai_reply.py):
  suggest(user, body)          2-3 short replies (My Circle Suggest / a notification)
  auto(user, body)             Busy / Full auto: send | hold | skip
  mark_sent(user, edge, msg, token)   called by the 1:1 send: tags an AI-sent message
  settings_get/settings_set    per-person / per-group mode, busy timer, label
  style_*                      consent + compact profile
  notif_token / notif_user     the lane-2 notification token (revocable)
"""
import logging
from datetime import timedelta

from django.core import signing
from django.utils import timezone

from .logic import ai_reply_rules as R

log = logging.getLogger(__name__)

FLAG = "ai_reply"
FLAG_NOTIF = "ai_reply_notif"
ACTION_SUGGEST = "ai_reply_suggest"
ACTION_AUTO = "ai_reply_auto"
SEND_SALT = "ai_reply_send.v1"
NOTIF_SALT = "ai_reply_notif.v1"
SEND_TOKEN_MAX_AGE = 600
NOTIF_TOKEN_DAYS = 7
UNLOCK_PLACEMENT = "ai_reply_unlock"


# ------------------------------------------------------------------ gates
def flag_on(user, key=FLAG):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(key, user))
    except Exception:  # noqa: BLE001 — a broken flag read never turns AI on
        return False


def is_child(user):
    """Family Care child or under 18. Fails CLOSED (error -> child)."""
    if user is None:
        return False
    try:
        from .ai_compliance import is_minor
        return bool(is_minor(user))
    except Exception:  # noqa: BLE001
        return True


def peer_of(edge):
    try:
        from .push import member_peer_user
        return member_peer_user(edge)
    except Exception:  # noqa: BLE001
        return None


def child_pair(user, edge):
    if is_child(user):
        return True
    if edge is None:
        return False
    if str(getattr(edge, "relation", "") or "") == "child":
        return True
    peer = peer_of(edge)
    return peer is not None and is_child(peer)


def is_paid(user):
    try:
        from . import sponsor_service as SS   # the rewarded-ticket view's own rule
        return bool(SS.is_paid(user))
    except Exception:  # noqa: BLE001
        return False


def reply_credits(action=ACTION_SUGGEST):
    from . import billing
    from .logic import pricing
    return pricing.credit_cost(action, billing.cfg())


def ads_per_reply():
    """Rewarded ads for one reply, from the EXISTING formula: N ads buy the
    credits of one Normal AI answer (ad_money_service.ads_per_answer)."""
    try:
        from . import ad_money_service as AMS
        from . import ai_levels_service as ALS
        n = int(AMS.ads_per_answer())
        normal = ALS.spec("normal") or {}
        per_answer = max(1, int(normal.get("credits") or 1))
        need = reply_credits()
        return max(1, -(-n * need // per_answer))
    except Exception:  # noqa: BLE001
        return None


def unlock_hint(user):
    """'ad' for a free user while the rewarded placement is live, else 'premium'."""
    if is_paid(user) or is_child(user):
        return "premium"
    try:
        from .admob_service import placement_on
        return "ad" if placement_on(UNLOCK_PLACEMENT) else "premium"
    except Exception:  # noqa: BLE001
        return "premium"


def free_left(user):
    """Replies the user's balance pays right now (any bucket, incl. rewarded-ad credits)."""
    need = max(1, reply_credits())
    try:
        user.refresh_from_db(fields=["ai_credits"])
    except Exception:  # noqa: BLE001
        pass
    return max(0, int(getattr(user, "ai_credits", 0) or 0) // need)


# ------------------------------------------------------------------ events
def _event(user, kind, **kw):
    from .models import AiReplyEvent
    return AiReplyEvent.objects.create(user=user, kind=kind, **kw)


def _settle(e, kind, **fields):
    for k, v in fields.items():
        setattr(e, k, v)
    e.kind = kind
    e.save(update_fields=["kind"] + list(fields))


def _count(user, kinds, since, **flt):
    from .models import AiReplyEvent
    return AiReplyEvent.objects.filter(user=user, kind__in=kinds, created_at__gte=since,
                                       **flt).count()


def suggest_rate_ok(user, now=None):
    now = now or timezone.now()
    if _count(user, ("suggest",), now - timedelta(seconds=R.SUGGEST_MIN_GAP_S)):
        return False
    return _count(user, ("suggest",), now - timedelta(hours=1)) < R.SUGGEST_PER_USER_HOUR


def auto_rate_ok(user, edge, now=None):
    now = now or timezone.now()
    kinds = ("auto", "busy")
    if _count(user, kinds, now - timedelta(seconds=R.AUTO_MIN_GAP_S), member=edge):
        return False
    if _count(user, kinds, now - timedelta(hours=1), member=edge) >= R.AUTO_PER_CHAT_HOUR:
        return False
    if _count(user, kinds, now - timedelta(hours=1)) >= R.AUTO_PER_USER_HOUR:
        return False
    return _count(user, kinds, now - timedelta(days=1)) < R.AUTO_PER_USER_DAY


# ------------------------------------------------------------------ settings
def _setting(user, edge=None, group=None, create=False):
    from .models import AiReplySetting
    flt = {"user": user, "member": edge} if edge is not None else {"user": user, "group": group}
    row = AiReplySetting.objects.filter(**flt).first()
    if row is None and create:
        row = AiReplySetting.objects.create(**flt)
    return row


def effective_mode(row, now=None):
    """The mode in force; an expired Busy timer turns itself off (server clock)."""
    if row is None:
        return "off"
    if row.mode == "busy" and row.busy_until is not None and row.busy_until <= (now or timezone.now()):
        row.mode, row.busy_until = "off", None
        row.save(update_fields=["mode", "busy_until", "updated_at"])
    return row.mode


def allowed_modes(user, edge=None, group=None):
    if child_pair(user, edge):
        return ["off"]
    if group is not None:
        return list(R.GROUP_MODES)
    return list(R.MODES)


def settings_body(user, edge=None, group=None):
    from .models import AiReplyEvent
    row = _setting(user, edge, group)
    mode = effective_mode(row)
    allowed = allowed_modes(user, edge, group)
    if mode not in allowed:
        mode = "off"
    held = []
    if edge is not None:
        for e in AiReplyEvent.objects.filter(user=user, member=edge, kind="held",
                                             seen=False).order_by("-created_at")[:5]:
            held.append({"id": e.id, "message_id": e.in_message_id, "category": e.category,
                         "at": e.created_at.isoformat()})
    prof = profile(user)
    return {
        "ok": True, "enabled": flag_on(user),
        "mode": mode, "allowed_modes": allowed,
        "busy_until": row.busy_until.isoformat() if row and row.busy_until and mode == "busy" else None,
        "label_on": bool(row.label_on) if row else True,
        "is_group": group is not None, "child": child_pair(user, edge),
        "style_consent": bool(prof.style_consent),
        "credits_per_reply": reply_credits(), "free_left": free_left(user),
        "unlock": unlock_hint(user), "unlock_ad_placement": UNLOCK_PLACEMENT,
        "ads_per_reply": ads_per_reply(),
        "held": held,
    }


def settings_set(user, data, edge=None, group=None):
    """(status, body). Group -> suggest/off only; child pair -> off only."""
    mode = str(data.get("mode") or "").strip()
    allowed = allowed_modes(user, edge, group)
    if mode and mode not in R.MODES:
        return 400, {"ok": False, "reason": "bad_mode"}
    if mode and mode not in allowed:
        return 403, {"ok": False, "reason": "child" if allowed == ["off"] else "group_suggest_only",
                     "allowed_modes": allowed}
    if mode and mode != "off" and not flag_on(user):
        return 403, {"ok": False, "reason": "flag_off"}
    row = _setting(user, edge, group, create=True)
    fields = ["updated_at"]
    if mode:
        row.mode = mode
        row.busy_until = None
        if mode == "busy":
            try:
                mins = int(data.get("busy_minutes") if data.get("busy_minutes") is not None else 60)
            except (TypeError, ValueError):
                mins = -1
            if mins not in R.BUSY_MINUTES:
                return 400, {"ok": False, "reason": "bad_busy_minutes"}
            if mins:
                row.busy_until = timezone.now() + timedelta(minutes=mins)
        fields += ["mode", "busy_until"]
    if "label_on" in data:
        row.label_on = bool(data.get("label_on"))
        fields.append("label_on")
    row.save(update_fields=fields)
    return 200, settings_body(user, edge, group)


# ------------------------------------------------------------------ style
def profile(user):
    from .models import AiReplyProfile
    row, _ = AiReplyProfile.objects.get_or_create(user=user)
    return row


def style_set_consent(user, on):
    p = profile(user)
    p.style_consent = bool(on)
    if not on:                      # consent off = the profile is deleted
        p.style, p.samples_seen = {}, 0
    p.save(update_fields=["style_consent", "style", "samples_seen", "updated_at"])
    return style_body(user)


def style_learn(user, samples):
    """Build the compact profile from the user's OWN sent texts; the texts
    are dropped as soon as this returns."""
    p = profile(user)
    if not p.style_consent:
        return 403, {"ok": False, "reason": "no_consent"}
    if not isinstance(samples, list):
        return 400, {"ok": False, "reason": "bad_samples"}
    prof = R.style_profile([s for s in samples if isinstance(s, str)])
    p.style = prof
    p.samples_seen = int(prof.get("n") or 0)
    p.save(update_fields=["style", "samples_seen", "updated_at"])
    return 200, style_body(user)


def style_body(user):
    p = profile(user)
    s = p.style or {}
    return {"ok": True, "consent": bool(p.style_consent), "learned": bool(s.get("n")),
            "samples": int(p.samples_seen or 0),
            "summary": {k: s.get(k) for k in ("words_median", "lang", "emoji_pct", "formality",
                                              "phrases") if k in s}}


# ------------------------------------------------------------------ notif token
def notif_token(user):
    """(status, body) — lane 2's token, scoped to the suggest call only."""
    if not flag_on(user, FLAG_NOTIF):
        return 403, {"ok": False, "reason": "flag_off"}
    if is_child(user):
        return 403, {"ok": False, "reason": "child"}
    p = profile(user)
    if not p.notif_on:
        p.notif_on = True
        p.save(update_fields=["notif_on", "updated_at"])
    tok = signing.dumps({"u": user.pk, "v": int(p.notif_token_ver), "s": "suggest"}, salt=NOTIF_SALT)
    exp = timezone.now() + timedelta(days=NOTIF_TOKEN_DAYS)
    return 200, {"ok": True, "token": tok, "expires_at": exp.isoformat()}


def notif_revoke(user):
    p = profile(user)
    p.notif_on = False
    p.notif_token_ver = int(p.notif_token_ver or 1) + 1
    p.save(update_fields=["notif_on", "notif_token_ver", "updated_at"])
    return {"ok": True}


def notif_user(token):
    """The user behind a valid, unrevoked notification token, else None."""
    from .models import AiReplyProfile
    try:
        d = signing.loads(str(token or ""), salt=NOTIF_SALT,
                          max_age=NOTIF_TOKEN_DAYS * 86400)
    except signing.BadSignature:
        return None
    if not isinstance(d, dict) or d.get("s") != "suggest":
        return None
    p = AiReplyProfile.objects.filter(user_id=d.get("u")).select_related("user").first()
    if p is None or not p.notif_on or int(p.notif_token_ver) != int(d.get("v") or -1):
        return None
    u = p.user
    if not u.is_active:
        return None
    return u


def notif_state(user):
    return {"ok": True, "enabled": flag_on(user, FLAG_NOTIF) and not is_child(user),
            "free_left": free_left(user), "credits_per_reply": reply_credits(),
            "unlock": unlock_hint(user), "unlock_ad_placement": UNLOCK_PLACEMENT,
            "ads_per_reply": ads_per_reply()}


# ------------------------------------------------------------------ model
_LANG_NAME = {"bn": "Bangla in Bengali script", "roman": "romanized Bangla (Bangla words in English letters)",
              "en": "English"}


def _clip_context(ctx):
    out = []
    for c in (ctx or [])[-R.CONTEXT_MAX:]:
        if not isinstance(c, dict):
            continue
        who = "me" if str(c.get("from") or "") == "me" else "them"
        t = str(c.get("text") or "").strip()[:R.CONTEXT_LINE_MAX]
        if t:
            out.append("%s: %s" % (who, t))
    return out


def _task(kind, lang, style, busy_label=""):
    n = "ONE short reply" if kind in ("auto", "busy") else "3 different short replies"
    lines = [
        "You draft chat replies FOR the user (\"me\") to the last message from \"them\".",
        "Output ONLY compact JSON: {\"hold\": true|false, \"category\": \"\", \"replies\": [\"...\"]}.",
        "Give %s, each under 15 words, natural, friendly, in %s." % (n, _LANG_NAME.get(lang, "English")),
        "Set hold=true (and replies=[]) if the message is about money or payments, an address or location, "
        "meeting in person, a health emergency or danger, a promise or commitment, a big life decision, "
        "a code/OTP/password, or anything the user must answer personally. category is one of: "
        + ", ".join(R.CATEGORIES) + ", other.",
        "Never invent facts, plans, times, prices or promises. Never claim to be the user in a way that "
        "commits them to anything.",
    ]
    if kind == "busy":
        lines.append("The user is busy%s: politely say they are busy and will reply later." %
                     (" until " + busy_label if busy_label else ""))
    if style:
        lines.append(style)
    return "\n".join(lines)


def _run_model(user, kind, text, context, lang, style, busy_label="", feature="ai_reply"):
    """(status, hold, category, replies, charged). status: ok | no_credits |
    ai_unavailable | bad_output. A failed / cut / unparsable answer is refunded."""
    from . import ai, billing
    action = ACTION_AUTO if kind in ("auto", "busy") else ACTION_SUGGEST
    meta = {}
    data = "\n".join(_clip_context(context) + ["them: " + text[:R.TEXT_MAX]])
    try:
        raw, _cost = ai.generate(_task(kind, lang, style, busy_label), data=data, tier="cheap",
                                 max_tokens=R.OUT_TOKENS, feature=feature, user=user,
                                 charge_action=action, task_class="cheap", out_meta=meta, pii=True)
    except ai.AIUnavailable as e:
        return ("no_credits" if e.reason == "credits" else "ai_unavailable"), False, "", [], 0
    except Exception as e:  # noqa: BLE001 — never the text, only the error type
        log.warning("ai_reply: model error %s", type(e).__name__)
        return "ai_unavailable", False, "", [], 0
    charged = int(meta.get("charged") or 0)
    hold, cat, replies = R.parse_model(raw)
    if hold is None or meta.get("truncated") or (not hold and not replies):
        if charged:   # a cut / unusable answer is never charged
            try:
                billing.credit(user, "adjust", charged, note="ai_reply refund (cut answer)",
                               spend_ref=meta.get("spend_ref") or None)
            except Exception:  # noqa: BLE001
                log.warning("ai_reply: refund failed")
        return "bad_output", False, "", [], 0
    return "ok", bool(hold), cat, replies, charged


# ------------------------------------------------------------------ suggest
def suggest(user, body, source="circle"):
    """(status, body) — never stores or logs the text."""
    from .models import CircleGroup, CircleGroupMember, CircleMember
    text = str(body.get("text") or "").strip()
    if not text:
        return 400, {"ok": False, "reason": "no_text"}
    flag = FLAG_NOTIF if source == "notif" else FLAG
    if not flag_on(user, flag):
        return 403, {"ok": False, "reason": "flag_off"}
    edge = group = None
    if source == "circle":
        if body.get("member_id"):
            edge = CircleMember.objects.filter(user=user, pk=body.get("member_id")).first()
            if edge is None:
                return 404, {"ok": False, "reason": "not_found"}
        elif body.get("group_id"):
            group = CircleGroup.objects.filter(pk=body.get("group_id")).first()
            if group is None or not CircleGroupMember.objects.filter(
                    group=group, member=user, status="active").exists():
                return 404, {"ok": False, "reason": "not_found"}
    if child_pair(user, edge):
        return 403, {"ok": False, "reason": "child"}
    cat = R.classify(text)
    ev = {"member": edge, "group_id_ref": getattr(group, "id", None), "source": source[:8]}
    if cat:
        _event(user, "refused", category=cat, **ev)
        return 200, {"ok": False, "reason": "blocked", "needs_you": True, "category": cat}
    if not suggest_rate_ok(user):
        return 429, {"ok": False, "reason": "rate_limited"}
    lang = str(body.get("lang") or "auto")
    lang = lang if lang in ("bn", "en", "roman") else R.detect_lang(text)
    prof = profile(user)
    style = R.style_hint(prof.style) if prof.style_consent else ""
    st, hold, mcat, replies, charged = _run_model(user, "suggest", text, body.get("context"), lang,
                                                  style, feature="ai_reply.suggest")
    if st == "no_credits":
        return 402, {"ok": False, "reason": "no_credits", "unlock": unlock_hint(user)}
    if st != "ok":
        return 503, {"ok": False, "reason": "ai_unavailable"}
    if hold:
        _event(user, "refused", category=mcat or "other", credits=charged, **ev)
        return 200, {"ok": False, "reason": "blocked", "needs_you": True, "category": mcat or "other",
                     "charged": charged}
    _event(user, "suggest", credits=charged, **ev)
    return 200, {"ok": True, "suggestions": replies, "charged": charged, "lang": lang}


# ------------------------------------------------------------------ auto
def _busy_label(row, lang):
    if row is None or row.busy_until is None:
        return ""
    t = timezone.localtime(row.busy_until)
    h12 = t.hour % 12 or 12
    s = "%d:%02d" % (h12, t.minute)
    if lang == "bn":
        return s.translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")) + "-এর"
    if lang == "roman":
        return s + " er"
    return s + (" pm" if t.hour >= 12 else " am")


def _loop_suspected(edge, msg):
    """True when BOTH sides' AI sent messages among the newest few — two
    auto-repliers talking to each other. My own AI replies to a human never
    count (Full auto keeps the conversation going)."""
    from .models import AiReplyMark
    from .views_m1_messenger import conversation_rows
    ids = list(conversation_rows(edge).order_by("-created_at", "-id")
               .values_list("id", flat=True)[:R.LOOP_WINDOW])
    if not ids:
        return False
    senders = set(AiReplyMark.objects.filter(message_id__in=ids)
                  .values_list("message__sender_id", flat=True))
    return len(senders) >= 2


def _notify_held(user, edge, category):
    try:
        from . import push
        name = (getattr(edge, "name", "") or "").strip()
        peer = peer_of(edge)
        if peer is not None:
            name = push.seen_name(user, peer) or name
        name = name or "Assisto"
        push.safe_push(user, "message",
                       "AI %s-এর একটি মেসেজ রেখে দিয়েছে" % name,
                       "AI held a message from %s" % name,
                       "এটির উত্তর আপনাকেই দিতে হবে।", "It needs you.",
                       data={"chat_kind": "member", "chat_id": edge.id, "ai_held": "1",
                             "category": category, "route": "circle/chat"})
    except Exception:  # noqa: BLE001 — a push never breaks the decision
        pass


def auto(user, body):
    """(status, body): {action: send|hold|skip}. The phone sends the reply
    itself (E2E) with the returned token; mark_sent() then tags it."""
    from .models import AiReplyEvent, AiReplyMark, CircleMember
    if not flag_on(user):
        return 200, {"ok": True, "action": "skip", "reason": "flag_off"}
    edge = CircleMember.objects.filter(user=user, pk=body.get("member_id")).first()
    if edge is None:
        return 404, {"ok": False, "reason": "not_found"}
    row = _setting(user, edge)
    mode = effective_mode(row)
    if mode not in ("busy", "auto"):
        return 200, {"ok": True, "action": "skip", "reason": "mode_" + mode}
    if child_pair(user, edge):
        return 200, {"ok": True, "action": "skip", "reason": "child"}
    try:
        mid = int(body.get("message_id") or 0)
    except (TypeError, ValueError):
        mid = 0
    from .views_m1_messenger import conversation_rows
    msg = conversation_rows(edge).filter(pk=mid).first() if mid else None
    peer = peer_of(edge)
    if msg is None or peer is None or msg.sender_id != peer.pk:
        return 404, {"ok": False, "reason": "not_found"}
    if msg.content_type != "text" or msg.deleted:
        return 200, {"ok": True, "action": "skip", "reason": "not_text"}
    if (timezone.now() - msg.created_at).total_seconds() > R.STALE_INCOMING_S:
        return 200, {"ok": True, "action": "skip", "reason": "stale"}
    if conversation_rows(edge).filter(pk__gt=mid, sender=user).exists():
        return 200, {"ok": True, "action": "skip", "reason": "answered"}   # I already wrote after it
    # loop guard: never answer an AI-tagged auto reply; never keep an AI ping-pong going
    if AiReplyMark.objects.filter(message=msg).exists() or _loop_suspected(edge, msg):
        return 200, {"ok": True, "action": "skip", "reason": "loop"}
    text = str(body.get("text") or "").strip()
    if not text:
        return 400, {"ok": False, "reason": "no_text"}
    # one decision per incoming message, even when the open chat and the
    # push handler ask at the same moment (DB-unique lock key)
    from django.db import IntegrityError, transaction
    try:
        with transaction.atomic():
            e = AiReplyEvent.objects.create(user=user, member=edge, source="circle", kind="pending",
                                            in_message_id=mid, lock_key="%d:%d" % (user.pk, mid))
    except IntegrityError:
        return 200, {"ok": True, "action": "skip", "reason": "done"}
    cat = R.classify(text)
    if cat:
        _settle(e, "held", category=cat)
        _notify_held(user, edge, cat)
        return 200, {"ok": True, "action": "hold", "category": cat}
    if not auto_rate_ok(user, edge):
        e.delete()
        return 200, {"ok": True, "action": "skip", "reason": "rate_limited"}
    lang = R.detect_lang(text)
    prof = profile(user)
    style = R.style_hint(prof.style) if prof.style_consent else ""
    label = _busy_label(row, lang) if mode == "busy" else ""
    st, hold, mcat, replies, charged = _run_model(user, mode, text, body.get("context"), lang, style,
                                                  busy_label=label, feature="ai_reply." + mode)
    if st == "no_credits":
        e.delete()          # nothing decided: a later try (after an ad / top-up) may answer it
        return 200, {"ok": True, "action": "skip", "reason": "no_credits", "unlock": unlock_hint(user)}
    if st != "ok":
        if mode != "busy":
            e.delete()
            return 200, {"ok": True, "action": "skip", "reason": "ai_unavailable"}
        replies, charged, hold = [R.busy_template(lang, label)], 0, False   # free fallback
    if hold:
        _settle(e, "held", category=mcat or "other", credits=charged)
        _notify_held(user, edge, mcat or "other")
        return 200, {"ok": True, "action": "hold", "category": mcat or "other"}
    _settle(e, mode, credits=charged)
    tok = signing.dumps({"u": user.pk, "m": edge.id, "e": e.id}, salt=SEND_SALT)
    return 200, {"ok": True, "action": "send", "reply": replies[0], "token": tok,
                 "label": bool(row.label_on), "kind": mode, "charged": charged}


def mark_sent(user, edge, message, token):
    """Tag a just-sent 1:1 message as AI-sent (single use). Never raises."""
    try:
        from .models import AiReplyEvent, AiReplyMark
        d = signing.loads(str(token or ""), salt=SEND_SALT, max_age=SEND_TOKEN_MAX_AGE)
        if d.get("u") != user.pk or d.get("m") != edge.id:
            return False
        n = AiReplyEvent.objects.filter(pk=d.get("e"), user=user, member=edge,
                                        token_used=False).update(token_used=True)
        if not n:
            return False
        ev = AiReplyEvent.objects.get(pk=d.get("e"))
        row = _setting(user, edge)
        AiReplyMark.objects.get_or_create(message=message, defaults={
            "kind": ev.kind if ev.kind in ("busy", "auto") else "auto",
            "label": bool(row.label_on) if row else True})
        return True
    except Exception:  # noqa: BLE001 — a bad token just sends a normal message
        return False


def annotate(rows, msgs):
    """Message list rows: ai_reply (AI sent it) + ai_label (show the tag)."""
    try:
        from .models import AiReplyMark
        ids = [x.id for x in msgs]
        marks = {m.message_id: m.label for m in AiReplyMark.objects.filter(message_id__in=ids)}
    except Exception:  # noqa: BLE001
        marks = {}
    for row in rows:
        lab = marks.get(row.get("id"))
        row["ai_reply"] = lab is not None
        row["ai_label"] = bool(lab)


def held_list(user):
    from .models import AiReplyEvent
    out = []
    for e in (AiReplyEvent.objects.filter(user=user, kind="held", seen=False)
              .select_related("member").order_by("-created_at")[:50]):
        out.append({"id": e.id, "member_id": e.member_id, "message_id": e.in_message_id,
                    "name": (getattr(e.member, "name", "") or "") if e.member else "",
                    "category": e.category, "at": e.created_at.isoformat()})
    return {"ok": True, "results": out}


def held_seen(user, pk):
    from .models import AiReplyEvent
    n = AiReplyEvent.objects.filter(user=user, kind="held", pk=pk).update(seen=True)
    return bool(n)
