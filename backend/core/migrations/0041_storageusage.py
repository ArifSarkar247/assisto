"""Business Model — Build 3 of N.

Adds the per-user cloud STORAGE meter (StorageUsage) that the always-visible app
meter and the upload-quota enforcement read. One row per user; `used_bytes` is the
running total of retained server-side media (vault documents, avatar, retained
status media, encrypted backups). The quota itself is NOT stored here — it comes
from the user's effective plan via PricingConfig (Free 1GB / Premium 5GB / Business
15GB), so an owner price edit re-quotas everyone with no migration.

Additive only (one new table, OneToOne on User); safe on the Assisto-owned DB.
No data migration — `manage.py storage_recompute` backfills used_bytes from the
live rows so the meter is accurate on first run.
"""
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0040_business_model_v2"),
    ]

    operations = [
        migrations.CreateModel(
            name="StorageUsage",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("used_bytes", models.BigIntegerField(default=0)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("user", models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="storage_usage", to="core.user")),
            ],
        ),
    ]
