# famcare (owner 28 Oct): FamilyMember picked from My Circle, shared vault
# documents, family shopping list. Additive only (new nullable column + two
# new tables); no existing row is rewritten.

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0117_cctvx"),
    ]

    operations = [
        migrations.AddField(
            model_name="familymember",
            name="circle_member",
            field=models.ForeignKey(blank=True, null=True,
                                    on_delete=django.db.models.deletion.SET_NULL,
                                    related_name="family_entries",
                                    to="core.circlemember"),
        ),
        migrations.CreateModel(
            name="FamilyDocShare",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("revoked_at", models.DateTimeField(blank=True, null=True)),
                ("opens", models.PositiveIntegerField(default=0)),
                ("last_opened_at", models.DateTimeField(blank=True, null=True)),
                ("document", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="family_shares", to="core.document")),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="family_doc_shares", to=settings.AUTH_USER_MODEL)),
                ("recipient", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="family_docs_shared_with_me", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "ordering": ["-id"],
                "indexes": [models.Index(fields=["recipient", "revoked_at"], name="core_family_recipie_famc01_idx")],
            },
        ),
        migrations.CreateModel(
            name="FamilyListItem",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("text", models.CharField(max_length=200)),
                ("qty", models.CharField(blank=True, default="", max_length=40)),
                ("done", models.BooleanField(default=False)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("added_by", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("done_by", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="family_list_items", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "ordering": ["done", "-id"],
                "indexes": [models.Index(fields=["owner", "done"], name="core_family_owner_famc02_idx")],
            },
        ),
    ]
