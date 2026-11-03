"""e-gaps (owner order E) — My Circle gaps vs WhatsApp / Messenger / Telegram.

Server side of:
  * VIEW-ONCE media (photo / video / voice; 1:1 and, since viewonce, groups):
    the send carries `view_once: true` (routing metadata only — the file key
    stays inside the E2E descriptor). The sender's own copy is never served
    back. The recipient's phone calls POST circle/messages/<id>/view-once-open
    {want_url: true} BEFORE downloading: claim_open() records the open (a
    second open by the same person is REFUSED, 409), blanks the descriptor
    and hands out the one signed download link. The encrypted blob is
    deleted by the minute job (view_once_purge) 15 min after the last
    recipient opened, or after 14 days (owner-editable) if unopened. A
    view-once blob can't be forwarded by anyone but its uploader.
  * DISAPPEARING messages really deleted without a cron: the read paths
    delete rows that are past the chat's timer (and drop their encrypted
    blobs) instead of only hiding them; the purge command does the same for
    chats nobody opens.
"""
from django.utils import timezone

VIEW_ONCE_KINDS = frozenset({"photo", "video", "voice"})   # viewonce: + voice
# viewonce: after the LAST recipient opened, the encrypted blob stays this
# long so the signed download link handed out at open time (10 min) can
# finish; then the minute job deletes it.
URL_GRACE_S = 15 * 60


def wants_view_once(env, content_type):
    return bool(env.get("view_once")) and content_type in VIEW_ONCE_KINDS


def is_view_once_blob(ref):
    """True when any message carrying `ref` is a view-once message."""
    from .models import CircleMessage
    if not ref:
        return False
    return CircleMessage.objects.filter(blob_ref=ref, view_once=True).exists()


def keep_days():
    from . import circle_blobs as CB
    return int(CB.limits()["circle_media_view_once_days"])


# ------------------------------------------------------------ recipients
def recipient_ids(x):
    """User ids this view-once message was sent TO (who may open it once).
    1:1: the other side of the edge. Group: the members it was sealed for
    (the per_recipient fan-out keys are membership ids) — someone who joins
    later never could decrypt it, so never counts."""
    if x.group_id:
        from .models import CircleGroupMember
        per = x.per_recipient if isinstance(x.per_recipient, dict) else {}
        gm_ids = [int(k) for k in per.keys() if str(k).isdigit()]
        for r in (x.recipient_ids if isinstance(x.recipient_ids, list) else []):
            if str(r).isdigit():
                gm_ids.append(int(r))
        ids = set(CircleGroupMember.objects.filter(
            id__in=set(gm_ids), group_id=x.group_id).values_list(
                "member_id", flat=True))
        return ids - {x.sender_id}
    m = x.member
    if m is None:
        return set()
    return {i for i in (m.user_id, m.peer_user_id) if i} - {x.sender_id}


def _opens(x):
    o = x.view_once_opens
    return dict(o) if isinstance(o, dict) else {}


def opened_by(x, uid):
    if str(uid) in _opens(x):
        return True
    # legacy rows (before viewonce): 1:1 opened time only
    return (not x.group_id and x.view_once_opened_at is not None
            and uid != x.sender_id)


def all_opened(x, rec=None):
    rec = recipient_ids(x) if rec is None else rec
    if not x.group_id and x.view_once_opened_at is not None:
        return True
    o = _opens(x)
    return bool(rec) and all(str(u) in o for u in rec)


# ------------------------------------------------------------ serializing
def annotate(row, x, uid):
    """Add the view-once state to one serialized 1:1 message for viewer
    `uid` and strip what this viewer must not get."""
    if not getattr(x, "view_once", False):
        return row
    mine = x.sender_id == uid
    expired = x.view_once_expired_at is not None
    opened = all_opened(x) if mine else opened_by(x, uid)
    row["view_once"] = True
    row["view_once_opened"] = opened
    row["view_once_expired"] = expired and not opened
    at = x.view_once_opened_at
    if not mine:
        t = _opens(x).get(str(uid))
        row["view_once_opened_at"] = t or (at.isoformat() if at else None)
    else:
        row["view_once_opened_at"] = at.isoformat() if at else None
    if opened or mine or expired:
        row["ciphertext"] = ""
        row["nonce"] = ""
        row["blob_ref"] = ""
    return row


