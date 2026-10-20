"""Business Model — Build 2 of N.

Adds the economic core: credit PACKS (CreditPurchase, 12-month expiry), the
ad-funded WALLET for free users (AdWallet + AdEvent), and the append-only daily
P&L row (DailyLedger) the Profit Guard reads. Widens CreditLedger.reason to
carry the Build-2 reasons (ad_appopen/ad_interstitial/ad_spend/expire).

DATA MIGRATION: updates the EXISTING seeded PricingConfig('global') row to the
v2 numbers (Business ৳999 -> ৳499; monthly included POOL Premium 90 / Business
240 / Free 0; credit packs ৳20/50/100/200 with 12-month validity; base storage
Free 1GB / Premium 5GB / Business 15GB; NET fee structure play_fee=0.15 etc.;
ai_msg_strong repriced 5->6 to hold the 60%-NET margin floor). IDEMPOTENT:
re-running renormalizes to the same v2 shape and only audits a real change.
All additive/nullable; safe on the Assisto-owned DB (never touch Asalify).
"""
from django.db import migrations, models
import django.db.models.deletion
import django.utils.timezone


def seed_v2_pricing(apps, schema_editor):
    """Rewrite the existing PricingConfig('global').data to the v2 defaults,
    preserving any owner-custom keys the normalizer carries forward. Idempotent."""
    from core.logic import pricing as P
    PricingConfig = apps.get_model("core", "PricingConfig")
    row, _ = PricingConfig.objects.get_or_create(key="global")

    # Rewrite to the shipped v2 DEFAULTS. We intentionally do NOT carry the old
    # Business=999 price forward — the v2 reprice is the point of this migration.
    row.data = P.normalize(P.DEFAULTS())

    audit = list(row.audit or [])
    audit.insert(0, {
        "path": "migration",
        "note": ("Build 2: v2 prices/pools/packs/storage + NET fee structure. "
                 "Business 999->499; pools Premium 90 / Business 240; packs "
                 "20/50/100/200 (12mo); storage 1/5/15 GB."),
        "actor": "migration:0040",
        "repriced_business": row.data["plans"]["business"]["price"],
    })
    row.audit = audit[:200]
    row.save(update_fields=["data", "audit", "updated_at"])


def noop_reverse(apps, schema_editor):
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0039_pricingconfig_family_to_premium"),
    ]

    operations = [
        migrations.AlterField(
            model_name="creditledger",
            name="reason",
            field=models.CharField(
                max_length=20,
                choices=[("grant", "monthly grant"), ("consume", "consume"),
                         ("rewarded", "rewarded ad"), ("topup", "top-up"),
                         ("trial", "trial"), ("adjust", "adjust"),
                         ("ad_appopen", "ad: app open"),
                         ("ad_interstitial", "ad: interstitial"),
                         ("ad_spend", "spent ad-wallet credits"),
                         ("expire", "credits expired")]),
        ),
        migrations.CreateModel(
            name="CreditPurchase",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("pack_id", models.CharField(max_length=16)),
                ("price_bdt", models.IntegerField(default=0)),
                ("credits", models.IntegerField(default=0)),
                ("provider", models.CharField(blank=True, default="", max_length=20)),
                ("status", models.CharField(
                    choices=[("pending", "pending"), ("confirmed", "confirmed"),
                             ("failed", "failed")],
                    default="pending", max_length=10)),
                ("txn_ref", models.CharField(blank=True, default="", max_length=120)),
                ("granted", models.BooleanField(default=False)),
                ("expires_at", models.DateTimeField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("confirmed_at", models.DateTimeField(blank=True, null=True)),
                ("user", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="credit_purchases", to="core.user")),
            ],
            options={"ordering": ["-created_at"]},
        ),
        migrations.AddIndex(
            model_name="creditpurchase",
            index=models.Index(fields=["user", "status"],
                               name="core_credit_user_id_0980c2_idx"),
        ),
        migrations.AddIndex(
            model_name="creditpurchase",
            index=models.Index(fields=["user", "expires_at"],
                               name="core_credit_user_id_653e11_idx"),
        ),
        migrations.CreateModel(
            name="AdWallet",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("balance_paisa", models.BigIntegerField(default=0)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("user", models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="ad_wallet", to="core.user")),
            ],
        ),
        migrations.CreateModel(
            name="AdEvent",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("kind", models.CharField(
                    choices=[("app_open", "app open"), ("rewarded", "rewarded"),
                             ("native", "native"),
                             ("interstitial", "interstitial")],
                    max_length=14)),
                ("device_id", models.CharField(blank=True, default="", max_length=64)),
                ("ad_id", models.CharField(blank=True, default="", max_length=80)),
                ("credited_paisa", models.IntegerField(default=0)),
                ("at", models.DateTimeField(default=django.utils.timezone.now)),
                ("user", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="ad_events", to="core.user")),
            ],
            options={"ordering": ["-at"]},
        ),
        migrations.AddIndex(
            model_name="adevent",
            index=models.Index(fields=["user", "kind", "at"],
                               name="core_adeven_user_id_fd0625_idx"),
        ),
        migrations.AddIndex(
            model_name="adevent",
            index=models.Index(fields=["device_id", "kind", "at"],
                               name="core_adeven_device__c72a1b_idx"),
        ),
        migrations.CreateModel(
            name="DailyLedger",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("date", models.DateField(unique=True)),
                ("revenue_by_source", models.JSONField(blank=True, default=dict)),
                ("variable_cost_by_type", models.JSONField(blank=True, default=dict)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={"ordering": ["-date"]},
        ),
        migrations.RunPython(seed_v2_pricing, noop_reverse),
    ]
