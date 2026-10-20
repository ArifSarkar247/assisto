"""CCTV / shop loss-prevention backend (Business, Part 4) — ingest + alert +
config schema.

Adds ShopSite / ShopCamera / ShopEvent / ShopPosEvent. All additive + nullable
or defaulted; safe on the Assisto-owned DB. NO video field exists anywhere —
ShopEvent carries at most ONE small snapshot (ImageField), auto-pruned after the
site's retention window by the shop_prune_snapshots management command.

Hand-written so `makemigrations --dry-run` stays clean.
"""
from django.db import migrations, models
import django.db.models.deletion
import django.utils.timezone

import core.models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0042_ai_chat"),
    ]

    operations = [
        migrations.CreateModel(
            name="ShopSite",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("name", models.CharField(blank=True, default="", max_length=120)),
                ("enrollment_token", models.CharField(
                    db_index=True, default=core.models._gen_token,
                    max_length=64, unique=True)),
                ("snapshot_retention_days",
                 models.PositiveSmallIntegerField(default=7)),
                ("created", models.DateTimeField(auto_now_add=True)),
                ("owner", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="shop_sites", to="core.user")),
            ],
            options={"ordering": ["-created"]},
        ),
        migrations.AddIndex(
            model_name="shopsite",
            index=models.Index(fields=["owner", "-created"],
                               name="core_shopsi_owner_i_677faf_idx"),
        ),
        migrations.CreateModel(
            name="ShopCamera",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("name", models.CharField(blank=True, default="", max_length=120)),
                ("kind", models.CharField(
                    choices=[("edge_webhook", "edge webhook"),
                             ("shopbox", "Shop Box")],
                    default="edge_webhook", max_length=16)),
                ("camera_token", models.CharField(
                    db_index=True, default=core.models._gen_token,
                    max_length=64, unique=True)),
                ("zone_config", models.JSONField(blank=True, default=dict)),
                ("enabled", models.BooleanField(default=True)),
                ("created", models.DateTimeField(auto_now_add=True)),
                ("site", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="cameras", to="core.shopsite")),
            ],
            options={"ordering": ["created", "id"]},
        ),
        migrations.AddIndex(
            model_name="shopcamera",
            index=models.Index(fields=["site", "enabled"],
                               name="core_shopca_site_id_7f6cc1_idx"),
        ),
        migrations.CreateModel(
            name="ShopEvent",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("type", models.CharField(
                    choices=[("hand_in_cash_zone", "hand in cash zone"),
                             ("drawer_open", "drawer open"),
                             ("void_spike", "void spike"),
                             ("refund_spike", "refund spike"),
                             ("discount_spike", "discount spike"),
                             ("eod_mismatch", "end-of-day mismatch"),
                             ("motion", "motion"),
                             ("after_hours", "after hours"),
                             ("pose_possible", "pose (possible)")],
                    max_length=20)),
                ("signals", models.JSONField(blank=True, default=dict)),
                ("confidence", models.FloatField(default=0.0)),
                ("snapshot", models.ImageField(blank=True, null=True,
                                               upload_to="shop/")),
                ("pos_matched", models.BooleanField(default=False)),
                ("possible", models.BooleanField(default=False)),
                ("status", models.CharField(
                    choices=[("open", "open"), ("checked", "checked"),
                             ("false_alarm", "false alarm")],
                    default="open", max_length=12)),
                ("created", models.DateTimeField(auto_now_add=True)),
                ("camera", models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="events", to="core.shopcamera")),
                ("site", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="events", to="core.shopsite")),
            ],
            options={"ordering": ["-created"]},
        ),
        migrations.AddIndex(
            model_name="shopevent",
            index=models.Index(fields=["site", "-created"],
                               name="core_shopev_site_id_22c441_idx"),
        ),
        migrations.AddIndex(
            model_name="shopevent",
            index=models.Index(fields=["site", "status"],
                               name="core_shopev_site_id_a7458f_idx"),
        ),
        migrations.AddIndex(
            model_name="shopevent",
            index=models.Index(fields=["site", "type"],
                               name="core_shopev_site_id_808f52_idx"),
        ),
        migrations.CreateModel(
            name="ShopPosEvent",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("kind", models.CharField(
                    choices=[("sale", "sale"), ("void", "void"),
                             ("refund", "refund"), ("discount", "discount"),
                             ("drawer_open", "drawer open")],
                    max_length=12)),
                ("amount", models.BigIntegerField(default=0)),
                ("at", models.DateTimeField(default=django.utils.timezone.now)),
                ("site", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="pos_events", to="core.shopsite")),
            ],
            options={"ordering": ["-at"]},
        ),
        migrations.AddIndex(
            model_name="shopposevent",
            index=models.Index(fields=["site", "kind", "at"],
                               name="core_shoppo_site_id_c00caa_idx"),
        ),
        migrations.AddIndex(
            model_name="shopposevent",
            index=models.Index(fields=["site", "at"],
                               name="core_shoppo_site_id_ed333e_idx"),
        ),
    ]
