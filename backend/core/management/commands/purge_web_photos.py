"""w1-webphoto: delete website passport/visa photos older than their expiry
(<= 1 hour). Run from cron every 10 minutes; the web/app paths also delete an
expired drop the moment it is touched, so this is the sweep for abandoned ones.
"""
from django.core.management.base import BaseCommand

from web.logic import webphoto as W
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Delete expired lifeassisto.com/photo drops (w1-webphoto)."

    @track_job("purge_web_photos")
    def handle(self, *args, **opts):
        n = W.purge_expired()
        self.stdout.write("purge_web_photos: deleted %d expired photo(s)" % n)
