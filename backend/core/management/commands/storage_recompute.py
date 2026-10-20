"""Recompute every user's StorageUsage.used_bytes from the live rows
(Business Model, Build 3).

The storage meter is kept live by core.billing.add_storage on each upload/delete,
but a crash mid-write, a bulk import or a manual DB edit can drift it. This
command rebuilds used_bytes from the ACTUAL retained media so the always-visible
meter is accurate:

  * vault Documents (Document.file.size),
  * the profile avatar (User.photo.size),
  * retained messenger/circle status media (CircleStatus.meta['byte_size'] for
    photo/video statuses that have NOT yet expired — WhatsApp model: delivered+
    expired media is pruned, so only un-expired blobs count),
  * the user's current encrypted chat backup (ChatBackup.size_bytes).

Text messages, voice/video calls and ALL safety features are deliberately NOT
counted (they never consume the media quota).

Run after a deploy and nightly. Crontab (Asia/Dhaka), Assisto-owned box only:
    15 3 * * *  cd /home/ubuntu/assisto/backend && \
        /home/ubuntu/assisto/.venv/bin/python manage.py storage_recompute
"""
from django.core.management.base import BaseCommand
from django.utils import timezone


class Command(BaseCommand):
    help = "Recompute StorageUsage.used_bytes from live retained-media rows."

    def handle(self, *args, **opts):
        from core.models import (User, Document, CircleStatus, ChatBackup,
                                  StorageUsage)
        now = timezone.now()
        touched = 0
        for u in User.objects.all().only("id"):
            total = 0
            # vault documents
            for d in Document.objects.filter(user=u).only("file"):
                total += _file_size(getattr(d, "file", None))
            # avatar
            u_full = User.objects.filter(pk=u.pk).only("photo").first()
            if u_full is not None:
                total += _file_size(getattr(u_full, "photo", None))
            # un-expired status media (photo/video only)
            for st in CircleStatus.objects.filter(
                    author=u, expires_at__gt=now).only("kind", "meta"):
                if st.kind in ("photo", "video"):
                    try:
                        total += int((st.meta or {}).get("byte_size", 0) or 0)
                    except (TypeError, ValueError):
                        pass
            # current chat backup(s)
            for b in ChatBackup.objects.filter(owner=u).only("size_bytes"):
                total += int(b.size_bytes or 0)

            row, _ = StorageUsage.objects.get_or_create(user=u)
            if int(row.used_bytes or 0) != total:
                row.used_bytes = total
                row.save(update_fields=["used_bytes", "updated_at"])
                touched += 1
        self.stdout.write(f"[storage_recompute] recomputed {touched} user(s)")


def _file_size(f):
    try:
        return int(f.size) if f else 0
    except Exception:
        return 0
