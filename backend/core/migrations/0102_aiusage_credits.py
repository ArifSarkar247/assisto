# pricing-40 (owner 27 Oct): credits charged for each successful AI call, so
# the daily alert can compute the REAL AI cost per credit (cost ÷ credits).
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0101_antitheft2_location_routing"),
    ]

    operations = [
        migrations.AddField(
            model_name="aiusage",
            name="credits_charged",
            field=models.IntegerField(default=0),
        ),
    ]
