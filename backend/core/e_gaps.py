"""e-gaps (owner order E) — My Circle gaps vs WhatsApp / Messenger / Telegram.

Server side of:
  * VIEW-ONCE media (1:1): the send carries `view_once: true` (routing
    metadata only — the file key stays inside the E2E descriptor). The
    sender's own copy is never served back as ciphertext (WhatsApp: the
    sender can't re-open it either). When the RECIPIENT opens it, the phone
    calls POST circle/messages/<id>/view-once-open: the ciphertext + nonce
    are blanked and the encrypted blob is deleted, so nobody — not even the
    same phone after a reinstall — can open it again. A view-once blob can't
    be forwarded by anyone but its uploader.
  * DISAPPEARING messages really deleted without a cron: the read paths
    delete rows that are past the chat's timer (and drop their encrypted
    blobs) instead of only hiding them; the purge command does the same for
    chats nobody opens.
"""
from django.utils import timezone

VIEW_ONCE_KINDS = frozenset({"photo", "video"})


def wants_view_once(env, content_type):
    return bool(env.get("view_once")) and content_type in VIEW_ONCE_KINDS


def is_view_once_blob(ref):
    """True when any message carrying `ref` is a view-once message."""
    from .models import CircleMessage
    if not ref:
        return False
    return CircleMessage.objects.filter(blob_ref=ref, view_once=True).exists()


def annotate(row, x, uid):
    """Add the view-once state to one serialized 1:1 message for viewer
    `uid` and strip what this viewer must not get."""
    if not getattr(x, "view_once", False):
        return row
    opened = x.view_once_opened_at is not None
    row["view_once"] = True
    row["view_once_opened"] = opened
    if opened or x.sender_id == uid:
        row["ciphertext"] = ""
        row["nonce"] = ""
        row["blob_ref"] = ""
    return row


def open_view_once(x, user):
    """The recipient opened it: wipe the server copies. Returns (ok, code)."""
    if not x.view_once:
        return False, "not_view_once"
    if x.sender_id == user.id:
        return False, "sender"
    if x.view_once_opened_at is not None:
        return True, "already"
    ref = x.blob_ref
    x.view_once_opened_at = timezone.now()
    x.ciphertext = ""
    x.nonce = ""
    x.blob_ref = ""
    x.save(update_fields=["view_once_opened_at", "ciphertext", "nonce",
                          "blob_ref"])
    if ref:
        from . import circle_blobs as CB
        CB.release(ref)
    return True, "opened"


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
