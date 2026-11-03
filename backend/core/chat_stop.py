"""aileft (owner AI rebuild 4 Nov 01:02 item 4/6 + 23:15 PART 4): the Stop
button of the home chat and of Assisto AI — "Stop cancels the request on the
server and charges only for what was delivered".

THE STOP RULE (documented for the owner in owner_actions/FEATURE_CARD_AI_CHAT_BN.md):

  * The app reports how many characters of the answer were already SHOWN on
    the screen when the user tapped Stop (`shown_chars`).
  * Nothing shown, or less than MIN_SHOWN_CHARS (120) characters, or less
    than MIN_SHOWN_FRACTION (15 %) of the answer  ->  0 credits (full refund).
  * Otherwise the charge is the delivered share of the answer's price,
    rounded UP:  ceil(credits x shown / total)  (never more than the price).
  * Abuse guard: at most FREE_STOPS_PER_DAY (10) zero-charge stops per user
    per day; after that a stopped answer that delivered anything costs at
    least 1 credit (an instant stop with nothing shown stays free).
  * A stop is accepted only within STOP_WINDOW_S (10 min) of the answer.
  * The stored answer is cut to the part the user saw, so the next turn's
    context matches the screen; the message is marked `stopped`.

Honest limit: the provider call that is already running cannot be aborted
mid-way (every answer passes the safety / money / action guards on the FULL
text before the first token is sent). A stop that arrives while the answer
is still being made is parked here and applied the moment the turn is saved
(the user is refunded in full; our provider cost for that answer is a loss,
bounded by the abuse guard above).

Cross-worker: the parked stop is a PaCollectionItem row (collection
"chatstop"), not the per-process cache — gunicorn runs several workers.
"""
import logging
import math
from datetime import timedelta

from django.db import transaction
from django.utils import timezone

log = logging.getLogger(__name__)

MIN_SHOWN_CHARS = 120
MIN_SHOWN_FRACTION = 0.15
FREE_STOPS_PER_DAY = 10
STOP_WINDOW_S = 600
_COLL = "chatstop"
_PAID_LEVELS = ("better", "best")


def charge_for(credits, shown, total, free_stops_used=0):
    """Credits to keep for an answer of `total` chars stopped after `shown`
    chars were on the screen (pure; the rule above)."""
    credits = max(0, int(credits or 0))
    total = max(0, int(total or 0))
    shown = max(0, min(int(shown or 0), total))
    if credits <= 0 or shown <= 0 or total <= 0:
        return 0
    if shown >= total:
        return credits
    if shown < MIN_SHOWN_CHARS or shown < total * MIN_SHOWN_FRACTION:
        return 1 if free_stops_used >= FREE_STOPS_PER_DAY else 0
    return min(credits, max(1, math.ceil(credits * shown / total)))


def _free_stops_today(user):
    from .models import ChatMessage
    day0 = timezone.localtime().replace(hour=0, minute=0, second=0, microsecond=0)
    return ChatMessage.objects.filter(session__user=user, role="assistant",
                                      created_at__gte=day0, meta__stopped=True,
                                      meta__stop_free=True).count()


def _find_answer(user, cid):
    """(user message, its assistant answer or None) for this client id over
    the user's own chats (home + Assisto AI)."""
    from .models import ChatMessage
    um = (ChatMessage.objects.filter(session__user=user, role="user", meta__client_id=cid)
          .order_by("-id").first())
    if um is None:
        return None, None
    nxt = ChatMessage.objects.filter(session=um.session, role="user", id__gt=um.id) \
        .order_by("id").first()
    qs = ChatMessage.objects.filter(session=um.session, role="assistant", id__gt=um.id)
    if nxt is not None:
        qs = qs.filter(id__lt=nxt.id)
    return um, qs.order_by("id").first()


def _cut_text(text, shown):
    """The part of the answer the user saw (never mid-word when possible)."""
    if shown >= len(text):
        return text
    part = text[:max(0, shown)]
    sp = part.rfind(" ")
    if sp > len(part) * 0.6:
        part = part[:sp]
    return part.rstrip()


