from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0080_calls_health"),
    ]

    operations = [
        migrations.AddField(
            model_name="antitheftengine",
            name="device_hash",
            field=models.CharField(blank=True, db_index=True, default="",
                                   max_length=64),
        ),
    ]