def annotate_group(row, x, uid, my_gm_id=None):
    """viewonce: the same for one serialized GROUP message. Each member
    opens once; the sender sees how many opened and when the last did."""
    if not getattr(x, "view_once", False):
        return row
    mine = x.sender_id == uid
    expired = x.view_once_expired_at is not None
    o = _opens(x)
    row["view_once"] = True
    row["view_once_expired"] = expired
    row["ciphertext"] = ""     # the top-level copy is one member's entry
    row["nonce"] = ""
    if mine:
        rec = recipient_ids(x)
        row["view_once_open_count"] = len([u for u in rec if str(u) in o])
        row["view_once_total"] = len(rec)
        row["view_once_opened"] = bool(rec) and all(str(u) in o for u in rec)
        last = max(o.values()) if o else None
        row["view_once_opened_at"] = last
    else:
        row["view_once_opened"] = str(uid) in o
        row["view_once_opened_at"] = o.get(str(uid))
    per = row.get("per_recipient")
    keep_mine = not mine and not expired and not row["view_once_opened"]
    if isinstance(per, dict):
        row["per_recipient"] = {
            k: (v if keep_mine and my_gm_id is not None and str(k) == str(my_gm_id)
                else {}) for k, v in per.items()}
    if mine or expired or row["view_once_opened"]:
        row["blob_ref"] = ""
    return row


def envelope_hook(env, x):
    """viewonce: notification / chat-list envelopes NEVER carry a view-once
    descriptor (it holds the file key) — the phone shows only
    "Photo, view once"."""
    if getattr(x, "view_once", False):
        env["view_once"] = True
        env["ciphertext"] = ""
        env["nonce"] = ""
    return env


# ------------------------------------------------------------ open (server-enforced)
def _my_gm_id(x, uid):
    from .models import CircleGroupMember
    return CircleGroupMember.objects.filter(
        group_id=x.group_id, member_id=uid).values_list("id", flat=True).first()


def claim_open(x, user, now=None):
    """The ONE place a view-once message is opened. Returns (ok, code):
    opened | already_opened | sender | expired | not_recipient |
    not_view_once. A second open by the same person is REFUSED here — the
    phone's own record is only a second line of defence."""
    from django.db import transaction
    from .models import CircleMessage
    if not x.view_once:
        return False, "not_view_once"
    if x.sender_id == user.id:
        return False, "sender"
    now = now or timezone.now()
    with transaction.atomic():
        x = CircleMessage.objects.select_for_update().get(pk=x.pk)
        if opened_by(x, user.id):
            return False, "already_opened"
        if x.view_once_expired_at is not None:
            return False, "expired"
        rec = recipient_ids(x)
        if user.id not in rec:
            return False, "not_recipient"
        o = _opens(x)
        o[str(user.id)] = now.isoformat()
        x.view_once_opens = o
        fields = ["view_once_opens"]
        if x.group_id:
            gm = _my_gm_id(x, user.id)
            per = x.per_recipient if isinstance(x.per_recipient, dict) else {}
            if gm is not None and str(gm) in per:
                per = dict(per)
                per[str(gm)] = {}
                x.per_recipient = per
                fields.append("per_recipient")
            x.ciphertext = ""
            x.nonce = ""
            fields += ["ciphertext", "nonce"]
            if all(str(u) in o for u in rec):
                x.view_once_opened_at = now
                fields.append("view_once_opened_at")
        else:
            x.view_once_opened_at = now
            x.ciphertext = ""
            x.nonce = ""
            fields += ["view_once_opened_at", "ciphertext", "nonce"]
        x.save(update_fields=fields)
    return True, "opened"


