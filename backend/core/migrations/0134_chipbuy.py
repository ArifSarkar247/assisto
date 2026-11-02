# chipbuy (owner 2 Nov): small GPS tracker chip for a child's school bag /
# shoe on the existing vehicle tracker server. Additive only: VehicleTracker
# gets kind / child_name / child_user / battery_pct; SchoolPlan can be fed by
# a chip. The integrator renumbers this after the current leaf.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0133_journey100b"),
    ]

    operations = [
        migrations.AddField(
            model_name="vehicletracker",
            name="kind",
            field=models.CharField(choices=[("vehicle", "vehicle"), ("chip", "chip")],
                                   default="vehicle", max_length=8),
        ),
        migrations.AddField(
            model_name="vehicletracker",
            name="child_name",
            field=models.CharField(blank=True, default="", max_length=60),
        ),
        migrations.AddField(
            model_name="vehicletracker",
            name="child_user",
            field=models.ForeignKey(blank=True, null=True,
                                    on_delete=django.db.models.deletion.SET_NULL,
                                    related_name="tracker_chips_carried",
                                    to=settings.AUTH_USER_MODEL),
        ),
        migrations.AddField(
            model_name="vehicletracker",
            name="battery_pct",
            field=models.IntegerField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="schoolplan",
            name="chip",
            field=models.OneToOneField(blank=True, null=True,
                                       on_delete=django.db.models.deletion.SET_NULL,
                                       related_name="school_plan",
                                       to="core.vehicletracker"),
        ),
    ]
