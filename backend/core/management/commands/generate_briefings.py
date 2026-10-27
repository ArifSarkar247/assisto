"""
Batch-generate the next day's morning briefing at night, so the morning open is
instant and cheap (no live AI at peak). Run from cron (nice/ionice), e.g.:
  0 3 * * *  nice -n15 ionice -c3 <venv>/python manage.py generate_briefings
Only touches Assisto's own DB. Degrades silently if AI is unavailable.
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core import ai
from core.i18n import pick
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
            lang = getattr(u, "language", "bn")
            doses = [f"{m.name} ({s})" for m in u.medicines.all() for s in (m.times or [])]
            rem = list(u.reminders.filter(done=False).values_list("title", flat=True))[:6]
            al = _build_alerts(u)
            parts = []
            if rem:
                parts.append(pick(lang, "রিমাইন্ডার: ", "Reminders: ") + ", ".join(rem))
            if doses:
                parts.append(pick(lang, "ওষুধ: ", "Medicines: ") + ", ".join(doses[:6]))
            for a in al[:5]:
                parts.append(a["text"])
            data = "\n".join(parts) or pick(lang,
                "আজ বিশেষ কিছু নেই।", "Nothing special today.")
            text, ai_used = "", False
            if ai.available():
                try:
                    text, _ = ai.generate(
                        task=pick(lang,
                            "নিচের তথ্য দিয়ে ছোট, উষ্ণ বাংলা সকালের ব্রিফিং লেখো (৩-৪ লাইন)।",
                            "Using the information below, write a short, warm morning "
                            "briefing in English (3-4 lines)."),
                        data=data, tier="cheap", feature="briefing.batch",
                        max_tokens=300, user=u)
                    from core import ai_guard   # aieval: no medical claims
                    text, _flags = ai_guard.clean_assistant_answer(text, lang, actions=False)
                    ai_used = True
                except ai.AIUnavailable:
                    text = ""
            NightBriefing.objects.update_or_create(
                user=u, for_date=target,
                defaults={"text": text, "ai_used": ai_used})
            made += 1
        self.stdout.write(self.style.SUCCESS(
            f"briefings: made={made} skipped={skipped} for {target}"))
