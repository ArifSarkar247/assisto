# CRM first-run: org industry / team size / invite code (join a team).
# Hand-written to match crm.models.CrmOrg (do NOT makemigrations here).
from django.db import migrations, models
import crm.models


def _seed_invite_codes(apps, schema_editor):
    """Backfill a unique invite code for any pre-existing org rows (the column
    default fires per-row on fresh creates; this covers rows that existed before
    the column, and guarantees uniqueness)."""
    CrmOrg = apps.get_model("crm", "CrmOrg")
    seen = set(CrmOrg.objects.exclude(invite_code="")
               .values_list("invite_code", flat=True))
    for org in CrmOrg.objects.filter(invite_code=""):
        code = crm.models._new_invite_code()
        while code in seen:
            code = crm.models._new_invite_code()
        seen.add(code)
        org.invite_code = code
        org.save(update_fields=["invite_code"])


class Migration(migrations.Migration):

    dependencies = [
        ("crm", "0003_lead_budget_range_lead_decision_maker_and_more"),
    ]

    operations = [
        # Clean up any orphaned invite_code indexes left by a prior aborted run
        # (idempotent; no-op on a clean DB). Keeps the whole fix inside migrate.
        migrations.RunSQL(
            sql=[
                "DROP INDEX IF EXISTS crm_crmorg_invite_code_ec4ede1e_like;",
                "DROP INDEX IF EXISTS crm_crmorg_invite_code_ec4ede1e;",
            ],
            reverse_sql=migrations.RunSQL.noop,
        ),
        migrations.AddField(
            model_name="crmorg",
            name="industry",
            field=models.CharField(
                blank=True, default="other", max_length=20,
                choices=[("rmg", "গার্মেন্টস / RMG"), ("pharma", "ফার্মা / Pharma"),
                         ("retail", "রিটেইল / Retail"), ("it", "আইটি / IT & Software"),
                         ("manufacturing", "ম্যানুফ্যাকচারিং / Manufacturing"),
                         ("services", "সার্ভিস / Services"), ("other", "অন্যান্য / Other")]),
        ),
        migrations.AddField(
            model_name="crmorg",
            name="team_size",
            field=models.CharField(
                blank=True, default="small", max_length=10,
                choices=[("solo", "১ জন / Just me"), ("small", "২–৫ জন / 2–5"),
                         ("medium", "৬–২০ জন / 6–20"), ("large", "২০+ / 20+")]),
        ),
        # Add nullable-ish (blank, non-unique) first so existing rows backfill
        # without colliding on the unique default, then enforce uniqueness.
        migrations.AddField(
            model_name="crmorg",
            name="invite_code",
            field=models.CharField(blank=True, default="", max_length=12),
        ),
        migrations.RunPython(_seed_invite_codes, migrations.RunPython.noop),
        migrations.AlterField(
            model_name="crmorg",
            name="invite_code",
            field=models.CharField(blank=True,
                                   default=crm.models._new_invite_code,
                                   max_length=12, unique=True),
        ),
    ]
