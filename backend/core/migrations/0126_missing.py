# missing (owner 2 Nov): Missing person alert ("নিখোঁজ সতর্কতা") — alerts,
# one-push-per-user recipients, private tip threads, fake-post reports,
# the nearby-alerts opt-in (coarse area only) and the abuse/audit log.
# Additive only. The integrator renumbers this after the current leaf.
import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0123_sosat"),
    ]

    operations = [
        migrations.CreateModel(
            name="MissingAlert",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("relation", models.CharField(blank=True, default="", max_length=20)),
                ("name", models.CharField(max_length=80)),
                ("age", models.PositiveSmallIntegerField(default=0)),
                ("is_child", models.BooleanField(default=False)),
                ("description", models.CharField(blank=True, default="", max_length=500)),
                ("last_seen_at", models.DateTimeField()),
                ("area_text", models.CharField(max_length=120)),
                ("district", models.CharField(blank=True, default="", max_length=24)),
                ("lat", models.FloatField(blank=True, null=True)),
                ("lng", models.FloatField(blank=True, null=True)),
                ("radius_km", models.PositiveSmallIntegerField(default=10)),
                ("photo", models.FileField(blank=True, default="", upload_to="missing/")),
                ("gd_number", models.CharField(blank=True, default="", max_length=40)),
                ("gd_thana", models.CharField(blank=True, default="", max_length=80)),
                ("gd_date", models.DateField(blank=True, null=True)),
                ("basis", models.CharField(blank=True, default="", max_length=16)),
                ("state", models.CharField(db_index=True, default="pending", max_length=10)),
                ("hidden_from", models.CharField(blank=True, default="", max_length=10)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("activated_at", models.DateTimeField(blank=True, null=True)),
                ("expires_at", models.DateTimeField(blank=True, null=True)),
                ("closed_at", models.DateTimeField(blank=True, null=True)),
                ("closed_by", models.CharField(blank=True, default="", max_length=12)),
                ("renewals", models.PositiveSmallIntegerField(default=0)),
                ("safe_said_at", models.DateTimeField(blank=True, null=True)),
                ("share_agreed", models.BooleanField(default=False)),
                ("pushed", models.PositiveIntegerField(default=0)),
                ("listed", models.PositiveIntegerField(default=0)),
                ("cosign_asked", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("cosigner", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="missing_cosigned", to=settings.AUTH_USER_MODEL)),
                ("family_member", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to="core.familymember")),
                ("poster", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="missing_alerts", to=settings.AUTH_USER_MODEL)),
                ("subject_user", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="missing_about_me", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ["-id"]},
        ),
        migrations.CreateModel(
            name="NearbyAlertPref",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("enabled", models.BooleanField(default=False)),
                ("district", models.CharField(blank=True, default="", max_length=24)),
                ("home_lat", models.FloatField(blank=True, null=True)),
                ("home_lng", models.FloatField(blank=True, null=True)),
                ("use_open_location", models.BooleanField(default=False)),
                ("open_lat", models.FloatField(blank=True, null=True)),
                ("open_lng", models.FloatField(blank=True, null=True)),
                ("open_at", models.DateTimeField(blank=True, null=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("user", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="nearby_alert_pref", to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.CreateModel(
            name="MissingEvent",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("kind", models.CharField(max_length=24)),
                ("meta", models.JSONField(blank=True, default=dict)),
                ("at", models.DateTimeField(db_index=True, default=django.utils.timezone.now)),
                ("actor", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="+", to=settings.AUTH_USER_MODEL)),
                ("alert", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="events", to="core.missingalert")),
            ],
            options={
                "ordering": ["-id"],
                "indexes": [models.Index(fields=["actor", "kind", "at"], name="core_missev_actor_idx")],
            },
        ),
        migrations.CreateModel(
            name="MissingRecipient",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("source", models.CharField(default="home_area", max_length=12)),
                ("pushed_at", models.DateTimeField(blank=True, null=True)),
                ("end_pushed_at", models.DateTimeField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("alert", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="recipients", to="core.missingalert")),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="+", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "indexes": [models.Index(fields=["user", "created_at"], name="core_missrec_user_at_idx")],
                "constraints": [models.UniqueConstraint(fields=("alert", "user"), name="core_missing_recipient_once")],
            },
        ),
        migrations.CreateModel(
            name="MissingReport",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("reason", models.CharField(default="fake", max_length=16)),
                ("note", models.CharField(blank=True, default="", max_length=300)),
                ("counted", models.BooleanField(default=True)),
                ("status", models.CharField(default="open", max_length=10)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("alert", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="reports", to="core.missingalert")),
                ("reporter", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="+", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "ordering": ["-id"],
                "constraints": [models.UniqueConstraint(fields=("alert", "reporter"), name="core_missing_report_once")],
            },
        ),
        migrations.CreateModel(
            name="MissingTipThread",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("share_identity", models.BooleanField(default=False)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("last_at", models.DateTimeField(default=django.utils.timezone.now)),
                ("family_unread", models.PositiveSmallIntegerField(default=0)),
                ("tipster_unread", models.PositiveSmallIntegerField(default=0)),
                ("alert", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="tips", to="core.missingalert")),
                ("tipster", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="+", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "ordering": ["-last_at"],
                "constraints": [models.UniqueConstraint(fields=("alert", "tipster"), name="core_missing_tip_once")],
            },
        ),
        migrations.CreateModel(
            name="MissingTipMessage",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("by_family", models.BooleanField(default=False)),
                ("text", models.CharField(max_length=600)),
                ("lat", models.FloatField(blank=True, null=True)),
                ("lng", models.FloatField(blank=True, null=True)),
                ("at", models.DateTimeField(default=django.utils.timezone.now)),
                ("thread", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="messages", to="core.missingtipthread")),
            ],
            options={"ordering": ["at", "id"]},
        ),
    ]
