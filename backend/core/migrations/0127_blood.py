# blood (owner 2 Nov): Blood donor panel ("রক্তদাতা প্যানেল") — opt-in donors
# (coarse area only), urgent requests + per-donor recipient rows, fake-request
# reports, private donor<->seeker threads, donation-slip verification (photo
# deleted after review) and the abuse/audit log. Additive only.
# Depends on BOTH current leaves (0124_placesafe from main, 0126_missing merged
# from agent/missing) so it also acts as their merge. The integrator renumbers.
import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0124_placesafe"),
        ("core", "0126_missing"),
    ]

    operations = [
        migrations.CreateModel(
            name="BloodDonor",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("enabled", models.BooleanField(db_index=True, default=False)),
                ("consent_at", models.DateTimeField(blank=True, null=True)),
                ("consent_version", models.PositiveSmallIntegerField(default=0)),
                ("blood_group", models.CharField(blank=True, default="", max_length=4)),
                ("sex", models.CharField(blank=True, default="", max_length=1)),
                ("last_donation", models.DateField(blank=True, null=True)),
                ("available", models.BooleanField(default=True)),
                ("district", models.CharField(blank=True, default="", max_length=24)),
                ("area_text", models.CharField(blank=True, default="", max_length=60)),
                ("lat", models.FloatField(blank=True, null=True)),
                ("lng", models.FloatField(blank=True, null=True)),
                ("phone_public", models.BooleanField(default=False)),
                ("email_public", models.BooleanField(default=False)),
                ("verified_at", models.DateTimeField(blank=True, null=True)),
                ("reminded_for", models.DateField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("user", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="blood_donor", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "indexes": [models.Index(fields=["enabled", "blood_group"], name="core_blooddonor_grp_idx")],
            },
        ),
        migrations.CreateModel(
            name="BloodRequest",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("blood_group", models.CharField(max_length=4)),
                ("units", models.PositiveSmallIntegerField(default=1)),
                ("hospital", models.CharField(max_length=120)),
                ("area_text", models.CharField(blank=True, default="", max_length=60)),
                ("district", models.CharField(blank=True, default="", max_length=24)),
                ("lat", models.FloatField(blank=True, null=True)),
                ("lng", models.FloatField(blank=True, null=True)),
                ("radius_km", models.PositiveSmallIntegerField(default=5)),
                ("needed_by", models.DateTimeField()),
                ("note", models.CharField(blank=True, default="", max_length=300)),
                ("state", models.CharField(db_index=True, default="active", max_length=10)),
                ("hidden_from", models.CharField(blank=True, default="", max_length=10)),
                ("pushed", models.PositiveIntegerField(default=0)),
                ("listed", models.PositiveIntegerField(default=0)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("expires_at", models.DateTimeField(db_index=True)),
                ("closed_at", models.DateTimeField(blank=True, null=True)),
                ("requester", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="blood_requests", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ["-id"]},
        ),
        migrations.CreateModel(
            name="BloodRecipient",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("source", models.CharField(default="push", max_length=12)),
                ("pushed_at", models.DateTimeField(blank=True, db_index=True, null=True)),
                ("response", models.CharField(blank=True, default="", max_length=10)),
                ("responded_at", models.DateTimeField(blank=True, null=True)),
                ("request", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="recipients", to="core.bloodrequest")),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="blood_recipient_rows", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "constraints": [models.UniqueConstraint(fields=("request", "user"), name="core_blood_recipient_once")],
            },
        ),
        migrations.CreateModel(
            name="BloodReport",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("reason", models.CharField(default="other", max_length=12)),
                ("note", models.CharField(blank=True, default="", max_length=300)),
                ("counted", models.BooleanField(default=True)),
                ("status", models.CharField(default="open", max_length=10)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("reporter", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("request", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="reports", to="core.bloodrequest")),
            ],
            options={
                "ordering": ["-id"],
                "constraints": [models.UniqueConstraint(fields=("request", "reporter"), name="core_blood_report_once")],
            },
        ),
        migrations.CreateModel(
            name="BloodThread",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("last_at", models.DateTimeField(default=django.utils.timezone.now)),
                ("donor_unread", models.PositiveIntegerField(default=0)),
                ("seeker_unread", models.PositiveIntegerField(default=0)),
                ("blocked_by", models.CharField(blank=True, default="", max_length=8)),
                ("circle_ask", models.CharField(blank=True, default="", max_length=10)),
                ("donor", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="blood_threads_donor", to=settings.AUTH_USER_MODEL)),
                ("request", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="threads", to="core.bloodrequest")),
                ("seeker", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="blood_threads_seeker", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "ordering": ["-last_at"],
                "constraints": [models.UniqueConstraint(fields=("donor", "seeker"), name="core_blood_thread_pair")],
            },
        ),
        migrations.CreateModel(
            name="BloodMessage",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("by_donor", models.BooleanField(default=False)),
                ("text", models.CharField(max_length=600)),
                ("at", models.DateTimeField(default=django.utils.timezone.now)),
                ("thread", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="messages", to="core.bloodthread")),
            ],
            options={"ordering": ["id"]},
        ),
        migrations.CreateModel(
            name="BloodVerification",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("photo", models.FileField(blank=True, default="", upload_to="blood_slips/")),
                ("state", models.CharField(db_index=True, default="pending", max_length=10)),
                ("note", models.CharField(blank=True, default="", max_length=200)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("reviewed_at", models.DateTimeField(blank=True, null=True)),
                ("reviewed_by", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="blood_verifications", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ["-id"]},
        ),
        migrations.CreateModel(
            name="BloodEvent",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("kind", models.CharField(max_length=24)),
                ("meta", models.JSONField(blank=True, default=dict)),
                ("at", models.DateTimeField(db_index=True, default=django.utils.timezone.now)),
                ("actor", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("request", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="events", to="core.bloodrequest")),
            ],
            options={
                "ordering": ["-id"],
                "indexes": [models.Index(fields=["actor", "kind", "at"], name="core_bloodev_actor_idx")],
            },
        ),
    ]
