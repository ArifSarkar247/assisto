"""Business Model, Build 1 of N.

Adds the single-row SERVER-SIDE PRICING config table (PricingConfig) and
migrates any existing Family subscribers to Premium, PRESERVING their plan
expiry and their 5-member circle entitlement (Premium now carries family=5, so
nothing about their Circle breaks). Idempotent and additive — no destructive
schema change; safe on the Assisto-owned DB.
"""
from django.db import migrations, models


def family_to_premium(apps, schema_editor):
    """Migrate plan == 'family' users to 'premium'. plan_until is left untouched
    (expiry preserved). Premium's family=5 keeps their Circle intact. Idempotent:
    re-running finds no 'family' rows and does nothing. Audit grandfather note is
    written into the seeded PricingConfig row's audit."""
    User = apps.get_model("core", "User")
    migrated = list(
        User.objects.filter(plan="family").values_list("id", flat=True))
    if migrated:
        User.objects.filter(plan="family").update(plan="premium")

    PricingConfig = apps.get_model("core", "PricingConfig")
    row, _ = PricingConfig.objects.get_or_create(key="global")
    audit = list(row.audit or [])
    audit.insert(0, {
        "path": "migration",
        "note": "Build 1: Family plan removed; folded into Premium (family=5).",
        "migrated_family_user_ids": migrated,
        "count": len(migrated),
        "actor": "migration:0039",
    })
    row.audit = audit
    row.save(update_fields=["audit", "updated_at"])


def noop_reverse(apps, schema_editor):
    # Non-reversible data move (we don't know who was originally Family vs Premium
    # after the fact); schema drop is handled by the reverse of CreateModel.
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0038_account_deletion_request"),
    ]

    operations = [
        migrations.CreateModel(
            name="PricingConfig",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("key", models.CharField(default="global", max_length=32, unique=True)),
                ("data", models.JSONField(blank=True, default=dict)),
                ("audit", models.JSONField(blank=True, default=list)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
        ),
        migrations.RunPython(family_to_premium, noop_reverse),
    ]
