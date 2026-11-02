# remhbar (2 Nov): Birthdays & memorable days kept only name/date/kind and ONE
# lead day — the app's several pre-reminders (1 week + 1 day + on the day),
# relation, note, phone and "every year" were silently dropped on save (the
# list made clamp_lead_days fall back to 1). New columns only; nothing
# existing changes. Agent number 0125 — may be renumbered at merge.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0124_placesafe"),
    ]

    operations = [
        migrations.AddField(
            model_name="birthday", name="leads",
            field=models.JSONField(blank=True, default=list)),
        migrations.AddField(
            model_name="birthday", name="relation",
            field=models.CharField(blank=True, default="", max_length=60)),
        migrations.AddField(
            model_name="birthday", name="notes",
            field=models.CharField(blank=True, default="", max_length=500)),
        migrations.AddField(
            model_name="birthday", name="phone",
            field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(
            model_name="birthday", name="yearly",
            field=models.BooleanField(default=True)),
    ]
