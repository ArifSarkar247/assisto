"""
Hard-delete accounts whose "Delete my profile & all data" grace period has
elapsed. This is the ONLY place the real, complete, cascading delete happens.

For every AccountDeletionRequest that is still `pending` and whose effective_at
is now in the past, we:
  1. delete the user's uploaded FILES off disk first (vault docs, avatar,
     captured theft photos, support screenshots, catalog/khata photos) — a DB
     cascade removes the rows but NOT the bytes on disk;
  2. hard-delete the User, which cascades every CASCADE child (memories, audit,
     reminders, notes, todos, money, circle edges, protected phones, …);
  3. the AccountDeletionRequest row goes with the user (OneToOne CASCADE), so a
     completed purge leaves no trace to re-process — the command is IDEMPOTENT.

A CANCELLED request is never touched. A not-yet-due pending request is skipped.

Idempotent + cheap: safe to run hourly from cron. Only touches Assisto's own DB.
Crontab (hourly, low priority):

  0 * * * *  nice -n15 ionice -c3 /home/ubuntu/assisto/backend/.venv/bin/python /home/ubuntu/assisto/backend/manage.py purge_deletions >> /home/ubuntu/assisto/backend/logs/purge_deletions.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.db import transaction
from django.utils import timezone

from core.models import AccountDeletionRequest, AuditLog


# dl1: the file sweep lives in core.account_purge so the in-app "Delete now
# and start fresh" path (views_account_deletion.StartFreshView) reuses the
# exact same purge. Re-exported here for existing imports.
from core.account_purge import _FILE_FIELDS, _delete_user_files  # noqa: E402,F401


class Command(BaseCommand):
    help = ("Hard-delete accounts whose deletion grace period has elapsed "
            "(pending + effective_at<=now). Idempotent.")

    def add_arguments(self, parser):
        parser.add_argument("--dry-run", action="store_true",
                            help="Report what would be purged; delete nothing.")

    def handle(self, *args, **opts):
        now = timezone.now()
        dry = opts.get("dry_run")
        due = (AccountDeletionRequest.objects
               .filter(state=AccountDeletionRequest.STATE_PENDING,
                       effective_at__lte=now)
               .select_related("user"))
        purged = 0
        for req in due:
            user = req.user
            uid, uname = user.id, (user.username or "")
            if dry:
                self.stdout.write(f"[dry-run] would purge user {uid} ({uname})")
                continue
            with transaction.atomic():
                files = _delete_user_files(user)
                # Audit the purge on a SEPARATE row keyed to nobody via a copy
                # of the facts — the user's own AuditLog rows cascade away. We
                # write it just before the delete so the transaction keeps it
                # only if the delete commits; here we store it detached by
                # nulling the FK is impossible (AuditLog.user is NOT NULL), so
                # we emit it to stdout for the cron log and keep the DB clean.
                self.stdout.write(
                    f"purged user {uid} ({uname}); files_removed={files}; "
                    f"requested_at={req.requested_at.isoformat()}")
                user.delete()  # cascades all data + the deletion_request row
            purged += 1
        if not dry:
            self.stdout.write(self.style.SUCCESS(f"purged {purged} account(s)"))
        else:
            self.stdout.write(f"[dry-run] {due.count()} account(s) due")
