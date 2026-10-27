"""Server-side enforcement of disappearing-message timers (m1-messenger).

Deletes for real (rows, not just hidden):
  * 1:1 — messages on a sender's edge whose ChatSettings.disappearing_sec > 0,
    sent at/after the timer started (MsgChatPref.disappearing_since), once
    created_at + ttl has passed. The timer is mirrored onto both edges when it
    is set, so each side's sent messages are covered.
  * groups — messages of a group with MsgGroupTimer.disappearing_sec > 0, sent
    at/after MsgGroupTimer.since, once past the ttl.
  * expired MsgExport files (signed-link group exports, 2h lifetime).

The message READ paths already hide anything past its ttl, so a gap between
runs never shows an expired message. Safe to run as often as you like.

Crontab (Assisto box, every 15 min):
    */15 * * * *  cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py purge_disappearing >> /home/ubuntu/assisto/logs/purge_disappearing.log 2>&1
"""
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Delete messages past their disappearing timer + expired exports."

    def add_arguments(self, parser):
        parser.add_argument("--dry-run", action="store_true")

    @track_job("purge_disappearing")
    def handle(self, *args, **opts):
        from core.models import (ChatSettings, CircleMessage, MsgChatPref,
                                 MsgExport, MsgGroupTimer)
        from core.logic import circle_extras as X
        from core import e_gaps
        now = timezone.now()
        dry = opts.get("dry_run")
        n_dm = n_grp = n_exp = 0

        for cs in ChatSettings.objects.filter(disappearing_sec__gt=0) \
                .select_related("peer"):
            ttl = X.normalize_disappearing(cs.disappearing_sec)
            if not ttl:
                continue
            pref = MsgChatPref.objects.filter(
                user_id=cs.user_id, chat_kind="member",
                chat_id=str(cs.peer_id)).first()
            since = pref.disappearing_since if pref else None
            if since is None:
                continue  # no recorded start -> never purge older history
            qs = CircleMessage.objects.filter(
                member_id=cs.peer_id, sender_id=cs.user_id, group=None,
                created_at__gte=since,
                created_at__lt=now - timedelta(seconds=ttl))
            n_dm += qs.count()
            if not dry:
                e_gaps.purge_rows(list(qs))   # e-gaps: + encrypted blobs

        for t in MsgGroupTimer.objects.filter(disappearing_sec__gt=0):
            ttl = X.normalize_disappearing(t.disappearing_sec)
            if not ttl or t.since is None:
                continue
            qs = CircleMessage.objects.filter(
                group_id=t.group_id, created_at__gte=t.since,
                created_at__lt=now - timedelta(seconds=ttl))
            n_grp += qs.count()
            if not dry:
                e_gaps.purge_rows(list(qs))   # e-gaps: + encrypted blobs

        for e in MsgExport.objects.filter(expires_at__lt=now):
            n_exp += 1
            if not dry:
                try:
                    e.file.delete(save=False)
                except Exception:
                    pass
                e.delete()

        self.stdout.write("[purge_disappearing] %s1:1=%d group=%d exports=%d" % (
            "(dry) " if dry else "", n_dm, n_grp, n_exp))
