# callsbar (owner 2 Nov: calls to the launch bar): CallQualityReport — one
# row per call per side (measured numbers + optional one-tap rating). Agent
# number 0125 — may be renumbered at merge.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0125_missing"),
    ]

    operations = [
        migrations.CreateModel(
            name="CallQualityReport",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("side", models.CharField(default="", max_length=8)),
                ("rating", models.CharField(blank=True, default="", max_length=8)),
                ("issue", models.CharField(blank=True, default="", max_length=16)),
                ("video", models.BooleanField(default=False)),
                ("low_data", models.BooleanField(default=False)),
                ("relayed", models.BooleanField(default=False)),
                ("net", models.CharField(blank=True, default="", max_length=12)),
                ("rtt_ms", models.PositiveIntegerField(blank=True, null=True)),
                ("loss_pct", models.FloatField(blank=True, null=True)),
                ("jitter_ms", models.PositiveIntegerField(blank=True, null=True)),
                ("min_kbps", models.PositiveIntegerField(blank=True, null=True)),
                ("talk_s", models.PositiveIntegerField(default=0)),
                ("data_kb", models.PositiveIntegerField(default=0)),
                ("video_paused_s", models.PositiveIntegerField(default=0)),
                ("reconnects", models.PositiveSmallIntegerField(default=0)),
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("call", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="quality_reports", to="core.callrecord")),
                ("user", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="+", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ["-id"]},
        ),
        migrations.AddConstraint(
            model_name="callqualityreport",
            constraint=models.UniqueConstraint(
                fields=("call", "user"), name="core_callq_call_user_uniq"),
        ),
    ]