def open_view_once(x, user):
    """Legacy ack (builds before viewonce call this AFTER they fetched the
    file): idempotent — an open already recorded is "already" (ok)."""
    ok, code = claim_open(x, user)
    if not ok and code == "already_opened":
        return True, "already"
    return ok, code


def message_for_blob(ref):
    from .models import CircleMessage
    if not ref:
        return None
    return CircleMessage.objects.filter(blob_ref=ref, view_once=True).first()


def refusal_text(code, lang="bn"):
    from .logic.circle import pick
    return {
        "already_opened": pick(lang, "এটি আগেই একবার খোলা হয়েছে — আর খোলা যাবে না।",
                               "This was already opened once. It can't be opened again."),
        "expired": pick(lang, "১৪ দিনে খোলা হয়নি, তাই সার্ভার থেকে মুছে গেছে।",
                        "It wasn't opened within 14 days, so it was deleted from the server."),
        "sender": pick(lang, "আপনার পাঠানো একবার-দেখা মেসেজ আপনি খুলতে পারবেন না।",
                       "You can't open a view-once message you sent."),
    }.get(code, pick(lang, "খোলা যায়নি।", "Couldn't open it."))


# ------------------------------------------------------------ purge (minute job)
def purge_view_once(now=None, limit=500):
    """Delete the server copy (encrypted blob + any descriptor left) of
    view-once messages that (a) every recipient opened, URL_GRACE_S after
    the last open, or (b) nobody opened within keep_days(). Returns
    {"opened": n, "expired": n}. Never raises per row."""
    from datetime import timedelta
    from .models import CircleMessage
    from . import circle_blobs as CB
    now = now or timezone.now()
    out = {"opened": 0, "expired": 0}
    cutoff = now - timedelta(days=keep_days())
    grace = now - timedelta(seconds=URL_GRACE_S)
    qs = (CircleMessage.objects.filter(view_once=True,
                                       view_once_expired_at__isnull=True)
          .exclude(blob_ref="")      # the server copy still exists
          .select_related("member").order_by("id")[:limit])
    for x in qs:
        try:
            rec = recipient_ids(x)
            done = all_opened(x, rec)
            if done:
                o = _opens(x)
                last = x.view_once_opened_at
                if o:
                    try:
                        from datetime import datetime
                        last = max(datetime.fromisoformat(v) for v in o.values())
                    except (TypeError, ValueError):
                        pass
                if last is not None and last > grace:
                    continue
                why = "opened"
            elif x.created_at < cutoff:
                why = "expired"
            else:
                continue
            ref = x.blob_ref
            fields = ["blob_ref", "ciphertext", "nonce"]
            x.blob_ref = ""
            x.ciphertext = ""
            x.nonce = ""
            if isinstance(x.per_recipient, dict) and x.per_recipient:
                x.per_recipient = {k: {} for k in x.per_recipient}
                fields.append("per_recipient")
            if why == "expired":
                x.view_once_expired_at = now
                fields.append("view_once_expired_at")
            x.save(update_fields=fields)
            if ref:
                CB.release(ref)
            out[why] += 1
        except Exception:  # noqa: BLE001 — one bad row never stops the sweep
            continue
    return out


def purge_rows(rows):
    """Delete expired (disappearing) message rows for real + their blobs.
    Never raises — a read must never fail because a purge did."""
    if not rows:
        return 0
    from .models import CircleMessage
    ids = [r.id for r in rows]
    refs = sorted({r.blob_ref for r in rows if r.blob_ref})
    try:
        n, _ = CircleMessage.objects.filter(id__in=ids).delete()
        if refs:
            from . import circle_blobs as CB
            for ref in refs:
                CB.release(ref)
        return n
    except Exception:  # noqa: BLE001
        return 0
