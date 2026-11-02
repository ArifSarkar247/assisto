# journey100b (2 Nov): JourneyRequest.outcome was max_length=16 but the
# one-tap stop writes "stopped_by_traveller" (20) — PostgreSQL refused it
# (HTTP 500 on POST /journey/requests/<id>/stop, caught by reality flow 16b;
# SQLite in unit tests does not enforce the length). Widen only.
# The integrator renumbers this after the current leaf.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0129_blood"),
    ]

    operations = [
        migrations.AlterField(
            model_name="journeyrequest",
            name="outcome",
            field=models.CharField(blank=True, default="", max_length=32),
        ),
    ]
