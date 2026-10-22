"""e2-keys item 2 — paged chat history for the reversed chat list.

GET /circle/<id>/messages and /circle/groups/<id>/messages stay backward
compatible (no params -> the whole visible conversation). The app now sends:
  ?limit=N            newest N messages (extended back to include the FIRST
                      unread incoming message, so the chat can open at the
                      "N unread messages" divider), capped at PAGE_MAX_UNREAD;
  ?limit=N&before=ID  the N messages older than message ID (scroll-up paging).
Every incoming message carries `unseen` (no seen receipt for the viewer yet)
and the response carries `has_more` + `unread_count`.
"""
PAGE_MAX = 200
PAGE_MAX_UNREAD = 500


def _int(v, default=None):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def wants_page(request):
    return request.query_params.get("limit") not in (None, "")


def unseen_ids(viewer, msgs):
    """ids of incoming messages the viewer has not SEEN yet."""
    from .models import CircleReceipt
    incoming = [x.id for x in msgs if x.sender_id != viewer.id
                and (x.deleted or "") != "everyone"]
    if not incoming:
        return set()
    seen = set(CircleReceipt.objects.filter(
        user=viewer, message_id__in=incoming, seen_at__isnull=False)
        .values_list("message_id", flat=True))
    return set(incoming) - seen


def page(request, msgs, viewer):
    """(page_msgs, meta) — msgs is the oldest-first visible list."""
    limit = max(1, min(PAGE_MAX, _int(request.query_params.get("limit"), 50)))
    before = _int(request.query_params.get("before"))
    rows = list(msgs)
    if before:
        rows = [x for x in rows if x.id < before]
    start = max(0, len(rows) - limit)
    unseen = unseen_ids(viewer, rows)
    if not before and unseen:
        first = next((i for i, x in enumerate(rows) if x.id in unseen), None)
        if first is not None and first < start:
            start = max(first, len(rows) - PAGE_MAX_UNREAD)
    out = rows[start:]
    return out, {"has_more": start > 0, "unread_count": len(unseen),
                 "unseen": unseen}


def mark_unseen(out_rows, unseen):
    for d in out_rows:
        if not d.get("mine"):
            d["unseen"] = d.get("id") in unseen
    return out_rows
