# kidaudio (owner 2 Nov, PART 1 b): child emergency audio — advance consent
# per guardian/child pair + the audit/session log both sides see.
# Additive only. The integrator renumbers this after the current leaf.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0134_chipbuy"),
    ]

    operations = [
        migrations.CreateModel(
            name="KidAudioConsent",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("birth_year", models.PositiveSmallIntegerField()),
                ("parent_ok_at", models.DateTimeField(blank=True, null=True)),
                ("child_ok_at", models.DateTimeField(blank=True, null=True)),
                ("revoked_at", models.DateTimeField(blank=True, null=True)),
                ("revoked_by", models.CharField(blank=True, default="", max_length=8)),
                ("watch_phone", models.CharField(blank=True, default="", max_length=20)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("child", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="kid_audio_as_child", to=settings.AUTH_USER_MODEL)),
                ("guardian", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="kid_audio_as_guardian", to=settings.AUTH_USER_MODEL)),
                ("watch", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to="core.kidswatch")),
            ],
            options={
                "constraints": [models.UniqueConstraint(fields=("guardian", "child"), name="uniq_kidaudio_pair")],
            },
        ),
        migrations.CreateModel(
            name="KidAudioSession",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("channel", models.CharField(default="phone", max_length=6)),
                ("status", models.CharField(default="requested", max_length=10)),
                ("reason", models.CharField(blank=True, default="", max_length=24)),
                ("emergency_kind", models.CharField(blank=True, default="", max_length=16)),
                ("emergency_ref", models.CharField(blank=True, default="", max_length=80)),
                ("limit_s", models.PositiveIntegerField(default=180)),
                ("notice_shown", models.BooleanField(default=False)),
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
                ("started_at", models.DateTimeField(blank=True, null=True)),
                ("ended_at", models.DateTimeField(blank=True, null=True)),
                ("ended_by", models.CharField(blank=True, default="", max_length=8)),
                ("call", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to="core.callrecord")),
                ("child", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("consent", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="sessions", to="core.kidaudioconsent")),
                ("guardian", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="+", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "ordering": ["-id"],
                "indexes": [models.Index(fields=["child", "status"], name="kidaudio_child_st"),
                            models.Index(fields=["guardian", "created_at"], name="kidaudio_guard_at")],
            },
        ),
    ]
