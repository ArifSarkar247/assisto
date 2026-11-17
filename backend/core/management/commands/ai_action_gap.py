"""gap-aichat2: READ-ONLY counts (no text, no user ids) for the money tools:
chat turns in the last N days that look like "log X taka spent / earned"
vs expense / income confirm proposals created in the same window.

    python manage.py ai_action_gap [--days 7]

Prints only numbers. Writes nothing."""
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone


class Command(BaseCommand):
    help = "Read-only counts: money-log chat turns vs expense/income proposals."

    def add_arguments(self, parser):
        parser.add_argument("--days", type=int, default=7)

    def handle(self, *args, **opts):
        from core import ai_tools as AT
        from core.models import ChatMessage, PaCollectionItem
        since = timezone.now() - timedelta(days=max(1, int(opts["days"])))
        turns = ChatMessage.objects.filter(role="user", created_at__gte=since) \
            .values_list("text", flat=True).iterator()
        n_user = n_money = 0
        for t in turns:
            n_user += 1
            if AT.money_safety_net(t) is not None:
                n_money += 1
        props = PaCollectionItem.objects.filter(collection=AT.PENDING, created_at__gte=since) \
            .values_list("data", flat=True).iterator()
        n_prop = n_net = 0
        for d in props:
            p = (d or {}).get("p") or {}
            if p.get("type") in ("expense", "income"):
                n_prop += 1
                n_net += 1 if p.get("safety_net") else 0
        self.stdout.write("days=%d user_turns=%d money_log_turns=%d money_proposals=%d "
                          "of_which_safety_net=%d gap=%d"
                          % (opts["days"], n_user, n_money, n_prop, n_net,
                             max(0, n_money - n_prop)))
