"""b2-badges one-time repair: mark old incoming My Circle messages READ in
every conversation the user has demonstrably opened.

Why: the pre-c3 read path (messenger/chats/<pk>/read) filtered the reader's
own edge, so messages the peer sent on THEIR edge never got read_by — the home
badge kept counting them (owner: "14" that never dropped).

A conversation counts as OPENED by user U when U sent at least one message in
it, or there is any receipt / read_by mark from U in it. Only incoming
messages created strictly BEFORE --before are touched; chats U never opened and
messages at/after the cutoff are left alone. Marking goes through c3's
views_c3_msg.mark(..., seen=True): CircleReceipt delivered_at/seen_at +
legacy read_by/delivered_to stay consistent. Idempotent: a second run finds
nothing to do.

  manage.py repair_chat_read_state --before 2026-10-22T00:00:00+06:00 --dry-run
  manage.py repair_chat_read_state --before 2026-10-22T00:00:00+06:00
  [--user <id>]   limit to one user
"""
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone
from django.utils.dateparse import parse_datetime


def _needs(user_id, x, seen_ids):
    return user_id not in (x.read_by or []) or x.id not in seen_ids


def plan(before, user_ids=None):
    """[(user, kind, chat_id, [messages to mark])] — pure read, no writes."""
    from core.models import (CircleGroupMember, CircleMember, CircleMessage,
                             CircleReceipt, User)
    from core.views_m1_messenger import conversation_rows
    users = User.objects.all().order_by("id")
    if user_ids:
        users = users.filter(id__in=user_ids)
    out = []
    for u in users.iterator():
        done = set()
        # 1:1 — every edge of mine (one conversation may be reachable via
        # more than one edge; each message is planned once)
        for edge in CircleMember.objects.filter(user=u).order_by("id"):
            rows = list(conversation_rows(edge))
            if not rows:
                continue
            out.extend(_plan_chat(u, "member", edge.id, rows, before, done))
        for gm in CircleGroupMember.objects.filter(member=u).order_by("id"):
            rows = list(CircleMessage.objects.filter(group_id=gm.group_id)
                        .order_by("created_at", "id"))
            if not rows:
                continue
            out.extend(_plan_chat(u, "group", gm.group_id, rows, before, done))
    return out


def _plan_chat(u, kind, chat_id, rows, before, done):
    from core.models import CircleReceipt
    ids = [x.id for x in rows]
    rec = list(CircleReceipt.objects.filter(user=u, message_id__in=ids)
               .values_list("message_id", "seen_at"))
    seen_ids = {m for m, s in rec if s is not None}
    opened = (any(x.sender_id == u.id for x in rows) or bool(rec)
              or any(u.id in (x.read_by or []) for x in rows))
    if not opened:
        return []
    todo = [x for x in rows
            if x.sender_id != u.id and x.id not in done
            and x.created_at < before and _needs(u.id, x, seen_ids)]
    for x in todo:
        done.add(x.id)
    return [(u, kind, chat_id, todo)] if todo else []


class Command(BaseCommand):
    help = ("One-time, idempotent: mark incoming My Circle messages older "
            "than --before as read in chats each user has opened.")

    def add_arguments(self, parser):
        parser.add_argument("--before", required=False, default=None,
                            help="ISO timestamp cutoff (required).")
        parser.add_argument("--dry-run", action="store_true",
                            help="Print per-user/per-chat counts; write nothing.")
        parser.add_argument("--user", type=int, action="append", default=None,
                            help="Limit to this user id (repeatable).")

    def handle(self, *args, **opts):
        raw = opts.get("before")
        if not raw:
            raise CommandError("--before <ISO timestamp> is required "
                               "(refusing to run without a cutoff).")
        before = parse_datetime(raw)
        if before is None:
            raise CommandError("--before: not an ISO timestamp: %r" % raw)
        if timezone.is_naive(before):
            before = timezone.make_aware(before)
        dry = bool(opts.get("dry_run"))
        from core import views_c3_msg as C3
        rows = plan(before, opts.get("user"))
        total = 0
        now = timezone.now()
        for u, kind, cid, msgs in rows:
            if not dry:
                C3.mark(u, msgs, seen=True, now=now)
            total += len(msgs)
            self.stdout.write("user=%d %s:%s messages=%d" % (u.id, kind, cid,
                                                             len(msgs)))
        self.stdout.write("%s: %d message(s) in %d chat(s), cutoff %s" % (
            "DRY RUN — would mark" if dry else "marked read", total, len(rows),
            before.isoformat()))
