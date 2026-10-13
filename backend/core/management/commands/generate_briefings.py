"""
Batch-generate the next day's morning briefing at night, so the morning open is
instant and cheap (no live AI at peak). Run from cron (nice/ionice), e.g.:
  0 3 * * *  nice -n15 ionice -c3 <venv>/python manage.py generate_briefings
Only touches Assisto's own DB. Degrades silently if AI is unavailable.
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core import ai
from core.models import User, NightBriefing
from core.views import _build_alerts


class Command(BaseCommand):
    help = "Pre-generate tomorrow's morning briefing for active users."

    def add_arguments(self, parser):
        parser.add_argument("--days-active", type=int, default=14,
                            help="only users seen within N days")

    def handle(self, *args, **opts):
        target = timezone.localdate() + timezone.timedelta(days=1)
        since = timezone.now() - timezone.timedelta(days=opts["days_active"])
        users = User.objects.filter(last_login__gte=since) or User.objects.all()
        made = skipped = 0
        for u in users:
            if NightBriefing.objects.filter(user=u, for_date=target).exists():
                skipped += 1
                continue
            doses = [f"{m.name} ({s})" for m in u.medicines.all() for s in (m.times or [])]
            rem = list(u.reminders.filter(done=False).values_list("title", flat=True))[:6]
            al = _build_alerts(u)
            parts = []
            if rem:
                parts.append("রিমাইন্ডার: " + ", ".join(rem))
            if doses:
                parts.append("ওষুধ: " + ", ".join(doses[:6]))
            for a in al[:5]:
                parts.append(a["text"])
            data = "\n".join(parts) or "আজ বিশেষ কিছু নেই।"
            text, ai_used = "", False
            if ai.available():
                try:
                    text, _ = ai.generate(
                        task="নিচের তথ্য দিয়ে ছোট, উষ্ণ বাংলা সকালের ব্রিফিং লেখো (৩-৪ লাইন)।",
                        data=data, tier="cheap", feature="briefing.batch",
                        max_tokens=300, user=u)
                    ai_used = True
                except ai.AIUnavailable:
                    text = ""
            NightBriefing.objects.update_or_create(
                user=u, for_date=target,
                defaults={"text": text, "ai_used": ai_used})
            made += 1
        self.stdout.write(self.style.SUCCESS(
            f"briefings: made={made} skipped={skipped} for {target}"))
