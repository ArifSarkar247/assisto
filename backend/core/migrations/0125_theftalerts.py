# theftalerts (2 Nov): the three theft alerts — a new engine event kind
# `admin_off` (device-admin turn-off requested / done: the step Android needs
# before Assisto can be uninstalled while protection is on) and the owner's
# switch to also alert his nominee(s). Additive only.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0124_placesafe"),
    ]

    operations = [
        migrations.AddField(
            model_name="antitheftengine",
            name="alert_nominee",
            field=models.BooleanField(default=False),
        ),
        migrations.AlterField(
            model_name="antitheftevent",
            name="kind",
            field=models.CharField(choices=[
                ("snatch", "snatch"), ("snatch_cleared", "snatch_cleared"),
                ("sim_change", "sim_change"), ("offline", "offline"),
                ("online", "online"), ("low_battery", "low_battery"),
                ("shutdown", "shutdown"), ("boot", "boot"),
                ("failed_unlock", "failed_unlock"),
                ("intruder_photo", "intruder_photo"), ("test", "test"),
                ("went_dark", "went_dark"),
                ("sos_lockscreen", "sos_lockscreen"), ("sos_power", "sos_power"),
                ("fall", "fall"), ("fall_ok", "fall_ok"),
                ("admin_off", "admin_off")], max_length=20),
        ),
    ]
