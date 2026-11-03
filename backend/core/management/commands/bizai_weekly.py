"""bizai pillar 5: the weekly Bangla business report (core/bizai_prochar.run_weekly).
Once per shop per ISO week (idempotent). Crontab (Friday 10:00 Dhaka = 04:00 UTC):
    0 4 * * 5 ubuntu cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py bizai_weekly >> /home/ubuntu/assisto/logs/bizai_weekly.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Weekly business report per shop (saved + one push)."

    @track_job("bizai_weekly")
    def handle(self, *args, **opts):
        from core import bizai_prochar as BP
        n = BP.run_weekly()
        self.stdout.write("%s bizai_weekly sent=%d" % (timezone.now().isoformat(timespec="seconds"), n))