def apply(user, asst, shown):
    """Apply the stop rule to one stored answer (idempotent). Returns the
    public result {stopped, credits, refunded, balance, shown_chars}."""
    from . import billing
    from .models import ChatMessage
    with transaction.atomic():
        m = ChatMessage.objects.select_for_update().get(pk=asst.pk)
        meta = dict(m.meta or {})
        if meta.get("stopped"):
            return _result(user, meta)
        full = m.text or ""
        total = len(full)
        shown = max(0, min(int(shown or 0), total))
        credits = int(meta.get("credits") or 0)
        free_used = _free_stops_today(user)
        keep = charge_for(credits, shown, total, free_used)
        refund = credits - keep
        if refund > 0:
            try:
                # back to the SAME lots the answer was paid from (rule N) ...
                billing.credit(user, "adjust", credits, note="ai_refund:stopped",
                               spend_ref=meta.get("spend_ref") or None)
                if keep > 0:
                    # ... then only the delivered share is taken again
                    lvl = meta.get("level") or ""
                    res = billing.charge(user, ("ai_level_" + lvl) if lvl else "ai_msg_medium",
                                         qty=1, note="chat.stopped_part", exact=keep,
                                         paid_only=lvl in _PAID_LEVELS)
                    if not res.get("ok"):
                        keep, refund = 0, credits
                from . import ai_usage_log
                ai_usage_log.mark_refunded(user, refund, "chat:stopped")
            except Exception:  # noqa: BLE001 — the answer stays; log it
                log.exception("chat stop: refund failed")
                keep, refund = credits, 0
        meta.update({"stopped": True, "shown_chars": shown, "full_chars": total,
                     "credits": keep, "stop_free": keep == 0 and credits > 0})
        if refund > 0:
            meta["refunded"] = int(meta.get("refunded") or 0) + refund
        meta.pop("cut", None)          # a stopped answer offers no "Continue"
        m.text = _cut_text(full, shown)
        m.meta = meta
        m.save(update_fields=["text", "meta"])
    return _result(user, meta)


def _result(user, meta):
    from . import ai_chat_guard as G
    out = {"stopped": True, "credits": int(meta.get("credits") or 0),
           "refunded": int(meta.get("refunded") or 0),
           "shown_chars": int(meta.get("shown_chars") or 0)}
    bal = G.balance(user)
    if bal is not None:
        out["balance"] = bal
    return out


def request_stop(user, cid, shown):
    """POST /chat/stop. Park the stop FIRST (so a turn finishing right now
    still sees it), then apply it at once when the answer is already saved."""
    from .models import PaCollectionItem
    shown = max(0, int(shown or 0))
    PaCollectionItem.objects.filter(user=user, collection=_COLL, data__cid=cid).delete()
    PaCollectionItem.objects.create(user=user, collection=_COLL,
                                    data={"cid": cid, "shown": shown})
    um, asst = _find_answer(user, cid)
    if asst is None:
        out = {"stopped": True, "pending": True, "credits": 0, "refunded": 0,
               "shown_chars": shown}
        if um is not None:
            out["session_id"] = um.session_id
        return out
    if timezone.now() - asst.created_at > timedelta(seconds=STOP_WINDOW_S):
        _clear(user, cid)
        return None
    out = apply(user, asst, shown)
    out["session_id"] = asst.session_id
    _clear(user, cid)
    return out


def after_turn(user, cid, asst_id):
    """Called by every chat view right after it saved an answer: a stop that
    arrived while the answer was being made is applied now. Returns the stop
    result or None."""
    if not cid or not asst_id or user is None:
        return None
    try:
        from .models import PaCollectionItem, ChatMessage
        row = PaCollectionItem.objects.filter(user=user, collection=_COLL,
                                              data__cid=cid).first()
        if row is None:
            return None
        asst = ChatMessage.objects.filter(pk=asst_id, session__user=user).first()
        if asst is None:
            return None
        out = apply(user, asst, int((row.data or {}).get("shown") or 0))
        _clear(user, cid)
        return out
    except Exception:  # noqa: BLE001 — never breaks the answer
        log.exception("chat stop: after_turn failed")
        return None


def _clear(user, cid):
    from .models import PaCollectionItem
    PaCollectionItem.objects.filter(user=user, collection=_COLL, data__cid=cid).delete()
    # old parked stops (a turn that never finished) go after an hour
    PaCollectionItem.objects.filter(user=user, collection=_COLL,
                                    created_at__lt=timezone.now() - timedelta(hours=1)).delete()
