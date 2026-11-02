# circlea (2 Nov): My Circle "Family / Others" field on the Circle edge.
# "" = automatic (family relation / family or guardian link -> Family), so
# existing family-link data shows as Family with no data copy. Additive only.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0126_callsbar"),
    ]

    operations = [
        migrations.AddField(
            model_name="circlemember",
            name="circle_group",
            field=models.CharField(blank=True, default="", max_length=8),
        ),
    ]
