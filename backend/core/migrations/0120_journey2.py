# journey2 (28 Oct): the traveller can turn the shared watcher link OFF, and
# owner idea 1 — guardian-requested journeys (JourneyRequest, a new table).
# Journey.web_gen is baked into the signed /j/<token>; bumping it kills every
# link handed out so far (a fresh one can be shared again). Additive only.

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0118_famcare"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AddField(
            model_name="journey",
            name="web_gen",
            field=models.IntegerField(default=0),
        ),
        migrations.CreateModel(
            name="JourneyRequest",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("destination", models.JSONField(blank=True, default=dict)),
                ("window_start", models.DateTimeField()),
                ("window_end", models.DateTimeField()),
                ("note", models.CharField(blank=True, default="", max_length=200)),
                ("status", models.CharField(default="pending", max_length=12)),
                ("standing", models.BooleanField(default=False)),
                ("schedule", models.JSONField(blank=True, default=dict)),
                ("nudged_at", models.DateTimeField(blank=True, null=True)),
                ("started_at", models.DateTimeField(blank=True, null=True)),
                ("arrived_at", models.DateTimeField(blank=True, null=True)),
                ("ended_at", models.DateTimeField(blank=True, null=True)),
                ("outcome", models.CharField(blank=True, default="", max_length=16)),
                ("log", models.JSONField(blank=True, default=list)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("journey", models.ForeignKey(blank=True, null=True,
                                              on_delete=django.db.models.deletion.SET_NULL,
                                              related_name="guardian_requests", to="core.journey")),
                ("requester", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE,
                                                related_name="journey_requests_sent",
                                                to=settings.AUTH_USER_MODEL)),
                ("traveller", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE,
                                                related_name="journey_requests_got",
                                                to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "ordering": ["-created_at"],
                "indexes": [models.Index(fields=["status", "window_start"],
                                         name="jreq_status_start")],
            },
        ),
    ]
