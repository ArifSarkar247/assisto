# cctvevidence (W7, owner CCTV order 3 Nov D1-D3/I1/I2): CCTV photo / clip
# FileFields go through the sealed storage (core/logic/cctv_store.py — no
# column change, AlterField only records the storage), + the per-camera
# video add-on and the SD-card clip rows. Additive; no data rewritten here
# (plain legacy files are sealed on first access or by
# `manage.py cctv_store_migrate`).
import django.db.models.deletion
from django.db import migrations, models

import core.logic.cctv_store


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0137_homeorder"),
    ]

    operations = [
        migrations.AddField(
            model_name="shopsite",
            name="address",
            field=models.CharField(blank=True, default="", max_length=200),
        ),
        migrations.AlterField(
            model_name="shopcamera",
            name="preview",
            field=models.ImageField(blank=True, null=True,
                                    storage=core.logic.cctv_store.vault_storage,
                                    upload_to="shop/preview/"),
        ),
        migrations.AlterField(
            model_name="shopevent",
            name="snapshot",
            field=models.ImageField(blank=True, null=True,
                                    storage=core.logic.cctv_store.vault_storage,
                                    upload_to="shop/"),
        ),
        migrations.AlterField(
            model_name="shopeventclip",
            name="blob",
            field=models.FileField(blank=True, null=True,
                                   storage=core.logic.cctv_store.vault_storage,
                                   upload_to="shop/clip/"),
        ),
        migrations.CreateModel(
            name="ShopVideoAddon",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("tier", models.CharField(choices=[("7d", "7 days"), ("30d", "30 days")],
                                          default="7d", max_length=4)),
                ("active_until", models.DateTimeField(blank=True, db_index=True, null=True)),
                ("source", models.CharField(blank=True, default="", max_length=12)),
                ("ref", models.CharField(blank=True, default="", max_length=120)),
                ("auto_renew", models.BooleanField(default=True)),
                ("created", models.DateTimeField(auto_now_add=True)),
                ("updated", models.DateTimeField(auto_now=True)),
                ("camera", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE,
                                                related_name="video_addon",
                                                to="core.shopcamera")),
            ],
        ),
        migrations.CreateModel(
            name="ShopSdClip",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("status", models.CharField(choices=[("pending", "pending"), ("ready", "ready"),
                                                     ("unsupported", "unsupported"),
                                                     ("failed", "failed"),
                                                     ("expired", "expired")],
                                            db_index=True, default="pending", max_length=12)),
                ("reason", models.CharField(blank=True, default="", max_length=40)),
                ("name", models.CharField(blank=True, default="", max_length=200)),
                ("size", models.PositiveIntegerField(default=0)),
                ("sha256", models.CharField(blank=True, default="", max_length=64)),
                ("start", models.DateTimeField(blank=True, null=True)),
                ("end", models.DateTimeField(blank=True, null=True)),
                ("tries", models.PositiveSmallIntegerField(default=0)),
                ("due_at", models.DateTimeField(blank=True, null=True)),
                ("expires_at", models.DateTimeField(blank=True, db_index=True, null=True)),
                ("created", models.DateTimeField(auto_now_add=True)),
                ("camera", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE,
                                             related_name="sd_clips", to="core.shopcamera")),
                ("event", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE,
                                               related_name="sd_clip", to="core.shopevent")),
            ],
            options={
                "ordering": ["-created"],
                "indexes": [models.Index(fields=["camera", "-created"],
                                         name="shopsdclip_cam_created")],
            },
        ),
    ]
