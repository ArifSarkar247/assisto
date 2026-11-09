"""p1-bizagent — evening (21:00 Asia/Dhaka): the seller's daily sales/orders
summary (saved for the app + push) and the low-stock alert (max once a day)."""
from django.core.management.base import BaseCommand
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Business AI Agent: daily seller report + low-stock alert."

    def add_arguments(self, parser):
        parser.add_argument("--low-stock-only", action="store_true")

    @track_job("bizagent_daily")
    def handle(self, *args, **opts):
        from core import bizagent_service as S
        ls = S.run_low_stock()
        rep = 0 if opts["low_stock_only"] else S.run_daily_reports()
        # bizai2: every active shop owner's evening summary (sales, khata,
        # who to chase, stock-out forecast) — same 21:00 Dhaka slot.
        from core import bizai_daily as BD
        own = 0 if opts["low_stock_only"] else BD.run_daily()
        self.stdout.write("bizagent_daily reports=%d low_stock=%d owner_daily=%d"
                          % (rep, ls, own))
