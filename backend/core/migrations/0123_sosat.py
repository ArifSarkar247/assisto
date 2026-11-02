# sosat (2 Nov): SOS triggers that work without opening the app (lock-screen
# button, power button x5) and the experimental fall alert ride the existing
# anti-theft engine event table (new `kind` choices only — no data change),
# plus FamilyAlertDelivery.rerung_at for the SOS escalation ladder (an SOS
# nobody opened is rung once more). Additive only.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0122_kidswatch"),
    ]

    operations = [
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
                ("fall", "fall"), ("fall_ok", "fall_ok")], max_length=20),
        ),
        migrations.AddField(
            model_name="familyalertdelivery",
            name="rerung_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
