"""p1-bizagent — evening (21:00 Asia/Dhaka): the seller's daily sales/orders
summary (saved for the app + push) and the low-stock alert (max once a day)."""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Business AI Agent: daily seller report + low-stock alert."

    def add_arguments(self, parser):
        parser.add_argument("--low-stock-only", action="store_true")

    def handle(self, *args, **opts):
        from core import bizagent_service as S
        ls = S.run_low_stock()
        rep = 0 if opts["low_stock_only"] else S.run_daily_reports()
        self.stdout.write("bizagent_daily reports=%d low_stock=%d" % (rep, ls))
