"""p4-world: refresh the shared Unseen World cache (official RSS news, the
currency feed, MET Norway weather for every city a user picked, live sports
when a key is connected). Each source is fetched only when due (intervals are
admin-editable under /owner/pricing → world), so running this often is cheap.

Crontab (deploy/p4-world/world.cron):
    */15 * * * * cd /home/ubuntu/assisto/backend && \
        /home/ubuntu/assisto/.venv/bin/python manage.py world_refresh
"""
from django.core.management.base import BaseCommand
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Refresh Unseen World feeds (news, currency, weather, sports)."

    @track_job("world_refresh")
    def handle(self, *args, **opts):
        from core import world_service
        out = world_service.refresh_all()
        news = out.get("news") or {}
        self.stdout.write("[world_refresh] news ok=%d fail=%d fx=%s weather=%d sports=%s" % (
            sum(1 for v in news.values() if v), sum(1 for v in news.values() if v is False),
            out.get("fx"), len(out.get("weather") or {}), out.get("sports")))
