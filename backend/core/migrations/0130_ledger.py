# ledger (owner Part 1 f, 2 Nov): double-entry business accounting behind the
# flag accounting_v2 (OFF) — LedgerBook / LedgerAccount / JournalEntry /
# JournalLine. Additive only; journal rows are never edited or deleted.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0129_blood"),
    ]

    operations = [
        migrations.CreateModel(
            name="LedgerBook",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("start_date", models.DateField(blank=True, null=True)),
                ("lock_date", models.DateField(blank=True, null=True)),
                ("opening_inventory", models.BigIntegerField(blank=True, null=True)),
                ("opening_warning", models.JSONField(blank=True, default=dict)),
                ("opening", models.JSONField(blank=True, default=dict)),
                ("vat_periods", models.JSONField(blank=True, default=list)),
                ("next_number", models.PositiveIntegerField(default=1)),
                ("last_sync_at", models.DateTimeField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("business", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="ledger_book", to="core.businessprofile")),
            ],
        ),
        migrations.CreateModel(
            name="LedgerAccount",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("code", models.CharField(max_length=8)),
                ("type", models.CharField(choices=[("asset", "asset"), ("liability", "liability"), ("equity", "equity"), ("income", "income"), ("expense", "expense")], max_length=10)),
                ("group", models.CharField(default="", max_length=16)),
                ("name_bn", models.CharField(max_length=80)),
                ("name_en", models.CharField(max_length=80)),
                ("contra", models.BooleanField(default=False)),
                ("system", models.BooleanField(default=True)),
                ("business", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="ledger_accounts", to="core.businessprofile")),
            ],
            options={
                "ordering": ["code"],
                "unique_together": {("business", "code")},
            },
        ),
        migrations.CreateModel(
            name="JournalEntry",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("number", models.PositiveIntegerField()),
                ("date", models.DateField(db_index=True)),
                ("source_key", models.CharField(max_length=40)),
                ("fingerprint", models.CharField(blank=True, default="", max_length=32)),
                ("status", models.CharField(choices=[("posted", "posted"), ("reversed", "reversed"), ("reversal", "reversal")], default="posted", max_length=10)),
                ("memo_bn", models.CharField(blank=True, default="", max_length=200)),
                ("memo_en", models.CharField(blank=True, default="", max_length=200)),
                ("total", models.BigIntegerField(default=0)),
                ("late", models.BooleanField(default=False)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("business", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="journal_entries", to="core.businessprofile")),
                ("created_by", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("reversal_of", models.OneToOneField(blank=True, null=True, on_delete=django.db.models.deletion.RESTRICT, related_name="reversed_by", to="core.journalentry")),
            ],
            options={
                "ordering": ["date", "number"],
                "indexes": [models.Index(fields=["business", "date"], name="ledger_je_biz_date"), models.Index(fields=["business", "source_key"], name="ledger_je_biz_src")],
                "constraints": [models.UniqueConstraint(fields=("business", "number"), name="ledger_je_number_uniq"), models.UniqueConstraint(condition=models.Q(("status", "posted")), fields=("business", "source_key"), name="ledger_je_one_live_per_source")],
            },
        ),
        migrations.CreateModel(
            name="JournalLine",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("debit", models.BigIntegerField(default=0)),
                ("credit", models.BigIntegerField(default=0)),
                ("party", models.CharField(blank=True, default="", max_length=120)),
                ("account", models.ForeignKey(on_delete=django.db.models.deletion.RESTRICT, related_name="lines", to="core.ledgeraccount")),
                ("entry", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="lines", to="core.journalentry")),
            ],
            options={
                "constraints": [models.CheckConstraint(check=models.Q(models.Q(("credit", 0), ("debit__gte", 0)), models.Q(("credit__gte", 0), ("debit", 0)), _connector="OR"), name="ledger_line_one_side")],
            },
        ),
    ]
