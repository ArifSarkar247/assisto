# calls-health: CallSession.push_sent + CallHealthEvent (setup failures for the
# Owner Admin call-health card). The integrator re-chains `dependencies`.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0079_photo_final"),
    ]

    operations = [
        migrations.AddField(
            model_name="callsession",
            name="push_sent",
            field=models.BooleanField(default=False),
        ),
        migrations.CreateModel(
            name="CallHealthEvent",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("step", models.CharField(max_length=16)),
                ("code", models.CharField(blank=True, default="", max_length=24)),
                ("source", models.CharField(default="server", max_length=8)),
                ("call_id", models.IntegerField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True, db_index=True)),
                ("user", models.ForeignKey(
                    blank=True, null=True,
                    on_delete=django.db.models.deletion.SET_NULL,
                    related_name="+", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ["-id"]},
        ),
    ]
