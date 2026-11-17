# flag-antitheft: the owner's grab sensitivity (low / normal / high).
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0171_cctvprice"),
    ]

    operations = [
        migrations.AddField(
            model_name="antitheftengine",
            name="snatch_sensitivity",
            field=models.CharField(default="normal", max_length=8),
        ),
    ]
