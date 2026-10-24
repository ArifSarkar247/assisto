# e2e-groups: E2GroupResendRequest (peer-assisted re-share for group chats).
# Additive only. The integrator re-chains `dependencies`.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0080_calls_health"),
    ]

    operations = [
        migrations.CreateModel(
            name="E2GroupResendRequest",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("key_id", models.CharField(default="", max_length=64)),
                ("whole", models.BooleanField(default=False)),
                ("message_ids", models.JSONField(blank=True, default=list)),
                ("reason", models.CharField(default="decrypt", max_length=16)),
                ("asks", models.IntegerField(default=0)),
                ("served_by", models.JSONField(blank=True, default=list)),
                ("notified_at", models.DateTimeField(blank=True, null=True)),
                ("fulfilled_at", models.DateTimeField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("group", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="e2_resend_requests", to="core.circlegroup")),
                ("requester", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="e2_group_resend_made",
                    to=settings.AUTH_USER_MODEL)),
            ],
            options={"unique_together": {("requester", "group", "key_id")}},
        ),
    ]
