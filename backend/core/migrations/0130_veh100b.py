from django.db import migrations, models


class Migration(migrations.Migration):
    """veh100b: JT/T 808 tracker protocol choice (choices only, no data change)."""

    dependencies = [
        ("core", "0129_blood"),
    ]

    operations = [
        migrations.AlterField(
            model_name="vehicletracker",
            name="protocol",
            field=models.CharField(
                choices=[("auto", "auto"), ("gt06", "gt06"), ("teltonika", "teltonika"),
                         ("h02", "h02"), ("tk103", "tk103"), ("jt808", "jt808")],
                default="auto", max_length=10),
        ),
    ]
