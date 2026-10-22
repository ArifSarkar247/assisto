# x1-calls: CallSession.client_call_id (idempotent call placement).
# The integrator re-chains `dependencies` at merge time.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0058_f1_founders"),
    ]

    operations = [
        migrations.AddField(
            model_name="callsession",
            name="client_call_id",
            field=models.CharField(blank=True, db_index=True, default="",
                                   max_length=64),
        ),
    ]
