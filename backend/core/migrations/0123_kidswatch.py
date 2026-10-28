# kidswatch (owner idea 2, 28 Oct): kids GPS watch (open "3G" / SeTracker
# protocol) + Child School Mode. Additive only: six new tables, nothing
# existing is touched. (Agent number 0123 — renumbered at merge.)

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0119_adscheck"),
    ]

    operations = [
        migrations.CreateModel(
            name="KidsWatch",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("child_name", models.CharField(default="", max_length=60)),
                ("imei", models.CharField(max_length=20, unique=True)),
                ("maker", models.CharField(blank=True, default="", max_length=4)),
                ("state", models.CharField(choices=[("pending", "pending"), ("paired", "paired"), ("expired", "expired"), ("disabled", "disabled")], default="pending", max_length=10)),
                ("pair_expires_at", models.DateTimeField(blank=True, null=True)),
                ("paired_at", models.DateTimeField(blank=True, null=True)),
                ("billed_until", models.DateTimeField(blank=True, null=True)),
                ("guardian_ids", models.JSONField(blank=True, default=list)),
                ("sos_numbers", models.JSONField(blank=True, default=list)),
                ("tz_min", models.IntegerField(default=360)),
                ("last_seen_at", models.DateTimeField(blank=True, null=True)),
                ("last_fix_at", models.DateTimeField(blank=True, null=True)),
                ("last_lat", models.FloatField(blank=True, null=True)),
                ("last_lng", models.FloatField(blank=True, null=True)),
                ("last_acc_m", models.FloatField(blank=True, null=True)),
                ("last_source", models.CharField(blank=True, default="", max_length=8)),
                ("battery", models.IntegerField(blank=True, null=True)),
                ("steps", models.IntegerField(blank=True, null=True)),
                ("phase", models.CharField(blank=True, default="", max_length=12)),
                ("interval_s", models.IntegerField(blank=True, null=True)),
                ("alert_state", models.JSONField(blank=True, default=dict)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("child_user", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="kids_watches_worn", to=settings.AUTH_USER_MODEL)),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="kids_watches", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "ordering": ["created_at"],
            },
        ),
        migrations.CreateModel(
            name="KidsWatchPosition",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("at", models.DateTimeField()),
                ("lat", models.FloatField()),
                ("lng", models.FloatField()),
                ("source", models.CharField(default="gps", max_length=8)),
                ("acc_m", models.FloatField(blank=True, null=True)),
                ("battery", models.IntegerField(blank=True, null=True)),
                ("received_at", models.DateTimeField(auto_now_add=True)),
                ("watch", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="positions", to="core.kidswatch")),
            ],
            options={
                "ordering": ["at"],
                "indexes": [models.Index(fields=["watch", "at"], name="core_kwpos_watch_at_idx")],
            },
        ),
        migrations.CreateModel(
            name="KidsWatchCommand",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("kind", models.CharField(max_length=20)),
                ("payload", models.JSONField(blank=True, default=dict)),
                ("state", models.CharField(default="queued", max_length=10)),
                ("ack_type", models.CharField(blank=True, default="", max_length=16)),
                ("error", models.CharField(blank=True, default="", max_length=40)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("sent_at", models.DateTimeField(blank=True, null=True)),
                ("done_at", models.DateTimeField(blank=True, null=True)),
                ("requested_by", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("watch", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="commands", to="core.kidswatch")),
            ],
            options={
                "ordering": ["id"],
                "indexes": [models.Index(fields=["watch", "state"], name="core_kwcmd_watch_st_idx")],
            },
        ),
        migrations.CreateModel(
            name="SchoolPlan",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("child_name", models.CharField(default="", max_length=60)),
                ("watcher_ids", models.JSONField(blank=True, default=list)),
                ("config", models.JSONField(blank=True, default=dict)),
                ("enabled", models.BooleanField(default=True)),
                ("accepted_at", models.DateTimeField(blank=True, null=True)),
                ("day", models.JSONField(blank=True, default=dict)),
                ("last_known", models.JSONField(blank=True, default=dict)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("child_user", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name="school_plans_as_child", to=settings.AUTH_USER_MODEL)),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="school_plans", to=settings.AUTH_USER_MODEL)),
                ("watch", models.OneToOneField(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="school_plan", to="core.kidswatch")),
            ],
            options={
                "ordering": ["-id"],
            },
        ),
        migrations.CreateModel(
            name="KidsVoiceNote",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("direction", models.CharField(default="up", max_length=4)),
                ("file_name", models.CharField(blank=True, default="", max_length=120)),
                ("mime", models.CharField(default="audio/amr", max_length=24)),
                ("size", models.IntegerField(default=0)),
                ("duration_s", models.FloatField(blank=True, null=True)),
                ("lat", models.FloatField(blank=True, null=True)),
                ("lng", models.FloatField(blank=True, null=True)),
                ("at", models.DateTimeField()),
                ("state", models.CharField(default="stored", max_length=10)),
                ("transcript", models.TextField(blank=True, default="")),
                ("transcript_state", models.CharField(blank=True, default="", max_length=12)),
                ("heard_by", models.JSONField(blank=True, default=list)),
                ("expires_at", models.DateTimeField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("plan", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name="voice_notes", to="core.schoolplan")),
                ("sender", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("watch", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name="voice_notes", to="core.kidswatch")),
            ],
            options={
                "ordering": ["-at"],
                "indexes": [models.Index(fields=["watch", "at"], name="core_kwvoice_watch_idx"),
                            models.Index(fields=["expires_at"], name="core_kwvoice_exp_idx")],
            },
        ),
        migrations.CreateModel(
            name="SchoolEvent",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("kind", models.CharField(max_length=24)),
                ("at", models.DateTimeField()),
                ("lat", models.FloatField(blank=True, null=True)),
                ("lng", models.FloatField(blank=True, null=True)),
                ("source", models.CharField(blank=True, default="", max_length=8)),
                ("detail", models.JSONField(blank=True, default=dict)),
                ("plan", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="events", to="core.schoolplan")),
                ("voice", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to="core.kidsvoicenote")),
            ],
            options={
                "ordering": ["-at"],
                "indexes": [models.Index(fields=["plan", "at"], name="core_schoolev_plan_at_idx")],
            },
        ),
    ]
