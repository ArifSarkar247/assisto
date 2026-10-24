# connect-flow: CircleMember.connected_at (the "You are now connected" line +
# chat-list order on accept). Additive only. The integrator re-chains
# `dependencies`.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0083_ring_everywhere"),
    ]

    operations = [
        migrations.AddField(
            model_name="circlemember",
            name="connected_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
